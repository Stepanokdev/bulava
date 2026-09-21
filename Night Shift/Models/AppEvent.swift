import Foundation

nonisolated enum AppLink: Codable, Equatable, Sendable {
    case task(UUID)
    case review(UUID?)
    case report(UUID)
    case decisions
    case agents
    case confirmProposal(UUID)

    var chipTitle: String {
        switch self {
        case .task: "Відкрити задачу"
        case .review: "Відкрити ревʼю"
        case .report: "Відкрити звіт"
        case .decisions: "Відповісти"
        case .agents: "Воркери"
        case .confirmProposal: "Підтвердити"
        }
    }
    var chipIcon: String {
        switch self {
        case .task: "rectangle.righthalf.inset.filled"
        case .review: "checkmark.seal"
        case .report: "doc.richtext"
        case .decisions: "questionmark.bubble"
        case .agents: "cpu"
        case .confirmProposal: "checkmark.circle.fill"
        }
    }
}

nonisolated struct AppEvent: Identifiable, Codable, Equatable, Sendable {

    enum Origin: String, Codable, Sendable { case director, shift }

    enum Severity: String, Codable, Sendable { case info, good, attention, problem }

    enum Kind: String, Codable, Sendable {

        case taskCreated, taskEdited, taskDeleted, taskDispatched, taskStateChanged, dispatchedBatch
        case answerSent, decisionSent, changesRequested, approved, merged, prOpened, closedOut

        case reviewRejected
        case queueRun, queueStopped, workersStopped

        case workerStarted, workerAsked, workerAwaiting, workerFinished, workerStuck, reportReady

        case workerOffline, workerBackOnline
        case unknown

        init(from decoder: Decoder) throws {
            let raw = try decoder.singleValueContainer().decode(String.self)
            self = Kind(rawValue: raw) ?? .unknown
        }
    }

    var id: UUID
    var at: Date
    var kind: Kind
    var origin: Origin
    var severity: Severity
    var title: String
    var detail: String?
    var projectName: String?
    var taskID: UUID?
    var link: AppLink?

    init(id: UUID = UUID(), at: Date = Date(), kind: Kind, origin: Origin,
         severity: Severity, title: String, detail: String? = nil,
         projectName: String? = nil, taskID: UUID? = nil, link: AppLink? = nil) {
        self.id = id; self.at = at; self.kind = kind; self.origin = origin
        self.severity = severity; self.title = title; self.detail = detail
        self.projectName = projectName; self.taskID = taskID; self.link = link
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = (try? c.decode(UUID.self, forKey: .id)) ?? UUID()
        at = (try? c.decode(Date.self, forKey: .at)) ?? Date()
        kind = (try? c.decode(Kind.self, forKey: .kind)) ?? .unknown
        origin = (try? c.decode(Origin.self, forKey: .origin)) ?? .shift
        severity = (try? c.decode(Severity.self, forKey: .severity)) ?? .info
        title = (try? c.decode(String.self, forKey: .title)) ?? ""
        detail = (try? c.decodeIfPresent(String.self, forKey: .detail)) ?? nil
        projectName = (try? c.decodeIfPresent(String.self, forKey: .projectName)) ?? nil
        taskID = (try? c.decodeIfPresent(UUID.self, forKey: .taskID)) ?? nil
        link = (try? c.decodeIfPresent(AppLink.self, forKey: .link)) ?? nil
    }
}
