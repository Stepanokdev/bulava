import XCTest
@testable import Bulava

/// What the Mac's widgets showed on 8 Oct, pinned: a frozen extension left from the version before,
/// "Булава закрита" over a Bulava that was open, an age that stopped at "6 sec. ago", and a test
/// run's week on his desktop.
nonisolated final class WidgetFreshnessTests: XCTestCase {

    // MARK: The week is written again while Bulava is open

    @MainActor
    func testTheSameWeekIsWrittenAgainWellBeforeAWidgetCallsItStale() throws {
        let model = AppModel()
        // A Wednesday noon, so an hour and more stays inside the same week.
        let start = try XCTUnwrap(Calendar.bulavaWeek.date(from: DateComponents(year: 2026, month: 10, day: 7, hour: 12)))
        model.weekRaw = WeekRaw.empty(now: start)

        model.presentWeek(now: start)
        let first = try XCTUnwrap(model.week).generatedAt

        model.presentWeek(now: start.addingTimeInterval(600))
        XCTAssertEqual(model.week?.generatedAt, first,
                       "a week that says the same is not written again every few seconds")

        let later = start.addingTimeInterval(AppModel.weekRewriteEvery + 1)
        model.presentWeek(now: later)
        let rewritten = try XCTUnwrap(model.week)
        XCTAssertEqual(rewritten.generatedAt.timeIntervalSince1970, later.timeIntervalSince1970, accuracy: 0.001,
                       "an hour on, the same week is written again")
        XCTAssertLessThan(AppModel.weekRewriteEvery, WeekSnapshot.staleAfter,
                          "the rewrite comes before a widget would say Bulava is closed")
        XCTAssertFalse(rewritten.isStale(now: start.addingTimeInterval(WeekSnapshot.staleAfter + 60)),
                       "three hours after the first write, an open Bulava's week is not stale")
    }

    // MARK: The age a stale face states

    func testAStaleFaceStatesItsAgeAtTheMomentItIsShown() {
        let written = Date(timeIntervalSince1970: 1_791_370_800)
        let drawnRightAway = FaceHeader.age(of: written, at: written.addingTimeInterval(6))
        let shownLater = FaceHeader.age(of: written, at: written.addingTimeInterval(3 * 3600))
        XCTAssertNotEqual(drawnRightAway, shownLater, "the entry three hours on says three hours, not six seconds")
        XCTAssertTrue(shownLater.contains("3"), shownLater)
    }

    // MARK: One week file per channel

    func testBulavaDevAndTheTestHostKeepTheirWeekOutOfHisWidgets() {
        XCTAssertEqual(WeekStore.fileName(channel: "production"), "week.json")
        XCTAssertEqual(WeekStore.fileName(channel: nil), "week.json", "an extension built before the key is his")
        XCTAssertEqual(WeekStore.fileName(channel: "dev"), "week-dev.json")
        XCTAssertEqual(WeekStore.fileName, "week-dev.json",
                       "this suite runs inside a Debug build — Bulava Dev — and must not write his widgets' week")
    }

    // MARK: The extension left over from before an update

    func testAnExtensionNoLongerRunningTheFileAtItsPathIsStale() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("wext-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("BulavaMacWidgets")
        try Data("x".utf8).write(to: file)
        let ours = WidgetExtension.canonical(file.path)

        XCTAssertFalse(WidgetExtension.isStale(running: file.path, ours: ours), "the current file, running")
        XCTAssertTrue(WidgetExtension.isStale(running: nil, ours: ours),
                      "macOS reports no path for a process whose file was replaced under it")
        XCTAssertTrue(WidgetExtension.isStale(
            running: "/Applications/.Bulava-replaced.app/Contents/PlugIns/BulavaMacWidgets.appex/Contents/MacOS/BulavaMacWidgets",
            ours: ours), "the old copy, moved aside by the update")
    }
}
