import Foundation

extension AppModel {

    func hasSomethingToDecide(_ task: BacklogTask) -> Bool {
        if questionInstance(for: task)?.pendingQuestion != nil { return true }
        if let productID = productID(for: task),
           conversations.all(for: productID)
               .contains(where: { $0.kind == .question && $0.taskID == task.id }) { return true }
        if let blocker = task.externalBlocker,
           !blocker.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return true }
        return false
    }

    func workState(of task: BacklogTask) -> WorkState {
        WorkProgress.state(task: task, instance: liveInstance(for: task),
                           awaitingAnswer: hasSomethingToDecide(task))
    }

    func hasLiveTrail(for task: BacklogTask) -> Bool {
        conversations.entries.contains { entry in
            entry.taskID == task.id && entry.kind == .foreman
                && entry.blocks.contains { $0.kind == .activity }
        }
    }

    func showWorkerTrail(task: BacklogTask) {
        guard let productID = productID(for: task) else { return }
        guard task.projectPath != nil || task.worktree != nil else {
            postForemanText(String(localized: "This work has no folder on disk, so there is no trail to read."),
                            productID: productID)
            return
        }

        guard !hasLiveTrail(for: task) else { return }

        thinkingProductIDs.insert(productID)
        let run = task
        Task { [weak self] in

            let trail = await Task.detached(priority: .userInitiated) {
                WorkerTrail.read(task: run)
            }.value
            guard let self else { return }
            self.thinkingProductIDs.remove(productID)

            guard !trail.isEmpty else {

                self.postForemanText(self.noTrailReason(trail, task: run), productID: productID)
                return
            }

            var blocks: [ConversationBlock] = []
            blocks.append(.markdown(id: Self.trailHeadBlockID, Self.trailCaption(trail)))
            blocks += trail.blocks
            if let said = trail.lastSaid, !said.isEmpty {
                blocks.append(.markdown(id: "trail-said",
                                        String(localized: "The last thing it said:") + "\n\n"
                                        + String(said.prefix(1500))))
            }

            var entry = ConversationEntry(productID: productID, kind: .foreman,
                                          text: Self.trailCaption(trail), blocks: blocks,
                                          taskID: task.id)
            entry.chatID = self.conversations.currentChatID(for: productID)
            self.conversations.append(entry)
        }
    }

    func noTrailReason(_ trail: WorkerTrail.Trail, task: BacklogTask) -> String {
        if trail.miss == .ambiguous {
            return String(localized: "More than one session was running in this project at the time, and I cannot tell which one was this run — so I will not guess at its trail.")
        }
        if let dispatched = task.dispatchedAt {
            return String(format: String(localized: "This run started at %@ and never wrote a single step — its task most likely never reached the worker. Running it again is the fix."),
                          Fmt.clock(dispatched))
        }
        return String(localized: "I cannot find the session log for this run — there is no trail to show.")
    }

    nonisolated static func trailCaption(_ trail: WorkerTrail.Trail) -> String {
        let head = String(localized: "What it did while you were away:")
        guard trail.omitted > 0 else { return head }
        return head + " " + String(format: String(localized: "%@ earlier steps are past the window"),
                                   String(trail.omitted))
    }

    nonisolated static let trailHeadBlockID = "trail-head"
}
