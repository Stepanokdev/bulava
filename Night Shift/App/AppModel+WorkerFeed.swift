import Foundation

extension AppModel {

    func syncWorkerFeeds() {
        var live: Set<UUID> = []

        for (task, productID, transcript) in followable() {
            live.insert(task.id)
            guard workerFeeds[task.id] == nil else { continue }
            let chat = chatShowing(task, productID: productID)
            let feed = WorkerFeed(taskID: task.id, productID: productID, chatID: chat,
                                  transcript: transcript, store: conversations)
            workerFeeds[task.id] = feed
            Trace.note("feed-start", task: task.id, chat: chat, file: transcript)
            feed.start()
        }

        for (id, feed) in workerFeeds where !live.contains(id) {

            feed.stop()
            workerFeeds[id] = nil
            Trace.note("feed-stop", task: id)
        }
    }

    private func followable() -> [(BacklogTask, UUID, URL)] {
        var candidates: [(BacklogTask, UUID, URL)] = []
        for task in backlog.tasks {

            let instance = liveInstance(for: task)
            let onShift = instance?.active == true || workState(of: task) == .running
            guard onShift, let productID = productID(for: task) else { continue }

            guard case .one(let transcript) = WorkerTrail.pickTranscript(for: task) else { continue }

            candidates.append((task, productID, transcript))
        }
        return Self.onePerTranscript(candidates)
    }

    nonisolated static func onePerTranscript<T>(_ candidates: [(BacklogTask, T, URL)]) -> [(BacklogTask, T, URL)] {
        var byFile: [String: (BacklogTask, T, URL)] = [:]
        for candidate in candidates {
            let file = candidate.2.resolvingSymlinksInPath().path
            if let held = byFile[file],
               (held.0.dispatchedAt ?? .distantPast) >= (candidate.0.dispatchedAt ?? .distantPast) { continue }
            byFile[file] = candidate
        }
        return Array(byFile.values)
    }

    func stopWorkerFeeds() {
        for (_, feed) in workerFeeds { feed.stop() }
        workerFeeds.removeAll()
    }
}
