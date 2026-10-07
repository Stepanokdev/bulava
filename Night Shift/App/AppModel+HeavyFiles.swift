import Foundation

/// Files too big for a checkpoint, met at the start of a run (engine exit 79).
///
/// A four-gigabyte screen recording lying untracked in a folder stopped every start there, and the
/// chat said so in red megabytes with nothing to press. Now the engine names the files and the chat
/// asks: leave them out of checkpoints and send — in the engine's own exclude, so nothing changes in
/// the project — or the same in the project's `.gitignore`, or not now. The message waits under the
/// row and goes out with the same retry every other answered question uses.
extension AppModel {

    /// Put the list under the message. Without a list there is nothing to offer, and the engine's
    /// words — which name no terminal command — are what is left to show.
    func stopOnHeavyFiles(chatID: UUID, entryID: UUID, folder: String,
                          keepChanges: Bool, fallback: String) async {
        guard let files = await client.heavyFiles(projectPath: folder), !files.files.isEmpty else {
            failChat(chatID, fallback.isEmpty ? String(localized: "The checkpoint would be too big, and I could not read which files make it so. Nothing was changed.") : fallback, .unexpected("chat.heavy_unreadable"))
            return
        }
        heavyFilesBlocked[chatID] = HeavyFilesBlock(entryID: entryID, folder: folder, files: files,
                                                    keepChanges: keepChanges)
        chatErrors[chatID] = nil
        toast = ToastMessage(text: files.canLeaveOut
                             ? String(localized: "A few big files would not fit in the checkpoint. Nothing was changed — choose what to do with them.")
                             : String(localized: "The checkpoint would be too big because of files git already tracks. Nothing was changed."),
                             kind: .info)
    }

    /// «Leave them out and send» (`.local`) or «Add to .gitignore and send» (`.gitignore`).
    ///
    /// The engine applies the rule to the list it wrote down itself, then the message is sent again:
    /// that start measures the folder afresh, so whatever is still too heavy — a tracked file, more
    /// files than were listed — comes back as a new list rather than as a failure.
    func leaveOutHeavyFiles(entryID: UUID, in chatID: UUID, rule: HeavyFilesRule) {
        guard var block = heavyFilesBlocked[chatID], block.entryID == entryID,
              !block.applying, block.files.canLeaveOut else { return }
        block.applying = true
        block.problem = nil
        heavyFilesBlocked[chatID] = block
        Task {
            let r = await client.leaveOutOfCheckpoints(projectPath: block.folder, rule: rule)
            guard heavyFilesBlocked[chatID]?.entryID == entryID else { return }
            guard r.ok else {
                block.applying = false
                block.problem = Self.firstLine(r.combined).isEmpty
                    ? String(localized: "Could not write the rule. Nothing was changed.")
                    : Self.firstLine(r.combined)
                heavyFilesBlocked[chatID] = block
                return
            }
            heavyFilesBlocked[chatID] = nil
            if block.keepChanges { dirtyTreeAnswer[chatID] = .keep }
            toast = ToastMessage(text: rule == .gitignore
                                 ? String(localized: "Added to .gitignore — sending your message.")
                                 : String(localized: "Left out of checkpoints — sending your message."),
                                 kind: .success)
            retryDirectMessage(entryID: entryID)
        }
    }

    /// «Not now»: the row goes and nothing is sent later. The message stays undelivered, with
    /// «Send again» beside it.
    func dismissHeavyFiles(chatID: UUID) {
        heavyFilesBlocked[chatID] = nil
    }
}
