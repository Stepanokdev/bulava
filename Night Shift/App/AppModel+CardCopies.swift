import Foundation

/// Where a card's worker runs: its project folder, or a copy of it when the folder is busy.
///
/// One mechanism for every copy. A card started while its project was busy used to get a nested
/// `.nightshift-worktrees` checkout with no record, no lock and no owner — the sweep never saw
/// it, which is how one sat on disk for six weeks — and when making it failed the card quietly ran
/// in his folder after all. Now it is the same managed copy an automation run gets, and a copy
/// that cannot be made stops the start with the reason instead.
extension AppModel {

    enum CardFolder: Equatable {
        case folder(String)
        case refused(String)
    }

    /// The folder to start this card in. A recorded copy is used only if it is still there and
    /// still a checkout of the card's project; otherwise it is retired from the card, and a card
    /// that was continuing work inside it is refused rather than sent somewhere else.
    func prepareCardFolder(task: BacklogTask, projectPath path: String, isolated: Bool,
                           continuing: Bool) async -> CardFolder {
        if let recorded = task.worktree {
            if await cardCopyIsUsable(recorded, projectPath: path, taskID: task.id) { return .folder(recorded) }
            backlog.retireWorktree(task.id)
            if continuing {
                return .refused(String(localized: "The separate copy this task was working in is gone, so it cannot be continued there. Start the task again — it starts from what the folder holds now."))
            }
        }
        guard isolated else { return .folder(path) }
        switch await makeCardCopy(task: task, projectPath: path) {
        case .success(let copy):
            backlog.setWorktree(task.id, copy.path)
            return .folder(copy.path)
        case .failure(let refusal):
            return .refused(refusal.message)
        }
    }

    /// Whether a folder a card recorded is somewhere it may still run.
    func cardCopyIsUsable(_ folder: String, projectPath: String, taskID: UUID) async -> Bool {
        if let managed = automations.copies.first(where: {
            Slug.canonicalPath($0.path) == Slug.canonicalPath(folder)
        }) {
            // Ours, this card's, and a checkout of the repository the card is about now — a card
            // moved to another project does not keep working in the old one.
            guard managed.isLive, managed.owner == .task(taskID), await WorkCopies.isOurs(managed) else { return false }
            return await WorkCopies.isLinkedCheckout(managed.checkoutRoot, of: projectPath)
        }
        // A copy made before Bulava kept a record of them: still used for the card it belongs to,
        // but only while it is a checkout of this project's repository and not the repository itself.
        return await WorkCopies.isLinkedCheckout(folder, of: projectPath)
    }

    private func makeCardCopy(task: BacklogTask, projectPath path: String) async -> Result<WorkCopy, ChatCopyRefusal> {
        let id = UUID()
        guard let sourceRoot = await WorkCopies.topLevel(of: path) else {
            return .failure(ChatCopyRefusal(message: Self.copyProblem(.notARepository)))
        }
        let planned = WorkCopies.plannedCheckoutRoot(sourceRoot: sourceRoot, id: id)
        automations.addCopy(WorkCopy(id: id, path: planned, checkoutRoot: planned, sourcePath: path,
                                     sourceRoot: sourceRoot, projectID: task.projectID ?? UUID(),
                                     branch: "", baseRef: "", baseSHA: "", owner: .task(task.id),
                                     state: .preparing))
        // From the branch his folder is on, as the card's work always started: the card is about
        // what is in the folder now.
        let base = await WorkCopies.currentBranch(of: path)
        let made = await WorkCopies.make(sourcePath: path, projectID: task.projectID ?? UUID(), baseRef: base,
                                         branch: "night/task-\(task.id.uuidString.prefix(8))",
                                         owner: .task(task.id), id: id)
        switch made {
        case .success(let copy):
            automations.addCopy(copy)
            await readyForUnattendedWork(copy)
            return .success(copy)
        case .failure(let f):
            automations.updateCopy(id) { $0.state = .removed; $0.removedAt = Date() }
            return .failure(ChatCopyRefusal(message: Self.copyProblem(f)))
        }
    }

    /// A start refused before anything ran: the card goes back exactly as it was, and says why —
    /// in its product's conversation, in the activity list, and in a toast.
    func abandonCardStart(_ before: BacklogTask, reason: String) {
        backlog.restore(before)
        if let productID = productID(for: before) {
            conversations.postEventOnce(reason, productID: productID, tone: .problem, taskID: before.id)
        }
        note(.taskStateChanged, .problem,
             String(format: String(localized: "Did not start “%@” — no separate copy to work in"), before.title),
             detail: reason, projectPath: before.projectPath, taskID: before.id, link: .task(before.id))
        toast = ToastMessage(text: reason, kind: .error)
    }
}
