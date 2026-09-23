import Foundation

nonisolated enum WorkerPhase: String, Sendable {
    case starting
    case working
    case awaitingDecision
    case pausedForLimit
    case reviewing
    case done
    case blocked
    case stalled
    case offline
    case idle

    var label: String {
        switch self {
        case .starting: "Starting"
        case .working: "Working"
        case .awaitingDecision: "Awaiting decision"
        case .pausedForLimit: "Paused · limit"
        case .reviewing: "In review"
        case .done: "Finished"
        case .blocked: "Blocked"
        case .stalled: "Stalled"
        case .offline: "Waiting for the network"
        case .idle: "Idle"
        }
    }
}

/// A peer forming its position right now: when it started, and how much of it has arrived.
///
/// The chat could only say "Claude and Codex are reading this first", which is the same sentence
/// whether they started two seconds ago or two minutes ago, and the same sentence when a pipeline
/// has died. A reader watching a simple question sit under it has no way to tell thinking from
/// hung, and says so.
nonisolated struct PeerWork: Sendable, Equatable {
    var startedAt: Date
    var bytes: Int
}

nonisolated struct CodexReviewArtifact: Sendable, Equatable {
    enum Kind: String, Sendable { case review, audit, decision, position }

    var key: String
    var kind: Kind
    var at: Date
    var text: String
}

nonisolated enum WorkerOutcome: String, Sendable {
    case succeededChanges = "succeeded_changes"
    case succeededNoChange = "succeeded_no_change"
    case succeededResearch = "succeeded_research"
    case blocked
    case needsInput = "needs_input"
    case failed

    init?(raw: String?) {
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty,
              let v = WorkerOutcome(rawValue: raw) else { return nil }
        self = v
    }

    var isInformational: Bool { self == .succeededNoChange || self == .succeededResearch }
    var isSuccess: Bool { self == .succeededChanges || isInformational }

    var label: String {
        switch self {
        case .succeededChanges: "Done — changes"
        case .succeededNoChange: "Done — no change needed"
        case .succeededResearch: "Research complete"
        case .blocked: "Blocked"
        case .needsInput: "Needs your input"
        case .failed: "Failed"
        }
    }
}

nonisolated struct PendingUserQuestion: Sendable, Equatable {
    nonisolated enum Source: String, Sendable, Equatable {

        case hook

        case terminal
    }

    var record: DecisionRecord {
        DecisionRecord(headline: headline,
                       situation: situation,
                       items: questions.map {
                           .init(question: $0.question, header: $0.header,
                                 options: $0.options, multiSelect: $0.multiSelect,
                                 optionDescriptions: $0.optionDescriptions)
                       },
                       gateLabelKey: gateLabelKey,
                       recommendation: recommendation,
                       defaultAction: defaultAction,
                       unblockAction: unblockAction)
    }

    nonisolated struct Item: Sendable, Equatable {
        var question: String
        var header: String?
        var options: [String]
        var multiSelect: Bool
        var optionDescriptions: [String: String]? = nil
    }
    var questions: [Item]
    var askedAt: Date?

    var reasonCode: String?

    var summary: String?

    /// What is going on, in the engine's own words, under the headline.
    ///
    /// The card renders it; nothing used to fill it for a hook question, so a decision arrived with
    /// a classification and no evidence — "Codex has no window left" whether the window was spent,
    /// the login had died or the call had simply timed out.
    var situation: String?

    var recommendation: String?

    var defaultAction: String?

    var unblockAction: String?

    var toolUseID: String? = nil
    var source: Source = .hook

    var terminalSelectedIndex: Int? = nil
    var terminalOptionIndices: [String: Int] = [:]
    var terminalCustomOptionIndex: Int? = nil

    var terminalReview: Bool = false

    var headline: String {
        if let summary, !summary.isEmpty { return summary }
        return questions.first?.question ?? "A worker needs your decision."
    }

    var gateLabelKey: String? {
        switch reasonCode {
        case "missing_authority": "Needs an access you have and Bulava does not"
        case "irreversible":      "This cannot be undone"
        case "product_fork":      "This changes what your users will see"
        case "scope_expansion":   "This needs more room than we agreed"
        case "no_safe_probe":     "There is no safe way to find out by trying"
        default:                  nil
        }
    }
}

/// Codex cannot be reached, and the run is standing still until he says what to do about it.
///
/// This is not the ask-user channel wearing a different hat. That one answers itself after an hour
/// and carries on, which is the correct behaviour for a question about the work and exactly the
/// wrong one here: the whole point is that nothing continues without Codex unless he says so. So
/// it has its own file, its own request id, and no timeout at all — an unanswered question leaves
/// the run parked for as long as it takes.
nonisolated struct CodexDecision: Sendable, Equatable {

    /// The request this answer must name. A permission is granted once, to this question and no
    /// other — a file left over from last night unlocks nothing.
    var id: String

    /// Where the wall was hit: `review` or `preflight`.
    var stage: String

    /// `exhausted` (the window is spent) or `signed_out` (there are no credentials to call with).
    var state: String

    /// When the window is expected back. Absent when Codex would not say, and an absent one is
    /// never shown as a countdown — "back around ?" is worse than no time at all.
    var resetsAt: Date?

    var reason: String

    var askedAt: Date?

    /// In the order the engine offered them, which is the order the card shows. The answer is
    /// matched back by position rather than by the words on the button, so translating the
    /// interface cannot change what pressing it means.
    var choices: [String]
}

nonisolated struct DispatchRecord: Sendable, Equatable, Codable {
    var id: String
    var at: Date?

    var task: String

    var reportKey: String?

    var result: String?

    var finishedAt: Date?

    /// A turn of a conversation rather than a task somebody filed. The backlog adopts finished
    /// dispatches into cards; a chat that filed a card for every message typed into it would bury
    /// the real work under its own small talk.
    var chat: Bool = false

    var title: String {
        let line = task.split(whereSeparator: \.isNewline)
            .first { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            .map(String.init)?.trimmingCharacters(in: .whitespaces) ?? ""
        guard line.count > 80 else { return line }
        let cut = line.prefix(80)
        let end = cut.lastIndex(of: " ") ?? cut.endIndex
        return String(cut[..<end]) + "…"
    }
}

nonisolated struct SupervisorInstance: Sendable, Identifiable, Equatable {
    var slug: String
    var projectPath: String
    var session: String
    var branch: String?
    var baseBranch: String?
    var baseSHA: String?
    var runID: String?
    var authMode: String?
    var sessionID: String?
    var startedAt: Date?
    var lastActivity: Date?
    var watchdogAlive: Bool
    var doneResult: String?
    var finishedAt: Date?
    var pausedResumeAt: Date?
    var awaitingUntil: Date?

    var awaitingReason: String?

    var reviewProgress: ReviewProgress?

    var reviewVerdict: ReviewVerdict?
    var auditState: String?
    var reviewActive: Bool = false
    var reviewStage: String? = nil
    var workerStatus: String? = nil
    var queuedMessageCount: Int = 0
    var queuedMessageIDs: [UUID] = []
    /// A message is being prepared: two independent positions are being formed before the worker
    /// is handed anything. The pane is idle throughout, which is exactly why this has to be its
    /// own signal rather than something inferred from the session.
    ///
    /// This is narrower than it used to be, deliberately. It now means a preparation is RUNNING,
    /// not merely that something is in line for one.
    var preparing: Bool = false

    /// Something has been accepted and is not finished with: a message in the queue, or one being
    /// prepared. Whether either engine has seen it yet is a different question — `preparing`.
    var queuedWork: Bool = false

    /// What the queue is waiting for, in the pump's own words: `turn`, `limit`, `review`,
    /// `another-message`.
    var queueWaitReason: String?
    var queueWaitSince: Date?

    /// Whose limit the pause belongs to. Codex running out does not stop Claude, and the screen
    /// must not imply it does.
    var pauseProvider: String?

    /// One engine could not take part in the last reading, and why.
    var degradedNote: String?

    /// Why an engine is sitting this one out, as it is happening. Empty means it is taking part.
    var codexUnavailable: String?
    var claudeUnavailable: String?

    /// What the conversation should be told about working a hand short — the live reason while a
    /// message is being read, the settled one afterwards.
    var degradation: String? { codexUnavailable ?? claudeUnavailable ?? degradedNote }
    var failedMessageIDs: [UUID] = []
    var codexArtifacts: [CodexReviewArtifact] = []
    /// Envelopes in the queue counted as files, including any this build cannot parse. The parsed
    /// list is what the app shows; this is what says the directory is not empty.
    var pendingFiles: Int = 0
    /// Which peer is reading this message right now, if either is.
    var peerClaude: PeerWork?
    var peerCodex: PeerWork?
    var hasPlan: Bool
    var hasResearch: Bool
    var pendingQuestion: PendingUserQuestion?
    /// Set together with `pendingQuestion` when the question is about Codex being out, and read on
    /// the way back so the answer reaches the engine's own channel rather than the ask-user one.
    var codexDecision: CodexDecision?
    var scopeViolationCount: Int?
    var outcome: WorkerOutcome?
    var outcomeSummary: String?
    var stalled: Bool = false

    /// The engine found this worker frozen on a turn it had been given, and is restarting it — or
    /// restarted it and it still did not answer. Read from `hung-recovery.json` and the `recovery`
    /// the watchdog writes into `stalled.json`.
    var frozenRecovery: FrozenRecovery?

    var offline: Bool = false

    var offlineSince: Date?

    var injectFailure: String?
    var injectFailureDispatchID: String?

    var dispatch: DispatchRecord?

    var finishedDispatches: [DispatchRecord] = []

    var id: String { slug }

    var hasScopeViolation: Bool { (scopeViolationCount ?? 0) > 0 }

    var projectName: String { (projectPath as NSString).lastPathComponent }

    var active: Bool { watchdogAlive && doneResult == nil }

    /// Whether this run is doing something a second message must wait behind.
    ///
    /// Preparation counts. It holds the project, it ends in an injection, and Stop cancels it —
    /// treating it as idleness would let another chat take the project out from under two model
    /// calls that are already running.
    var turnRunning: Bool {
        workerStatus == "busy" || reviewActive || auditState == "audit_running"
            || preparing || queuedWork
    }

    /// A message is in line and nothing has started on it. The honest middle state between
    /// "accepted" and "both engines are reading it", and the one the app had no word for.
    var queuedNotStarted: Bool { queuedWork && !preparing && workerStatus != "busy" }

    /// A usage window this run is parked on, and whose it is.
    var pausedOnCodex: Bool { pausedResumeAt != nil && pauseProvider == "codex" }

    /// Work that is not running this second but is not over either.
    ///
    /// A worker holding a question for the director sits at an idle prompt. So does one paused on
    /// a usage window, one parked on a deadline, one waiting out a network outage, and one the
    /// watchdog stopped for going quiet. `turnRunning` is false for every one of them, and taking
    /// the project away on that basis would end work that was only waiting.
    var waitingToContinue: Bool {
        pendingQuestion != nil || awaitingUntil != nil || pausedResumeAt != nil
            || stalled || offline
    }

    /// Whether this run has genuinely finished — the only state in which another chat may take
    /// the project. Terminal means the gate wrote a result, not merely that nothing is happening
    /// at this instant.
    var isFinished: Bool {
        doneResult != nil && !turnRunning && !waitingToContinue
    }

    /// A run nothing is ever coming back to.
    ///
    /// Not finished — nothing wrote a result — and not running either. A worker that stopped
    /// without declaring an outcome leaves exactly this: no result, no turn, nobody about to do
    /// anything. It used to refuse every new chat in that project for ever, because "finished"
    /// means an outcome was declared and there was no longer anybody left to declare one. A tester
    /// hit it on every new conversation and had to press Stop each time, for a run that was doing
    /// nothing at all.
    ///
    /// A run holding a question, parked on a usage window or waiting for the network is NOT this.
    /// Those come back, and taking one over throws away a context nobody can recover.
    var isAbandoned: Bool {
        guard doneResult == nil, !turnRunning else { return false }
        // Counted as files, not as parsed ids: one envelope this build cannot read leaves the queue
        // looking empty, and taking the project over deletes the directory it is sitting in.
        guard pendingFiles == 0 else { return false }
        guard pendingQuestion == nil, awaitingUntil == nil, pausedResumeAt == nil, !offline else {
            return false
        }
        // A run whose watchdog has not come up yet is starting, not abandoned. Without this, a
        // second chat opened in the same seconds could clear a run that was just dispatched.
        if let started = startedAt, Date().timeIntervalSince(started) < Self.startupGrace {
            return false
        }
        if !watchdogAlive { return true }
        // Still supervised: judged by the clock, not by a marker. `stalled` is not enough on its
        // own — the engine parks a run that way for a person to look at, a new message or a
        // changed pane clears it, and something does come back to some of them. A run that has not
        // moved for twice the engine's own stall window is a different claim, and a safer one.
        return (idleSeconds ?? 0) > Self.abandonedAfter
    }

    /// Long enough for a dispatched run to get its watchdog up.
    static let startupGrace: TimeInterval = 60

    /// Twice the engine's stall-park window, so a run this call gives up on is one the engine had
    /// already given up on and then some.
    static let abandonedAfter: TimeInterval = 30 * 60

    /// Whether another chat may take this project: the run either finished properly or is never
    /// coming back.
    var isTakeable: Bool { isFinished || isAbandoned }

    var awaitingWait: AwaitingWait? {
        guard let until = awaitingUntil else { return nil }
        let reason = (awaitingReason ?? "").lowercased()

        let kind: AwaitingWait.Kind = reason.contains("window") || reason.contains("reset")
            ? .codexWindow : .director
        return AwaitingWait(kind: kind, until: until)
    }

    var phase: WorkerPhase {

        if reviewActive || auditState == "audit_running" { return .reviewing }
        if workerStatus == "busy" { return .working }
        if doneResult != nil {
            return doneResult == "needs-user" ? .blocked : .done
        }
        if awaitingUntil != nil { return .awaitingDecision }
        if pausedResumeAt != nil { return .pausedForLimit }
        if !watchdogAlive { return .idle }

        if offline { return .offline }
        if stalled { return .stalled }
        if let started = startedAt, Date().timeIntervalSince(started) < 8 { return .starting }
        return .working
    }

    var looksStuck: Bool {
        if offline { return false }
        return (!watchdogAlive && doneResult == nil)
            || (active && (idleSeconds ?? 0) > 3 * 3600)
            || (stalled && doneResult == nil)
    }

    var healthy: Bool { watchdogAlive }

    var idleSeconds: TimeInterval? {
        guard let lastActivity else { return nil }
        return Date().timeIntervalSince(lastActivity)
    }
}

nonisolated struct AwaitingWait: Sendable, Equatable {
    enum Kind: Sendable, Equatable {

        case codexWindow

        case director
    }
    var kind: Kind
    var until: Date
}

nonisolated struct ReviewProgress: Sendable, Equatable {
    enum Kind: String, Sendable {

        case review

        case remediation

        case nudge
    }
    var kind: Kind
    var round: Int
    var max: Int
    var findings: Int?
    var previousFindings: Int?
    var stall: Int?
    var stallLimit: Int?

    var isConverging: Bool {
        guard let findings, let previousFindings else { return false }
        return findings < previousFindings
    }

    var isStalling: Bool {
        guard let stall, let stallLimit, stallLimit > 0 else { return false }
        return stall >= stallLimit
    }
}

nonisolated struct ReviewVerdict: Sendable, Equatable {
    var state: String
    var verdict: String
    var disposition: String
    var round: Int
    var findings: String
    var at: String

    var isWorthShowing: Bool {
        !findings.isEmpty && (verdict.uppercased() == "FAIL" || disposition == "needs-user"
                              || disposition == "scope_violation")
    }

    var identity: String { "\(at)|\(round)|\(verdict)|\(disposition)" }
}

/// Where the engine's recovery of a frozen turn stands.
nonisolated enum FrozenRecovery: String, Sendable, Equatable {
    /// Restarted in place and nudged; waiting to see it produce again.
    case restarting
    /// Its attempts ran out. The next message from the director gets one more restart.
    case gaveUp
}
