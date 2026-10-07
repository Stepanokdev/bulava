import XCTest
@testable import Bulava

/// The weekly summary that leaves the Mac. Its promise is that it says how Bulava was used and
/// nothing about whose Mac it is: a closed list of coarse values, the same list the server accepts.
nonisolated final class UsageReportTests: XCTestCase {

    private var kyiv: Calendar {
        var c = Calendar(identifier: .iso8601)
        c.timeZone = TimeZone(identifier: "Europe/Kyiv")!
        return c
    }

    private func sample() -> UsageReport {
        let now = Date(timeIntervalSince1970: 1_791_342_000)
        var raw = WeekRaw.empty(now: now, calendar: kyiv)
        raw.agentSec = [60_900, 35_340, 20_340, 0, 0, 0, 0]
        raw.heatSec[0][2] = 1_800
        raw.passed = [4, 4, 3, 0, 0, 0, 0]; raw.debt = [3, 6, 1, 0, 0, 0, 0]; raw.waiting = [4, 3, 0, 0, 0, 0, 0]
        raw.codexConsults = 9
        return UsageReport.make(raw: raw, widgets: ["limits", "autonomy", "weather"], phone: true, automations: false,
                                app: "1.12 (412)", os: "27.0", channel: "production", language: "uk")
    }

    func testTheSummaryCarriesRangesNotNumbers() {
        let r = sample()
        XCTAssertEqual(r.runs, "21–60", "28 finished runs")
        XCTAssertEqual(r.agentHours, "20–40", "32 agent-hours")
        XCTAssertEqual(r.acceptedShare, "70–80%", "21 of 28")
        XCTAssertEqual(r.activeDays, 3)
        XCTAssertTrue(r.nightWork)
        XCTAssertTrue(r.codexReview)
        XCTAssertEqual(r.widgets, ["autonomy", "limits"], "only widgets Bulava makes, in a fixed order")
        XCTAssertEqual(r.week, "2026-W41")
    }

    func testEdgesOfTheRanges() {
        XCTAssertEqual(UsageReport.bucket(0, [(0, "0"), (5, "1–5")], over: "6+"), "0")
        XCTAssertEqual(UsageReport.bucket(0.2, [(0, "0"), (5, "<5")], over: "5+"), "<5", "a little is not nothing")
        XCTAssertEqual(UsageReport.bucket(5, [(0, "0"), (5, "1–5")], over: "6+"), "1–5")
        XCTAssertEqual(UsageReport.bucket(6, [(0, "0"), (5, "1–5")], over: "6+"), "6+")
        XCTAssertEqual(UsageReport.share(10, of: 10), "90–100%")
        XCTAssertEqual(UsageReport.share(0, of: 3), "0–10%")
    }

    func testTheKeysAreExactlyTheOnesTheServerAccepts() throws {
        let data = try JSONEncoder().encode(sample())
        let keys = Set(try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any]).keys)
        XCTAssertEqual(keys, Set(UsageReport.keys), "Settings lists UsageReport.keys as what is sent")
        // And the server's own list, read from its source, so the two cannot drift apart.
        let server = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("server/report-inbox/usage.go")
        let source = try String(contentsOf: server, encoding: .utf8)
        let start = try XCTUnwrap(source.range(of: "type Usage struct {")).upperBound
        let usage = String(source[start...].prefix { $0 != "}" })
        let tags = Set(usage.matches(of: /json:"([A-Za-z]+)/).map { String($0.output.1) })
        XCTAssertEqual(tags, Set(UsageReport.keys))
    }

    func testNothingInItNamesAnyone() throws {
        let text = String(data: try JSONEncoder().encode(sample()), encoding: .utf8) ?? ""
        for leak in [NSUserName(), Host.current().localizedName ?? "\u{0}", "Users/", "/"] where !leak.isEmpty {
            if leak == "/" { continue }
            XCTAssertFalse(text.contains(leak), "“\(leak)” would leave the Mac: \(text)")
        }
        XCTAssertNotEqual(sample().id, sample().id, "a new random id every time: nothing links two weeks")
    }

    func testTheFirstSummaryIsOfAWholeWeekAfterTheSettingAppeared() {
        let wednesday = ISO8601DateFormatter().date(from: "2026-10-07T09:00:00Z")!
        // The setting first there this Wednesday: last week began before that, so nothing is due yet.
        XCTAssertNil(UsageReport.due(now: wednesday, since: wednesday, reportedWeek: nil, calendar: kyiv))
        // A week later, the week that began after it is due — and only that one.
        let nextWeek = wednesday.addingTimeInterval(7 * 86400)
        XCTAssertNil(UsageReport.due(now: nextWeek, since: wednesday, reportedWeek: nil, calendar: kyiv),
                     "the week the setting appeared in began before it")
        let twoWeeks = wednesday.addingTimeInterval(14 * 86400)
        let due = UsageReport.due(now: twoWeeks, since: wednesday, reportedWeek: nil, calendar: kyiv)
        XCTAssertEqual(due?.week, "2026-W42")
        XCTAssertNil(UsageReport.due(now: twoWeeks, since: wednesday, reportedWeek: "2026-W42", calendar: kyiv),
                     "a week is sent once")
        XCTAssertNil(UsageReport.due(now: twoWeeks, since: nil, reportedWeek: nil, calendar: kyiv),
                     "nothing before this Mac has had the setting")
    }

    /// Settings saved when a notice came before the first summary keep their date as the start.
    func testTheDateTheOldNoticeWasShownIsKeptAsTheStart() throws {
        let json = #"{"stateDirPath":"/tmp/x","pollSeconds":4,"usageNoticeShownAt":812966400,"shareUsage":true}"#
        let settings = try JSONDecoder().decode(AppSettings.self, from: Data(json.utf8))
        XCTAssertEqual(settings.usageSince, Date(timeIntervalSinceReferenceDate: 812966400))
        let again = try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(settings))
        XCTAssertEqual(again.usageSince, settings.usageSince, "and written back under its own name")
    }

    func testARefusedSummaryIsNotSentAgainAndAnOfflineOneIs() async {
        let outbox = UsageOutbox()
        let url = URL(string: "https://example.invalid/v1/usage")!
        await outbox.setTransport { _ in 422 }
        let refused = await outbox.send(sample(), to: url)
        XCTAssertEqual(refused, .refused)
        await outbox.setTransport { _ in -1 }
        let offline = await outbox.send(sample(), to: url)
        XCTAssertEqual(offline, .later)
        await outbox.setTransport { _ in 202 }
        let sent = await outbox.send(sample(), to: url)
        XCTAssertEqual(sent, .sent)
    }
}
