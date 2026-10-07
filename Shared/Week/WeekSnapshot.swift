import Foundation

/// One calendar week of Bulava's work, as every widget, the Mac's Week page and the phone draw it.
///
/// The Mac computes it (`WeekCollector`, `WeekPresenter`); everything else only lays it out. Every
/// word in it is already in the Mac's language and every number already formatted — the same rule as
/// the link (`LinkWire.swift`): a widget on the Mac, the iPhone or Android never picks a plural or
/// a unit, so all three say exactly what the Mac says. Numbers travel beside the words only where a
/// chart needs their size.
///
/// The same JSON is the phone's `home.week` (`Wire.kt` mirrors it key for key) and the file the
/// Mac's widgets read. New fields are optional or have defaults: an older reader ignores them.
nonisolated struct WeekSnapshot: Codable, Equatable, Sendable {
    static let currentVersion = 1

    var v: Int = WeekSnapshot.currentVersion
    /// When the Mac computed it, in milliseconds since 1970. A reader keeps the newest it has seen.
    var generatedMs: Int64
    /// The ISO week, "2026-W41": tells a reader whether what it holds is still this week.
    var week: String
    /// The week as a heading says it: "5–11 жовт.".
    var period: String
    /// The seven days, Monday first: "Пн" … "Нд".
    var days: [String]
    /// Which of the seven is today. Days after it are still ahead and drawn empty, not as zero.
    var today: Int
    /// The person switched weekly statistics off: the faces carry nothing and say so.
    var off: Bool = false
    var words: WeekWords
    var autonomy: AutonomyFace
    var outcomes: OutcomesFace
    var receipt: ReceiptFace
    var rhythm: RhythmFace
    var volume: VolumeFace
    var limits: LimitsFace
    var now: NowFace

    var generatedAt: Date { Date(timeIntervalSince1970: TimeInterval(generatedMs) / 1000) }

    /// Older than this and a widget says how old it is instead of passing it off as current.
    static let staleAfter: TimeInterval = 3 * 3600

    func isStale(now: Date = Date()) -> Bool { now.timeIntervalSince(generatedAt) > Self.staleAfter }

    /// The same week saying the same things: only the moment it was written, and the running
    /// minutes a widget counts by itself, differ. What decides whether the widgets are redrawn.
    func saysTheSame(as other: WeekSnapshot) -> Bool {
        var a = self, b = other
        a.generatedMs = 0; b.generatedMs = 0
        for i in a.now.runs.indices { a.now.runs[i].time = "" }
        for i in b.now.runs.indices { b.now.runs[i].time = "" }
        return a == b
    }

    static func decode(_ data: Data) -> WeekSnapshot? {
        guard let s = try? JSONDecoder().decode(WeekSnapshot.self, from: data), s.v >= 1,
              s.days.count == 7 else { return nil }
        return s
    }

    func encoded() -> Data? {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys]
        return try? e.encode(self)
    }
}

/// Words every face shares.
nonisolated struct WeekWords: Codable, Equatable, Sendable {
    /// "Статистику вимкнено".
    var off: String
    /// "Віджет нічого не рахує, поки її не ввімкнути."
    var offHint: String
    /// "Увімкнути в Булаві".
    var turnOn: String
    /// What a stale widget on the Mac says before the age: "Булава закрита".
    var appClosed: String
    /// What a stale widget on the phone says before the age: "Mac не на зв'язку".
    var macAway: String
    /// "7 днів" is not a calendar week; this is the short word under a period: "тиждень".
    var week: String
    /// "зараз" — the heading of what is a live reading rather than a week's total.
    var now: String
}

/// A line with an optional emphasised beginning: **50 хв** роботи на кожне твоє повідомлення.
nonisolated struct WeekLine: Codable, Equatable, Sendable {
    var strong: String? = nil
    var text: String
}

/// A labelled value in a list: "Найдовший хід — 4 год 17 хв".
nonisolated struct WeekKV: Codable, Equatable, Sendable {
    var label: String
    var value: String
}

// MARK: - The faces

/// A. How long the agents worked without you.
nonisolated struct AutonomyFace: Codable, Equatable, Sendable {
    var title: String
    /// "63" — agent-hours this week.
    var hero: String
    /// "год".
    var unit: String
    var lines: [WeekLine]
    /// Agent minutes per day, Monday first; nil for a day still ahead.
    var perDay: [Int?]
    var facts: [WeekKV]
    /// Said instead of the lines when the agents did nothing this week.
    var empty: String?
    var spoken: String
}

/// B. How the runs ended.
nonisolated struct OutcomesFace: Codable, Equatable, Sendable {
    var title: String
    /// "35" accepted.
    var hero: String
    /// "прийнято".
    var unit: String
    /// passed · debt · waiting, in that order, each with its own words.
    var legend: [WeekLegend]
    /// Per day [passed, debt, waiting]; nil for a day still ahead.
    var perDay: [[Int]?]
    var lines: [WeekLine]
    var facts: [WeekKV]
    var empty: String?
    var spoken: String
}

nonisolated struct WeekLegend: Codable, Equatable, Sendable {
    /// passed | debt | waiting — the colour a reader draws it in.
    var key: String
    var text: String
}

/// D. The week's receipt at API prices.
nonisolated struct ReceiptFace: Codable, Equatable, Sendable {
    var title: String
    /// "Чек тижня" — the longer title for bigger faces.
    var longTitle: String
    /// "за цінами API".
    var caption: String
    /// "≈ $1 125".
    var hero: String
    var rows: [WeekKV]
    var total: WeekKV
    /// "оцінка, не витрати".
    var note: String
    /// "7,7 млн токенів".
    var tokens: String
    /// Estimated dollars per day, for the bars; nil for a day still ahead.
    var perDay: [Double?]
    /// "ціни API · не витрати · план Team".
    var footer: String
    var spoken: String
}

/// E. The week's rhythm: seven days by twenty-four hours.
nonisolated struct RhythmFace: Codable, Equatable, Sendable {
    var title: String
    var longTitle: String
    /// Agent minutes in each hour, [day][hour], Monday first; nil for a day still ahead. Parallel
    /// agents add up, so an hour can hold more than sixty.
    var heat: [[Int]?]
    var peakLabel: String
    /// "20:00", or "—" before anything ran.
    var peak: String
    var activeLabel: String
    /// "6".
    var active: String
    /// "/7".
    var activeOf: String
    /// The small face's single line: "пік 20:00 · активні дні 6/7".
    var line: String
    var spoken: String
}

/// F. How much code changed.
nonisolated struct VolumeFace: Codable, Equatable, Sendable {
    var title: String
    var longTitle: String
    /// "+35,4 тис.".
    var added: String
    /// "−830".
    var removed: String
    /// "рядки · 215 файлів".
    var line: String
    /// "215 файлів · 43 коміти".
    var detail: String
    /// Per day [added, removed]; nil for a day still ahead.
    var perDay: [[Int]?]
    var spoken: String
}

/// G. Claude's and Codex's limits, with the pace.
nonisolated struct LimitsFace: Codable, Equatable, Sendable {
    var title: String
    var meters: [WeekMeter]
    /// The small face's line: "Claude: швидше за темп".
    var line: String
    /// Said instead of the meters while neither engine's limits are known.
    var empty: String?
    var spoken: String
}

nonisolated struct WeekMeter: Codable, Equatable, Sendable {
    /// "Claude".
    var engine: String
    /// "Claude · тиждень".
    var label: String
    /// true for the weekly window, false for the session one.
    var weekly: Bool
    /// 0…100.
    var used: Int
    /// "20%".
    var usedText: String
    /// How much of the window has already passed, 0…100 — where an even pace would stand.
    var elapsed: Int?
    /// "швидше за темп" · "у темпі" · "із запасом".
    var pace: String?
    /// ahead | even | behind.
    var paceKey: String?
    /// ok | warn | bad.
    var severity: String
    /// When it comes back: "2 год 5 хв".
    var resets: String?
}

/// H. Who is working now.
nonisolated struct NowFace: Codable, Equatable, Sendable {
    var title: String
    var longTitle: String
    /// "2".
    var count: String
    /// "агенти".
    var unit: String
    var runs: [WeekRun]
    /// "1 прогін чекає на тебе".
    var waiting: String?
    /// "Зараз ніхто не працює".
    var empty: String
    var spoken: String
}

nonisolated struct WeekRun: Codable, Equatable, Sendable {
    var name: String
    /// "47 хв", or the word for waiting — as it stood when the Mac wrote it.
    var time: String
    var waiting: Bool
    /// When it started, ms since 1970: a widget that can run its own clock counts up from it, so the
    /// minutes stay right between the Mac's writes.
    var sinceMs: Int64? = nil
}

// MARK: - Where the Mac's widgets find it

#if os(macOS)
nonisolated enum WeekStore {
    /// The App Group both the Mac app and its widget extension are entitled to. Prefixed with the
    /// team, which on macOS needs no provisioning profile and raises no "access data from other
    /// apps" prompt.
    static let appGroup = "KHU94Q2JSS.group.bulava.week"
    static let fileName = "week.json"

    /// The shared container, or — for a build signed without the entitlement — the same path under
    /// the home folder, which only a non-sandboxed process can reach.
    static func fileURL() -> URL {
        if let url = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroup) {
            return url.appendingPathComponent(fileName)
        }
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home.appendingPathComponent("Library/Group Containers/\(appGroup)/\(fileName)")
    }

    static func read() -> WeekSnapshot? {
        guard let data = try? Data(contentsOf: fileURL()) else { return nil }
        return WeekSnapshot.decode(data)
    }
}
#endif
