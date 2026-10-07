import XCTest
@testable import Bulava

/// The schedule arithmetic. Kyiv's Sunday 03:00 is the case that matters: the hour happens twice
/// on the last Sunday of October and not at all on the last Sunday of March.
nonisolated final class AutomationClockTests: XCTestCase {

    private let kyiv = "Europe/Kyiv"

    private func date(_ text: String, _ zone: String) -> Date {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: zone)
        f.dateFormat = "yyyy-MM-dd HH:mm"
        return f.date(from: text)!
    }

    private func localDay(_ d: Date, _ zone: String) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: zone)
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: d)
    }

    func testSundayThreeAmInKyivRunsOnceOnBothClockChanges() {
        let schedule = AutomationSchedule(cadence: .weekly(days: [1]), hour: 3, minute: 0, timeZoneID: kyiv)
        let times = AutomationClock.times(schedule, after: date("2026-10-01 00:00", kyiv),
                                          through: date("2027-04-30 00:00", kyiv))
        let days = times.map { localDay($0, kyiv) }
        XCTAssertEqual(days.filter { $0 == "2026-10-25" }.count, 1, "the repeated hour gives one run, not two")
        XCTAssertEqual(days.filter { $0 == "2027-03-28" }.count, 1, "the missing hour still gives one run")
        XCTAssertEqual(Set(days).count, days.count, "never two runs on one night")
        // Every one of them is a Sunday.
        var cal = Calendar(identifier: .gregorian); cal.timeZone = TimeZone(identifier: kyiv)!
        XCTAssertTrue(times.allSatisfy { cal.component(.weekday, from: $0) == 1 })
    }

    func testTheNextThreeOfADailySchedule() {
        let schedule = AutomationSchedule(cadence: .daily, hour: 2, minute: 30, timeZoneID: kyiv)
        let next = AutomationClock.next(schedule, after: date("2026-10-02 10:00", kyiv), count: 3)
        XCTAssertEqual(next, [date("2026-10-03 02:30", kyiv), date("2026-10-04 02:30", kyiv),
                              date("2026-10-05 02:30", kyiv)])
    }

    func testWeekdaysSkipTheWeekend() {
        let schedule = AutomationSchedule(cadence: .weekdays, hour: 9, minute: 0, timeZoneID: kyiv)
        // 2026-10-02 is a Friday.
        let next = AutomationClock.next(schedule, after: date("2026-10-02 10:00", kyiv), count: 2)
        XCTAssertEqual(next.map { localDay($0, kyiv) }, ["2026-10-05", "2026-10-06"])
    }

    func testEveryOtherWeekStaysOnTheWeekItWasSetUpIn() {
        let anchor = date("2026-10-02 12:00", kyiv)    // a Friday
        let schedule = AutomationSchedule(cadence: .biweekly(day: 1, anchor: anchor), hour: 3, minute: 0,
                                          timeZoneID: kyiv)
        let next = AutomationClock.next(schedule, after: anchor, count: 4)
        XCTAssertEqual(next.count, 4)
        for (a, b) in zip(next, next.dropFirst()) {
            let days = b.timeIntervalSince(a) / 86_400
            XCTAssertEqual(days, 14, accuracy: 0.05, "fortnightly does not drift (\(localDay(a, kyiv)) → \(localDay(b, kyiv)))")
        }
        // Set up on a Friday: the coming Sunday, 2026-10-04, is the first run; 2026-10-11 is skipped.
        XCTAssertEqual(localDay(next[0], kyiv), "2026-10-04")
    }

    func testTheThirtyFirstFallsOnTheLastDayOfShortMonths() {
        let schedule = AutomationSchedule(cadence: .monthly(day: 31), hour: 4, minute: 0, timeZoneID: kyiv)
        let next = AutomationClock.next(schedule, after: date("2027-01-15 00:00", kyiv), count: 3)
        XCTAssertEqual(next.map { localDay($0, kyiv) }, ["2027-01-31", "2027-02-28", "2027-03-31"])
    }

    func testEverySixHoursStaysOnItsHours() {
        let schedule = AutomationSchedule(cadence: .hourly(every: 6), hour: 1, minute: 15, timeZoneID: kyiv)
        let next = AutomationClock.next(schedule, after: date("2026-10-02 00:00", kyiv), count: 4)
        XCTAssertEqual(next, [date("2026-10-02 01:15", kyiv), date("2026-10-02 07:15", kyiv),
                              date("2026-10-02 13:15", kyiv), date("2026-10-02 19:15", kyiv)])
    }

    func testThreeMissedWeeksAreOneCatchUpAndTwoSkips() {
        let schedule = AutomationSchedule(cadence: .weekly(days: [1]), hour: 3, minute: 0, timeZoneID: kyiv)
        let owed = AutomationClock.owed(schedule, evaluatedThrough: date("2026-10-03 12:00", kyiv),
                                        now: date("2026-10-20 12:00", kyiv))
        XCTAssertEqual(owed.due, date("2026-10-18 03:00", kyiv))
        XCTAssertEqual(owed.skipped, [date("2026-10-04 03:00", kyiv), date("2026-10-11 03:00", kyiv)])
    }

    func testAMissedRunOlderThanAWeekIsNotCaughtUp() {
        let schedule = AutomationSchedule(cadence: .monthly(day: 1), hour: 3, minute: 0, timeZoneID: kyiv)
        let owed = AutomationClock.owed(schedule, evaluatedThrough: date("2026-09-20 12:00", kyiv),
                                        now: date("2026-10-20 12:00", kyiv))
        XCTAssertNil(owed.due, "a run due nineteen days ago is history, not work")
        XCTAssertEqual(owed.skipped, [date("2026-10-01 03:00", kyiv)])
    }

    func testNothingOwedBetweenTwoTimes() {
        let schedule = AutomationSchedule(cadence: .daily, hour: 3, minute: 0, timeZoneID: kyiv)
        let owed = AutomationClock.owed(schedule, evaluatedThrough: date("2026-10-02 04:00", kyiv),
                                        now: date("2026-10-02 23:00", kyiv))
        XCTAssertNil(owed.due)
        XCTAssertTrue(owed.skipped.isEmpty)
    }

    func testTheSameNightHasTheSameNameAcrossTheClockChange() {
        let schedule = AutomationSchedule(cadence: .weekly(days: [1]), hour: 3, minute: 0, timeZoneID: kyiv)
        let night = AutomationClock.times(schedule, after: date("2026-10-24 12:00", kyiv),
                                          through: date("2026-10-26 00:00", kyiv))
        XCTAssertEqual(night.count, 1)
        XCTAssertEqual(AutomationClock.occurrenceKey(night[0], schedule), "slot:2026-10-25T03:00")
    }
}
