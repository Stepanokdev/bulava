import SwiftUI
import Observation

@MainActor
@Observable
final class BacklogStore {
    private(set) var tasks: [BacklogTask] = []
    private let file: JSONFile<[BacklogTask]>
    private let adoptedFile: JSONFile<[String]>
    private var adoptedKeys: Set<String> = []

    init(fileURL: URL = AppSupport.file("backlog.json"),
         adoptedURL: URL = AppSupport.file("adopted.json")) {
        file = JSONFile(url: fileURL)
        adoptedFile = JSONFile(url: adoptedURL)
        tasks = file.load() ?? []
        adoptedKeys = Set(adoptedFile.load() ?? [])
    }
    private func persist() { file.save(tasks) }
    private func persistAdopted() { adoptedFile.save(Array(adoptedKeys)) }

    // MARK: Mutations

    @discardableResult
    func add(_ task: BacklogTask) -> BacklogTask { tasks.insert(task, at: 0); persist(); return task }

    func update(_ task: BacklogTask) {
        guard let idx = tasks.firstIndex(where: { $0.id == task.id }) else { return }
        var t = task; t.updatedAt = Date(); tasks[idx] = t; persist()
    }

    func remove(_ id: UUID) { tasks.removeAll { $0.id == id }; persist() }

    func task(id: UUID) -> BacklogTask? { tasks.first { $0.id == id } }

    func setState(_ id: UUID, _ state: TaskState) {
        guard let idx = tasks.firstIndex(where: { $0.id == id }) else { return }
        tasks[idx].state = state; tasks[idx].updatedAt = Date(); persist()
    }

    func restate(_ id: UUID, as state: TaskState) {
        guard let idx = tasks.firstIndex(where: { $0.id == id }) else { return }
        tasks[idx].state = state
        tasks[idx].lastOutcome = nil
        tasks[idx].updatedAt = Date()
        persist()
    }

    func beginFinalizing(_ id: UUID, branch: String, target: String) {
        guard let idx = tasks.firstIndex(where: { $0.id == id }) else { return }
        tasks[idx].state = .finalizing
        tasks[idx].boundBranch = branch
        tasks[idx].boundBaseBranch = target
        tasks[idx].finalizingSince = Date()
        tasks[idx].updatedAt = Date()
        persist()
    }

    func bindDispatch(_ id: UUID, dispatchID: String) {
        guard let idx = tasks.firstIndex(where: { $0.id == id }) else { return }
        tasks[idx].boundDispatchID = dispatchID
        tasks[idx].updatedAt = Date()
        persist()
    }

    func markDispatched(_ id: UUID, keepBindings: Bool = false) {
        guard let idx = tasks.firstIndex(where: { $0.id == id }) else { return }
        tasks[idx].dispatchedAt = Date()

        tasks[idx].state = .executing
        if !keepBindings {

            tasks[idx].boundRunID = nil
            tasks[idx].boundBranch = nil
            tasks[idx].boundBaseSHA = nil
            tasks[idx].boundBaseBranch = nil
            tasks[idx].boundSessionID = nil
            tasks[idx].queueDirName = nil
        }
        tasks[idx].updatedAt = Date()
        persist()
    }

    nonisolated static func isWorktreePath(_ path: String) -> Bool {
        path.contains("/.nightshift-worktrees/")
    }

    @discardableResult
    func removeGhostRunCards() -> [BacklogTask] {

        func isAdoptedRunCard(_ t: BacklogTask) -> Bool {
            t.title.hasPrefix("Night run · ") || t.detail.hasPrefix("Direct night-shift run on ")
        }
        let doomed = tasks.filter { t in
            if isAdoptedRunCard(t), let runID = t.boundRunID, !runID.isEmpty,
               tasks.contains(where: { $0.id != t.id && $0.boundRunID == runID && !isAdoptedRunCard($0) }) {
                return true
            }
            guard t.productID == nil, t.title.hasPrefix("Night run · ") else { return false }
            guard let path = t.projectPath else { return true }
            return Self.isWorktreePath(path) || !FileManager.default.fileExists(atPath: path)
        }
        guard !doomed.isEmpty else { return [] }
        let ids = Set(doomed.map(\.id))
        tasks.removeAll { ids.contains($0.id) }
        persist()
        return doomed
    }

    @discardableResult
    func adoptRealRunCards(resolve: (String) -> (productID: UUID, projectName: String)?) -> Int {
        var touched = 0
        for i in tasks.indices where tasks[i].productID == nil {
            guard tasks[i].title.hasPrefix("Night run · "),
                  let path = tasks[i].projectPath,
                  !Self.isWorktreePath(path) else { continue }

            if let owner = resolve(path) {
                tasks[i].productID = owner.productID
                tasks[i].title = String(format: String(localized: "Night shift in %@"), owner.projectName)
            } else {
                let name = URL(fileURLWithPath: path).lastPathComponent
                tasks[i].title = String(format: String(localized: "Night shift in %@"), name)
            }
            touched += 1
        }
        if touched > 0 { persist() }
        return touched
    }

    func stripRunLabelPrefixes() {
        let marker = "Нічний джоб · "
        var touched = 0
        for i in tasks.indices where tasks[i].title.hasPrefix(marker) {
            let rest = String(tasks[i].title.dropFirst(marker.count))

            if let colon = rest.firstIndex(of: ":") {
                let work = rest[rest.index(after: colon)...].trimmingCharacters(in: .whitespaces)
                tasks[i].title = work.isEmpty ? rest : work
            } else {
                tasks[i].title = rest
            }
            touched += 1
        }
        if touched > 0 { persist() }
    }

    @discardableResult
    func removeFindingNotes() -> [BacklogTask] {
        let doomed = tasks.filter { $0.type == .idea && $0.detail.contains("[finding-id: ") }
        guard !doomed.isEmpty else { return [] }
        let ids = Set(doomed.map(\.id))
        tasks.removeAll { ids.contains($0.id) }
        persist()
        return doomed
    }

    func undoDispatch(_ id: UUID) {
        guard let idx = tasks.firstIndex(where: { $0.id == id }) else { return }
        tasks[idx].dispatchedAt = nil
        tasks[idx].state = .ready
        tasks[idx].updatedAt = Date()
        persist()
    }

    func appendFeedback(_ id: UUID, _ text: String) {
        guard let idx = tasks.firstIndex(where: { $0.id == id }) else { return }
        tasks[idx].reviewFeedback.append(text)
        tasks[idx].state = .ready
        tasks[idx].dispatchedAt = nil
        tasks[idx].updatedAt = Date()
        persist()
    }

    func tasks(forProjectID id: UUID) -> [BacklogTask] { tasks.filter { $0.projectID == id } }

    func grouped() -> [BoardColumn: [BacklogTask]] {
        var out: [BoardColumn: [BacklogTask]] = [:]
        for col in BoardColumn.allCases { out[col] = [] }
        for t in tasks.sorted(by: taskOrder) { out[t.state.column, default: []].append(t) }
        return out
    }

    var reviewReady: [BacklogTask] {
        tasks.filter { $0.state == .review }.sorted { $0.updatedAt > $1.updatedAt }
    }
    var reviewReadyCount: Int { tasks.filter { $0.state == .review }.count }

    // MARK: Dependencies & scheduling

    func isBlocked(_ task: BacklogTask) -> Bool {
        if task.externalBlocker != nil { return true }
        return task.dependsOn.contains { depID in
            guard let dep = tasks.first(where: { $0.id == depID }) else { return false }
            return dep.state != .merged && dep.state != .approved
        }
    }

    func blockReason(_ task: BacklogTask) -> String? {
        if let ext = task.externalBlocker { return "Waiting on \(ext)" }
        let pending = task.dependsOn
            .compactMap { id in tasks.first(where: { $0.id == id }) }
            .filter { $0.state != .merged && $0.state != .approved }
        if pending.isEmpty { return nil }
        return "Waiting on: " + pending.map(\.title).joined(separator: ", ")
    }

    var readyToDispatch: [BacklogTask] {
        tasks.filter { $0.isDispatchable && $0.dispatchedAt == nil && !isBlocked($0) }
            .sorted { $0.priority != $1.priority ? $0.priority < $1.priority : $0.createdAt < $1.createdAt }
    }

    var blockedByDeps: [BacklogTask] { tasks.filter { isBlocked($0) } }

    func setExternalBlocker(_ id: UUID, _ blocker: String?) {
        guard let idx = tasks.firstIndex(where: { $0.id == id }) else { return }
        tasks[idx].externalBlocker = (blocker?.isEmpty ?? true) ? nil : blocker
        tasks[idx].updatedAt = Date(); persist()
    }

    func setDependencies(_ id: UUID, _ deps: [UUID]) {
        guard let idx = tasks.firstIndex(where: { $0.id == id }) else { return }
        tasks[idx].dependsOn = deps.filter { $0 != id }
        tasks[idx].updatedAt = Date(); persist()
    }

    func setAutoResume(_ id: UUID, _ value: Bool) {
        guard let idx = tasks.firstIndex(where: { $0.id == id }) else { return }
        tasks[idx].autoResume = value; persist()
    }

    func setHolds(_ id: UUID, _ holds: [TaskHold]) {
        guard let idx = tasks.firstIndex(where: { $0.id == id }) else { return }
        guard tasks[idx].holds != holds else { return }
        tasks[idx].holds = holds
        tasks[idx].updatedAt = Date()
        persist()
    }

    func setWorktree(_ id: UUID, _ path: String?) {
        guard let idx = tasks.firstIndex(where: { $0.id == id }) else { return }
        tasks[idx].worktree = path; persist()
    }

    func resumable() -> [BacklogTask] {
        tasks.filter { $0.autoResume && $0.dispatchedAt == nil && !isBlocked($0) && $0.isDispatchable }
    }

    func withExternalPRBlocker() -> [BacklogTask] {
        tasks.filter { t in
            guard let b = t.externalBlocker else { return false }
            return b.range(of: #"#\d+"#, options: .regularExpression) != nil || b.lowercased().contains("github.com")
        }
    }

    private func taskOrder(_ a: BacklogTask, _ b: BacklogTask) -> Bool {
        if a.priority != b.priority { return a.priority < b.priority }
        return a.updatedAt > b.updatedAt
    }

    // MARK: Adopting work finished outside the app

    func adopt(from snap: SupervisorSnapshot, resolveProjectID: (String) -> UUID?) {
        var changed = false
        var keysChanged = false

        func adoptable(_ inst: SupervisorInstance) -> Bool {
            guard !Self.isWorktreePath(inst.projectPath) else { return false }
            guard !tasks.contains(where: { $0.worktree == inst.projectPath }) else { return false }
            return FileManager.default.fileExists(atPath: inst.projectPath)
        }

        func ownerOfWorktree(_ inst: SupervisorInstance) -> BacklogTask? {
            guard Self.isWorktreePath(inst.projectPath) else { return nil }
            return tasks.first { $0.worktree == inst.projectPath }
        }

        func card(for inst: SupervisorInstance, title: String, detail: String,
                  outcome: String, blocked: Bool, home: BacklogTask? = nil) -> BacklogTask {
            var t = BacklogTask(title: title, detail: detail,
                                projectID: home?.projectID ?? resolveProjectID(inst.projectPath),
                                projectPath: home?.projectPath ?? inst.projectPath,
                                type: .feature, priority: .p2, state: blocked ? .blocked : .review)
            t.productID = home?.productID
            t.chatID = home?.chatID
            t.worktree = home != nil ? inst.projectPath : nil
            t.lastOutcome = outcome
            t.boundBranch = inst.branch; t.boundBaseSHA = inst.baseSHA
            t.boundBaseBranch = inst.baseBranch
            t.boundSessionID = inst.sessionID; t.boundRunID = inst.runID
            return t
        }

        func alreadyCovered(_ path: String, title: String) -> Bool {
            let canon = Slug.canonicalPath(path)
            return tasks.contains { t in
                guard let p = t.projectPath, Slug.canonicalPath(p) == canon else { return false }
                let a = t.title.trimmingCharacters(in: .whitespaces)
                return !a.isEmpty && (a.localizedCaseInsensitiveContains(title) || title.localizedCaseInsensitiveContains(a))
            }
        }

        for entry in snap.queue.done + snap.queue.needsUser {
            let key = "q:" + entry.dirName
            if adoptedKeys.contains(key) { continue }
            adoptedKeys.insert(key); keysChanged = true
            let title = adoptTitle(entry.task, fallback: entry.projectName)
            guard !alreadyCovered(entry.projectPath, title: title) else { continue }

            guard !Self.isWorktreePath(entry.projectPath),
                  !tasks.contains(where: { $0.worktree == entry.projectPath }) else { continue }
            let queueInstance = snap.instances.first { $0.slug == Slug.forPath(entry.projectPath) }
            if let runID = queueInstance?.runID, !runID.isEmpty,
               tasks.contains(where: { $0.boundRunID == runID }) { continue }
            let blocked = entry.outcome.needsAttention && entry.outcome != .debt && !entry.outcome.isSuccess
            var t = BacklogTask(title: title, detail: entry.task,
                                projectID: resolveProjectID(entry.projectPath), projectPath: entry.projectPath,
                                type: .feature, priority: .p2, state: blocked ? .blocked : .review)
            t.dispatchedAt = entry.finishedAt ?? Date()
            t.lastOutcome = entry.outcome.rawValue
            t.queueDirName = entry.dirName
            if let inst = queueInstance, inst.branch != nil {
                t.boundBranch = inst.branch; t.boundBaseSHA = inst.baseSHA
                t.boundBaseBranch = inst.baseBranch; t.boundSessionID = inst.sessionID; t.boundRunID = inst.runID
            }
            tasks.insert(t, at: 0); changed = true
        }

        for inst in snap.instances {
            for record in inst.finishedDispatches {
                // A conversation's own turns are not work to be filed.
                if record.chat { continue }
                let key = "d:\(record.id)"
                if adoptedKeys.contains(key) { continue }
                adoptedKeys.insert(key); keysChanged = true
                if let mine = tasks.first(where: { $0.boundDispatchID == record.id }) {
                    Trace.note("adopt-skip", task: mine.id, dispatch: record.id,
                               detail: "already this card's own dispatch")
                    continue
                }

                if let key = record.reportKey, !key.isEmpty,
                   let mine = tasks.first(where: { $0.reportKey == key }) {
                    Trace.note("adopt-skip", task: mine.id, dispatch: record.id, report: key,
                               detail: "this card already owns that report directory")
                    continue
                }

                let home = ownerOfWorktree(inst)
                guard home != nil || adoptable(inst) else { continue }
                let outcome = QueueOutcome(raw: record.result ?? "")
                var t = card(for: inst, title: record.title, detail: record.task,
                             outcome: record.result ?? "", blocked: outcome == .needsUser || outcome == .blocked,
                             home: home)
                t.dispatchedAt = record.at ?? record.finishedAt ?? Date()
                t.boundDispatchID = record.id
                t.boundReportKey = record.reportKey
                Trace.note("adopt", task: t.id, dispatch: record.id, report: record.reportKey,
                           project: inst.projectPath,
                           detail: "outcome=\(record.result ?? "—") «\(record.title)»")
                tasks.insert(t, at: 0); changed = true
            }

            // Chat turns are not dispatches for this purpose either: counting them here would
            // silently stop a run that also had a conversation from ever being picked up.
            guard inst.finishedDispatches.allSatisfy(\.chat),
                  !inst.active, let result = inst.doneResult else { continue }
            let key = "i:\(inst.slug):\(result):\(Int((inst.finishedAt ?? .distantPast).timeIntervalSince1970))"
            if adoptedKeys.contains(key) { continue }
            adoptedKeys.insert(key); keysChanged = true
            guard adoptable(inst) else { continue }
            guard !alreadyCovered(inst.projectPath, title: inst.projectName) else { continue }
            if let runID = inst.runID, !runID.isEmpty,
               tasks.contains(where: { $0.boundRunID == runID }) { continue }
            let outcome = QueueOutcome(raw: result)
            var t = card(for: inst, title: "Night run · \(inst.projectName)",
                         detail: "Direct night-shift run on \(inst.branch ?? "—").",
                         outcome: result, blocked: outcome == .needsUser || outcome == .blocked)
            t.dispatchedAt = inst.finishedAt ?? Date()
            tasks.insert(t, at: 0); changed = true
        }

        if changed { persist() }
        if keysChanged { persistAdopted() }
    }

    private func adoptTitle(_ text: String, fallback: String) -> String {
        let line = text.split(separator: "\n").first.map(String.init) ?? text
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty { return fallback }
        return trimmed.count > 90 ? String(trimmed.prefix(90)) + "…" : trimmed
    }

    // MARK: Live reconciliation with the queue

    func reconcile(with snap: SupervisorSnapshot) {
        var didChange = false
        for i in tasks.indices {
            let t = tasks[i]

            guard t.dispatchedAt != nil, t.state != .approved, t.state != .merged,
                  t.state != .finalizing, let pp = t.projectPath else { continue }

            let canon = Slug.canonicalPath(t.worktree ?? pp)

            if tasks[i].boundBranch == nil,

               [.executing, .researching, .planning, .verifying].contains(tasks[i].state),
               let inst = snap.instances.first(where: { $0.slug == Slug.forPath(canon) }),
               inst.branch != nil {
                tasks[i].boundBranch = inst.branch
                tasks[i].boundBaseSHA = inst.baseSHA
                tasks[i].boundBaseBranch = inst.baseBranch
                tasks[i].boundSessionID = inst.sessionID
                tasks[i].boundRunID = inst.runID
                didChange = true
            }

            if tasks[i].boundSessionID == nil, let runID = tasks[i].boundRunID,
               let inst = snap.instances.first(where: { $0.runID == runID }),
               let sid = inst.sessionID, !sid.isEmpty {
                tasks[i].boundSessionID = sid
                didChange = true
            }

            if let pend = snap.queue.pending.first(where: { Slug.canonicalPath($0.projectPath) == canon && matches($0.task, t) }) {
                let runningHere = snap.queue.current.map { Slug.canonicalPath($0) == canon } ?? false
                let inst = snap.instances.first { $0.slug == Slug.forPath(canon) }
                let newState: TaskState = runningHere ? runningState(inst) : .ready
                didChange = apply(&tasks[i], state: newState, dir: pend.dirName, outcome: nil) || didChange
                continue
            }

            if let fin = (snap.queue.done + snap.queue.needsUser)
                .first(where: { Slug.canonicalPath($0.projectPath) == canon && matches($0.task, t) }) {
                let newState = resolvedState(done: fin.outcome, outcome: fin.workerOutcome, current: t.state)
                let outcomeStr = fin.workerOutcome?.rawValue ?? fin.outcome.rawValue
                didChange = apply(&tasks[i], state: newState, dir: fin.dirName, outcome: outcomeStr) || didChange
                continue
            }

            let liveInst = snap.instances.first(where: { $0.slug == Slug.forPath(canon) })
            if let inst = liveInst, inst.active,
               ([.ready, .researching, .planning, .executing, .verifying].contains(tasks[i].state)

                || (tasks[i].state == .blocked && inst.runID != nil && inst.runID == tasks[i].boundRunID)) {

                didChange = apply(&tasks[i], state: runningState(inst), dir: nil, outcome: nil) || didChange
            } else if let inst = liveInst, inst.doneResult != nil,

                      [.researching, .planning, .executing, .verifying].contains(tasks[i].state),
                      !(inst.finishedAt.map { fin in (tasks[i].dispatchedAt ?? .distantPast) > fin } ?? false) {

                let newState = resolvedState(done: QueueOutcome(raw: inst.doneResult ?? ""),
                                             outcome: inst.outcome, current: tasks[i].state)
                let outcomeStr = inst.outcome?.rawValue ?? inst.doneResult
                didChange = apply(&tasks[i], state: newState, dir: nil, outcome: outcomeStr) || didChange
            } else if let inst = liveInst, inst.doneResult != nil,
                      [.researching, .planning, .executing, .verifying].contains(tasks[i].state),
                      let dispatched = tasks[i].dispatchedAt,
                      let finished = inst.finishedAt, dispatched > finished,
                      Date().timeIntervalSince(dispatched) > Self.vanishedGrace {

                didChange = apply(&tasks[i], state: .failed, dir: nil, outcome: "gone") || didChange
            } else if let inst = liveInst, !inst.watchdogAlive, inst.doneResult == nil,
                      [.researching, .planning, .executing, .verifying].contains(tasks[i].state),
                      let dispatched = tasks[i].dispatchedAt,
                      Date().timeIntervalSince(dispatched) > Self.vanishedGrace {

                didChange = apply(&tasks[i], state: .failed, dir: nil, outcome: inst.outcome?.rawValue ?? "gone") || didChange
            } else if liveInst == nil,
                      [.researching, .planning, .executing, .verifying].contains(tasks[i].state),
                      let dispatched = tasks[i].dispatchedAt,
                      Date().timeIntervalSince(dispatched) > Self.vanishedGrace {

                didChange = apply(&tasks[i], state: .failed, dir: nil, outcome: "gone") || didChange
            }
        }
        if didChange { persist() }
    }

    private static let vanishedGrace: TimeInterval = 120

    private func apply(_ t: inout BacklogTask, state: TaskState, dir: String?, outcome: String?) -> Bool {
        var changed = false
        if t.state != state { t.state = state; changed = true }
        if let dir, t.queueDirName != dir { t.queueDirName = dir; changed = true }
        if let outcome, t.lastOutcome != outcome { t.lastOutcome = outcome; changed = true }
        if changed { t.updatedAt = Date() }
        return changed
    }

    private func runningState(_ inst: SupervisorInstance?) -> TaskState {
        switch inst?.phase {
        case .reviewing: .verifying
        case .awaitingDecision, .blocked, .stalled: .blocked
        default: .executing
        }
    }

    private func resolvedState(done: QueueOutcome, outcome: WorkerOutcome?, current: TaskState) -> TaskState {
        switch done {
        case .passed, .debt:
            return current == .approved || current == .merged ? current : .review
        case .needsUser, .handoff, .blocked:
            return outcome == .failed ? .failed : .blocked
        case .timeout, .startfail, .injectfail, .gone, .vanished, .interrupted, .unknown:
            return .failed
        }
    }

    private func matches(_ entryTask: String, _ task: BacklogTask) -> Bool {
        let needle = task.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return false }
        return entryTask.localizedCaseInsensitiveContains(needle)
    }
}
