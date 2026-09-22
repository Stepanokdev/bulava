import Foundation

// MARK: - Who it is written for

/// What he wrote in Settings about himself, made safe to put in a prompt.
///
/// Free text on purpose: "iOS / Swift", "backend, Go, no frontend", "designer, I read code but do
/// not write it". A preset list would have to guess at the set of people who use this, and the one
/// thing worth knowing about the reader is the thing a list leaves out.
nonisolated enum LearningProfile {

    /// Long enough for a real sentence about yourself, short enough that it cannot become the
    /// prompt. Anything past this is his own doing and is cut without ceremony.
    static let limit = 240

    /// Trimmed, on one line, bounded. Whitespace alone is empty — otherwise the button promises a
    /// tailored explanation and the prompt carries three spaces.
    static func normalized(_ raw: String) -> String {
        String(raw.split(whereSeparator: \.isWhitespace).joined(separator: " ").prefix(limit))
    }

    static func isGiven(_ raw: String) -> Bool { !normalized(raw).isEmpty }
}

// MARK: - How deep

/// The two passes an explanation comes in.
///
/// Short first, and deeper only when asked. A finished result has to answer "what happened" before
/// anything else, and a lesson bolted onto every result buries exactly that.
nonisolated enum ExplainDepth: String, Codable, Sendable, CaseIterable {

    /// What was done, why, and what to check. Three short sections.
    case brief

    /// The walk-through: each step, what it changed, what the technology is.
    case stepByStep

    var id: String { rawValue }

    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = ExplainDepth(rawValue: raw) ?? .brief
    }
}

// MARK: - What is being explained

/// The record an explanation belongs to.
///
/// A turn is keyed by its entry, not by its chat: keyed by chat, explaining one turn would lock
/// out every other turn in the same conversation, and the answer would land under whichever turn
/// happened to be last.
nonisolated enum ExplainAnchor: Hashable, Sendable {
    case turn(UUID)
    case task(UUID)

    var key: String {
        switch self {
        case .turn(let id): "turn:" + id.uuidString
        case .task(let id): "task:" + id.uuidString
        }
    }
}

// MARK: - The explanation itself

nonisolated struct Explanation: Codable, Equatable, Sendable {

    var text: String

    /// The profile that was actually applied, word for word, or empty for plain words. Stored
    /// rather than read back from Settings: the panel says which background this was written
    /// through, and that has to stay true after the profile is edited.
    var profile: String

    var languageName: String

    /// A digest of the material it was written from. When the record changes underneath — a report
    /// regenerated, a turn re-read from a resumed transcript — the panel says so instead of
    /// presenting an answer about an older version of the same thing.
    var fingerprint: String

    var at: Date

    init(text: String, profile: String, languageName: String, fingerprint: String,
         at: Date = Date()) {
        self.text = text
        self.profile = profile
        self.languageName = languageName
        self.fingerprint = fingerprint
        self.at = at
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        text = (try? c.decode(String.self, forKey: .text)) ?? ""
        profile = (try? c.decode(String.self, forKey: .profile)) ?? ""
        languageName = (try? c.decode(String.self, forKey: .languageName)) ?? "English"
        fingerprint = (try? c.decode(String.self, forKey: .fingerprint)) ?? ""
        at = (try? c.decode(Date.self, forKey: .at)) ?? Date()
    }
}
