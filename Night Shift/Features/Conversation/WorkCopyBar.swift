import SwiftUI

/// Above a conversation that works in a copy: which copy, from where, and what to do with what is
/// in it. A run's conversation also says whose run it is, with the way back to the automation.
struct WorkCopyBar: View {
    @Environment(AppModel.self) private var model
    let chatID: UUID?

    @State private var status: WorkCopyStatus?
    @State private var showingChanges = false
    @State private var confirmingDiscard = false
    @State private var working = false
    @State private var problem: String?
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
                        if working { ProgressView().controlSize(.small) }
                        actions
                    }
                    .fixedSize(horizontal: !stacked, vertical: false)
                }
                if let problem {
                    Text(verbatim: problem)
                        .font(Typo.caption)
                        .foregroundStyle(Palette.orange)
                        .fixedSize(horizontal: false, vertical: true)
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
            .confirmationDialog(Text("Throw these changes away?"), isPresented: $confirmingDiscard,
                                titleVisibility: .visible) {
                Button("Discard changes", role: .destructive) { discard() }
                Button("Keep", role: .cancel) {}
            } message: {
                Text("The copy and its branch are deleted. Your folder is not touched.")
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
        if let copy, copy.isLive {
            Group {
                Button("Changes") { showingChanges = true }
                    .buttonStyle(.bulava(.quiet))
                Button { model.openCopy(copy.id) } label: { Image(systemName: "folder") }
                    .buttonStyle(.icon(size: 26, glyph: 11))
                    .help(Text("Show the copy in Finder"))
                    .accessibilityLabel(Text("Show the copy in Finder"))
                if status?.hasWork == true, !busy {
                    Button(String(format: String(localized: "Merge into %@"), copy.baseRef)) { merge() }
                        .buttonStyle(.bulava(.primary))
                        .disabled(busy || working)
                        .help(busy ? Text("Wait for it to finish") : Text("Moves your branch forward to this work"))
                }
                Button("Discard changes") { confirmingDiscard = true }
                    .buttonStyle(.bulava(.danger))
                    .disabled(busy || working)
            }
        }
    }

    private func refresh() async {
        guard let copy, copy.isLive else { status = nil; return }
        status = await model.copyStatus(copy.id)
    }

    private func merge() {
        guard let chatID else { return }
        working = true
        Task {
            if let run {
                problem = await model.mergeRun(run.id)
            } else {
                problem = await model.mergeChatCopy(chatID)
            }
            working = false
            if problem == nil {
                model.toast = ToastMessage(text: String(localized: "Merged. The copy is cleaned up."), kind: .info)
            }
            await refresh()
        }
    }

    private func discard() {
        guard let chatID else { return }
        working = true
        Task {
            if let run {
                problem = await model.discardRun(run.id)
            } else {
                problem = await model.discardChatCopy(chatID)
            }
            working = false
            await refresh()
        }
    }
}

/// Under the composer of a new chat: whether its work happens in his folder or in a copy of it.
/// Asked before the first message — a conversation does not move folders half way through.
struct WhereItWorksControl: View {
    @Environment(AppModel.self) private var model
    let productID: UUID
    let chatID: UUID?
    let folderName: String

    private var chat: Chat? { chatID.flatMap { model.conversations.chat(id: $0) } }
    private var fresh: Bool { chatID.map { model.conversations.entries(inChat: $0).isEmpty } ?? true }
    private var inCopy: Bool { chat?.wantsCopy == true || chat?.workCopyID != nil }

    var body: some View {
        if fresh, chat?.isAutomationRun != true {
            Menu {
                Picker("", selection: Binding(get: { inCopy }, set: { choose($0) })) {
                    Text(verbatim: String(format: String(localized: "In %@"), folderName)).tag(false)
                    Text("In a separate copy").tag(true)
                }
                .pickerStyle(.inline)
                .labelsHidden()
            } label: {
                label
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help(Text("A separate copy keeps this chat's changes off your folder until you merge them"))
        } else {
            label
        }
    }

    private var label: some View {
        HStack(spacing: 5) {
            Image(systemName: inCopy ? "arrow.triangle.branch" : "folder")
                .font(.system(size: 9, weight: .medium))
            Text(verbatim: inCopy ? String(format: String(localized: "%@ · separate copy"), folderName) : folderName)
        }
        .font(Typo.meta)
        .foregroundStyle(inCopy ? Palette.accent : Palette.textFaint)
        .lineLimit(1)
    }

    private func choose(_ copy: Bool) {
        let chat = model.conversations.currentChat(for: productID)
        model.conversations.setWantsCopy(copy, for: chat.id)
    }
}
