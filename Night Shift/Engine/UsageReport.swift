import Foundation

/// The once-a-week summary of how Bulava was used that goes to its author while the person keeps it
/// on (`AppSettings.shareUsage`).
///
/// A closed list of coarse values: ranges instead of counts, the ISO week instead of dates, yes or
/// no instead of what. No install id, account, name, project, folder, path, chat or task text, and
/// no time of day. A random id per report lets the server drop a retried upload and says nothing
/// about who sent it: the next week's report has a new one. The server keeps no IP address.
nonisolated struct UsageReport: Codable, Equatable, Sendable {
    /// Random for this report only.
    var id: String
    /// The completed ISO week it describes: "2026-W41".
    var week: String
    /// "1.12 (412)".
    var app: String
    /// "27.0".
    var os: String
    /// production | dev.
    var channel: String
    /// The interface language: en | uk | ru.
    var language: String
    /// Runs review finished: "0", "1–5", "6–20", "21–60", "60+".
    var runs: String
    /// Agent-hours: "0", "<5", "5–20", "20–40", "40–80", "80+".
    var agentHours: String
    /// Share of finished runs review accepted, in steps of ten: "70–80%". Absent with no runs.
    var acceptedShare: String?
    /// Days with any agent work, 0…7.
    var activeDays: Int
    /// Agents worked between midnight and seven.
    var nightWork: Bool
    /// Codex reviewed or advised this week.
    var codexReview: Bool
    /// A phone is paired with this Mac.
    var phone: Bool
    /// An automation ran this week.
    var automations: Bool
    /// Which of Bulava's widgets are on this Mac's desktop: autonomy, outcomes, receipt, rhythm,
    /// volume, limits, now, glance.
    var widgets: [String]

    /// The keys a report may carry: what the Settings page lists, and all the server accepts.
    static let keys = ["id", "week", "app", "os", "channel", "language", "runs", "agentHours", "acceptedShare",
                       "activeDays", "nightWork", "codexReview", "phone", "automations", "widgets"]

    static let widgetKinds: Set<String> = ["autonomy", "outcomes", "receipt", "rhythm", "volume", "limits", "now", "glance"]

    static func make(raw: WeekRaw, widgets: [String], phone: Bool, automations: Bool,
                     app: String, os: String, channel: String, language: String) -> UsageReport {
        let finished = raw.passed.reduce(0, +) + raw.debt.reduce(0, +) + raw.waiting.reduce(0, +)
        let accepted = raw.passed.reduce(0, +) + raw.debt.reduce(0, +)
        let hours = raw.agentSec.reduce(0, +) / 3600
        let night = raw.heatSec.contains { day in day.prefix(7).contains { $0 >= 60 } }
        return UsageReport(
            id: UUID().uuidString, week: raw.isoWeek, app: app, os: os, channel: channel, language: language,
            runs: bucket(Double(finished), [(0, "0"), (5, "1–5"), (20, "6–20"), (60, "21–60")], over: "60+"),
            agentHours: bucket(hours, [(0, "0"), (5, "<5"), (20, "5–20"), (40, "20–40"), (80, "40–80")], over: "80+"),
            acceptedShare: finished > 0 ? share(accepted, of: finished) : nil,
            activeDays: raw.agentSec.filter { $0 >= 60 }.count,
            nightWork: night, codexReview: raw.codexConsults > 0 || raw.codexTokens > 0,
            phone: phone, automations: automations,
            widgets: widgets.filter { widgetKinds.contains($0) }.sorted())
    }

    /// The completed week due to be reported at `now`, or nil. Only last week, never older ones sent
    /// late; never a week already sent; and never a week that began before `since` — when the
    /// setting was first there — so the first summary is of a whole week after it.
    static func due(now: Date, since: Date?, reportedWeek: String?,
                    calendar: Calendar = .bulavaWeek) -> (week: String, start: Date, end: Date)? {
        guard let shown = since else { return nil }
        let thisWeek = WeekCollector.weekBounds(containing: now, calendar: calendar)[0]
        guard let start = calendar.date(byAdding: .day, value: -7, to: thisWeek) else { return nil }
        let week = WeekCollector.isoWeek(of: start, calendar: calendar)
        guard reportedWeek != week, shown < start else { return nil }
        return (week, start, thisWeek)
    }

    /// The first range whose upper end holds the value; "0" only for nothing at all.
    static func bucket(_ v: Double, _ ranges: [(Double, String)], over: String) -> String {
        for (top, label) in ranges where v <= top {
            if top == 0, v > 0 { continue }
            return label
        }
        return over
    }

    /// "70–80%", the top step being "90–100%".
    static func share(_ part: Int, of whole: Int) -> String {
        let step = min(9, Int(Double(part) / Double(whole) * 10))
        return "\(step * 10)–\(step * 10 + 10)%"
    }
}

/// The week's report on its way to the author. One report per completed week, sent once; an
/// offline Mac or a server that is down tries again later, and a report too old to matter (four
/// weeks) is dropped rather than sent late.
///
/// Where it goes: `https://bulava-push.stepanok.com/v1/usage`, beside the error reports.
/// `BulavaUsageURL` in the app's defaults (or `BULAVA_USAGE_URL`) points elsewhere, and `off` turns
/// it off whatever the setting says. A test host never reaches the real server.
actor UsageOutbox {
    static let defaultsKey = "BulavaUsageURL"
    static let defaultEndpoint = URL(string: "https://bulava-push.stepanok.com/v1/usage")!

    private var sending = false
    var transport: @Sendable (URLRequest) async -> Int = ReportOutbox.urlSessionTransport

    func setTransport(_ t: @escaping @Sendable (URLRequest) async -> Int) { transport = t }

    nonisolated static var endpoint: URL? {
        let raw = ProcessInfo.processInfo.environment["BULAVA_USAGE_URL"]
            ?? UserDefaults.standard.string(forKey: defaultsKey)
        guard let raw else { return isTestHost ? nil : defaultEndpoint }
        guard raw.lowercased() != "off", let url = URL(string: raw),
              url.scheme == "https" || url.host == "127.0.0.1" else { return nil }
        return url
    }

    private nonisolated static var isTestHost: Bool {
        let env = ProcessInfo.processInfo.environment
        return env["XCTestConfigurationFilePath"] != nil || env["XCTestBundlePath"] != nil
            || env["XCTestSessionIdentifier"] != nil
    }

    enum Outcome: Equatable { case sent, refused, later }

    /// One attempt. `.sent` and `.refused` both close the week — a report the server does not
    /// accept will not be accepted the second time; `.later` leaves it for the next try.
    func send(_ report: UsageReport, to endpoint: URL? = UsageOutbox.endpoint) async -> Outcome {
        guard let endpoint, !sending else { return .later }
        sending = true
        defer { sending = false }
        var request = URLRequest(url: endpoint, timeoutInterval: 20)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONEncoder().encode(report)
        let status = await transport(request)
        switch status {
        case 200..<300: return .sent
        case 400, 413, 415, 422: return .refused
        default: return .later
        }
    }
}
