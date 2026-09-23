import Foundation

// MARK: - User-facing lifecycle

nonisolated enum WorkState: String, Sendable, CaseIterable {
    case planned
    case running
    case needsAnswer
    case reportReady
    case paused
    case done

    case partial

    case failed

    case stopped

    var labelKey: String {
        switch self {
        case .planned:     "Planned"
        case .running:     "Running"
        case .needsAnswer: "Needs your answer"
        case .reportReady: "Report ready"
        case .paused:      "Paused"
        case .done:        "Done"
        case .partial:     "Partly done"
        case .failed:      "Stopped"
        case .stopped:     "Stopped — needs a look"
        }
    }

    var symbol: String {
        switch self {
        case .planned:     "circle.dotted"
        case .running:     "circle.fill"
        case .needsAnswer: "questionmark"
        case .reportReady: "checkmark.seal.fill"
        case .paused:      "pause.fill"
        case .partial:     "circle.bottomhalf.filled"
        case .done:        "checkmark"
        case .failed:      "exclamationmark.triangle.fill"
        case .stopped:     "pause.circle"
        }
    }

    var isOpen: Bool { self != .done }

    var wantsAttention: Bool {
        self == .needsAnswer || self == .reportReady || self == .failed || self == .partial
            || self == .stopped
    }
}

// MARK: - Milestone

nonisolated struct WorkMilestone: Identifiable, Sendable, Equatable {
    enum Mark: Sendable, Equatable {
        case done
        case current
        case waiting
        case failed

        case skipped
    }

    var id: String
    var titleKey: String
    var mark: Mark
}

// MARK: - Progress

nonisolated enum WorkProgress {

    struct StreamOutcome: Sendable, Equatable {
        var state: WorkState

        var settled: Bool

        var delivered: Bool
        var preempted: Bool = false
    }

    static func itemState(kind: WorkItem.Kind, streams: [StreamOutcome]) -> WorkState {
        guard !streams.isEmpty else { return .planned }
        if streams.contains(where: \.preempted), streams.allSatisfy({ $0.state != .running }) {
            return .paused
        }

        if kind == .variants, streams.allSatisfy(\.settled) {
            return streams.contains(where: \.delivered)
                ? (streams.contains { $0.state == .reportReady } ? .reportReady : .done)
                : .failed
        }

        let states = kind == .variants
            ? streams.map(\.state).filter { $0 != .failed }
            : streams.map(\.state)
        guard !states.isEmpty else { return .failed }

        if states.contains(.running) { return .running }
        if states.contains(.needsAnswer) { return .needsAnswer }
        if states.contains(.paused) { return .paused }

        let delivered = streams.filter(\.delivered).count
        if delivered == streams.count {
            return states.contains(.reportReady) ? .reportReady : .done
        }
        if delivered > 0, streams.allSatisfy(\.settled) { return .partial }
        if delivered > 0 { return .reportReady }
        let order: [WorkState] = [.failed, .planned, .reportReady, .done]
        return order.first { states.contains($0) } ?? .planned
    }

    static func state(task: BacklogTask, instance: SupervisorInstance?,
                      awaitingAnswer: Bool = true) -> WorkState {
        switch task.state {
        case .approved, .merged, .closed:
            return .done
        case .review:
            return .reportReady
        case .failed:
            return .failed
        case .researching, .planning, .executing, .verifying, .finalizing:

            if instance?.phase == .pausedForLimit { return .paused }
            return .running
        case .blocked, .needsClarification:
            if instance?.phase == .pausedForLimit { return .paused }

            return awaitingAnswer ? .needsAnswer : .stopped
        case .ready:
            return task.dispatchedAt == nil ? .planned : .running
        }
    }

    static func milestones(task: BacklogTask,
                           instance: SupervisorInstance?,
                           evidence: Evidence?,
                           disposition: String?,
                           hasReport: Bool) -> [WorkMilestone] {
        let user = state(task: task, instance: instance)
        let finished = user == .done || user == .reportReady
        let failed = user == .failed
        let started = task.dispatchedAt != nil

        let observable = instance != nil

        let over = finished || failed || instance?.doneResult != nil || task.lastOutcome != nil
        let unreached: WorkMilestone.Mark = over ? .skipped : .waiting

        var out: [WorkMilestone] = []

        out.append(WorkMilestone(id: "queued", titleKey: "Work handed over",
                                 mark: started ? .done : .waiting))

        let planned = instance?.hasPlan == true || task.state == .verifying || finished
        out.append(WorkMilestone(id: "plan", titleKey: "Understand the work",
                                 mark: planned ? .done
                                     : (observable ? .current : (started ? .skipped : unreached))))

        if instance?.hasResearch == true {
            out.append(WorkMilestone(id: "research", titleKey: "Research what is unclear", mark: .done))
        } else if !over {
            out.append(WorkMilestone(id: "research", titleKey: "Research what is unclear", mark: .waiting))
        } else {
            out.append(WorkMilestone(id: "research", titleKey: "Research what is unclear", mark: .skipped))
        }

        let built = finished || instance?.doneResult != nil
        let building = instance?.phase == .working
        out.append(WorkMilestone(id: "build", titleKey: "Do the work",
                                 mark: built ? .done : (building ? .current : unreached)))

        let checkMark: WorkMilestone.Mark = {
            if let evidence {
                return evidence.overallStatus == .pass ? .done : .failed
            }
            if instance?.auditState == "audit_failed" { return .failed }
            if instance?.phase == .reviewing || instance?.auditState == "audit_running" { return .current }
            return unreached
        }()
        out.append(WorkMilestone(id: "check", titleKey: "Check it really works", mark: checkMark))

        let reviewMark: WorkMilestone.Mark = {
            switch disposition {
            case "passed": return .done
            case "debt": return .done
            case .some("scope_violation"), .some("needs-user"): return .failed
            case .some: return .done
            case nil: return unreached
            }
        }()
        out.append(WorkMilestone(id: "review", titleKey: "Independent review", mark: reviewMark))

        out.append(WorkMilestone(id: "report", titleKey: "Write the report",
                                 mark: hasReport ? .done : unreached))

        if failed {

            let confirmed = out.lastIndex { ($0.mark == .done || $0.mark == .current) && $0.id != "queued" }
            if let confirmed, confirmed + 1 < out.count {
                out[confirmed + 1].mark = .failed
                for j in out.indices where j > confirmed + 1 { out[j].mark = .waiting }
            }
        }
        return out
    }

    static func nowLine(task: BacklogTask, instance: SupervisorInstance?,
                        activity: WorkerActivity.Line? = nil) -> NowLine? {
        if let q = instance?.pendingQuestion {
            return NowLine(key: "A worker is waiting on your answer.", detail: q.headline)
        }
        if let inst = instance, inst.phase == .pausedForLimit, let at = inst.pausedResumeAt {
            return NowLine(key: "Paused on a usage limit. Resumes automatically.", until: at)
        }

        if let wait = instance?.awaitingWait {
            switch wait.kind {
            case .codexWindow:
                return NowLine(key: "Codex is out of usage. Picks up by itself.", until: wait.until)
            case .director:
                return NowLine(key: "Holding for your decision.", until: wait.until)
            }
        }
        switch instance?.frozenRecovery {
        case .restarting?:
            return NowLine(key: "The worker froze — Bulava is restarting it.", detail: nil)
        case .gaveUp?:
            return NowLine(key: "The worker froze and restarting did not help. Send a message to try again.",
                           detail: nil)
        case nil: break
        }
        if instance?.stalled == true {
            return NowLine(key: "The worker went quiet — Bulava is checking on it.", detail: nil)
        }
        switch instance?.phase {
        case .reviewing:
            return NowLine(key: "Codex is reviewing the result.",
                           detail: loopPhrase(instance?.reviewProgress))
        case .working:

            let loop = loopPhrase(instance?.reviewProgress)
            if let activity {
                return NowLine(key: activity.key, detail: loop, object: activity.object)
            }
            return NowLine(key: "Claude is working.", detail: loop ?? instance?.outcomeSummary)
        case .starting:
            return NowLine(key: "Starting up.", detail: nil)
        default: break
        }
        if task.state == .finalizing {
            return NowLine(key: "Committing and merging the approved work.", detail: nil)
        }
        if task.state == .review {
            return NowLine(key: "Finished and reviewed — waiting for you.",
                           detail: instance?.outcomeSummary)
        }
        if task.state == .ready, task.dispatchedAt != nil {
            return NowLine(key: "Queued behind other work.", detail: nil)
        }
        return nil
    }

    static func loopPhrase(_ p: ReviewProgress?) -> String? {
        guard let p else { return nil }
        func t(_ key: String) -> String {
            LanguageBundle.current.localizedString(forKey: key, value: key, table: nil)
        }
        let n = "\(p.round)", max = p.max > 0 ? "\(p.max)" : "—"
        switch p.kind {
        case .nudge:
            return String(format: t("nudge %1$@ of %2$@ — told to keep going"), n, max)
        case .remediation:
            return String(format: t("fix round %1$@ of %2$@"), n, max)
        case .review:
            guard let f = p.findings else {
                return String(format: t("round %1$@ of %2$@"), n, max)
            }

            if let prev = p.previousFindings {
                return String(format: t("round %1$@ of %2$@ · findings: %3$@, was %4$@"),
                              n, max, "\(f)", "\(prev)")
            }
            return String(format: t("round %1$@ of %2$@ · findings: %3$@"), n, max, "\(f)")
        }
    }

    static func startedAt(task: BacklogTask, instance: SupervisorInstance?) -> Date? {
        instance?.startedAt ?? task.dispatchedAt
    }
}

nonisolated struct NowLine: Sendable, Equatable {
    var key: String
    var detail: String?

    var until: Date?

    var object: String?

    var sentence: String {
        let format = LanguageBundle.current.localizedString(forKey: key, value: key, table: nil)
        guard let object, !object.isEmpty, format.contains("%@") else { return format }
        return String(format: format, object)
    }
}
