import Foundation
import OSLog
import Darwin

nonisolated struct SupervisorSnapshot: Sendable {
    var capacity = CapacitySnapshot()
    var instances: [SupervisorInstance] = []
    var queue = QueueState()
    var nightModeActive = false
    var takenAt = Date()
}

actor SupervisorClient {
    private(set) var paths: SupervisorPaths
    private let fm = FileManager.default

    private let nightShiftCmd: String
    private let nightQueueCmd: String

    private let dispatchCmd: String?

    private let engineBin: String?

    init(paths: SupervisorPaths = .default) {
        self.paths = paths
        if let home = OrchestratorHome.detect()?.path,
           FileManager.default.fileExists(atPath: "\(home)/bin/night-shift.sh") {
            nightShiftCmd = "bash \"\(home)/bin/night-shift.sh\""
            nightQueueCmd = "bash \"\(home)/bin/queue.sh\""
            let dispatchPath = "\(home)/bin/dispatch.sh"
            dispatchCmd = FileManager.default.fileExists(atPath: dispatchPath) ? "bash \"\(dispatchPath)\"" : nil
            engineBin = "\(home)/bin"
        } else {
            nightShiftCmd = "night-shift"
            nightQueueCmd = "night-queue"
            dispatchCmd = nil
            engineBin = nil
        }
    }

    private func engineScript(_ name: String, timeout: TimeInterval) async {
        let cmd: String
        if let engineBin, FileManager.default.fileExists(atPath: "\(engineBin)/\(name)") {
            cmd = "bash \"\(engineBin)/\(name)\""
        } else {
            cmd = name
        }

        let r = await Shell.run("\(cmd) 2>&1", timeout: timeout)

        if r.launched, r.exitCode == 0 {
            Log.engine.debug("\(name, privacy: .public) ok")
        } else {
            Log.failure(Log.engine, name, exit: r.exitCode, output: r.stdout + r.stderr)
        }
    }

    var canDispatchConcurrently: Bool { dispatchCmd != nil }

    func updatePaths(_ p: SupervisorPaths) { paths = p }

    // MARK: - Reading a full snapshot

    func snapshot() async -> SupervisorSnapshot {
        var snap = SupervisorSnapshot()
        snap.capacity = readCapacity()
        snap.nightModeActive = fm.fileExists(atPath: paths.nightModeFlag.path)
        snap.instances = readInstances()

        for index in snap.instances.indices
            where snap.instances[index].workerStatus == "waiting"
                && snap.instances[index].pendingQuestion == nil {
            let pane = await capturePane(session: snap.instances[index].session, lines: 160)
            snap.instances[index].pendingQuestion = TerminalQuestionParser.parse(pane)
        }
        snap.queue = readQueue()
        snap.takenAt = Date()
        return snap
    }

    // MARK: - Capacity

    func readCapacity() -> CapacitySnapshot {
        var cap = CapacitySnapshot()
        if let d = try? Data(contentsOf: paths.usageJSON), let s = UsageSnapshot.decode(from: d) { cap.claude = s }
        if let d = try? Data(contentsOf: paths.codexUsageJSON), let s = UsageSnapshot.decode(from: d) { cap.codex = s }
        return cap
    }

    @discardableResult
    func refreshWorkerEnvironment(force: Bool = false, now: Date = Date()) async -> WorkerEnvironment? {
        let cached = workerEnvironment
        guard force || Self.workerEnvironmentNeedsRefresh(checkedAt: cached?.checkedAt,
                                                           lastAttempt: lastWorkerEnvironmentProbeAttempt,
                                                           now: now) else { return cached }
        guard !workerEnvironmentProbeInFlight else { return cached }
        workerEnvironmentProbeInFlight = true
        lastWorkerEnvironmentProbeAttempt = now
        defer { workerEnvironmentProbeInFlight = false }

        let env = await WorkerEnvironment.probe { script, args, timeout in

            let r = await Shell.run(script, args: args, timeout: timeout,
                                    isolatingProcessTree: true)
            return (r.stdout, r.launched)
        }
        guard let env else { return cached }
        if let data = try? JSONEncoder().encode(env) { try? data.write(to: paths.workerEnvJSON) }
        workerEnvironment = env
        return env
    }

    private var workerEnvironmentProbeInFlight = false
    private var lastWorkerEnvironmentProbeAttempt: Date?
    nonisolated static let workerEnvironmentRefreshInterval: TimeInterval = 60 * 60

    nonisolated static func workerEnvironmentNeedsRefresh(checkedAt: Date?,
                                                           lastAttempt: Date?,
                                                           now: Date,
                                                           interval: TimeInterval = workerEnvironmentRefreshInterval) -> Bool {
        let latest = [checkedAt, lastAttempt].compactMap { $0 }.max()
        guard let latest else { return true }
        return now.timeIntervalSince(latest) >= interval
    }

    private(set) var workerEnvironment: WorkerEnvironment? {
        get {
            if let cached = _workerEnvironment { return cached }
            guard let data = try? Data(contentsOf: paths.workerEnvJSON),
                  let env = try? JSONDecoder().decode(WorkerEnvironment.self, from: data) else { return nil }
            _workerEnvironment = env
            return env
        }
        set { _workerEnvironment = newValue }
    }
    private var _workerEnvironment: WorkerEnvironment?

    func refreshCodexUsage() async {
        await engineScript("codex-usage.sh", timeout: 20)
    }

    func refreshClaudeUsage() async {
        await engineScript("claude-usage.sh", timeout: 25)
    }

    // MARK: - Instances

    func readInstances() -> [SupervisorInstance] {
        guard let dirs = try? fm.contentsOfDirectory(at: paths.instancesDir,
                                                     includingPropertiesForKeys: nil) else { return [] }
        var result: [SupervisorInstance] = []
        for dir in dirs {
            let slug = dir.lastPathComponent
            guard let project = readTrimmed(dir.appendingPathComponent("project")) else { continue }
            let session = readTrimmed(dir.appendingPathComponent("session")) ?? "night-\(slug)"
            let watchdogPID = readTrimmed(dir.appendingPathComponent("watchdog.pid")).flatMap { Int32($0) }
            let paused = readJSONNumber(dir.appendingPathComponent("paused-for-limit.json"), key: "resume_after")
            let awaitingURL = dir.appendingPathComponent("awaiting-codex")
            let awaiting = readJSONNumber(awaitingURL, key: "await_until")

            let awaitingReason = readJSONString(awaitingURL, key: "reason")
            let reviewProgress = readReviewProgress(dir.appendingPathComponent("review-progress.json"))
            let reviewVerdict = readReviewVerdict(dir.appendingPathComponent("reports/review.json"))

            let scopeViolations = readJSONNumber(dir.appendingPathComponent("scope-violation.json"), key: "count").map { Int($0) }
            let doneURL = dir.appendingPathComponent("done")
            let finishedAt = fm.fileExists(atPath: doneURL.path) ? modifiedDate(doneURL) : nil
            let startedAt = modifiedDate(dir.appendingPathComponent("started-at"))

            let (workerOutcome, outcomeSummary) = readOutcome(dir.appendingPathComponent("outcome.json"))
            let stalled = fm.fileExists(atPath: dir.appendingPathComponent("stalled.json").path)

            let offlineURL = dir.appendingPathComponent("offline.json")
            let offline = fm.fileExists(atPath: offlineURL.path)
            let offlineSince = offline ? (readOfflineSince(offlineURL) ?? modifiedDate(offlineURL)) : nil

            let injected = readInjectFailure(dir.appendingPathComponent("inject-failed"))
            let dispatch = readDispatch(dir.appendingPathComponent("dispatch.json"))
            let finishedDispatches = readFinishedDispatches(dir.appendingPathComponent("dispatches"))
            let runID = readTrimmed(dir.appendingPathComponent("run-id"))

            let sessionID = readTrimmed(dir.appendingPathComponent("claude-session-id"))
                ?? newestEvidenceSID(dir)
            let auditState = sessionID.flatMap { readTrimmed(paths.auditState(sid: $0)) }
            let reviewActive = fm.fileExists(atPath: dir.appendingPathComponent("review-active").path)
            let reviewStage = readTrimmed(dir.appendingPathComponent("review-stage"))
            let workerStatus = readWorkerStatus(session: session)

            let durable = paths.undeliveredDir(slug: slug)
            var queued = readMessageQueue(durable.appendingPathComponent("undelivered.jsonl"),
                                          alsoLegacy: dir.appendingPathComponent("undelivered.jsonl"))
            // Messages waiting for their independent positions. They are queued in the plainest
            // sense — accepted, not delivered — so they belong in the same count the composer
            // already shows, and their ids have to be here or taking one back finds nothing.
            let pendingIDs = readPendingEnvelopes(dir.appendingPathComponent("pending"))
            let pendingFiles = countPendingFiles(dir.appendingPathComponent("pending"))
            queued = (queued.count + pendingIDs.count, queued.ids + pendingIDs)
            // Two different facts, and telling them apart is the whole point.
            //
            // `preparing` means two positions are BEING FORMED right now — a pipeline process
            // exists and is doing it. `queuedWork` means a message has been accepted and nothing
            // has started on it yet. The app used to call both of them preparation, so a message
            // parked behind a usage limit displayed as "Claude and Codex are reading this first"
            // for an hour while neither engine had so much as seen it.
            let preparing = readPreparing(dir.appendingPathComponent("pipeline-active.json"))
            let queuedWork = !pendingIDs.isEmpty || preparing
            let queueWait = readQueueWait(dir.appendingPathComponent("queue-wait.json"))
            let pauseProvider = readJSONString(dir.appendingPathComponent("paused-for-limit.json"),
                                               key: "provider")
            let degradedNote = readDegraded(dir.appendingPathComponent("degraded.md"))
            // Which engineer could not take part, published the moment the stage skips it rather
            // than when the whole preparation ends — the header has to be true WHILE it is true.
            let codexOut = readDegraded(dir.appendingPathComponent("peer-codex.unavailable"))
            let claudeOut = readDegraded(dir.appendingPathComponent("peer-claude.unavailable"))
            // And which of them is reading at this moment, so the chat can count rather than
            // repeat one sentence for two minutes.
            let peerClaude = readPeerWork(dir.appendingPathComponent("peer-claude.running"))
            let peerCodex = readPeerWork(dir.appendingPathComponent("peer-codex.running"))
            let failed = readMessageQueue(durable.appendingPathComponent("undelivered-stuck.jsonl"),
                                          alsoLegacy: dir.appendingPathComponent("undelivered-stuck.jsonl"))
            let codexArtifacts = readCodexPosition(dir.appendingPathComponent("peer-codex.latest.md"))
                + readCodexArtifacts(
                reportsDir: dir.appendingPathComponent("reports"),
                slug: slug,
                runID: runID,
                sessionID: sessionID,
                startedAt: startedAt,
                auditRunning: auditState == "audit_running")

            // Read once and used twice: as the card he sees, and as the addressed request his
            // answer has to name on the way back.
            let codexDecision = readCodexDecision(dir)

            let inst = SupervisorInstance(
                slug: slug,
                projectPath: project,
                session: session,
                branch: readTrimmed(dir.appendingPathComponent("branch")),
                baseBranch: readTrimmed(dir.appendingPathComponent("base-branch")),
                baseSHA: readCommit(dir.appendingPathComponent("base-sha")),
                runID: runID,
                authMode: readTrimmed(dir.appendingPathComponent("auth-mode")),
                sessionID: sessionID,
                startedAt: startedAt,
                lastActivity: modifiedDate(dir.appendingPathComponent("last-activity")),
                watchdogAlive: watchdogAlive(watchdogPID, slug: slug),
                doneResult: readTrimmed(doneURL),
                finishedAt: finishedAt,
                pausedResumeAt: paused.map { Date(timeIntervalSince1970: $0) },
                awaitingUntil: awaiting.map { Date(timeIntervalSince1970: $0) },
                awaitingReason: awaitingReason,
                reviewProgress: reviewProgress,
                reviewVerdict: reviewVerdict,
                auditState: auditState,
                reviewActive: reviewActive,
                reviewStage: reviewStage,
                workerStatus: workerStatus,
                queuedMessageCount: queued.count,
                queuedMessageIDs: queued.ids,
                preparing: preparing,
                queuedWork: queuedWork,
                queueWaitReason: queueWait?.reason,
                queueWaitSince: queueWait?.since,
                pauseProvider: pauseProvider,
                degradedNote: degradedNote,
                codexUnavailable: codexOut,
                claudeUnavailable: claudeOut,
                failedMessageIDs: failed.ids,
                codexArtifacts: codexArtifacts,
                pendingFiles: pendingFiles,
                peerClaude: peerClaude,
                peerCodex: peerCodex,
                hasPlan: fm.fileExists(atPath: dir.appendingPathComponent("plan.md").path),
                hasResearch: fm.fileExists(atPath: dir.appendingPathComponent("research.md").path),
                pendingQuestion: readPendingQuestion(dir)
                    ?? codexDecision.map(Self.question(forCodex:)),
                codexDecision: codexDecision,
                scopeViolationCount: scopeViolations,
                outcome: workerOutcome,
                outcomeSummary: outcomeSummary,
                stalled: stalled,
                offline: offline,
                offlineSince: offlineSince,
                injectFailure: injected?.reason,
                injectFailureDispatchID: injected?.dispatch,
                dispatch: dispatch,
                finishedDispatches: finishedDispatches)
            result.append(inst)
        }
        return result.sorted { ($0.startedAt ?? .distantPast) > ($1.startedAt ?? .distantPast) }
    }

    private func readWorkerStatus(session: String) -> String? {
        let dir = fm.homeDirectoryForCurrentUser.appendingPathComponent(".claude/sessions")
        guard let files = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else {
            return nil
        }
        for file in files where file.pathExtension == "json" {
            guard let data = try? Data(contentsOf: file),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let tmux = object["tmux"] as? String,
                  tmux.hasPrefix(session + ":"),
                  let pidNumber = object["pid"] as? NSNumber,
                  pidAlive(pidNumber.int32Value),
                  let status = object["status"] as? String,
                  status == "busy" || status == "idle" || status == "waiting" else { continue }
            return status
        }
        return nil
    }

    /// Message ids sitting in the prepared-message queue, oldest first.
    /// How many envelopes are sitting in the queue, counted as FILES.
    ///
    /// `readPendingEnvelopes` drops anything it cannot parse into a message id, so one malformed
    /// envelope leaves the queue looking empty while the file is still there — and a hand-off that
    /// believed it would delete the directory it lives in.
    private func countPendingFiles(_ dir: URL) -> Int {
        guard let files = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
        else { return 0 }
        return files.filter { $0.pathExtension == "json" && !$0.lastPathComponent.hasPrefix(".") }.count
    }

    private func readPendingEnvelopes(_ dir: URL) -> [UUID] {
        guard let files = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
        else { return [] }
        return files
            .filter { $0.pathExtension == "json" && !$0.lastPathComponent.hasPrefix(".") }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
            .compactMap { url -> UUID? in
                guard let data = try? Data(contentsOf: url),
                      let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let raw = object["message_id"] as? String else { return nil }
                return UUID(uuidString: raw)
            }
    }

    /// Whether a pipeline is preparing a message right now.
    ///
    /// The marker names its own process, and a marker whose process is gone is not work in
    /// progress — it is litter from something that was killed, and believing it would leave a
    /// conversation waiting for ever on nothing.
    private func readPreparing(_ url: URL) -> Bool {
        guard let data = try? Data(contentsOf: url),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let pid = object["pid"] as? Int, pid > 0 else { return false }
        return kill(pid_t(pid), 0) == 0 || errno == EPERM
    }

    /// What a queued message is actually waiting for, as the pump itself recorded it.
    ///
    /// Guessing this from the outside is how the header came to claim both engines were reading a
    /// message that was really parked behind somebody else's usage window.
    private func readQueueWait(_ url: URL) -> (reason: String, since: Date)? {
        guard let data = try? Data(contentsOf: url),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let reason = object["reason"] as? String, !reason.isEmpty else { return nil }
        let since = (object["since"] as? Double).map { Date(timeIntervalSince1970: $0) } ?? Date()
        return (reason, since)
    }

    /// One engine could not take part. Said plainly rather than hidden, because it changes what
    /// the result is worth.
    private func readDegraded(_ url: URL) -> String? {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func readMessageQueue(_ url: URL, alsoLegacy legacy: URL) -> (count: Int, ids: [UUID]) {
        let a = readMessageQueue(url), b = readMessageQueue(legacy)
        return (a.count + b.count, a.ids + b.ids)
    }

    private func readMessageQueue(_ url: URL) -> (count: Int, ids: [UUID]) {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return (0, []) }
        let lines = text.split(separator: "\n")
        let ids = lines.compactMap { line -> UUID? in
            guard let data = String(line).data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let raw = object["id"] as? String else { return nil }
            return UUID(uuidString: raw)
        }
        return (lines.count, ids)
    }

    /// Codex's own reading of the message, as a card in the thread.
    ///
    /// Both engineers read everything that arrives, and only one of them was ever heard from:
    /// Claude's reading turns into the answer, and Codex's went into a file under the instance that
    /// nobody opens. Keyed by when it was written and how long it is, so one position appears once.
    private func readCodexPosition(_ url: URL) -> [CodexReviewArtifact] {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        let body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty, let at = modifiedDate(url) else { return [] }
        return [CodexReviewArtifact(
            key: "position:\(Int(at.timeIntervalSince1970)):\(body.count)",
            kind: .position, at: at,
            text: "## \(String(localized: "Codex read this too"))\n\n\(body)")]
    }

    /// What a peer published about itself when it started. Nil when it is not reading.
    private func readPeerWork(_ url: URL) -> PeerWork? {
        guard let data = try? Data(contentsOf: url),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let started = object["started_at"] as? Double, started > 0 else { return nil }
        var bytes = 0
        if let partial = object["partial"] as? String,
           let size = (try? fm.attributesOfItem(atPath: partial))?[.size] as? Int {
            bytes = size
        }
        return PeerWork(startedAt: Date(timeIntervalSince1970: started), bytes: bytes)
    }

    private func readCodexArtifacts(reportsDir: URL, slug: String, runID: String?,
                                    sessionID: String?, startedAt: Date?,
                                    auditRunning: Bool) -> [CodexReviewArtifact] {
        var artifacts = readCodexDecisions(slug: slug, runID: runID, startedAt: startedAt)

        let reviewURL = reportsDir.appendingPathComponent("review.json")
        if let data = try? Data(contentsOf: reviewURL),
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let artifactSession = object["session_id"] as? String,
           sessionID == nil || artifactSession == sessionID {
            let state = object["state"] as? String ?? ""
            let verdict = object["verdict"] as? String ?? ""
            let verify = object["verify_status"] as? String ?? ""
            let findings = (object["findings"] as? String ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !state.isEmpty || !verdict.isEmpty || !findings.isEmpty {
                let fallback = [state.isEmpty ? nil : "STATE: \(state)",
                                verdict.isEmpty ? nil : "VERDICT: \(verdict)",
                                verify.isEmpty ? nil : "Verifier: \(verify)"]
                    .compactMap { $0 }.joined(separator: "\n")
                let body = findings.isEmpty ? fallback : findings
                let at = parseEngineDate(object["ts"] as? String)
                    ?? modifiedDate(reviewURL) ?? Date()
                artifacts.append(CodexReviewArtifact(
                    key: "review:\(artifactSession):\(body)", kind: .review, at: at,
                    text: "## Codex review\n\n\(body)"))
            }
        }

        if !auditRunning,
           let files = try? fm.contentsOfDirectory(at: reportsDir,
                                                   includingPropertiesForKeys: [.contentModificationDateKey]) {
            for file in files where file.lastPathComponent.hasPrefix("audit-") && file.pathExtension == "md" {
                guard let at = modifiedDate(file),
                      startedAt == nil || at >= startedAt!.addingTimeInterval(-60),
                      let body = try? String(contentsOf: file, encoding: .utf8),
                      !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
                artifacts.append(CodexReviewArtifact(
                    key: "audit:\(file.lastPathComponent):\(body)", kind: .audit, at: at,
                    text: "## Codex audit\n\n\(body)"))
            }
        }
        return artifacts.sorted { $0.at < $1.at }
    }

    private func readCodexDecisions(slug: String, runID: String?,
                                    startedAt: Date?) -> [CodexReviewArtifact] {
        guard let text = try? String(contentsOf: paths.decisionsJSONL, encoding: .utf8) else { return [] }
        return text.split(separator: "\n").compactMap { line in
            guard let data = String(line).data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  object["kind"] as? String == "answer",
                  object["decision"] as? String == "auto",
                  object["slug"] as? String == slug else { return nil }

            let recordedRun = object["run_id"] as? String ?? ""
            if let runID, !runID.isEmpty, recordedRun != runID { return nil }
            let at = (object["ts"] as? String).flatMap { ISO8601DateFormatter().date(from: $0) }
                ?? startedAt ?? Date()
            if (runID == nil || runID?.isEmpty == true),
               let startedAt, at < startedAt.addingTimeInterval(-60) { return nil }

            let answer = ((object["answer"] as? String) ?? (object["summary"] as? String) ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !answer.isEmpty else { return nil }
            let questionLines = (object["questions"] as? [[String: Any]] ?? [])
                .compactMap { ($0["question"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            let question: String
            if questionLines.isEmpty {
                question = ""
            } else if questionLines.count == 1 {
                question = "Питання Claude:\n\n> \(questionLines[0].replacingOccurrences(of: "\n", with: "\n> "))\n\n"
            } else {
                question = "Питання Claude:\n\n" + questionLines.enumerated()
                    .map { "\($0.offset + 1). \($0.element)" }.joined(separator: "\n") + "\n\n"
            }
            let toolID = (object["tool_use_id"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            let key = toolID ?? "\(object["ts"] as? String ?? ""):\(answer)"
            return CodexReviewArtifact(key: "decision:\(key)", kind: .decision, at: at,
                                       text: "\(question)**Codex обрав:**\n\n\(answer)")
        }
    }

    private func parseEngineDate(_ raw: String?) -> Date? {
        guard let raw else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter.date(from: raw)
    }

    private func readPendingQuestion(_ dir: URL) -> PendingUserQuestion? {
        let url = dir.appendingPathComponent("ask-user.json")
        guard let data = try? Data(contentsOf: url),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        let rawQs = (obj["questions"] as? [[String: Any]]) ?? []
        let items: [PendingUserQuestion.Item] = rawQs.compactMap { q in
            guard let text = (q["question"] as? String), !text.isEmpty else { return nil }
            return PendingUserQuestion.Item(
                question: text,
                header: (q["header"] as? String).flatMap { $0.isEmpty ? nil : $0 },
                options: (q["options"] as? [String]) ?? [],
                multiSelect: (q["multiSelect"] as? Bool) ?? false,
                optionDescriptions: q["optionDescriptions"] as? [String: String])
        }
        guard !items.isEmpty else { return nil }
        let askedAt = (obj["asked_at"] as? Double).map { Date(timeIntervalSince1970: $0) }
        func text(_ key: String) -> String? {
            (obj[key] as? String).flatMap { $0.isEmpty ? nil : $0 }
        }
        return PendingUserQuestion(questions: items, askedAt: askedAt,
                                   reasonCode: text("reason_code"),
                                   summary: text("headline"),
                                   recommendation: text("recommendation"),
                                   defaultAction: text("default_action"),
                                   unblockAction: text("unblock_action"),
                                   toolUseID: text("tool_use_id"))
    }

    private func readCodexDecision(_ dir: URL) -> CodexDecision? {
        let url = dir.appendingPathComponent("codex-decision.json")
        guard let data = try? Data(contentsOf: url),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let id = obj["id"] as? String, !id.isEmpty else { return nil }
        let choices = (obj["choices"] as? [String])?.filter { !$0.isEmpty } ?? []
        guard !choices.isEmpty else { return nil }
        // Zero is how the engine says "Codex would not tell me when it comes back". Turning that
        // into 1 Jan 1970 and showing it as a time is worse than showing no time at all.
        let resets = (obj["resets_at"] as? Double).flatMap { $0 > 0 ? Date(timeIntervalSince1970: $0) : nil }
        return CodexDecision(id: id,
                             stage: (obj["stage"] as? String) ?? "review",
                             state: (obj["state"] as? String) ?? "exhausted",
                             resetsAt: resets,
                             reason: (obj["reason"] as? String) ?? "",
                             askedAt: (obj["asked_at"] as? Double).map { Date(timeIntervalSince1970: $0) },
                             choices: choices)
    }

    /// The same card every other decision uses, so this one needs no interface of its own.
    ///
    /// The options are built in the engine's order and answered by position: a button's words can
    /// be translated, and matching on them would make the meaning of a press depend on the
    /// interface language.
    nonisolated static func question(forCodex decision: CodexDecision) -> PendingUserQuestion {
        // The day, not only the clock. A weekly window five days out printed as a bare "11:41"
        // reads as six minutes away, and that exact sentence is what sent the director asking why
        // Codex was being called out of window at all.
        let back: String
        if let at = decision.resetsAt {
            back = String(format: String(localized: "back around %@"), Fmt.stamp(at))
        } else {
            back = String(localized: "no reset time given")
        }
        // WHICH kind of unavailable. Every one of these used to read as a spent window, which sent
        // the reader off to wait out a limit while the real problem was a dead login or a call that
        // never came back — and waiting does not fix either of those.
        let headline: String
        switch decision.state {
        case "signed_out":
            headline = String(localized: "Codex is signed out — wait for it, or go on with Claude?")
        case "timeout":
            headline = String(localized: "Codex did not answer in time — wait for it, or go on with Claude?")
        case "silent":
            headline = String(localized: "Codex answered nothing — wait for it, or go on with Claude?")
        case "tampered":
            headline = String(localized: "The stand-in changed files instead of reading them — wait for Codex, or let Claude try again?")
        case "failed":
            headline = String(localized: "Codex stopped with an error — wait for it, or go on with Claude?")
        default:
            headline = String(format: String(localized: "Codex has no window left (%@) — wait for it, or go on with Claude?"),
                              back)
        }
        let labels: [String: (String, String)] = [
            "wait": (String(localized: "Wait for Codex"),
                     String(localized: "Nothing finishes until Codex has read it. The work is kept exactly as it is.")),
            "claude": (String(localized: "Go on with Claude instead"),
                       String(localized: "A separate Claude takes Codex's place for this run — same job, same read-only access, no memory of this conversation.")),
        ]
        let options = decision.choices.map { labels[$0]?.0 ?? $0 }
        var descriptions: [String: String] = [:]
        for choice in decision.choices {
            guard let pair = labels[choice] else { continue }
            descriptions[pair.0] = pair.1
        }
        return PendingUserQuestion(
            questions: [.init(question: headline, header: String(localized: "Codex"),
                              options: options, multiSelect: false,
                              optionDescriptions: descriptions)],
            askedAt: decision.askedAt,
            reasonCode: "codex_unavailable",
            summary: headline,
            situation: decision.reason.isEmpty ? nil : decision.reason,
            recommendation: String(localized: "Wait — that is what you asked for by default."),
            defaultAction: String(localized: "Nothing happens until you answer. The run stays parked."),
            unblockAction: String(localized: "Go on with Claude instead"),
            toolUseID: "codex-decision:" + decision.id)
    }

    /// Answer the engine's open question — signed, because the file itself proves nothing.
    ///
    /// Returns false when the signature could not be made (locked keychain, a denied prompt). The
    /// answer is NOT written in that case: an unsigned one would be refused by the engine anyway,
    /// and writing it would leave the interface looking as though the decision had been sent.
    @discardableResult
    func answerCodexDecision(slug: String, requestID: String, choice: String) -> Bool {
        let dir = paths.instanceDir(slug: slug)
        guard fm.fileExists(atPath: dir.path) else { return false }
        DecisionSigner.publishPublicKey(stateDir: paths.stateDir)
        // Read from the run's own folder rather than from the snapshot in hand: the engine will
        // rebuild the same pair when it verifies, and a signature made against a stale view is one
        // it will rightly refuse. Reading them here means the two agree or the answer is honestly
        // rejected as being about work that has since been replaced.
        let runID = (try? String(contentsOf: dir.appendingPathComponent("run-id"), encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        var dispatchID = ""
        if let data = try? Data(contentsOf: dir.appendingPathComponent("dispatch.json")),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            dispatchID = (obj["id"] as? String) ?? ""
        }
        guard let signature = DecisionSigner.sign(requestID: requestID, choice: choice,
                                                  runID: runID, dispatchID: dispatchID) else {
            return false
        }
        let payload: [String: Any] = ["request_id": requestID, "choice": choice,
                                      "answered_at": Date().timeIntervalSince1970,
                                      "signature": signature]
        guard let data = try? JSONSerialization.data(withJSONObject: payload) else { return false }
        let url = dir.appendingPathComponent("codex-decision-answer.json")
        guard (try? data.write(to: url, options: .atomic)) != nil else { return false }
        return true
    }

    private func readOutcome(_ url: URL) -> (WorkerOutcome?, String?) {
        guard let data = try? Data(contentsOf: url),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return (nil, nil) }
        let outcome = WorkerOutcome(raw: obj["result"] as? String)
        let summary = (obj["summary"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        return (outcome, summary)
    }

    private func readDispatch(_ url: URL) -> DispatchRecord? {
        guard let data = try? Data(contentsOf: url),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let id = obj["id"] as? String, !id.isEmpty,
              let task = obj["task"] as? String, !task.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return nil }
        let at = (obj["at"] as? String).flatMap { ISO8601DateFormatter().date(from: $0) }
        let key = (obj["report_key"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        return DispatchRecord(id: id, at: at, task: task, reportKey: key,
                              chat: obj["chat"] as? Bool ?? false)
    }

    private func readInjectFailure(_ url: URL) -> (reason: String, dispatch: String?)? {
        guard fm.fileExists(atPath: url.path) else { return nil }
        guard let data = try? Data(contentsOf: url),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return (String(localized: "The task never reached the worker"), nil)
        }
        let reason = (obj["reason"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (reason?.isEmpty == false ? reason! : String(localized: "The task never reached the worker"),
                obj["dispatch"] as? String)
    }

    private func readFinishedDispatches(_ dir: URL) -> [DispatchRecord] {
        guard let names = try? fm.contentsOfDirectory(atPath: dir.path) else { return [] }
        var out: [DispatchRecord] = []
        for name in names where name.hasSuffix(".json") {
            guard var record = readDispatch(dir.appendingPathComponent(name)) else { continue }
            let stamp = dir.appendingPathComponent(record.id + ".done")
            guard let result = readTrimmed(stamp), !result.isEmpty else { continue }
            record.result = result
            record.finishedAt = modifiedDate(stamp)
            out.append(record)
        }
        return out.sorted { ($0.finishedAt ?? .distantPast) < ($1.finishedAt ?? .distantPast) }
    }

    func answerUserQuestion(slug: String, answer: String) {
        let dir = paths.instanceDir(slug: slug)
        guard fm.fileExists(atPath: dir.path) else { return }
        let payload: [String: Any] = ["answer": answer, "answered_at": Date().timeIntervalSince1970]
        guard let data = try? JSONSerialization.data(withJSONObject: payload) else { return }
        try? data.write(to: dir.appendingPathComponent("answer.json"), options: .atomic)
    }

    func writeAskUserConfig(enabled: Bool, waitSeconds: Int) {
        try? fm.createDirectory(at: paths.stateDir, withIntermediateDirectories: true)
        try? "\(enabled ? 1 : 0)\n".write(to: paths.stateDir.appendingPathComponent("ask-user-enabled"),
                                          atomically: true, encoding: .utf8)
        try? "\(max(0, waitSeconds))\n".write(to: paths.stateDir.appendingPathComponent("ask-user-wait"),
                                              atomically: true, encoding: .utf8)
    }

    func latestEvidence(slug: String) -> Evidence? {
        latestEvidence(in: paths.instanceDir(slug: slug))
    }

    func latestEvidence(in base: URL) -> Evidence? {
        let evDir = base.appendingPathComponent("evidence")
        var candidates: [URL] = []
        if let sids = try? fm.contentsOfDirectory(at: evDir, includingPropertiesForKeys: [.contentModificationDateKey]) {
            for s in sids {
                let f = s.appendingPathComponent("evidence.json")
                if fm.fileExists(atPath: f.path) { candidates.append(f) }
            }
        }
        let newest = candidates.max { (modifiedDate($0) ?? .distantPast) < (modifiedDate($1) ?? .distantPast) }
        guard let newest, let d = try? Data(contentsOf: newest) else { return nil }
        return Evidence.decode(from: d)
    }

    private func newestEvidenceSID(_ instanceDir: URL) -> String? {
        let evDir = instanceDir.appendingPathComponent("evidence")
        guard let subs = try? fm.contentsOfDirectory(at: evDir, includingPropertiesForKeys: [.contentModificationDateKey]) else { return nil }
        let dirs = subs.filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
        return dirs.max { (modifiedDate($0) ?? .distantPast) < (modifiedDate($1) ?? .distantPast) }?.lastPathComponent
    }

    // MARK: - Findings channel (§8.4 / §10.3)

    func ingestFindings(slug: String, projectPath: String) -> [Finding] {
        let url = paths.instanceDir(slug: slug).appendingPathComponent("findings.jsonl")
        guard let raw = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        var out: [Finding] = []
        for line in raw.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let d = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
                  let text = (obj["text"] as? String), !text.isEmpty else { continue }
            let cls = (obj["class"] as? String) ?? "finding"
            out.append(Finding(cls: cls,
                               text: text,
                               cwd: (obj["cwd"] as? String) ?? projectPath,
                               timestamp: obj["ts"] as? String))
        }
        return out
    }

    func reviewReason(slug: String) -> String? {
        let url = paths.instanceDir(slug: slug)
            .appendingPathComponent("reports/review.json")
        guard let d = try? Data(contentsOf: url),
              let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
              let text = obj["findings"] as? String else { return nil }

        let body = text.split(separator: "\n", omittingEmptySubsequences: false)
            .drop { line in
                let l = line.trimmingCharacters(in: .whitespaces).uppercased()
                return l.isEmpty || l.hasPrefix("STATE:") || l.hasPrefix("VERDICT:")
            }
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return body.isEmpty ? nil : body
    }

    func runFindings(runID: String) -> [Finding] {
        guard !runID.isEmpty else { return [] }
        let url = paths.stateDir.appendingPathComponent("runs/\(runID)/findings.jsonl")
        guard let raw = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        var out: [Finding] = []
        for line in raw.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let d = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
                  let text = (obj["text"] as? String), !text.isEmpty else { continue }
            out.append(Finding(cls: (obj["class"] as? String) ?? "finding",
                               text: text,
                               cwd: obj["cwd"] as? String,
                               timestamp: obj["ts"] as? String))
        }
        return out
    }

    // MARK: - Queue

    func readQueue() -> QueueState {
        var q = QueueState()
        if let pid = readTrimmed(paths.queueRunnerPID).flatMap({ Int32($0) }) { q.runnerAlive = pidAlive(pid) }
        q.current = readTrimmed(paths.queueCurrent)
        q.stopRequested = fm.fileExists(atPath: paths.queueStopFlag.path)

        if let dirs = try? fm.contentsOfDirectory(at: paths.queuePending, includingPropertiesForKeys: nil) {
            for d in dirs.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                guard fm.fileExists(atPath: d.appendingPathComponent("project").path) else { continue }
                let name = d.lastPathComponent
                let num = Int(name.split(separator: "-").first ?? "0") ?? 0
                q.pending.append(QueuePendingEntry(
                    dirName: name, number: num,
                    projectPath: readTrimmed(d.appendingPathComponent("project")) ?? "",
                    task: readTrimmed(d.appendingPathComponent("task")) ?? ""))
            }
        }
        q.done = readDoneEntries(paths.queueDone)
        q.needsUser = readDoneEntries(paths.queueNeedsUser)
        return q
    }

    private func readDoneEntries(_ dir: URL) -> [QueueDoneEntry] {
        guard let dirs = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { return [] }
        var out: [QueueDoneEntry] = []
        for d in dirs {
            guard fm.fileExists(atPath: d.appendingPathComponent("project").path) else { continue }
            let result = readTrimmed(d.appendingPathComponent("result")) ?? "unknown"
            out.append(QueueDoneEntry(
                dirName: d.lastPathComponent,
                projectPath: readTrimmed(d.appendingPathComponent("project")) ?? "",
                task: readTrimmed(d.appendingPathComponent("task")) ?? "",
                outcome: QueueOutcome(raw: result),
                finishedAt: modifiedDate(d),
                workerOutcome: WorkerOutcome(raw: readTrimmed(d.appendingPathComponent("outcome")))))
        }
        return out.sorted { ($0.finishedAt ?? .distantPast) > ($1.finishedAt ?? .distantPast) }
    }

    // MARK: - tmux

    func tmuxSessions() async -> Set<String> {
        let r = await Shell.run("tmux list-sessions -F '#{session_name}' 2>/dev/null || true", timeout: 10)
        guard r.launched else { return [] }
        return Set(r.stdout.split(separator: "\n").map(String.init).filter { !$0.isEmpty })
    }

    @discardableResult
    func reapAbandonedTemporarySessions() async -> Int {
        let result = await Shell.run(
            "tmux list-panes -a -F '#{session_name}|#{pane_current_path}' 2>/dev/null || true",
            timeout: 10)
        guard result.launched else { return 0 }

        let temporaryRoot = fm.temporaryDirectory.resolvingSymlinksInPath().standardizedFileURL.path
        var candidates: Set<String> = []
        for line in result.stdout.split(separator: "\n") {
            let fields = line.split(separator: "|", maxSplits: 1, omittingEmptySubsequences: false)
            guard fields.count == 2 else { continue }
            let session = String(fields[0])
            let workingDirectory = String(fields[1])
            let exists = fm.fileExists(atPath: workingDirectory)
            let canonicalDirectory = URL(fileURLWithPath: workingDirectory)
                .resolvingSymlinksInPath().standardizedFileURL.path
            if Self.isAbandonedTemporarySession(name: session,
                                                workingDirectory: canonicalDirectory,
                                                temporaryRoot: temporaryRoot,
                                                pathExists: exists) {
                candidates.insert(session)
            }
        }

        var closed = 0
        for session in candidates {
            let result = await killSession(session)
            if result.launched, result.exitCode == 0 { closed += 1 }
        }
        return closed
    }

    nonisolated static func isAbandonedTemporarySession(name: String,
                                                        workingDirectory: String,
                                                        temporaryRoot: String,
                                                        pathExists: Bool) -> Bool {
        guard name.hasPrefix("night-"), !pathExists else { return false }
        let root = temporaryRoot.hasSuffix("/") ? String(temporaryRoot.dropLast()) : temporaryRoot
        return workingDirectory.hasPrefix(root + "/")
    }

    func capturePane(session: String, lines: Int = 200) async -> String {
        let r = await Shell.run("tmux capture-pane -pt \"$1\" -S -\(lines) 2>/dev/null || true",
                                args: [session], timeout: 10)
        return r.stdout
    }

    // MARK: - Commands (drive the VENDORED engine; see nightShiftCmd/nightQueueCmd)

    /// Record the director's consent to creating git in this folder.
    ///
    /// The decision lives in the run's state, not in the folder: saying yes writes nothing into
    /// anybody's files by itself. The repository appears when work starts there.
    @discardableResult
    func allowGit(projectPath: String) async -> CommandResult {
        await Shell.run("\(nightShiftCmd) allow-git \"$1\" 2>&1", args: [projectPath], timeout: 60)
    }

    @discardableResult
    func startNightShift(project: String, strategy: RunStrategy = .standing) async -> CommandResult {
        await Shell.run("\(nightShiftCmd) start \"$1\" --no-attach 2>&1", args: [project],
                        extraEnv: Self.launchEnv(strategy), timeout: 120)
    }

    private static func effortEnv(claude: String?, codex: String?,
                                  claudeModel: String? = nil, codexModel: String? = nil) -> [String: String] {
        var e: [String: String] = [:]
        if let c = claude, !c.isEmpty { e["SUPERVISOR_CLAUDE_EFFORT"] = c }
        if let c = codex, !c.isEmpty { e["SUPERVISOR_CODEX_EFFORT"] = c }

        if let m = claudeModel, !m.isEmpty { e["SUPERVISOR_CLAUDE_MODEL"] = m }
        if let m = codexModel, !m.isEmpty { e["SUPERVISOR_CODEX_MODEL"] = m }
        return e
    }

    static func launchEnv(_ strategy: RunStrategy) -> [String: String] {
        var env = effortEnv(claude: strategy.claudeEffort, codex: strategy.codexEffort,
                            claudeModel: strategy.claudeModel, codexModel: strategy.codexModel)

        if !strategy.reportLanguage.isEmpty {
            env["SUPERVISOR_REPORT_LANGUAGE"] = strategy.reportLanguage
        }

        if !strategy.workBranch.isEmpty {
            env["SUPERVISOR_WORK_BRANCH"] = strategy.workBranch
        }
        if !strategy.reportWriter.isEmpty {
            env["SUPERVISOR_REPORT_WRITER"] = strategy.reportWriter
        }
        return env
    }

    @discardableResult

    func dispatchConcurrent(project: String, task: String, runspec: RunSpec? = nil,
                            strategy: RunStrategy = .standing,
                            reportKey: String? = nil,
                            dispatchID: String? = nil) async -> CommandResult {
        guard let dispatchCmd else {
            return CommandResult(stdout: "", stderr: "concurrent dispatch unavailable", exitCode: -1, launched: false)
        }

        let env = Self.launchEnv(strategy)

        var keyArgs = reportKey.map { "--report-key \"\($0)\" " } ?? ""
        if let dispatchID, !dispatchID.isEmpty { keyArgs += "--dispatch-id \"\(dispatchID)\" " }

        if let runspec {
            let enc = JSONEncoder()
            enc.outputFormatting = [.withoutEscapingSlashes]
            if let data = try? enc.encode(runspec) {
                let tmp = FileManager.default.temporaryDirectory
                    .appendingPathComponent("runspec-\(UUID().uuidString.prefix(8)).json")
                if (try? data.write(to: tmp)) != nil {
                    return await Shell.run("\(dispatchCmd) \(keyArgs)--runspec \"$3\" \"$1\" \"$2\" 2>&1",
                                           args: [project, task, tmp.path], extraEnv: env, timeout: 120)
                }
            }
        }
        return await Shell.run("\(dispatchCmd) \(keyArgs)\"$1\" \"$2\" 2>&1",
                               args: [project, task], extraEnv: env, timeout: 120)
    }

    @discardableResult
    func stopNightShift(project: String) async -> CommandResult {
        await Shell.run("\(nightShiftCmd) stop \"$1\" 2>&1", args: [project], timeout: 60)
    }

    @discardableResult
    func stopAll() async -> CommandResult {
        await Shell.run("\(nightShiftCmd) stop --all 2>&1", timeout: 60)
    }

    @discardableResult

    func sessionExists(_ name: String) async -> Bool {
        let r = await Shell.run("tmux has-session -t \"$1\" 2>/dev/null && echo yes || true",
                                args: [name], timeout: 10)
        return r.stdout.contains("yes")
    }

    func killSession(_ name: String) async -> CommandResult {
        guard !name.isEmpty else { return CommandResult(stdout: "", stderr: "no session", exitCode: -1, launched: false) }
        return await Shell.run("tmux kill-session -t \"$1\" 2>/dev/null || echo ok", args: [name], timeout: 10)
    }

    @discardableResult
    func queueAdd(project: String, task: String) async -> CommandResult {
        await Shell.run("\(nightQueueCmd) add \"$1\" \"$2\" 2>&1", args: [project, task], timeout: 30)
    }

    @discardableResult
    func queueRun(strategy: RunStrategy = .standing) async -> CommandResult {

        await Shell.run("\(nightQueueCmd) run 2>&1",
                        extraEnv: Self.launchEnv(strategy), timeout: 30)
    }

    @discardableResult
    func queueStop() async -> CommandResult {
        await Shell.run("\(nightQueueCmd) stop 2>&1", timeout: 30)
    }

    @discardableResult
    func queueRemove(number: Int) async -> CommandResult {
        await Shell.run("\(nightQueueCmd) remove \"$1\" 2>&1", args: [String(number)], timeout: 30)
    }

    @discardableResult
    func queueClear() async -> CommandResult {
        await Shell.run("\(nightQueueCmd) clear 2>&1", timeout: 30)
    }

    @discardableResult
    func queueKillRunner() async -> CommandResult {
        await Shell.run("""
        pid=$(cat "$1" 2>/dev/null); [ -n "$pid" ] && kill "$pid" 2>/dev/null; echo ok
        """, args: [paths.queueRunnerPID.path], timeout: 15)
    }

    // MARK: - Small file readers

    private func readTrimmed(_ url: URL) -> String? {
        guard let s = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }

    /// An object id, or nothing. Runs started in a repository that had no commits yet wrote the
    /// word `HEAD` into this file — `git rev-parse HEAD` prints it rather than failing quietly —
    /// and a name that resolves to whatever HEAD is now answers every later question wrongly:
    /// nothing has changed since the work was committed, and the branch looks merged into itself.
    /// Those files are still on disk, so this is checked on the way in.
    nonisolated static func commitID(_ text: String?) -> String? {
        guard let t = text?.trimmingCharacters(in: .whitespacesAndNewlines), t.count >= 7,
              t.allSatisfy(\.isHexDigit) else { return nil }
        return t
    }

    private func readCommit(_ url: URL) -> String? { Self.commitID(readTrimmed(url)) }

    private func readOfflineSince(_ url: URL) -> Date? {
        guard let data = try? Data(contentsOf: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let raw = json["since"] as? String else { return nil }
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd HH:mm:ss"
        fmt.locale = Locale(identifier: "en_US_POSIX")
        return fmt.date(from: raw)
    }

    private func modifiedDate(_ url: URL) -> Date? {
        (try? fm.attributesOfItem(atPath: url.path)[.modificationDate]) as? Date
    }

    private func readJSONNumber(_ url: URL, key: String) -> Double? {
        guard let d = try? Data(contentsOf: url),
              let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return nil }
        if let n = obj[key] as? Double { return n }
        if let n = obj[key] as? Int { return Double(n) }
        return nil
    }

    private func readReviewProgress(_ url: URL) -> ReviewProgress? {
        guard let d = try? Data(contentsOf: url),
              let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
              let kind = (o["kind"] as? String).flatMap(ReviewProgress.Kind.init(rawValue:)),
              let round = (o["round"] as? NSNumber)?.intValue, round > 0 else { return nil }
        return ReviewProgress(kind: kind, round: round,
                              max: (o["max"] as? NSNumber)?.intValue ?? 0,
                              findings: (o["findings"] as? NSNumber)?.intValue,
                              previousFindings: (o["prev_findings"] as? NSNumber)?.intValue,
                              stall: (o["stall"] as? NSNumber)?.intValue,
                              stallLimit: (o["stall_limit"] as? NSNumber)?.intValue)
    }

    func readReviewVerdictForTesting(_ url: URL) -> ReviewVerdict? { readReviewVerdict(url) }

    private func readReviewVerdict(_ url: URL) -> ReviewVerdict? {
        guard let d = try? Data(contentsOf: url),
              let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return nil }
        let text = (o["findings"] as? String) ?? ""

        let body = text.split(separator: "\n", omittingEmptySubsequences: false)
            .drop { line in
                let l = line.trimmingCharacters(in: .whitespaces).uppercased()
                return l.isEmpty || l.hasPrefix("STATE:") || l.hasPrefix("VERDICT:")
            }
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return ReviewVerdict(state: (o["state"] as? String) ?? "",
                             verdict: (o["verdict"] as? String) ?? "",
                             disposition: (o["disposition"] as? String) ?? "",
                             round: (o["round"] as? NSNumber)?.intValue ?? 0,
                             findings: body,
                             at: (o["ts"] as? String) ?? "")
    }

    private func readJSONString(_ url: URL, key: String) -> String? {
        guard let d = try? Data(contentsOf: url),
              let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
              let s = obj[key] as? String else { return nil }
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }

    private nonisolated func pidAlive(_ pid: Int32) -> Bool {
        guard pid > 0 else { return false }
        if kill(pid, 0) == 0 { return true }
        return errno == EPERM
    }

    private nonisolated func watchdogAlive(_ pid: Int32?, slug: String) -> Bool {
        guard let pid, pidAlive(pid) else { return false }
        guard let cmd = processCommand(pid) else { return true }

        return cmd.contains("watchdog.sh") && cmd.contains(slug)
    }

    private nonisolated func processCommand(_ pid: Int32) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/ps")
        p.arguments = ["-ww", "-p", String(pid), "-o", "command="]
        let out = Pipe(); p.standardOutput = out; p.standardError = Pipe()
        do { try p.run() } catch { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        let s = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (s?.isEmpty ?? true) ? nil : s
    }
}
