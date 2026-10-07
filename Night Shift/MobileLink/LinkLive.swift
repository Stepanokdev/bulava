import CryptoKit
import Foundation

/// The story of one stretch of work, as the Lock Screen of an iPhone tells it: what is running by
/// name, what stopped since the stretch began and how, and when the stretch is over.
///
/// Built from one reading of the app after another. A line that drops out of "running" does not
/// count as stopped at once — between Claude's answer and Codex's review a chat can look idle for
/// a moment — so it keeps its place until it has stayed out for `settle`. Only then is it ended,
/// told as finished (the push, the Live Activity's last word), and the stretch over once nothing
/// has run for as long. A Mac that just started begins with nothing running: what finished while
/// it was not looking is not news.
nonisolated struct LiveTracker: Equatable, Sendable {

    /// How long a line has to stay out of "running" to count as stopped. Tests shorten it.
    var settle: TimeInterval = 20
    /// What a phone is sent at most: the Lock Screen shows three lines and counts the rest.
    static let maxRunning = 6
    static let maxEnded = 3

    private(set) var running: [String: LiveLineDTO] = [:]
    private var missingSince: [String: Date] = [:]
    private(set) var ended: [LiveLineDTO] = []
    private var lastActive: Date?
    private(set) var over = true

    /// Takes one reading. Returns the lines that count as stopped as of now, each with its outcome.
    /// `working` is the count of runs that go on by themselves; a run no line names still keeps the
    /// stretch going.
    mutating func observe(_ lines: [LiveLineDTO], working: Int, now: Date,
                          outcome: (LiveLineDTO) -> (code: String, label: String?)) -> [LiveLineDTO] {
        let active = !lines.isEmpty || working > 0
        if active {
            if over { ended = [] }
            over = false
            lastActive = now
        }
        let present = Set(lines.map(\.id))
        for line in lines {
            running[line.id] = line
            missingSince[line.id] = nil
        }
        var stopped: [LiveLineDTO] = []
        for (id, line) in running where !present.contains(id) {
            let since = missingSince[id] ?? now
            missingSince[id] = since
            guard now.timeIntervalSince(since) >= settle else { continue }
            running[id] = nil
            missingSince[id] = nil
            var done = line
            let how = outcome(line)
            done.outcome = how.code
            done.label = how.label
            stopped.append(done)
        }
        for line in stopped.sorted(by: { ($0.sinceMs ?? 0) < ($1.sinceMs ?? 0) }) {
            ended.removeAll { $0.id == line.id }
            ended.insert(line, at: 0)
        }
        ended = Array(ended.prefix(Self.maxEnded))
        if !over, running.isEmpty, !active, let lastActive, now.timeIntervalSince(lastActive) >= settle {
            over = true
        }
        return stopped
    }

    /// Whether a line is waiting out its `settle` — the moment to look again.
    var settling: Bool { !missingSince.isEmpty || (!over && running.isEmpty) }

    var detail: LiveDTO {
        let lines = running.values.sorted { ($0.sinceMs ?? 0) > ($1.sinceMs ?? 0) }
        return LiveDTO(running: Array(lines.prefix(Self.maxRunning)), ended: ended, over: over)
    }
}

/// What a Live Activity is told by name, sealed so that only the phone that made the key can read
/// it. The relay carries it as an opaque string next to the three counts, and Apple the same: the
/// promise that nothing of the work passes through a server of ours holds for the names too.
///
/// The key is the phone's (`push.register`'s `seal`), 32 random bytes it keeps in its Keychain for
/// its Lock Screen widget and handed to this Mac over the pinned link. AES-GCM, a fresh nonce each
/// time, bound to `aad` so a box made for something else never opens as this.
nonisolated enum LiveSeal {

    static let aad = Data("bulava.live.v1".utf8)

    /// A title as the Lock Screen has room for it. The whole box has to fit an ActivityKit push
    /// (4 KB, with the counts and Apple's own keys), and a Cyrillic letter is two bytes.
    static let titleLimit = 40
    static let productLimit = 24

    /// The same story in short keys: every byte here travels through Apple's push service.
    struct Box: Codable, Equatable {
        struct Line: Codable, Equatable {
            var title: String
            var product: String
            var sinceMs: Int64?
            var outcome: String?

            enum CodingKeys: String, CodingKey {
                case title = "t", product = "p", sinceMs = "s", outcome = "o"
            }
        }
        var running: [Line]
        /// How many are running in all, when more than `running` names.
        var count: Int
        var ended: [Line]
        var over: Bool
        /// The product and chat the first line is about, for a tap on the activity.
        var productID: String?
        var chatID: String?

        enum CodingKeys: String, CodingKey {
            case running = "r", count = "n", ended = "e", over = "x", productID = "pi", chatID = "ci"
        }
    }

    static func box(_ live: LiveDTO) -> Box {
        func line(_ l: LiveLineDTO) -> Box.Line {
            Box.Line(title: clip(l.title, titleLimit), product: clip(l.product, productLimit),
                     sinceMs: l.sinceMs, outcome: l.outcome)
        }
        let first = live.running.first ?? live.ended.first
        return Box(running: live.running.prefix(3).map(line), count: live.running.count,
                   ended: live.ended.prefix(3).map(line), over: live.over,
                   productID: first?.productID, chatID: first?.chatID)
    }

    /// The where of a tap on a completion push: which chat to open. Nothing else.
    struct Route: Codable, Equatable {
        var productID: String?
        var chatID: String?

        enum CodingKeys: String, CodingKey { case productID = "pi", chatID = "ci" }
    }

    /// The key a phone sent, if it is one: 32 bytes, base64.
    static func key(_ raw: String?) -> SymmetricKey? {
        guard let raw, let data = Data(base64Encoded: raw), data.count == 32 else { return nil }
        return SymmetricKey(data: data)
    }

    static func seal<T: Encodable>(_ value: T, key: SymmetricKey) -> String? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard let plain = try? encoder.encode(value),
              let box = try? AES.GCM.seal(plain, using: key, authenticating: aad),
              let combined = box.combined else { return nil }
        return combined.base64EncodedString()
    }

    static func open<T: Decodable>(_ sealed: String, as type: T.Type, key: SymmetricKey) -> T? {
        guard let data = Data(base64Encoded: sealed),
              let box = try? AES.GCM.SealedBox(combined: data),
              let plain = try? AES.GCM.open(box, using: key, authenticating: aad) else { return nil }
        return try? JSONDecoder().decode(type, from: plain)
    }

    static func clip(_ s: String, _ limit: Int) -> String {
        let flat = s.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces)
        guard flat.count > limit else { return flat }
        return String(flat.prefix(limit - 1)).trimmingCharacters(in: .whitespaces) + "…"
    }
}
