import Foundation

nonisolated struct QueuePendingEntry: Sendable, Identifiable, Equatable {
    var dirName: String
    var number: Int
    var projectPath: String
    var task: String
    var id: String { dirName }
    var projectName: String { (projectPath as NSString).lastPathComponent }
}

nonisolated enum QueueOutcome: String, Sendable {
    case passed, debt, needsUser = "needs-user", handoff, blocked
    case timeout, interrupted, vanished, gone
    case startfail, injectfail
    case unknown

    init(raw: String) { self = QueueOutcome(rawValue: raw.trimmingCharacters(in: .whitespacesAndNewlines)) ?? .unknown }

    var isSuccess: Bool { self == .passed }
    var needsAttention: Bool {
        switch self {
        case .needsUser, .handoff, .blocked, .debt, .timeout, .startfail, .injectfail: true
        default: false
        }
    }

    var humanLabel: String {
        switch self {
        case .passed:      String(localized: "Passed")
        case .debt:        String(localized: "Review debt")
        case .needsUser:   String(localized: "Needs you")
        case .handoff:     String(localized: "Handed off")
        case .blocked:     String(localized: "Blocked")
        case .timeout:     String(localized: "Timed out")
        case .interrupted: String(localized: "Interrupted")
        case .vanished:    String(localized: "Stopped")
        case .gone:        String(localized: "Folder gone")
        case .startfail:   String(localized: "Start failed")
        case .injectfail:  String(localized: "Inject failed")

        case .unknown:     String(localized: "Unknown outcome")
        }
    }

    var label: String {
        switch self {
        case .passed: "Passed"
        case .debt: "Review debt"
        case .needsUser: "Needs you"
        case .handoff: "Handed off"
        case .blocked: "Blocked"
        case .timeout: "Timed out"
        case .interrupted: "Interrupted"
        case .vanished: "Stopped"
        case .gone: "Folder gone"
        case .startfail: "Start failed"
        case .injectfail: "Inject failed"
        case .unknown: "Unknown"
        }
    }
}

nonisolated struct QueueDoneEntry: Sendable, Identifiable, Equatable {
    var dirName: String
    var projectPath: String
    var task: String
    var outcome: QueueOutcome
    var finishedAt: Date?
    var workerOutcome: WorkerOutcome? = nil
    var id: String { dirName }
    var projectName: String { (projectPath as NSString).lastPathComponent }
}

nonisolated struct QueueState: Sendable, Equatable {
    var runnerAlive: Bool = false
    var current: String?
    var pending: [QueuePendingEntry] = []
    var done: [QueueDoneEntry] = []
    var needsUser: [QueueDoneEntry] = []
    var stopRequested: Bool = false

    var pendingCount: Int { pending.count }
}
