import Foundation

/// The few words a run uses to say when an automation starts (`$IDIR/automation create --when`):
///
///     manual                 only when he starts it
///     hourly 3               every 3 hours (1–12)
///     daily 09:00            every day
///     weekdays 18:30         Monday to Friday
///     weekly mon,thu 09:00   on those days (sun mon tue wed thu fri sat)
///     monthly 1 09:00        on that day of the month (1–31)
///
/// Any schedule may end in `away`: it then starts only once he has stepped away from the Mac, as
/// the editor's "once you step away" does. The same limits as the editor; anything else is nil.
nonisolated enum AutomationWhen {
    static let days = ["sun": 1, "mon": 2, "tue": 3, "wed": 4, "thu": 5, "fri": 6, "sat": 7]

    static func parse(_ text: String, timeZone: TimeZone = .current) -> AutomationTrigger? {
        var words = text.lowercased().split(whereSeparator: \.isWhitespace).map(String.init)
        guard let first = words.first else { return nil }
        var away = false
        if words.count > 1, words.last == "away" { away = true; words.removeLast() }

        func time(_ text: String) -> (hour: Int, minute: Int)? {
            let parts = text.split(separator: ":", omittingEmptySubsequences: false)
            guard parts.count == 2, parts[1].count == 2, let hour = Int(parts[0]), let minute = Int(parts[1]),
                  (0...23).contains(hour), (0...59).contains(minute) else { return nil }
            return (hour, minute)
        }
        func schedule(_ cadence: AutomationSchedule.Cadence, at time: (hour: Int, minute: Int)) -> AutomationTrigger {
            .schedule(AutomationSchedule(cadence: cadence, hour: time.hour, minute: time.minute,
                                         timeZoneID: timeZone.identifier, waitUntilAway: away))
        }

        switch (first, words.count) {
        case ("manual", 1):
            return away ? nil : .manual
        case ("hourly", 2):
            guard let every = Int(words[1]), (1...12).contains(every) else { return nil }
            return schedule(.hourly(every: every), at: (0, 0))
        case ("daily", 2):
            return time(words[1]).map { schedule(.daily, at: $0) }
        case ("weekdays", 2):
            return time(words[1]).map { schedule(.weekdays, at: $0) }
        case ("weekly", 3):
            let named = words[1].split(separator: ",").map { days[String($0)] }
            guard !named.isEmpty, named.allSatisfy({ $0 != nil }), let at = time(words[2]) else { return nil }
            return schedule(.weekly(days: Array(Set(named.compactMap { $0 })).sorted()), at: at)
        case ("monthly", 3):
            guard let day = Int(words[1]), (1...31).contains(day), let at = time(words[2]) else { return nil }
            return schedule(.monthly(day: day), at: at)
        default:
            return nil
        }
    }
}
