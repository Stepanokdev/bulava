import SwiftUI

/// Under a message that stopped because the folder holds uncommitted work (engine exit 77).
///
/// The engine used to commit it all as `night-shift` and start. Now nothing is committed until the
/// director picks: leave the changes and start, commit them under their own name, or sort the folder
/// out their own way — while this row is up the folder is watched, and the message goes by itself
/// the moment it is clean. «Not now» is an exit that sends nothing later.
struct DirtyTreeRow: View {
    @Environment(AppModel.self) private var model
    let block: AppModel.DirtyTreeBlock
    let entryID: UUID
    let chatID: UUID

    @State private var expanded = false

    private var tree: DirtyTree { block.tree }

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "tray.full")
                    .font(.system(size: 12))
                    .foregroundStyle(Palette.orange)
                    .padding(.top, 1)
                VStack(alignment: .leading, spacing: 3) {
                    Text(tree.unborn ? LocalizedStringKey("This repository has no commits yet, so a run has nothing to measure its work against. The first commit is yours.") : LocalizedStringKey("This folder has uncommitted changes. They are as you left them, and nothing was committed."))
                        .font(Typo.caption)
                        .foregroundStyle(Palette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(tree.unborn ? LocalizedStringKey("Make it here, or in your own tool: the message goes out once there is a commit.") : LocalizedStringKey("Pick an option, or commit or stash them yourself. The message goes out once the folder is clean."))
                        .font(Typo.meta)
                        .foregroundStyle(Palette.textFaint)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            if !tree.files.isEmpty {
                DirtyFileList(tree: tree, limit: expanded ? nil : 5)
                    .padding(.leading, 22)
                if tree.total > 5 {
                    Button { withAnimation(Motion.snappy) { expanded.toggle() } } label: {
                        Text(expanded ? String(localized: "Show fewer")
                                      : String(format: String(localized: "and %lld more"), tree.total - 5))
                            .font(Typo.panelMeta)
                            .foregroundStyle(Palette.accentEmphasis)
                    }
                    .buttonStyle(.plain)
                    .padding(.leading, 22)
                }
            }

            if !block.waiting.isEmpty {
                Text("Earlier messages that stopped here go out too, in the order you wrote them.")
                    .font(Typo.meta)
                    .foregroundStyle(Palette.textFaint)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, 22)
            }

            if let problem = block.problem {
                Text(verbatim: AppModel.firstLine(problem))
                    .font(Typo.meta)
                    .foregroundStyle(Palette.red)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, 22)
            }

            HStack(spacing: 8) {
                if tree.keepPossible {
                    Button {
                        model.leaveChangesAndSend(entryID: entryID, in: chatID)
                    } label: {
                        Text("Start, leave my changes")
                    }
                    .buttonStyle(.bulava(.primary))
                    .help(Text("Your files and what you staged stay exactly as they are. A snapshot is kept to restore them from, and review counts only what the run changes."))
                }
                Button {
                    model.askToCommitAsMe(entryID: entryID, in: chatID)
                } label: {
                    Text(tree.unborn ? LocalizedStringKey("Make the first commit…") : LocalizedStringKey("Commit as me…"))
                }
                .buttonStyle(.bulava(tree.keepPossible ? .secondary : .primary))
                Button {
                    model.dismissDirtyTree(chatID: chatID)
                } label: {
                    Text("Not now")
                }
                .buttonStyle(.bulava(.quiet))
                Spacer(minLength: 8)
                HStack(spacing: 5) {
                    ProgressView().controlSize(.mini)
                    Text("Watching the folder")
                }
                .font(Typo.panelMeta)
                .foregroundStyle(Palette.textFaint)
                .help(Text(verbatim: block.folder))
            }
            .padding(.leading, 22)
        }
        .padding(11)
        .frame(maxWidth: 680, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: Metrics.radiusPanel, style: .continuous)
            .fill(Palette.orangeSoft))
        .animation(Motion.snappy, value: tree.digest)
    }
}

/// The files, the way `git status --short` shows them, with a letter for what happened to each.
struct DirtyFileList: View {
    let tree: DirtyTree
    var limit: Int?

    var body: some View {
        let shown = limit.map { Array(tree.files.prefix($0)) } ?? tree.files
        VStack(alignment: .leading, spacing: 2) {
            ForEach(shown) { entry in
                HStack(spacing: 7) {
                    Text(verbatim: Self.letter(entry.kind))
                        .font(Typo.mono(9.5).weight(.semibold))
                        .foregroundStyle(Self.tint(entry.kind))
                        .frame(width: 10, alignment: .center)
                        .help(Text(Self.kindName(entry.kind)))
                    Text(verbatim: entry.path)
                        .font(Typo.mono(9.5))
                        .foregroundStyle(Palette.textSecondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                }
            }
        }
    }

    static func letter(_ kind: DirtyTree.Entry.Kind) -> String {
        switch kind {
        case .modified: "M"
        case .added: "A"
        case .deleted: "D"
        case .renamed: "R"
        case .untracked: "+"
        case .conflicted: "!"
        }
    }

    static func tint(_ kind: DirtyTree.Entry.Kind) -> Color {
        switch kind {
        case .deleted, .conflicted: Palette.red
        case .untracked, .added: Palette.accentEmphasis
        default: Palette.orange
        }
    }

    static func kindName(_ kind: DirtyTree.Entry.Kind) -> LocalizedStringKey {
        switch kind {
        case .modified: "Changed"
        case .added: "Added"
        case .deleted: "Deleted"
        case .renamed: "Renamed"
        case .untracked: "New, not tracked by git yet"
        case .conflicted: "Unresolved merge conflict"
        }
    }
}

/// «Commit as me»: the director's own commit, made because they pressed for it.
///
/// Their name is on the screen before they press, so nobody learns afterwards whose it was. What
/// goes in is exactly the list — all of it, staged or not, which the sheet says when the two differ.
/// The engine checks the list again when the answer arrives and asks afresh if it changed.
struct CommitAsMeSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let request: AppModel.CommitAsMeRequest

    @State private var message: String
    @State private var review: Review = .reading
    /// Concerns are read, not merely shown: the button waits for this once there are any.
    @State private var concernsAcknowledged = false
    /// The person typed in the field — a suggestion that arrives later does not overwrite them.
    @State private var edited = false
    @FocusState private var focused: Bool

    /// The second look at what goes in, and where it stands.
    enum Review: Equatable {
        case reading
        case advised(CommitAdvisor.Advice)
        /// Something looks like a key. The engine would refuse the commit anyway; saying it here
        /// saves the press, and nothing was shown to a model.
        case secrets([String])
        case unavailable
    }

    init(request: AppModel.CommitAsMeRequest) {
        self.request = request
        _message = State(initialValue: request.tree.suggestedMessage)
    }

    private var tree: DirtyTree { request.tree }
    private var concerns: [String] {
        if case .advised(let advice) = review { return advice.concerns }
        return []
    }
    private var canCommit: Bool {
        guard tree.author != nil, !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return false }
        if case .secrets = review { return false }
        return concerns.isEmpty || concernsAcknowledged
    }
    private var confirmTitle: LocalizedStringKey {
        if case .task = request.target { return "Commit and start" }
        return "Commit and send"
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(tree.unborn ? LocalizedStringKey("The first commit") : LocalizedStringKey("A commit in your name"))
                    .font(Typo.cardTitle).foregroundStyle(Palette.text)
                Spacer()
                Button { dismiss() } label: { Image(systemName: "xmark") }
                    .buttonStyle(.icon)
                    .keyboardShortcut(.escape, modifiers: [])
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 13)
            .background(Palette.chrome)

            Hairline()

            VStack(alignment: .leading, spacing: 12) {
                if let author = tree.author {
                    HStack(spacing: 6) {
                        Image(systemName: "person.crop.circle").font(.system(size: 11))
                        Text(String(format: String(localized: "Author: %@"), author))
                    }
                    .font(Typo.caption)
                    .foregroundStyle(Palette.textSecondary)
                } else {
                    Text("Git does not know who you are here: user.name and user.email are not set. Set them, or start without committing.")
                        .font(Typo.caption)
                        .foregroundStyle(Palette.red)
                        .fixedSize(horizontal: false, vertical: true)
                }

                TextField("Commit message", text: Binding(get: { message },
                                                          set: { message = $0; edited = true }),
                          axis: .vertical)
                    .lineLimit(1...6)
                    .textFieldStyle(.plain)
                    .font(Typo.body)
                    .focused($focused)
                    .padding(10)
                    .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Palette.field))
                    .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(Palette.line, lineWidth: 1))

                reviewNote

                VStack(alignment: .leading, spacing: 6) {
                    // The count, because the list scrolls: fourteen files in a box that shows
                    // thirteen read as thirteen, and the fourteenth went into the commit unseen.
                    Text(tree.branch.isEmpty
                         ? String(format: String(localized: "%lld files, all in one commit."), tree.total)
                         : String(format: String(localized: "%lld files, all in one commit on “%@”."), tree.total, tree.branch))
                        .font(Typo.meta)
                        .foregroundStyle(Palette.textFaint)
                    if tree.hasStagedSplit {
                        Text("Some of it is staged and some is not. The commit takes all of it.")
                            .font(Typo.meta)
                            .foregroundStyle(Palette.orange)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    ScrollView {
                        DirtyFileList(tree: tree)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 180)
                    if tree.total > tree.files.count {
                        Text(String(format: String(localized: "and %lld more"), tree.total - tree.files.count))
                            .font(Typo.panelMeta)
                            .foregroundStyle(Palette.textFaint)
                    }
                }
            }
            .padding(16)

            Hairline()

            HStack(spacing: 8) {
                Spacer()
                Button { dismiss() } label: { Text("Cancel") }
                    .buttonStyle(.bulava(.quiet))
                Button { commit() } label: { Text(confirmTitle) }
                    .buttonStyle(.bulava(.primary))
                    .keyboardShortcut(.return, modifiers: [.command])
                    .disabled(!canCommit)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(Palette.chrome)
        }
        .frame(width: 520)
        .background(Palette.content)
        .onAppear { focused = true }
        .task { await readTheChanges() }
    }

    /// Under the field: what the second look is doing, or what it found.
    @ViewBuilder private var reviewNote: some View {
        switch review {
        case .reading:
            HStack(spacing: 7) {
                ProgressView().controlSize(.mini)
                Text("Claude is reading the changes to name the commit and check what goes in…")
            }
            .font(Typo.meta)
            .foregroundStyle(Palette.textFaint)
        case .advised(let advice) where advice.concerns.isEmpty:
            Label {
                Text("Claude wrote the title; change it if you like. Nothing here looks like it should stay out.")
            } icon: {
                Image(systemName: "checkmark.seal")
            }
            .font(Typo.meta)
            .foregroundStyle(Palette.textFaint)
        case .advised(let advice):
            VStack(alignment: .leading, spacing: 6) {
                Label {
                    Text("Worth a look before it goes in:")
                } icon: {
                    Image(systemName: "exclamationmark.triangle")
                }
                .font(Typo.caption.weight(.medium))
                .foregroundStyle(Palette.orange)
                ForEach(advice.concerns, id: \.self) { concern in
                    Text(verbatim: "• " + concern)
                        .font(Typo.caption)
                        .foregroundStyle(Palette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
                Toggle(isOn: $concernsAcknowledged) {
                    Text("I have checked. Commit it as it is")
                        .font(Typo.caption)
                }
                .toggleStyle(.checkbox)
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: Metrics.radiusPanel, style: .continuous)
                .fill(Palette.orangeSoft))
        case .secrets(let files):
            VStack(alignment: .leading, spacing: 4) {
                Text("These look like they hold a key or a password, so they will not be committed. Take them out or add them to .gitignore, or start without committing.")
                    .font(Typo.caption)
                    .foregroundStyle(Palette.red)
                    .fixedSize(horizontal: false, vertical: true)
                ForEach(files, id: \.self) { file in
                    Text(verbatim: file)
                        .font(Typo.mono(9.5))
                        .foregroundStyle(Palette.textSecondary)
                        .textSelection(.enabled)
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: Metrics.radiusPanel, style: .continuous)
                .fill(Palette.redSoft))
        case .unavailable:
            Text("Claude could not be asked for a title, so this one is Bulava's own. The commit works the same.")
                .font(Typo.meta)
                .foregroundStyle(Palette.textFaint)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// The same staging the commit will do, in a throwaway index; then, if nothing looks like a
    /// key, a model's title and second look. Whatever happens, committing stays possible.
    private func readTheChanges() async {
        guard let preview = await model.client.commitPreview(projectPath: request.folder) else {
            review = .unavailable
            return
        }
        if !preview.secrets.isEmpty { review = .secrets(preview.secrets); return }
        guard !preview.scanFailed, !preview.diff.isEmpty,
              let advice = await CommitAdvisor.advise(preview, languageName: model.explainLanguageName) else {
            review = .unavailable
            return
        }
        if Task.isCancelled { return }
        withAnimation(Motion.snappy) {
            review = .advised(advice)
            if !edited, !tree.unborn { message = CommitAdvisor.message(advice) }
        }
    }

    private func commit() {
        guard canCommit else { return }
        model.confirmCommitAsMe(request, message: message)
        dismiss()
    }
}

/// Where the question is asked when there is no message to put it under: a task card met uncommitted
/// work in its folder. «Not now» is an answer too, and it sends nothing later.
struct DirtyTreePrompts: ViewModifier {
    @Environment(AppModel.self) private var model

    func body(content: Content) -> some View {
        content
            .confirmationDialog(title, isPresented: presented, titleVisibility: .visible,
                                presenting: model.dirtyTreeAsk) { ask in
                if ask.tree.keepPossible {
                    Button { model.leaveChangesAndDispatch(ask) } label: { Text("Start, leave my changes") }
                }
                Button { model.askToCommitAsMe(ask) } label: {
                    Text(ask.tree.unborn ? LocalizedStringKey("Make the first commit…") : LocalizedStringKey("Commit as me…"))
                }
                Button { model.dispatchWhenClean(ask) } label: { Text("I’ll sort it out — start when it’s clean") }
                Button(role: .cancel) { model.dirtyTreeAsk = nil } label: { Text("Not now") }
            } message: { ask in
                Text(verbatim: Self.fileSummary(ask.tree))
            }
            .sheet(item: sheet) { request in
                CommitAsMeSheet(request: request)
            }
    }

    private var title: Text {
        Text(String(format: String(localized: "“%@” did not start: the folder has uncommitted changes. Nothing was committed."),
                    model.dirtyTreeAsk?.task.title ?? ""))
    }

    private var presented: Binding<Bool> {
        Binding(get: { model.dirtyTreeAsk != nil }, set: { if !$0 { model.dirtyTreeAsk = nil } })
    }

    private var sheet: Binding<AppModel.CommitAsMeRequest?> {
        Binding(get: { model.commitAsMe }, set: { if $0 == nil { model.commitAsMe = nil } })
    }

    static func fileSummary(_ tree: DirtyTree, limit: Int = 8) -> String {
        var lines = tree.files.prefix(limit).map { "\(DirtyFileList.letter($0.kind))  \($0.path)" }
        if tree.total > limit {
            lines.append(String(format: String(localized: "and %lld more"), tree.total - limit))
        }
        return lines.joined(separator: "\n")
    }
}
