import Foundation

nonisolated struct ChatSessionBinding: Codable, Equatable, Sendable {

    var primaryProjectID: UUID?
    var projectPath: String
    var claudeSessionID: String?

    var codexThreadID: String?
    var activeRunID: String?
    var branch: String?
    var startedAt: Date
    var outcomeAt: Date?

    var lastCompletedTurnKey: String?

    var lastReportedTurnKey: String?
    var reportPaths: [String]

    init(primaryProjectID: UUID?, projectPath: String, claudeSessionID: String? = nil,
         codexThreadID: String? = nil,
         activeRunID: String? = nil, branch: String? = nil, startedAt: Date = Date(),
         outcomeAt: Date? = nil, lastCompletedTurnKey: String? = nil,
         lastReportedTurnKey: String? = nil, reportPaths: [String] = []) {
        self.primaryProjectID = primaryProjectID
        self.projectPath = projectPath
        self.claudeSessionID = claudeSessionID
        self.codexThreadID = codexThreadID
        self.activeRunID = activeRunID
        self.branch = branch
        self.startedAt = startedAt
        self.outcomeAt = outcomeAt
        self.lastCompletedTurnKey = lastCompletedTurnKey
        self.lastReportedTurnKey = lastReportedTurnKey
        self.reportPaths = reportPaths
    }

    // MARK: Turn keys

    static func turnKeyParts(_ key: String) -> (prompt: String, segment: Int) {
        guard let hash = key.lastIndex(of: "#"),
              let n = Int(key[key.index(after: hash)...]), n >= 0 else { return (key, 0) }
        return (String(key[..<hash]), n)
    }

    func hasReported(turnKey: String) -> Bool {
        guard let reported = lastReportedTurnKey else { return false }
        let done = Self.turnKeyParts(reported), asked = Self.turnKeyParts(turnKey)
        return done.prompt == asked.prompt && asked.segment <= done.segment
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)

        primaryProjectID = try? c.decodeIfPresent(UUID.self, forKey: .primaryProjectID)
        projectPath = (try? c.decode(String.self, forKey: .projectPath)) ?? ""
        claudeSessionID = try? c.decodeIfPresent(String.self, forKey: .claudeSessionID)
        codexThreadID = try? c.decodeIfPresent(String.self, forKey: .codexThreadID)
        activeRunID = try? c.decodeIfPresent(String.self, forKey: .activeRunID)
        branch = try? c.decodeIfPresent(String.self, forKey: .branch)
        startedAt = (try? c.decode(Date.self, forKey: .startedAt)) ?? Date()
        outcomeAt = try? c.decodeIfPresent(Date.self, forKey: .outcomeAt)
        lastCompletedTurnKey = try? c.decodeIfPresent(String.self, forKey: .lastCompletedTurnKey)
        lastReportedTurnKey = try? c.decodeIfPresent(String.self, forKey: .lastReportedTurnKey)
        reportPaths = (try? c.decode([String].self, forKey: .reportPaths)) ?? []
    }
}

nonisolated struct Chat: Identifiable, Codable, Equatable, Sendable {
    var id: UUID
    var productID: UUID

    var title: String
    var createdAt: Date

    var updatedAt: Date

    var archived: Bool
    var pinned: Bool

    var firstMessage: String

    var session: ChatSessionBinding?

    init(id: UUID = UUID(), productID: UUID, title: String = "", createdAt: Date = Date(),
         updatedAt: Date = Date(), archived: Bool = false, pinned: Bool = false,
         firstMessage: String = "", session: ChatSessionBinding? = nil) {
        self.id = id
        self.productID = productID
        self.title = title
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.archived = archived
        self.pinned = pinned
        self.firstMessage = firstMessage
        self.session = session
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        productID = try c.decode(UUID.self, forKey: .productID)
        title = (try? c.decode(String.self, forKey: .title)) ?? ""
        createdAt = (try? c.decode(Date.self, forKey: .createdAt)) ?? Date()
        updatedAt = (try? c.decode(Date.self, forKey: .updatedAt)) ?? createdAt
        archived = (try? c.decode(Bool.self, forKey: .archived)) ?? false
        pinned = (try? c.decode(Bool.self, forKey: .pinned)) ?? false
        firstMessage = (try? c.decode(String.self, forKey: .firstMessage)) ?? ""
        session = try? c.decodeIfPresent(ChatSessionBinding.self, forKey: .session)
    }

    static func title(from message: String) -> String {
        let flat = message
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !flat.isEmpty else { return String(localized: "New chat") }

        var candidate = flat
        if let stop = flat.firstIndex(where: { ".!?".contains($0) }),
           flat.distance(from: flat.startIndex, to: stop) > 12 {
            candidate = String(flat[flat.startIndex..<stop])
        }
        if candidate.count <= 52 { return candidate }
        let cut = String(candidate.prefix(52))
        if let space = cut.lastIndex(of: " "), cut.distance(from: cut.startIndex, to: space) > 20 {
            return String(cut[cut.startIndex..<space]) + "…"
        }
        return cut + "…"
    }
}
