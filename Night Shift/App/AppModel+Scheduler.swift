import SwiftUI

extension AppModel {

    func runScheduler() {
        guard !workItems.items.isEmpty else { return }
        preemptForUrgentWork()
        resumePreemptedWork()
        startUnblockedStreams()
    }

    // MARK: - Dependencies

    private func startUnblockedStreams() {
        for item in workItems.sorted {

            let finished = finishedStreamIDs(of: item)
            let running = runningStreamIDs(of: item)

            for stream in item.startable(finished: finished, alreadyRunning: running) {
                guard let task = backlog.task(id: stream.id) else { continue }

                guard task.dispatchedAt == nil, canDispatch(task) else { continue }

                guard !recentlyFailedToLaunch(task.id) else { continue }
                guard !item.preemptedStreamIDs.contains(stream.id) else { continue }

                if item.priority == .whenFree, !activeInstances.isEmpty { continue }

                dispatch(task: task, userInitiated: false)
            }
        }
    }

    private func finishedStreamIDs(of item: WorkItem) -> Set<UUID> {
        Set(item.streamIDs.filter { id in
            guard let task = backlog.task(id: id) else { return true }

            return task.state == .review || task.state == .approved || task.state == .merged
                || task.state == .closed
        })
    }

    private func runningStreamIDs(of item: WorkItem) -> Set<UUID> {
        Set(item.streamIDs.filter { id in
            guard let task = backlog.task(id: id) else { return false }
            return task.dispatchedAt != nil && !(task.state == .review
                || task.state == .approved || task.state == .merged || task.state == .failed
                || task.state == .closed)
        })
    }

    // MARK: - Preemption

    private func preemptForUrgentWork() {
        let urgent = workItems.items.filter {
            $0.priority == .urgent && !isItemFinished($0)
        }
        guard !urgent.isEmpty else { return }

        let blockedUrgentProjects: Set<String> = Set(urgent.flatMap { item -> [String] in
            let finished = finishedStreamIDs(of: item)
            let running = runningStreamIDs(of: item)
            return item.startable(finished: finished, alreadyRunning: running)
                .compactMap { backlog.task(id: $0.id)?.projectPath }
                .map { Slug.canonicalPath($0) }
        })
        guard !blockedUrgentProjects.isEmpty else { return }

        for item in workItems.items where item.priority > .urgent {
            for streamID in runningStreamIDs(of: item) {
                guard let task = backlog.task(id: streamID),
                      let path = task.projectPath,
                      blockedUrgentProjects.contains(Slug.canonicalPath(path)),
                      liveInstance(for: task) != nil,
                      !item.preemptedStreamIDs.contains(streamID) else { continue }

                workItems.markPreempted(streamID, in: item.id)

                pause(task: task)
                if let productID = productID(for: task) {
                    conversations.postEventOnce(
                        String(format: String(localized: "Paused “%@” to let urgent work through. It goes back in the queue automatically."),
                               task.title),
                        productID: productID, tone: .attention, taskID: task.id)
                }
            }
        }
    }

    private func resumePreemptedWork() {
        let urgentStillOpen = workItems.items.contains {
            $0.priority == .urgent && !isItemFinished($0)
        }
        guard !urgentStillOpen else { return }

        for item in workItems.items where !item.preemptedStreamIDs.isEmpty {
            for streamID in item.preemptedStreamIDs {
                guard let task = backlog.task(id: streamID) else {
                    workItems.clearPreempted(streamID); continue
                }

                if let path = task.projectPath, liveInstance(forProjectPath: path) != nil { continue }
                workItems.clearPreempted(streamID)
                if let productID = productID(for: task) {
                    conversations.postEventOnce(
                        String(format: String(localized: "Back to “%@” — the urgent work is done."), task.title),
                        productID: productID, tone: .neutral, taskID: task.id)
                }
                resume(task: task)
            }
        }
    }

    // MARK: - Item state

    func isItemFinished(_ item: WorkItem) -> Bool {
        !item.streams.isEmpty && item.streamIDs.allSatisfy { id in
            guard let task = backlog.task(id: id) else { return true }
            return task.state == .approved || task.state == .merged || task.state == .closed
        }
    }

    func isItemComplete(_ item: WorkItem) -> Bool {
        !item.streams.isEmpty && item.streamIDs.allSatisfy { id in
            guard let task = backlog.task(id: id) else { return true }
            return task.state == .review || task.state == .approved || task.state == .merged
        }
    }

    func allStreamsSettled(_ item: WorkItem) -> Bool {
        !item.streams.isEmpty && item.streamIDs.allSatisfy { id in
            guard let task = backlog.task(id: id) else { return true }
            return task.state == .review || task.state == .approved
                || task.state == .merged || task.state == .failed
        }
    }

    func failedStreamCount(_ item: WorkItem) -> Int {
        item.streamIDs.filter { backlog.task(id: $0)?.state == .failed }.count
    }

    func deliveredStreamCount(_ item: WorkItem) -> Int {
        item.streamIDs.filter {
            guard let s = backlog.task(id: $0)?.state else { return false }
            return s == .review || s == .approved || s == .merged
        }.count
    }

    func state(of item: WorkItem) -> WorkState {
        let outcomes: [WorkProgress.StreamOutcome] = item.streams.compactMap { stream in
            guard let task = backlog.task(id: stream.id) else { return nil }
            let s = task.state
            return WorkProgress.StreamOutcome(
                state: WorkProgress.state(task: task, instance: liveInstance(for: task)),
                settled: s == .review || s == .approved || s == .merged || s == .failed,
                delivered: s == .review || s == .approved || s == .merged,
                preempted: item.preemptedStreamIDs.contains(stream.id))
        }
        return WorkProgress.itemState(kind: item.kind, streams: outcomes)
    }

    func streamTasks(of item: WorkItem) -> [BacklogTask] {
        item.streams.compactMap { backlog.task(id: $0.id) }
    }
}
