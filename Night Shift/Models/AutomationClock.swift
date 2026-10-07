import Foundation

/// When a schedule says to run, worked out on the wall clock of the schedule's own time zone.
///
/// "Sunday at 03:00" in Kyiv lands on a clock change twice a year: the hour happens twice in
/// October and not at all in March. A run is placed on the first of a repeated hour and on the
/// next real minute of a missing one, so either night still gets exactly one run.
nonisolated enum AutomationClock {

    /// How far back a missed time is still worth catching up. Older ones are recorded as skipped.
    static let catchUpWindow: TimeInterval = 7 * 24 * 3600

    /// A run that starts this much after its time is "late", and the history says so.
    static let lateAfter: TimeInterval = 10 * 60

    static func calendar(for schedule: AutomationSchedule) -> Calendar {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = schedule.timeZone
        cal.locale = Locale(identifier: "en_US_POSIX")
        return cal
    }

    /// The next `count` times strictly after `after`.
    static func next(_ schedule: AutomationSchedule, after: Date, count: Int) -> [Date] {
        times(schedule, after: after, through: nil, limit: count)
    }

    /// Every time in `(after, through]`, oldest first, at most `limit`.
    static func times(_ schedule: AutomationSchedule, after: Date, through: Date?, limit: Int = 1_000) -> [Date] {
        let cal = calendar(for: schedule)
        var out: [Date] = []
        var day = cal.startOfDay(for: after)
        // A year and a bit of days is more than any cadence here needs to find its next time.
        for _ in 0..<400 {
            for time in candidates(schedule, on: day, calendar: cal) where time > after {
                if let through, time > through { return out }
                out.append(time)
                if out.count >= limit { return out }
            }
            guard let tomorrow = cal.date(byAdding: .day, value: 1, to: day) else { break }
            day = cal.startOfDay(for: tomorrow)
            if let through, day > through { break }
        }
        return out
    }

    /// The scheduled times on one local day, earliest first.
    static func candidates(_ schedule: AutomationSchedule, on day: Date, calendar cal: Calendar) -> [Date] {
        let weekday = cal.component(.weekday, from: day)
        let hours: [Int]
        switch schedule.cadence {
        case .hourly(let every):
            let step = max(1, min(every, 24))
            let start = ((schedule.hour % step) + step) % step
            hours = Array(stride(from: start, to: 24, by: step))
        case .daily:
            hours = [schedule.hour]
        case .weekdays:
            hours = (2...6).contains(weekday) ? [schedule.hour] : []
        case .weekly(let days):
            hours = days.contains(weekday) ? [schedule.hour] : []
        case .biweekly(let wanted, let anchor):
            // Counted in days from the first such weekday on or after it was set up — not in
            // calendar weeks, whose first day depends on the locale. Set up on a Friday for
            // Sundays, the coming Sunday is the first run.
            guard weekday == wanted else { return [] }
            var first = cal.startOfDay(for: anchor)
            while cal.component(.weekday, from: first) != wanted {
                guard let next = cal.date(byAdding: .day, value: 1, to: first) else { break }
                first = cal.startOfDay(for: next)
            }
            let days = cal.dateComponents([.day], from: first, to: cal.startOfDay(for: day)).day ?? 0
            hours = days >= 0 && days % 14 == 0 ? [schedule.hour] : []
        case .monthly(let wanted):
            let lastDay = cal.range(of: .day, in: .month, for: day)?.count ?? 28
            let target = min(max(1, wanted), lastDay)
            hours = cal.component(.day, from: day) == target ? [schedule.hour] : []
        }
        return hours.compactMap { hour in
            cal.date(bySettingHour: hour, minute: schedule.minute, second: 0, of: day,
                     matchingPolicy: .nextTime, repeatedTimePolicy: .first, direction: .forward)
        }
        // A missing hour can push two candidates onto one instant; one run is enough.
        .reduce(into: [Date]()) { acc, d in if acc.last != d { acc.append(d) } }
    }

    /// The name of one scheduled time, written on the schedule's own wall clock so the same night
    /// has the same name across restarts and a clock change.
    static func occurrenceKey(_ time: Date, _ schedule: AutomationSchedule) -> String {
        let f = DateFormatter()
        f.calendar = calendar(for: schedule)
        f.timeZone = schedule.timeZone
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd'T'HH:mm"
        return "slot:" + f.string(from: time)
    }

    /// What is owed between the last decision and now.
    struct Owed: Equatable {
        /// The one time to run now: the most recent missed one, if it is recent enough.
        var due: Date?
        /// Every other time that passed. Each is recorded as skipped.
        var skipped: [Date]
        /// Up to here everything is decided.
        var through: Date
    }

    static func owed(_ schedule: AutomationSchedule, evaluatedThrough: Date, now: Date) -> Owed {
        guard now > evaluatedThrough else { return Owed(due: nil, skipped: [], through: evaluatedThrough) }
        // The time to run is looked for near now, whatever came before it: a walk forward from an
        // old watermark is bounded, and an hourly schedule after months away would stop short of
        // the one time that matters.
        let recentFrom = max(evaluatedThrough, now.addingTimeInterval(-catchUpWindow))
        let due = times(schedule, after: recentFrom, through: now).last
        // What was missed is listed from at most a month back: a Mac left off for a year owes one
        // run and a short list, not ten thousand records.
        let listFrom = max(evaluatedThrough, now.addingTimeInterval(-31 * 24 * 3600))
        let skipped = times(schedule, after: listFrom, through: now, limit: 2_000).filter { $0 != due }
        return Owed(due: due, skipped: Array(skipped.suffix(60)), through: now)
    }
}
