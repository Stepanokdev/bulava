import SwiftUI

/// Under a message that stopped because the checkpoint would be too big (engine exit 79).
///
/// What the director saw before was the engine's paragraph in red — megabytes, a limit, a `.git`
/// that was taken away — and nothing to press, though the remedy was plain from the paragraph: do
/// not take that one recording. Now the files are listed, biggest first, and leaving them out is
/// the first button. A file git already tracks cannot be left out by a rule, and the row says so
/// instead of offering what would not work.
struct HeavyFilesRow: View {
    @Environment(AppModel.self) private var model
    let block: AppModel.HeavyFilesBlock
    let entryID: UUID
    let chatID: UUID

    @State private var expanded = false

    private var files: HeavyFiles { block.files }

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "externaldrive.badge.exclamationmark")
                    .font(.system(size: 12))
                    .foregroundStyle(Palette.orange)
                    .padding(.top, 1)
                VStack(alignment: .leading, spacing: 3) {
                    Text(verbatim: Self.headline(files))
                        .font(Typo.caption)
                        .foregroundStyle(Palette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if files.canLeaveOut {
                        Text("Leaving them out changes nothing in the project: git just stops offering them for commits here.")
                            .font(Typo.meta)
                            .foregroundStyle(Palette.textFaint)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }

            HeavyFileList(files: files.files, limit: expanded ? nil : 5)
                .padding(.leading, 22)
            if files.files.count > 5 {
                Button { withAnimation(Motion.snappy) { expanded.toggle() } } label: {
                    Text(expanded ? String(localized: "Show fewer")
                                  : String(format: String(localized: "and %lld more"), files.files.count - 5))
                        .font(Typo.panelMeta)
                        .foregroundStyle(Palette.accentEmphasis)
                }
                .buttonStyle(.plain)
                .padding(.leading, 22)
            }

            if let note = Self.trackedNote(files) {
                Text(verbatim: note)
                    .font(Typo.meta)
                    .foregroundStyle(Palette.orange)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, 22)
            }

            if let problem = block.problem {
                Text(verbatim: problem)
                    .font(Typo.meta)
                    .foregroundStyle(Palette.red)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, 22)
            }

            HStack(spacing: 8) {
                if files.canLeaveOut {
                    Button {
                        model.leaveOutHeavyFiles(entryID: entryID, in: chatID, rule: .local)
                    } label: {
                        Text("Leave out of the checkpoint and send")
                    }
                    .buttonStyle(.bulava(.primary))
                    .help(Text("The rule goes into git’s local exclude list for this folder, not into your files. The files stay where they are."))
                    Button {
                        model.leaveOutHeavyFiles(entryID: entryID, in: chatID, rule: .gitignore)
                    } label: {
                        Text("Add to .gitignore and send")
                    }
                    .buttonStyle(.bulava(.secondary))
                    .help(Text("The same rule in the project’s .gitignore. That file is yours, so it will show up as a change."))
                }
                Button {
                    model.dismissHeavyFiles(chatID: chatID)
                } label: {
                    Text("Not now")
                }
                .buttonStyle(.bulava(.quiet))
                if block.applying {
                    ProgressView().controlSize(.mini)
                }
                Spacer(minLength: 8)
            }
            .disabled(block.applying)
            .padding(.leading, 22)
        }
        .padding(11)
        .frame(maxWidth: 680, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: Metrics.radiusPanel, style: .continuous)
            .fill(Palette.orangeSoft))
    }

    /// What the checkpoint would have cost, against which limit. Shared with the phone's card.
    static func headline(_ files: HeavyFiles) -> String {
        if files.totalBytes > files.limitBytes {
            return String(format: String(localized: "With these files the checkpoint would take %1$@, over its %2$@ limit. They are where you left them, and nothing was changed."),
                          Fmt.bytes(Int(files.totalBytes)), Fmt.bytes(Int(files.limitBytes)))
        }
        return String(format: String(localized: "A file here is bigger than a checkpoint takes in one piece (%@). It is where you left it, and nothing was changed."),
                      Fmt.bytes(Int(files.fileLimitBytes)))
    }

    /// Why the buttons will not be enough, when they will not.
    static func trackedNote(_ files: HeavyFiles) -> String? {
        if !files.tracked.isEmpty {
            var note = String(localized: "Git already tracks the files marked “in git”, and a rule cannot leave them out. Commit them yourself or move them out of the folder.")
            if !files.fitsAfter, files.canLeaveOut {
                note += " " + String(localized: "Even with the rest left out, the checkpoint would still be too big.")
            }
            return note
        }
        if !files.fitsAfter { return String(localized: "There are more big files. The rest will be listed after these.") }
        return nil
    }
}

/// The files, biggest first: the name, the folder it lies in, its size, and whether git tracks it.
struct HeavyFileList: View {
    let files: [HeavyFiles.File]
    var limit: Int?

    var body: some View {
        let shown = limit.map { Array(files.prefix($0)) } ?? files
        VStack(alignment: .leading, spacing: 3) {
            ForEach(shown) { file in
                HStack(spacing: 7) {
                    Text(verbatim: file.name)
                        .font(Typo.mono(9.5))
                        .foregroundStyle(Palette.textSecondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                        .layoutPriority(1)
                    if !file.folder.isEmpty {
                        Text(verbatim: file.folder)
                            .font(Typo.mono(9.5))
                            .foregroundStyle(Palette.textFaint)
                            .lineLimit(1)
                            .truncationMode(.head)
                    }
                    Spacer(minLength: 6)
                    if file.tracked {
                        Text("in git")
                            .font(Typo.tag)
                            .foregroundStyle(Palette.textSecondary)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 2)
                            .background(Capsule().fill(Palette.panelRaised))
                            .help(Text("Git already tracks this file"))
                    }
                    Text(verbatim: Fmt.bytes(Int(file.size)))
                        .font(Typo.mono(9.5).weight(.semibold))
                        .monospacedDigit()
                        .foregroundStyle(Palette.orange)
                }
                .help(Text(verbatim: file.path))
            }
        }
        .frame(maxWidth: 520, alignment: .leading)
    }
}
