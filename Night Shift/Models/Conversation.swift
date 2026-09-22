import Foundation

// MARK: - Entry

nonisolated struct DecisionRecord: Codable, Equatable, Sendable {

    nonisolated struct Item: Codable, Equatable, Sendable {
        var question: String
        var header: String?
        var options: [String]
        var multiSelect: Bool

        var optionDescriptions: [String: String]? = nil
    }

    var headline: String

    var situation: String?
    var items: [Item]
    var gateLabelKey: String?
    var recommendation: String?
    var defaultAction: String?
    var unblockAction: String?

    var question: String { items.first?.question ?? headline }
    var options: [String] { items.first?.options ?? [] }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        headline = (try? c.decode(String.self, forKey: .headline)) ?? ""
        situation = try? c.decodeIfPresent(String.self, forKey: .situation)
        gateLabelKey = try? c.decodeIfPresent(String.self, forKey: .gateLabelKey)
        recommendation = try? c.decodeIfPresent(String.self, forKey: .recommendation)
        defaultAction = try? c.decodeIfPresent(String.self, forKey: .defaultAction)
        unblockAction = try? c.decodeIfPresent(String.self, forKey: .unblockAction)
        if let items = try? c.decode([Item].self, forKey: .items), !items.isEmpty {
            self.items = items
        } else {
            let q = (try? c.decode(String.self, forKey: .legacyQuestion)) ?? headline
            let o = (try? c.decode([String].self, forKey: .legacyOptions)) ?? []
            self.items = [Item(question: q, header: nil, options: o, multiSelect: false)]
        }
    }

    init(headline: String, situation: String? = nil, items: [Item], gateLabelKey: String? = nil,
         recommendation: String? = nil, defaultAction: String? = nil, unblockAction: String? = nil) {
        self.headline = headline
        self.situation = situation
        self.items = items
        self.gateLabelKey = gateLabelKey
        self.recommendation = recommendation
        self.defaultAction = defaultAction
        self.unblockAction = unblockAction
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(headline, forKey: .headline)
        try c.encodeIfPresent(situation, forKey: .situation)
        try c.encode(items, forKey: .items)
        try c.encodeIfPresent(gateLabelKey, forKey: .gateLabelKey)
        try c.encodeIfPresent(recommendation, forKey: .recommendation)
        try c.encodeIfPresent(defaultAction, forKey: .defaultAction)
        try c.encodeIfPresent(unblockAction, forKey: .unblockAction)
    }

    private enum CodingKeys: String, CodingKey {
        case headline, situation, items, gateLabelKey, recommendation, defaultAction, unblockAction
        case legacyQuestion = "question"
        case legacyOptions = "options"
    }
}

nonisolated struct ConversationEntry: Identifiable, Codable, Equatable, Sendable {

    enum Kind: String, Codable, Sendable {

        case user

        case foreman

        case codex

        case task

        case question

        case report

        case decision

        case event

        init(from decoder: Decoder) throws {
            let raw = try decoder.singleValueContainer().decode(String.self)
            self = Kind(rawValue: raw) ?? .foreman
        }
    }

    enum Tone: String, Codable, Sendable {
        case neutral, good, attention, problem

        init(from decoder: Decoder) throws {
            let raw = try decoder.singleValueContainer().decode(String.self)
            self = Tone(rawValue: raw) ?? .neutral
        }
    }

    enum Delivery: String, Codable, Sendable {
        case queued
        case failed

        /// He took this message back after the agent had already read it. It stays on screen,
        /// because it WAS read — but the next message says out loud that it replaces this one.
        case replaced
    }

    var id: UUID
    var productID: UUID

    var chatID: UUID?
    var kind: Kind
    var at: Date

    var text: String

    var blocks: [ConversationBlock]
    var tone: Tone

    var taskID: UUID?

    var attachments: [Attachment]

    var proposalID: UUID?

    var decision: DecisionRecord?
    var delivery: Delivery?

    /// The CLI answered with its own "sign in again" notice instead of an answer, and this entry
    /// carries it. Kept out of the conversation for good.
    ///
    /// On the entry rather than in memory, because memory does not survive a relaunch: the notice
    /// came back on screen the next morning, and the refresh after that raised the same wall again
    /// over a message that had long since been re-sent.
    var hiddenNotice: Bool?

    /// Codex refused THIS message for want of quota, and the offer to let Claude take it instead
    /// is still open. Holds the wall in the engine's own words; cleared when the offer is used.
    ///
    /// On the entry for the same reason as `hiddenNotice`, and for two more. In a dictionary keyed
    /// by chat it did not survive a relaunch — the explanation and the button vanished overnight
    /// and the message just sat there marked "not delivered". And one key per chat meant a second
    /// refused message showed the first one's offer: pressing it re-sent the wrong text.
    var codexWall: String?

    /// The turn behind this entry has ended. Written by the feed that builds the entry, because
    /// nothing else in the app can know it.
    ///
    /// `TurnReducer.isFinished` lives in the fold and is gone by the time anyone asks, and every
    /// cheaper reading is wrong in both directions: `isDirectChatBusy` is true while a review, an
    /// audit or a preparation holds a chat whose last answer finished minutes ago, and false for a
    /// worker that is merely holding a question, paused on a usage window or waiting out a network
    /// outage — see `SupervisorInstance.waitingToContinue`. And "the newest entry in a busy chat"
    /// loses the finished answer for as long as it takes a freshly sent message to produce its
    /// first block.
    ///
    /// Optional because every entry written before this existed has no answer; `adoptFinishedTurns`
    /// settles those once, at launch, when by definition nothing is streaming.
    var turnFinished: Bool?

    init(id: UUID = UUID(),
         productID: UUID,
         chatID: UUID? = nil,
         kind: Kind,
         at: Date = Date(),
         text: String = "",
         blocks: [ConversationBlock] = [],
         tone: Tone = .neutral,
         taskID: UUID? = nil,
         attachments: [Attachment] = [],
         proposalID: UUID? = nil,
         decision: DecisionRecord? = nil,
         delivery: Delivery? = nil,
         hiddenNotice: Bool? = nil,
         codexWall: String? = nil,
         turnFinished: Bool? = nil) {
        self.id = id
        self.productID = productID
        self.chatID = chatID
        self.kind = kind
        self.at = at
        self.text = text
        self.blocks = blocks
        self.tone = tone
        self.taskID = taskID
        self.attachments = attachments
        self.proposalID = proposalID
        self.decision = decision
        self.delivery = delivery
        self.hiddenNotice = hiddenNotice
        self.codexWall = codexWall
        self.turnFinished = turnFinished
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = (try? c.decode(UUID.self, forKey: .id)) ?? UUID()
        productID = try c.decode(UUID.self, forKey: .productID)
        chatID = try? c.decodeIfPresent(UUID.self, forKey: .chatID)
        kind = (try? c.decode(Kind.self, forKey: .kind)) ?? .foreman
        at = (try? c.decode(Date.self, forKey: .at)) ?? Date()
        text = (try? c.decode(String.self, forKey: .text)) ?? ""
        blocks = (try? c.decode([ConversationBlock].self, forKey: .blocks)) ?? []
        tone = (try? c.decode(Tone.self, forKey: .tone)) ?? .neutral
        taskID = try? c.decodeIfPresent(UUID.self, forKey: .taskID)
        attachments = (try? c.decode([Attachment].self, forKey: .attachments)) ?? []
        proposalID = try? c.decodeIfPresent(UUID.self, forKey: .proposalID)
        decision = try? c.decodeIfPresent(DecisionRecord.self, forKey: .decision)
        delivery = try? c.decodeIfPresent(Delivery.self, forKey: .delivery)
        hiddenNotice = try? c.decodeIfPresent(Bool.self, forKey: .hiddenNotice)
        codexWall = try? c.decodeIfPresent(String.self, forKey: .codexWall)
        turnFinished = try? c.decodeIfPresent(Bool.self, forKey: .turnFinished)
    }

    var isSpoken: Bool { kind == .user || kind == .foreman || kind == .codex }
}

// MARK: - History

nonisolated struct HistoryItem: Identifiable, Sendable, Equatable {
    var id: UUID
    var title: String
    var finishedAt: Date

    var summary: String
    var hasReport: Bool
    var outcome: String?

    var closedByYou: Bool = false

    var dayLabel: String { Fmt.dayLabel(finishedAt) }
}
