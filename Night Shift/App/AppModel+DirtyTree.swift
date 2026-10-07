import Foundation

/// The director's uncommitted work, met at the start of a run.
///
/// The engine used to commit it all silently — `git add -A`, as `night-shift`, into the branch the
/// director was on — and a fix Claude Code had just made in another window reached a merge request
/// under a name that described nothing. Now the engine stops (exit 77) and this is the answer, in
/// three shapes: leave the changes exactly where they are and start; commit them under the
/// director's own name, with a message they wrote; or let the director sort the folder out their own
/// way — commit, stash, merge, throw away — and carry on by itself the moment it is clean.
extension AppModel {

    // MARK: A chat message that stopped on the question

    /// Put the question under the message and start watching the folder.
    func stopOnDirtyTree(chatID: UUID, entryID: UUID, folder: String,
                         tree known: DirtyTree? = nil, problem: String? = nil) async {
        guard let tree = await resolvedTree(known, folder: folder) else {
            failChat(chatID, String(localized: "There are uncommitted changes in this folder, and I could not read them. Nothing was committed."), .unexpected("chat.dirty_unreadable"))
            return
        }
        // Even if it was sorted out in the second it took to ask, the send is still unwinding here;
        // the watcher's first look, a few seconds on, is what sends it.
        // A second message sent while the first was still waiting stopped on the same question. It
        // takes the row, and the earlier one is carried along rather than left undelivered in silence.
        let earlier = (dirtyTreeBlocked[chatID]?.held ?? []).filter {
            $0 != entryID && conversations.entry(id: $0)?.delivery == .failed
        }
        dirtyTreeBlocked[chatID] = DirtyTreeBlock(entryID: entryID, folder: folder, tree: tree,
                                                  problem: problem, waiting: earlier)
        chatErrors[chatID] = nil
        toast = ToastMessage(text: problem.map { Self.firstLine($0) }
                             ?? String(localized: "The folder has uncommitted changes. Nothing was committed — choose what to do with them."),
                             kind: problem == nil ? .info : .error)
        watchDirtyTree(key: "chat:\(chatID)", folder: folder, onChange: { [weak self] fresh in
            guard let self, var block = self.dirtyTreeBlocked[chatID], block.entryID == entryID else { return }
            block.tree = fresh
            self.dirtyTreeBlocked[chatID] = block
        }, onClean: { [weak self] in
            // Exactly once: the block is the ticket, and it is taken before anything is sent.
            guard let self, let block = self.dirtyTreeBlocked[chatID], block.entryID == entryID else { return }
            self.dirtyTreeBlocked[chatID] = nil
            self.toast = ToastMessage(text: String(localized: "The folder is clean — sending your message."), kind: .success)
            self.sendHeldMessages(block.held, in: chatID)
        })
    }

    /// «Start, leave my changes»: the engine snapshots them to measure the run against and to
    /// restore from, and touches nothing the director can see.
    func leaveChangesAndSend(entryID: UUID, in chatID: UUID) {
        guard let block = dirtyTreeBlocked[chatID], block.entryID == entryID, block.tree.keepPossible else { return }
        dirtyTreeAnswer[chatID] = .keep
        sendHeldMessages(block.held, in: chatID)
    }

    /// Send the held messages in the order they were written. The first one carries the answer and
    /// starts the run; each next one waits until the one before it has been handed over. If the
    /// first stops on a question again, the rest stay held with it rather than piling up behind it.
    func sendHeldMessages(_ ids: [UUID], in chatID: UUID) {
        guard let first = ids.first else { return }
        retryDirectMessage(entryID: first)
        let rest = Array(ids.dropFirst())
        guard !rest.isEmpty else { return }
        Task { [weak self] in
            for id in rest {
                while let self, self.sendingChatIDs.contains(chatID) {
                    try? await Task.sleep(for: .milliseconds(200))
                }
                guard let self else { return }
                if var block = self.dirtyTreeBlocked[chatID] {
                    block.waiting = (block.waiting + rest).filter { $0 != block.entryID }
                    self.dirtyTreeBlocked[chatID] = block
                    return
                }
                if self.mcpBlocked[chatID] != nil || self.heavyFilesBlocked[chatID] != nil
                    || self.chatErrors[chatID] != nil { return }
                self.retryDirectMessage(entryID: id)
            }
        }
    }

    func askToCommitAsMe(entryID: UUID, in chatID: UUID) {
        guard let block = dirtyTreeBlocked[chatID], block.entryID == entryID else { return }
        commitAsMe = CommitAsMeRequest(target: .chat(entryID: entryID, chatID: chatID),
                                       folder: block.folder, tree: block.tree)
    }

    /// «Not now»: the row goes, the watching stops, and nothing is sent later behind their back.
    /// The message stays undelivered, with «Send again» beside it.
    func dismissDirtyTree(chatID: UUID) {
        dirtyTreeBlocked[chatID] = nil
        dirtyTreeAnswer[chatID] = nil
        stopDirtyTreeWatch("chat:\(chatID)")
    }

    /// The sheet's answer. The digest goes with it, so the engine commits the files that were on the
    /// screen and asks again if the folder changed in between.
    func confirmCommitAsMe(_ request: CommitAsMeRequest, message: String) {
        commitAsMe = nil
        let answer = DirtyTreeChoice.commit(message: message, digest: request.tree.digest)
        switch request.target {
        case .chat(let entryID, let chatID):
            guard let block = dirtyTreeBlocked[chatID], block.entryID == entryID else { return }
            dirtyTreeAnswer[chatID] = answer
            sendHeldMessages(block.held, in: chatID)
        case .task(let task):
            dirtyTaskAnswer[task.id] = answer
            launchFailures[task.id] = nil
            dispatch(task: backlog.task(id: task.id) ?? task)
        }
    }

    // MARK: A task card that stopped on the question

    func stopDispatchOnDirtyTree(task: BacklogTask, folder: String) async -> Bool {
        guard let tree = await client.dirtyState(projectPath: folder) else { return false }
        let ask = DirtyTreeAsk(task: task, folder: folder, tree: tree)
        // Already sorted out: nothing to ask. Not dispatched from here — this dispatch is still
        // unwinding and holds the project — but on the watcher's first look.
        if tree.isSettled {
            dispatchWhenClean(ask)
            return true
        }
        dirtyTreeAsk = ask
        note(.taskStateChanged, .info, "Незакомічені зміни в теці: «\(task.title)» чекає на рішення",
             detail: tree.files.prefix(12).map { "\($0.xy) \($0.path)" }.joined(separator: "\n"),
             projectPath: folder, taskID: task.id, link: .task(task.id))
        return true
    }

    func leaveChangesAndDispatch(_ ask: DirtyTreeAsk) {
        dirtyTreeAsk = nil
        dirtyTaskAnswer[ask.task.id] = .keep
        launchFailures[ask.task.id] = nil
        dispatch(task: backlog.task(id: ask.task.id) ?? ask.task)
    }

    func askToCommitAsMe(_ ask: DirtyTreeAsk) {
        dirtyTreeAsk = nil
        commitAsMe = CommitAsMeRequest(target: .task(ask.task), folder: ask.folder, tree: ask.tree)
    }

    /// «I will sort it out»: the task starts by itself once the folder is clean.
    func dispatchWhenClean(_ ask: DirtyTreeAsk) {
        dirtyTreeAsk = nil
        let taskID = ask.task.id
        dirtyTaskWaiting[taskID] = ask.folder
        if let productID = productID(for: ask.task) {
            conversations.postEventOnce(
                String(format: String(localized: "“%@” starts as soon as the folder has no uncommitted changes."), ask.task.title),
                productID: productID, tone: .neutral, taskID: taskID)
        }
        watchDirtyTree(key: "task:\(taskID)", folder: ask.folder, onChange: { _ in }, onClean: { [weak self] in
            guard let self, self.dirtyTaskWaiting.removeValue(forKey: taskID) != nil else { return }
            self.launchFailures[taskID] = nil
            self.toast = ToastMessage(text: String(format: String(localized: "The folder is clean — starting “%@”."), ask.task.title),
                                      kind: .success)
            self.dispatch(task: self.backlog.task(id: taskID) ?? ask.task)
        })
    }

    /// A dispatch the director started by hand replaces any waiting one.
    func forgetDirtyTreeWait(taskID: UUID) {
        dirtyTaskWaiting[taskID] = nil
        stopDirtyTreeWatch("task:\(taskID)")
    }

    // MARK: Watching

    /// Re-reads the folder every few seconds while the director sorts it out in their own tool.
    /// Bounded: a row nobody comes back to stops watching after a few hours, and the message simply
    /// stays undelivered.
    func watchDirtyTree(key: String, folder: String,
                        onChange: @escaping (DirtyTree) -> Void,
                        onClean: @escaping () -> Void) {
        dirtyTreeWatchers[key]?.cancel()
        dirtyTreeWatchers[key] = Task { [weak self] in
            let deadline = Date().addingTimeInterval(Self.dirtyTreeWatchLimit)
            var seen: String?
            while !Task.isCancelled, Date() < deadline {
                try? await Task.sleep(for: Self.dirtyTreePollInterval)
                guard !Task.isCancelled, let self else { return }
                guard let tree = await self.client.dirtyState(projectPath: folder), !Task.isCancelled else { continue }
                if tree.isSettled {
                    self.dirtyTreeWatchers[key] = nil
                    onClean()
                    return
                }
                if tree.digest != seen { seen = tree.digest; onChange(tree) }
            }
        }
    }

    func stopDirtyTreeWatch(_ key: String) {
        dirtyTreeWatchers.removeValue(forKey: key)?.cancel()
    }

    nonisolated static let dirtyTreePollInterval: Duration = .seconds(3)
    nonisolated static let dirtyTreeWatchLimit: TimeInterval = 4 * 3600

    private func resolvedTree(_ known: DirtyTree?, folder: String) async -> DirtyTree? {
        if let known { return known }
        return await client.dirtyState(projectPath: folder)
    }

    nonisolated static func firstLine(_ text: String) -> String {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.split(whereSeparator: \.isNewline).first.map(String.init) ?? t
    }
}
