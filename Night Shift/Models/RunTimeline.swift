import Foundation

/// One line of `<instance>/run-events.jsonl`: something that HAPPENED to a run, written by the engine
/// at the moment it happened and signed with the message it belongs to.
nonisolated struct RunEvent: Decodable, Sendable, Equatable {
    struct Stage: Decodable, Sendable, Equatable {
        var id: String
        var node: String?
        var group: String?
        var optional: Bool?
    }

    var at: String?
    var ms: Double?
    var runID: String?
    var dispatchID: String?
    var messageID: String?
    var pipeline: String?
    var stage: String
    var state: String
    var note: String?
    var node: String?
    var round: Int?
    var max: Int?
    var findings: Int?
    var attempt: Int?
    var result: String?
    var disposition: String?
    var kind: String?
    var snapshot: String?
    var revision: Int?
    var stages: [Stage]?
    var reason: String?
    var resumeAt: Double?
    var nodeRole: String?

    enum CodingKeys: String, CodingKey {
        case at, ms, pipeline, stage, state, note, node, round, max, findings, attempt, result
        case disposition, kind, snapshot, revision, stages, reason
        case runID = "run_id", dispatchID = "dispatch_id", messageID = "message_id"
        case resumeAt = "resume_at", nodeRole = "node_role"
    }

    var date: Date? { ms.map { Date(timeIntervalSince1970: $0 / 1000) } }

    /// Lines that are not events are skipped, never fatal: a half-written last line is the normal
    /// state of a file somebody is appending to right now.
    static func parse(lines: some Sequence<Substring>) -> [RunEvent] {
        let decoder = JSONDecoder()
        var out: [RunEvent] = []
        for line in lines {
            guard line.first == "{", let data = line.data(using: .utf8),
                  let e = try? decoder.decode(RunEvent.self, from: data) else { continue }
            out.append(e)
        }
        return out
    }
}

/// What a node of a running pipeline is doing, in the words the run view uses.
nonisolated enum RunNodeState: String, Sendable, Equatable, CaseIterable {
    case queued, running, delivered, done, verified, failed, retrying, waiting, skipped, unavailable, cancelled, parked

    /// Motion belongs to these and only these: something is actually happening there.
    var isActive: Bool { self == .running || self == .delivered || self == .retrying }
    var isFinished: Bool { self == .done || self == .verified }
}

nonisolated struct RunNodeStatus: Sendable, Equatable {
    var state: RunNodeState = .queued
    var note: String?
    var round: Int?
    var max: Int?
    /// How many findings a check sent the work back with.
    var findings: Int?
    var at: Date?
}

/// The run as a whole, for the one line under the chat that is always there.
nonisolated enum RunOverall: Sendable, Equatable {
    case notStarted
    case preparing
    case working
    case checking
    case returned(round: Int, max: Int)
    case waitingForYou(String?)
    case waitingForCodex
    case waitingForLimit
    case finished(String)
    case cancelled
    case failed(String?)

    var isLive: Bool {
        switch self {
        case .preparing, .working, .checking, .returned: true
        default: false
        }
    }
}

nonisolated struct RunGraph: Sendable, Equatable {
    var messageID: String
    var pipeline: String?
    var snapshot: String?
    var nodes: [String: RunNodeStatus] = [:]
    var overall: RunOverall = .notStarted
    var events: [RunEvent] = []
    var startedAt: Date?
    var lastEventAt: Date?

    func status(_ node: String) -> RunNodeStatus { nodes[node] ?? RunNodeStatus() }

    var isLive: Bool { overall.isLive }
}

/// Events → states. Nothing else: no timers, no guesses from how long it has been. A node changes
/// only when an event about it arrives, so a run whose engine stopped writing stands still on the
/// screen instead of animating towards an end that is not happening.
nonisolated enum RunReducer {

    static func reduce(events all: [RunEvent], messageID: String, document: PipelineDocument?) -> RunGraph {
        let events = all.filter { $0.messageID == messageID }
        var g = RunGraph(messageID: messageID, events: events)
        guard !events.isEmpty else { return g }
        g.startedAt = events.first?.date
        g.lastEventAt = events.last?.date
        g.pipeline = events.first(where: { $0.pipeline?.isEmpty == false })?.pipeline

        let nodes = document?.nodes ?? []
        func ids(withKey key: String) -> [String] { nodes.filter { $0.key == key }.map(\.id) }
        func ids(withPrefix prefix: String) -> [String] { nodes.filter { $0.key.hasPrefix(prefix) }.map(\.id) }
        let agent = nodes.first { ["agent.claude", "agent.codex", "agent.researcher"].contains($0.key) }?.id
        let triggers = ids(withPrefix: "trigger.")
        let gateNodes = ["gate.scope", "gate.verify", "gate.review", "gate.reportReview"].flatMap { ids(withKey: $0) }
        var stageNode: [String: String] = [:]
        var agentStages: Set<String> = []

        /// `rounds` is false when the event is about another step — a review's round is not the
        /// worker's round, and a note left from an earlier state does not describe the new one.
        func set(_ id: String?, _ state: RunNodeState, _ e: RunEvent, note: String? = nil, rounds: Bool = true) {
            guard let id else { return }
            var s = g.nodes[id] ?? RunNodeStatus()
            let same = s.state == state
            s.state = state
            s.note = note ?? e.note ?? (same ? s.note : nil)
            if rounds {
                if let r = e.round { s.round = r }
                if let m = e.max { s.max = m }
                s.findings = e.findings ?? (same ? s.findings : nil)
            }
            s.at = e.date ?? s.at
            g.nodes[id] = s
        }
        func node(for e: RunEvent) -> String? {
            if let n = e.node, !n.isEmpty, nodes.contains(where: { $0.id == n }) || document == nil { return n }
            return stageNode[e.stage] ?? (nodes.contains(where: { $0.id == e.stage }) ? e.stage : nil)
        }

        for e in events {
            let state = e.state
            switch e.stage {
            case "pipeline":
                for s in e.stages ?? [] {
                    let n = s.node ?? s.id
                    stageNode[s.id] = n
                    if n == agent { agentStages.insert(s.id) }
                }
                if g.snapshot == nil { g.snapshot = e.snapshot }
                switch state {
                case "running":
                    triggers.forEach { set($0, .done, e, note: e.note) }
                    g.overall = .preparing
                case "done":
                    if case .preparing = g.overall { g.overall = .working }
                case "cancelled":
                    cancelRemaining(&g, e)
                    g.overall = .cancelled
                case "failed":
                    g.overall = .failed(e.note)
                default: break
                }
            case "gate":
                if state == "running" {
                    if let agent, g.status(agent).state.isActive || g.status(agent).state == .delivered {
                        set(agent, .done, e, note: e.note, rounds: false)
                    }
                    g.overall = .checking
                }
            case "gate.scope", "gate.verify", "gate.review", "gate.reportReview":
                let targets = ids(withKey: e.stage)
                let mapped: RunNodeState = runState(state)
                targets.forEach { set($0, mapped, e) }
                if e.stage == "gate.review" || e.stage == "gate.reportReview" {
                    switch state {
                    case "retrying":
                        // Sent back: the worker is at it again, and every gate after it will run anew.
                        set(agent, .running, e, note: e.note, rounds: false)
                        for gid in gateNodes where !targets.contains(gid) { g.nodes[gid] = RunNodeStatus() }
                        g.overall = .returned(round: e.round ?? 1, max: e.max ?? 0)
                    case "waiting":
                        g.overall = e.reason == "codex-limit" || e.reason == "unreachable" ? .waitingForCodex : .waitingForYou(e.note)
                    case "running":
                        g.overall = .checking
                    default: break
                    }
                }
            case "gate.skill":
                ids(withKey: "skill.require").forEach { set($0, runState(state), e) }
                // A miss that still has retries left carries its ceiling; one without it is the
                // gate giving up and asking.
                if state == "failed", let max = e.max {
                    set(agent, .running, e, note: e.note, rounds: false)
                    g.overall = .returned(round: e.attempt ?? 1, max: max)
                } else if state == "failed" {
                    g.overall = .waitingForYou(e.note)
                }
            case "outcome":
                if state == "declared" {
                    switch e.result ?? "" {
                    case "needs_input", "blocked":
                        set(agent, .waiting, e)
                        g.overall = .waitingForYou(e.note)
                    case "failed":
                        set(agent, .failed, e)
                    default:
                        set(agent, .done, e)
                    }
                } else if state == "nudged" {
                    set(agent, .running, e)
                }
            case "agent":
                if state == "waiting" { set(agent, .waiting, e); g.overall = .waitingForLimit }
                if state == "nudged" { set(agent, .running, e) }
            case "run":
                let d = e.disposition ?? state
                // The run is over, whatever its last step said. A step still "working" after the
                // run ended is a step nobody closed — an engine that parked a run on a BLOCKED
                // review used to leave exactly that, and the chat showed "Codex review · working"
                // under "work stopped". Accepted work closes what was open; anything else leaves
                // it waiting for the person, with the reason when the engine gave one.
                let settled: RunNodeState = (d == "passed" || d == "debt") ? .done : .waiting
                for (id, status) in g.nodes where status.state.isActive {
                    var closed = status
                    closed.state = settled
                    if settled == .waiting, let why = e.note, !why.isEmpty { closed.note = why }
                    g.nodes[id] = closed
                }
                switch d {
                case "passed":
                    ids(withKey: "out.report").forEach { set($0, .done, e, note: nil) }
                    ids(withKey: "out.merge").forEach { set($0, .waiting, e, note: nil) }
                    g.overall = .finished("passed")
                case "debt":
                    ids(withKey: "out.report").forEach { set($0, .done, e, note: nil) }
                    ids(withKey: "out.merge").forEach { set($0, .waiting, e, note: nil) }
                    g.overall = .finished("debt")
                default:
                    g.overall = .waitingForYou(e.note)
                }
            default:
                guard let n = node(for: e) else { continue }
                if n == agent || agentStages.contains(e.stage) || e.nodeRole == "agent" {
                    switch state {
                    case "running": set(n, .running, e)
                    case "delivered": set(n, .delivered, e)
                    case "parked": set(n, .parked, e)
                    case "failed": set(n, .failed, e)
                    case "cancelled": set(n, .cancelled, e)
                    default: break   // the hand-over finishing is not the work finishing
                    }
                } else {
                    set(n, runState(state), e)
                }
            }
        }
        // A worker that confirmed receipt is working until something says otherwise.
        if let agent, g.status(agent).state == .delivered, case .working = g.overall {
            var s = g.status(agent); s.state = .running; g.nodes[agent] = s
        } else if let agent, g.status(agent).state == .delivered, case .preparing = g.overall {
            g.overall = .working
        }
        return g
    }

    private static func runState(_ s: String) -> RunNodeState {
        switch s {
        case "running": .running
        case "done": .done
        case "verified", "passed": .verified
        case "failed": .failed
        case "retrying": .retrying
        case "waiting": .waiting
        case "skipped": .skipped
        case "unavailable": .unavailable
        case "cancelled": .cancelled
        case "delivered": .delivered
        case "parked": .parked
        default: .queued
        }
    }

    private static func cancelRemaining(_ g: inout RunGraph, _ e: RunEvent) {
        for (id, s) in g.nodes where s.state.isActive || s.state == .waiting {
            var c = s; c.state = .cancelled; c.note = e.note; g.nodes[id] = c
        }
    }

    /// The message whose run the chat should show: the newest one that has events at all.
    static func latestMessage(in events: [RunEvent], among messageIDs: [String]) -> String? {
        let wanted = Set(messageIDs)
        return events.last(where: { $0.messageID.map(wanted.contains) ?? false })?.messageID
    }
}

/// A chat's latest run together with the description it follows — the pair the run view draws.
nonisolated struct ChatRun: Sendable, Equatable {
    var graph: RunGraph
    var document: PipelineDocument?
}
