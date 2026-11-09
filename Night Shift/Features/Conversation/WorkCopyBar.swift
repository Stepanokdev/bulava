import SwiftUI

/// Above a conversation that works in a copy: which copy, from where, and what to do with what is
/// in it. A run's conversation also says whose run it is, with the way back to the automation.
struct WorkCopyBar: View {
    @Environment(AppModel.self) private var model
    let chatID: UUID?

    @State private var status: WorkCopyStatus?
    @State private var showingChanges = false
    @State private var width: CGFloat = 0

    private var chat: Chat? { chatID.flatMap { model.conversations.chat(id: $0) } }
    private var copy: WorkCopy? { chat?.workCopyID.flatMap { model.automations.copy(id: $0) } }
    private var run: AutomationRun? { chat?.automationRunID.flatMap { model.automations.run(id: $0) } }
    private var automation: Automation? { run.flatMap { model.automations.automation(id: $0.automationID) } }
    private var busy: Bool { model.isDirectChatBusy(chatID) }

    var body: some View {
        if let chat, chat.isAutomationRun || chat.workCopyID != nil {
            VStack(alignment: .leading, spacing: 6) {
                // In a narrow conversation the buttons go under the line, and wrap, instead of
                // crushing it.
                let stacked = width > 0 && width < 560
                let layout = stacked ? AnyLayout(VStackLayout(alignment: .leading, spacing: 8))
                                     : AnyLayout(HStackLayout(spacing: 10))
                layout {
                    HStack(spacing: 10) {
                        Image(systemName: "arrow.triangle.branch")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(Palette.accentEmphasis)
                        VStack(alignment: .leading, spacing: 1) {
                            if let automation {
                                Button { model.navigate(to: .automation(automation.id)) } label: {
                                    Text(verbatim: String(format: String(localized: "A run of “%@”"), automation.name))
                                        .font(Typo.rowLabel)
                                        .foregroundStyle(Palette.text)
                                }
                                .buttonStyle(.plain)
                                .help(Text("Open the automation"))
                            }
                            Text(verbatim: placeLine)
                                .font(Typo.caption)
                                .foregroundStyle(Palette.textTertiary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                    }
                    if !stacked { Spacer(minLength: 8) }
                    WrappingHStack(horizontalSpacing: 6, verticalSpacing: 6, maximumUnproposedWidth: .infinity) {
                        actions
                    }
                    .fixedSize(horizontal: !stacked, vertical: false)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 9)
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
            .background(Palette.panelMuted.opacity(0.92))
            .overlay(alignment: .bottom) { Hairline() }
            .task(id: "\(copy?.id.uuidString ?? "-")-\(busy)") { await refresh() }
            .sheet(isPresented: $showingChanges) {
                if let copy { CopyChangesSheet(copy: copy, run: run) }
            }
        }
    }

    private var placeLine: String {
        guard let copy, copy.isLive else {
            return String(localized: "Its copy has been cleaned up. What it did is in the conversation below.")
        }
        var line = String(format: String(localized: "Working in a separate copy on %@, from %@"), copy.branch, copy.baseRef)
        if let status, status.inspected {
            if status.hasWork {
                line += " · " + Fmt.count("%lld changes", status.uncommitted.count + status.commitsAhead)
            } else {
                line += " · " + String(localized: "nothing changed yet")
            }
        }
        return line
    }

    @ViewBuilder private var actions: some View {
        // The copy's status and a way to look inside it. Resolving it — merge, discard, mark done —
        // now lives beneath the last answer (ChatOutcomeActions), where every end-of-work action is
        // gathered in one place, so it is not offered twice.
        if let copy, copy.isLive {
            Button("Changes") { showingChanges = true }
                .buttonStyle(.bulava(.quiet))
            Button { model.openCopy(copy.id) } label: { Image(systemName: "folder") }
                .buttonStyle(.icon(size: 26, glyph: 11))
                .help(Text("Show the copy in Finder"))
                .accessibilityLabel(Text("Show the copy in Finder"))
        }
    }

    private func refresh() async {
        guard let copy, copy.isLive else { status = nil; return }
        status = await model.copyStatus(copy.id)
    }
}

/// Under the composer: which of the product's folders this chat works in, and — before the first
/// message — whether in that folder or in a copy of it.
///
/// The folder is the chat's own. The product's default is only where a new chat starts, and for a
/// product of several folders that is often the heaviest one: the check after every answer runs in
/// the chat's folder, so a chat about one small repository should not have to run a monorepo's
/// suite. Before the first message the choice costs nothing. After it the chat moves — the agent's
/// session belongs to the folder it was started in — so that is asked first.
struct WhereItWorksControl: View {
    @Environment(AppModel.self) private var model
    let productID: UUID
    let chatID: UUID?

    /// A folder chosen in a chat that already has a conversation, waiting for him to confirm.
    @State private var pendingMove: ChatFolderChoice?

    private var chat: Chat? { chatID.flatMap { model.conversations.chat(id: $0) } }
    private var fresh: Bool { chatID.map { model.conversations.entries(inChat: $0).isEmpty } ?? true }
    private var inCopy: Bool { chat?.wantsCopy == true || chat?.workCopyID != nil }
    private var choices: [ChatFolderChoice] { model.chatFolderChoices(productID: productID) }
    private var folder: Project? { model.chatFolder(productID: productID, chatID: chatID) }
    private var lock: ChatFolderMove.Lock? { model.chatFolderLock(chatID: chatID) }
    private var moving: Bool { chatID.map { model.movingChatFolders.contains($0) } ?? false }

    private var folderName: String {
        guard let folder else { return String(localized: "Choose a project folder") }
        return choices.first { $0.id == folder.id }?.name ?? folder.name
    }

    /// More than one folder, in a chat whose folder is its own to choose.
    private var offersFolders: Bool {
        choices.count > 1 && lock != .inCopy && lock != .automationRun
    }
    private var offersCopy: Bool { fresh && chat?.isAutomationRun != true }

    var body: some View {
        Group {
            if (offersFolders || offersCopy) && !moving {
                Menu {
                    menu
                } label: {
                    label
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help(Text(help))
            } else {
                label
            }
        }
        .confirmationDialog(Text(String(format: String(localized: "Move this chat to “%@”?"),
                                        pendingMove?.name ?? "")),
                            isPresented: Binding(get: { pendingMove != nil },
                                                 set: { if !$0 { pendingMove = nil } }),
                            titleVisibility: .visible, presenting: pendingMove) { choice in
            Button { apply(choice) } label: { Text("Move") }
            Button(role: .cancel) { pendingMove = nil } label: { Text("Cancel") }
        } message: { choice in
            Text(String(format: String(localized: "The conversation stays here. The agent starts a new session in “%@” and gets the last messages of this chat. Its session in “%@” ends, along with anything it left running there."),
                        choice.name, folderName))
        }
    }

    @ViewBuilder private var menu: some View {
        if offersFolders {
            Section {
                Picker("", selection: Binding(get: { folder?.id }, set: { chooseFolder($0) })) {
                    ForEach(choices) { choice in
                        // The lock is the product's own mark for "ask before editing": choosing such
                        // a folder makes it where the chat works, never somewhere it may write freely.
                        Label(choice.name, systemImage: choice.asksBeforeEditing ? "lock" : "folder")
                            .tag(Optional(choice.id))
                    }
                }
                .pickerStyle(.inline)
                .labelsHidden()
                .disabled(lock == .working)
                if lock == .working {
                    Text("You can change the folder once the agent has finished")
                }
            } header: {
                Text("Folder")
            }
        }
        if offersCopy {
            Section {
                Picker("", selection: Binding(get: { inCopy }, set: { chooseCopy($0) })) {
                    Text(verbatim: String(format: String(localized: "In %@"), folderName)).tag(false)
                    Text("In a separate copy").tag(true)
                }
                .pickerStyle(.inline)
                .labelsHidden()
            }
        }
    }

    private var label: some View {
        HStack(spacing: 5) {
            if moving {
                ProgressView()
                    .controlSize(.mini)
                    .frame(width: 10, height: 10)
            } else {
                Image(systemName: inCopy ? "arrow.triangle.branch" : "folder")
                    .font(.system(size: 9, weight: .medium))
            }
            Text(verbatim: inCopy ? String(format: String(localized: "%@ · separate copy"), folderName) : folderName)
        }
        .font(Typo.meta)
        .foregroundStyle(inCopy ? Palette.accent : Palette.textFaint)
        .lineLimit(1)
    }

    private var help: String {
        switch (offersFolders, offersCopy) {
        case (true, true):
            return String(localized: "Choose the folder this chat works in, or a separate copy of it. The check after each answer runs in that folder.")
        case (true, false):
            return String(localized: "Choose the folder this chat works in. The check after each answer runs in that folder.")
        default:
            return String(localized: "A separate copy keeps this chat's changes off your folder until you merge them")
        }
    }

    private func chooseFolder(_ id: UUID?) {
        guard let id, id != folder?.id, let choice = choices.first(where: { $0.id == id }) else { return }
        if model.chatHasConversation(chatID) {
            pendingMove = choice
        } else {
            apply(choice)
        }
    }

    private func apply(_ choice: ChatFolderChoice) {
        pendingMove = nil
        let chatID = self.chatID, productID = self.productID
        _Concurrency.Task {
            if let problem = await model.chooseChatFolder(choice.id, productID: productID, chatID: chatID) {
                model.toast = ToastMessage(text: problem, kind: .error)
            }
        }
    }

    private func chooseCopy(_ copy: Bool) {
        let chat = model.conversations.currentChat(for: productID)
        model.conversations.setWantsCopy(copy, for: chat.id)
    }
}
