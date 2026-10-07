import XCTest
@testable import Bulava

/// The week's numbers, from files laid out the way Claude Code, Codex, the engine and Bulava write
/// them. Each test pins one rule the widgets depend on: parallel agents add up while the clock does
/// not, a session begun last week brings none of last week in, a record seen twice counts once, a
/// day that changes the clock is still one day.
nonisolated final class WeekCollectorTests: XCTestCase {

    private var root: URL!
    private let kyiv: Calendar = {
        var c = Calendar(identifier: .iso8601)
        c.timeZone = TimeZone(identifier: "Europe/Kyiv")!
        return c
    }()

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("week-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    // MARK: Fixtures

    private var sources: WeekCollector.Sources {
        WeekCollector.Sources(claudeProjects: root.appendingPathComponent("projects"),
                              codexSessions: root.appendingPathComponent("codex"),
                              decisions: root.appendingPathComponent("decisions.jsonl"),
                              conversations: root.appendingPathComponent("conversations.json"),
                              readGit: false)
    }

    private func at(_ s: String) -> Date { ISO8601DateFormatter().date(from: s)! }

    private func stamp(_ d: Date) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.string(from: d)
    }

    private func line(_ obj: [String: Any]) -> String {
        String(data: try! JSONSerialization.data(withJSONObject: obj), encoding: .utf8)!
    }

    private func turn(_ uuid: String, ends: Date, minutes: Double, cwd: String = "/Users/x/Developer/app") -> String {
        line(["type": "system", "subtype": "turn_duration", "uuid": uuid, "timestamp": stamp(ends),
              "durationMs": minutes * 60_000, "cwd": cwd, "sessionId": "s-\(uuid)", "isSidechain": false])
    }

    private func answer(_ id: String, at: Date, output: Int, cacheRead: Int = 0, model: String = "claude-opus-5-5") -> String {
        line(["type": "assistant", "uuid": UUID().uuidString, "timestamp": stamp(at), "cwd": "/Users/x/Developer/app",
              "message": ["id": id, "model": model,
                          "usage": ["input_tokens": 10, "output_tokens": output, "cache_read_input_tokens": cacheRead,
                                    "cache_creation_input_tokens": 0]]])
    }

    private func edit(_ uuid: String, at: Date, path: String, plus: Int, minus: Int) -> String {
        let lines = Array(repeating: "+a", count: plus) + Array(repeating: "-b", count: minus)
        return line(["type": "user", "uuid": uuid, "timestamp": stamp(at), "cwd": "/Users/x/Developer/app",
                     "toolUseResult": ["filePath": path, "structuredPatch": [["lines": lines]]]])
    }

    private func price(model: String = "claude-opus-5-5", perToken: Double) -> String {
        // 2M output tokens, weighted ×5: cost = 10M weighted tokens × price.
        line(["type": "cost-state", "modelUsage": [model: ["inputTokens": 0, "outputTokens": 2_000_000,
                                                            "cacheReadInputTokens": 0, "cacheCreationInputTokens": 0,
                                                            "costUSD": 10_000_000 * perToken]]])
    }

    private func write(_ lines: [String], folder: String = "-Users-x-Developer-app", file: String = "a.jsonl") throws {
        let dir = root.appendingPathComponent("projects/\(folder)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try (lines.joined(separator: "\n") + "\n").write(to: dir.appendingPathComponent(file), atomically: true, encoding: .utf8)
    }

    private func collect(now: Date) async -> WeekRaw {
        await WeekCollector(sources: sources).collect(now: now, calendar: kyiv)
    }

    // MARK: The week itself

    func testTheWeekIsMondayToMondayInTheMacsTimeZone() {
        let bounds = WeekCollector.weekBounds(containing: at("2026-10-07T03:00:00Z"), calendar: kyiv)
        XCTAssertEqual(bounds.count, 8)
        XCTAssertEqual(bounds[0], at("2026-10-04T21:00:00Z"), "Monday 5 Oct, 00:00 in Kyiv")
        XCTAssertEqual(bounds[7], at("2026-10-11T21:00:00Z"))
        XCTAssertEqual(WeekCollector.isoWeek(of: at("2026-10-07T03:00:00Z"), calendar: kyiv), "2026-W41")
        XCTAssertEqual(WeekRaw.dayIndex(of: at("2026-10-07T03:00:00Z"), bounds: bounds), 2, "Wednesday")
    }

    func testTheDayTheClocksGoBackIsStillOneDay() {
        // Kyiv leaves summer time on Sunday 25 Oct 2026: that day is 25 hours long.
        let bounds = WeekCollector.weekBounds(containing: at("2026-10-22T09:00:00Z"), calendar: kyiv)
        XCTAssertEqual(bounds[7].timeIntervalSince(bounds[6]), 25 * 3600)
        XCTAssertEqual(bounds[7].timeIntervalSince(bounds[0]), 169 * 3600)
        var hours = Array(repeating: 0.0, count: 24)
        WeekCollector.spread(bounds[6], bounds[7], bounds: bounds, calendar: kyiv) { d, h, s in
            XCTAssertEqual(d, 6)
            hours[h] += s
        }
        XCTAssertEqual(hours.reduce(0, +), 25 * 3600, "every second of the long day lands somewhere")
        XCTAssertEqual(hours[3], 7200, "the repeated hour holds both of its hours")
    }

    // MARK: Time

    func testParallelAgentsAddUpButTheClockDoesNot() async throws {
        // Two agents, 21:00–23:00 and 22:00–23:00 Kyiv on Monday.
        try write([turn("t1", ends: at("2026-10-05T20:00:00Z"), minutes: 120),
                   turn("t2", ends: at("2026-10-05T20:00:00Z"), minutes: 60)])
        let raw = await collect(now: at("2026-10-07T03:00:00Z"))
        XCTAssertEqual(raw.agentSec[0], 3 * 3600, accuracy: 1)
        XCTAssertEqual(raw.wallSec[0], 2 * 3600, accuracy: 1)
        XCTAssertEqual(raw.peakParallel, 2)
        XCTAssertEqual(raw.longestSec, 7200, accuracy: 1)
        XCTAssertEqual(raw.heatSec[0][22], 7200, accuracy: 1, "two agents in the same hour")
    }

    func testATurnAcrossMidnightIsSplitBetweenItsDays() async throws {
        // 23:00 Monday → 01:00 Tuesday, Kyiv.
        try write([turn("t1", ends: at("2026-10-05T22:00:00Z"), minutes: 120)])
        let raw = await collect(now: at("2026-10-07T03:00:00Z"))
        XCTAssertEqual(raw.agentSec[0], 3600, accuracy: 1)
        XCTAssertEqual(raw.agentSec[1], 3600, accuracy: 1)
    }

    func testOnlyTheWeeksPartOfATurnBegunLastWeekCounts() async throws {
        // Began Sunday 23:00 Kyiv, ended Monday 01:00.
        try write([turn("t1", ends: at("2026-10-04T22:00:00Z"), minutes: 120)])
        let raw = await collect(now: at("2026-10-07T03:00:00Z"))
        XCTAssertEqual(raw.agentSec.reduce(0, +), 3600, accuracy: 1)
    }

    func testARecordSeenTwiceCountsOnce() async throws {
        let t = turn("same", ends: at("2026-10-06T10:00:00Z"), minutes: 30)
        let a = answer("msg_1", at: at("2026-10-06T10:00:00Z"), output: 1000)
        try write([t, a, a], file: "a.jsonl")
        try write([t, a], file: "b.jsonl")   // a resumed session carries its history along
        let raw = await collect(now: at("2026-10-07T03:00:00Z"))
        XCTAssertEqual(raw.agentSec.reduce(0, +), 1800, accuracy: 1)
        XCTAssertEqual(raw.tokensOut, 1000)
    }

    func testBulavasOwnServiceCallsAreNotWork() async throws {
        try write([turn("t1", ends: at("2026-10-06T10:00:00Z"), minutes: 30)], folder: "-Users-x--bulava-cap-ABCD-p1")
        try write([turn("t2", ends: at("2026-10-06T10:00:00Z"), minutes: 30, cwd: "/private/var/folders/xy/T/run")],
                  folder: "-Users-x-other")
        let raw = await collect(now: at("2026-10-07T03:00:00Z"))
        XCTAssertEqual(raw.agentSec.reduce(0, +), 0)
    }

    // MARK: Lines and money

    func testLinesCountCodeNotStringsLocksOrReports() async throws {
        try write([
            edit("e1", at: at("2026-10-06T10:00:00Z"), path: "/Users/x/Developer/app/Sources/A.swift", plus: 10, minus: 2),
            edit("e2", at: at("2026-10-06T10:00:00Z"), path: "/Users/x/Developer/app/Localizable.xcstrings", plus: 900, minus: 0),
            edit("e3", at: at("2026-10-06T10:00:00Z"), path: "/Users/x/Developer/app/package-lock.json", plus: 500, minus: 0),
            edit("e4", at: at("2026-10-06T10:00:00Z"), path: "/Users/x/Developer/app/artifacts/r/index.html", plus: 300, minus: 0),
            edit("e5", at: at("2026-10-06T10:00:00Z"), path: "/private/tmp/scratch.py", plus: 40, minus: 0),
        ])
        let raw = await collect(now: at("2026-10-07T03:00:00Z"))
        XCTAssertEqual(raw.added.reduce(0, +), 10)
        XCTAssertEqual(raw.removed.reduce(0, +), 2)
        XCTAssertEqual(raw.files, 1)
    }

    func testTheCostUsesThePriceClaudeCodeItselfCharged() async throws {
        try write([price(perToken: 2.5e-6),
                   answer("m1", at: at("2026-10-06T10:00:00Z"), output: 1_000_000)])
        let raw = await collect(now: at("2026-10-07T03:00:00Z"))
        // (10 input + 5 × 1M output) × $2.5 per million.
        XCTAssertEqual(raw.costPerDay[1], (10 + 5_000_000) * 2.5e-6, accuracy: 0.01)
        XCTAssertTrue(raw.unpriced.isEmpty)
    }

    func testAModelNobodyPricedIsNamedNotGuessed() async throws {
        try write([answer("m1", at: at("2026-10-06T10:00:00Z"), output: 1000, model: "claude-new-model")])
        let raw = await collect(now: at("2026-10-07T03:00:00Z"))
        XCTAssertEqual(raw.costPerDay.reduce(0, +), 0)
        XCTAssertEqual(raw.unpriced, ["claude-new-model"])
    }

    func testASmallUnpricedModelDoesNotMarkTheReceiptIncomplete() async throws {
        try write([price(perToken: 2.5e-6),
                   answer("m1", at: at("2026-10-06T10:00:00Z"), output: 1_000_000),
                   answer("m2", at: at("2026-10-06T10:00:00Z"), output: 500, model: "claude-haiku-4-5")])
        let raw = await collect(now: at("2026-10-07T03:00:00Z"))
        XCTAssertTrue(raw.unpriced.isEmpty, "half a thousand tokens of a small model is not a gap in the receipt")
        XCTAssertGreaterThan(raw.costPerDay[1], 12)
    }

    // MARK: Outcomes, messages, Codex

    func testADispatchEndsOnceWithItsLastWord() async throws {
        let journal = [
            line(["ts": "2026-10-06T08:00:00Z", "kind": "terminal", "dispatch_id": "d1", "disposition": "needs-user"]),
            line(["ts": "2026-10-06T09:00:00Z", "kind": "terminal", "dispatch_id": "d1", "disposition": "passed"]),
            line(["ts": "2026-10-06T09:30:00Z", "kind": "terminal", "dispatch_id": "d2", "disposition": "debt"]),
            line(["ts": "2026-10-03T09:30:00Z", "kind": "terminal", "dispatch_id": "d0", "disposition": "passed"]),
            line(["ts": "2026-10-06T07:00:00Z", "kind": "dispatch-delivered", "dispatch_id": "d1"]),
            line(["ts": "2026-10-06T07:30:00Z", "kind": "peer-consultation"]),
        ]
        try journal.joined(separator: "\n").write(to: sources.decisions, atomically: true, encoding: .utf8)
        let raw = await collect(now: at("2026-10-07T03:00:00Z"))
        XCTAssertEqual(raw.passed.reduce(0, +), 1)
        XCTAssertEqual(raw.debt.reduce(0, +), 1)
        XCTAssertEqual(raw.waiting.reduce(0, +), 0, "the review that stopped was answered and passed")
        XCTAssertEqual(raw.tasksGiven, 1)
        XCTAssertEqual(raw.codexConsults, 1)
    }

    func testOnlyThePersonsOwnMessagesCount() async throws {
        let list: [[String: Any]] = [
            ["kind": "user", "at": "2026-10-06T08:00:00Z"],
            ["kind": "user", "at": "2026-10-07T01:00:00Z"],
            ["kind": "foreman", "at": "2026-10-06T08:01:00Z"],
            ["kind": "user", "at": "2026-10-01T08:00:00Z"],
        ]
        try JSONSerialization.data(withJSONObject: list).write(to: sources.conversations)
        let raw = await collect(now: at("2026-10-07T03:00:00Z"))
        XCTAssertEqual(raw.prompts, [0, 1, 1, 0, 0, 0, 0])
    }

    func testCodexCountsTheWeeksGrowthOfASessionBegunBefore() async throws {
        let dir = root.appendingPathComponent("codex/2026/10/04")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        func count(_ ts: String, _ total: Int) -> String {
            line(["timestamp": ts, "type": "event_msg",
                  "payload": ["type": "token_count", "info": ["total_token_usage": ["input_tokens": total, "output_tokens": 0]]]])
        }
        try [count("2026-10-04T10:00:00.000Z", 1_000), count("2026-10-04T20:00:00.000Z", 5_000),
             count("2026-10-05T10:00:00.000Z", 7_000), count("2026-10-06T10:00:00.000Z", 12_000)]
            .joined(separator: "\n").write(to: dir.appendingPathComponent("rollout-x.jsonl"), atomically: true, encoding: .utf8)
        let raw = await collect(now: at("2026-10-07T03:00:00Z"))
        XCTAssertEqual(raw.codexTokens, 7_000, "12 000 at the end minus the 5 000 it had on Sunday")
    }

    // MARK: Reading only what changed

    func testAGrowingTranscriptIsReadFromWhereItLeftOff() async throws {
        let collector = WeekCollector(sources: sources)
        try write([turn("t1", ends: at("2026-10-06T10:00:00Z"), minutes: 10)])
        var raw = await collector.collect(now: at("2026-10-07T03:00:00Z"), calendar: kyiv)
        XCTAssertEqual(raw.agentSec.reduce(0, +), 600, accuracy: 1)

        // The session goes on: a second turn is appended, the first stays where it was.
        let file = root.appendingPathComponent("projects/-Users-x-Developer-app/a.jsonl")
        let handle = try FileHandle(forWritingTo: file)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data((turn("t2", ends: at("2026-10-06T11:00:00Z"), minutes: 20) + "\n").utf8))
        // Half a line, as a writer mid-way leaves it: read next time, not now.
        try handle.write(contentsOf: Data(#"{"type":"system","subtype":"turn_dur"#.utf8))
        try handle.close()
        try FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: file.path)
        raw = await collector.collect(now: at("2026-10-07T03:00:00Z"), calendar: kyiv)
        XCTAssertEqual(raw.agentSec.reduce(0, +), 1800, accuracy: 1)
    }

    // MARK: Pace

    func testThePaceComparesUseWithTheShareOfTheWindowGone() {
        let now = at("2026-10-07T03:00:00Z")
        // A week window with 5 days 21 hours left has 16% behind it.
        let reset = now.addingTimeInterval((5 * 24 + 21) * 3600)
        XCTAssertEqual(LimitPace.elapsedPercent(resetsAt: reset, windowMinutes: 10080, now: now), 16)
        XCTAssertEqual(LimitPace.key(used: 20, elapsed: 16), "ahead")
        XCTAssertEqual(LimitPace.key(used: 38, elapsed: 53), "behind")
        XCTAssertEqual(LimitPace.key(used: 50, elapsed: 48), "even")
        XCTAssertNil(LimitPace.elapsedPercent(resetsAt: nil, windowMinutes: 300, now: now))
        XCTAssertNil(LimitPace.elapsedPercent(resetsAt: now.addingTimeInterval(-60), windowMinutes: 300, now: now))
    }
}

/// The Swift collector against the prototype's Python one, on this Mac's real files. Off unless
/// asked for (`TEST_RUNNER_BULAVA_REAL_WEEK=1`): it reads the person's own transcripts.
nonisolated final class WeekCollectorRealDataTests: XCTestCase {
    func testTheRealWeekAsTheCollectorReadsIt() async throws {
        guard ProcessInfo.processInfo.environment["BULAVA_REAL_WEEK"] == "1" else { throw XCTSkip("real data not requested") }
        var sources = WeekCollector.Sources.standard
        sources.readGit = true
        let raw = await WeekCollector(sources: sources).collect()
        let out: [String: Any] = [
            "agentMin": raw.agentSec.map { Int(($0 / 60).rounded()) },
            "wallMin": raw.wallSec.map { Int(($0 / 60).rounded()) },
            "prompts": raw.prompts, "passed": raw.passed, "debt": raw.debt, "waiting": raw.waiting,
            "added": raw.added, "removed": raw.removed, "files": raw.files,
            "tokensOut": raw.tokensOut, "cacheRead": raw.cacheRead, "cost": raw.costPerDay.map { Int($0.rounded()) },
            "codexTokens": raw.codexTokens, "commits": raw.commits, "peak": raw.peakParallel,
            "longestMin": Int((raw.longestSec / 60).rounded()), "today": raw.today, "week": raw.isoWeek,
            "unpriced": raw.unpriced,
        ]
        let data = try JSONSerialization.data(withJSONObject: out, options: [.sortedKeys])
        try data.write(to: URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("bulava-real-week.json"))
        print("REAL_WEEK " + String(data: data, encoding: .utf8)!)
    }
}
