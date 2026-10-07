import XCTest
@testable import Bulava

/// The Lock Screen's story of a stretch of work: what runs, what stopped and how, and when it is
/// over — without calling a chat finished in the moment between Claude's answer and Codex's review.
nonisolated final class LiveTrackerTests: XCTestCase {

    private func line(_ id: String, since: Int64 = 1) -> LiveLineDTO {
        LiveLineDTO(id: id, productID: "P1", chatID: id.hasPrefix("chat:") ? String(id.dropFirst(5)) : nil,
                    title: "Work \(id)", product: "Narada", sinceMs: since, outcome: nil)
    }

    func testALineThatDropsOutForAMomentIsStillRunning() {
        var t = LiveTracker()
        let start = Date(timeIntervalSince1970: 1_000)
        _ = t.observe([line("chat:A")], working: 1, now: start) { _ in ("done", nil) }
        // Claude has answered; Codex has not started its review yet.
        let blink = t.observe([], working: 0, now: start.addingTimeInterval(5)) { _ in ("done", nil) }
        XCTAssertTrue(blink.isEmpty)
        XCTAssertEqual(t.detail.running.map(\.id), ["chat:A"], "a line waiting out its settle keeps its place")
        XCTAssertFalse(t.detail.over)
        XCTAssertTrue(t.settling)
        // The review starts: it was never over.
        _ = t.observe([line("chat:A")], working: 1, now: start.addingTimeInterval(8)) { _ in ("done", nil) }
        let later = t.observe([], working: 0, now: start.addingTimeInterval(20)) { _ in ("done", nil) }
        XCTAssertTrue(later.isEmpty, "the settle starts again from the last time it was seen")
        XCTAssertTrue(t.detail.ended.isEmpty)
    }

    func testAStoppedLineIsEndedWithItsOutcomeAndTheStretchIsOver() {
        var t = LiveTracker()
        let start = Date(timeIntervalSince1970: 1_000)
        _ = t.observe([line("chat:A", since: 2), line("task:B", since: 1)], working: 2, now: start) { _ in ("", nil) }
        _ = t.observe([line("task:B", since: 1)], working: 1, now: start.addingTimeInterval(1)) { _ in ("", nil) }
        let stopped = t.observe([line("task:B", since: 1)], working: 1, now: start.addingTimeInterval(30)) { _ in ("done", nil) }
        XCTAssertEqual(stopped.map(\.id), ["chat:A"])
        XCTAssertEqual(stopped.first?.outcome, "done")
        XCTAssertEqual(t.detail.running.map(\.id), ["task:B"])
        XCTAssertEqual(t.detail.ended.map(\.id), ["chat:A"])
        XCTAssertFalse(t.detail.over, "something still runs")

        _ = t.observe([], working: 0, now: start.addingTimeInterval(40)) { _ in ("attention", nil) }
        let last = t.observe([], working: 0, now: start.addingTimeInterval(61)) { _ in ("attention", nil) }
        XCTAssertEqual(last.map(\.outcome), ["attention"])
        XCTAssertEqual(t.detail.ended.map(\.id), ["task:B", "chat:A"], "newest first")
        XCTAssertTrue(t.detail.over, "nothing has run for a while: the stretch is over")
        XCTAssertFalse(t.settling)

        // The next stretch starts from nothing.
        _ = t.observe([line("chat:C")], working: 1, now: start.addingTimeInterval(100)) { _ in ("", nil) }
        XCTAssertTrue(t.detail.ended.isEmpty)
        XCTAssertFalse(t.detail.over)
    }

    func testARunNoLineNamesKeepsTheStretchGoing() {
        var t = LiveTracker()
        let start = Date(timeIntervalSince1970: 1_000)
        _ = t.observe([], working: 1, now: start) { _ in ("", nil) }
        XCTAssertFalse(t.detail.over)
        _ = t.observe([], working: 0, now: start.addingTimeInterval(5)) { _ in ("", nil) }
        XCTAssertFalse(t.detail.over, "the count dropping for a moment is not the end either")
        _ = t.observe([], working: 0, now: start.addingTimeInterval(26)) { _ in ("", nil) }
        XCTAssertTrue(t.detail.over)
    }

    func testTheSealedBoxOpensOnlyWithItsKeyAndFitsALiveActivity() throws {
        let key = LiveSeal.key(Data(repeating: 7, count: 32).base64EncodedString())!
        let other = LiveSeal.key(Data(repeating: 8, count: 32).base64EncodedString())!
        let long = String(repeating: "Довга назва роботи ", count: 10)
        let live = LiveDTO(running: (0..<6).map { i in
            LiveLineDTO(id: "chat:\(i)", productID: UUID().uuidString, chatID: UUID().uuidString, title: long,
                        product: long, sinceMs: 1_790_000_000_000, outcome: nil)
        }, ended: (0..<3).map { i in
            LiveLineDTO(id: "task:\(i)", productID: UUID().uuidString, chatID: nil, title: long, product: long,
                        sinceMs: 1_790_000_000_000, outcome: "done")
        }, over: false)
        let sealed = try XCTUnwrap(LiveSeal.seal(LiveSeal.box(live), key: key))
        XCTAssertLessThan(sealed.utf8.count, 3000, "the relay takes at most 3000, and Apple 4 KB for the whole push")
        let box = try XCTUnwrap(LiveSeal.open(sealed, as: LiveSeal.Box.self, key: key))
        XCTAssertEqual(box.running.count, 3)
        XCTAssertEqual(box.count, 6, "the rest are counted")
        XCTAssertLessThanOrEqual(box.running[0].title.count, LiveSeal.titleLimit)
        XCTAssertTrue(box.running[0].title.hasSuffix("…"))
        XCTAssertNil(LiveSeal.open(sealed, as: LiveSeal.Box.self, key: other), "another key opens nothing")
        XCTAssertNotEqual(LiveSeal.seal(LiveSeal.box(live), key: key), sealed, "a fresh nonce every time")
        XCTAssertNil(LiveSeal.key("short"))
    }
}
