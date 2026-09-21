import Foundation

nonisolated enum Fmt {

    nonisolated(unsafe) private static let relative: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .abbreviated
        return f
    }()

    private static let elapsedFormatter: DateComponentsFormatter = {
        let f = DateComponentsFormatter()
        f.unitsStyle = .abbreviated
        f.allowedUnits = [.hour, .minute]
        f.maximumUnitCount = 2
        f.zeroFormattingBehavior = .dropAll
        return f
    }()

    private static let secondsFormatter: DateComponentsFormatter = {
        let f = DateComponentsFormatter()
        f.unitsStyle = .abbreviated
        f.allowedUnits = [.second]
        return f
    }()

    static func elapsed(_ seconds: TimeInterval) -> String {
        let s = max(0, seconds)
        if s < 60 { return secondsFormatter.string(from: s) ?? "0s" }
        return elapsedFormatter.string(from: s) ?? duration(s)
    }

    static func resetsIn(_ date: Date?) -> String? {
        guard let date else { return nil }
        let remaining = date.timeIntervalSinceNow
        if remaining <= 0 { return String(localized: "resetting…") }
        return String(format: String(localized: "resets in %@"), elapsed(remaining))
    }

    static func resetsCompact(_ date: Date?) -> String? {
        guard let date else { return nil }
        let left = date.timeIntervalSinceNow
        if left <= 0 { return String(localized: "now") }
        let f = DateComponentsFormatter()
        f.unitsStyle = .abbreviated
        f.maximumUnitCount = 2
        f.allowedUnits = left >= 86400 ? [.day, .hour] : (left >= 3600 ? [.hour, .minute] : [.minute])
        f.calendar = { var c = Calendar.current; c.locale = Locale.current; return c }()
        return f.string(from: left)
    }

    static func until(_ date: Date?) -> String? {
        guard let date else { return nil }
        if date.timeIntervalSinceNow <= 0 { return String(localized: "now") }
        let cal = Calendar.current
        let f = DateFormatter()

        f.locale = Locale.current
        if cal.isDateInToday(date) {
            f.dateFormat = "HH:mm"
        } else if let days = cal.dateComponents([.day], from: Date(), to: date).day, days < 6 {
            f.dateFormat = "EEE HH:mm"
        } else {
            f.dateFormat = "d MMM"
        }
        return String(format: String(localized: "to %@"), f.string(from: date))
    }

    static func ago(_ date: Date?) -> String {
        guard let date else { return "—" }
        return relative.localizedString(for: date, relativeTo: Date())
    }

    static func duration(_ seconds: TimeInterval) -> String {
        let s = max(0, Int(seconds))
        let h = s / 3600, m = (s % 3600) / 60
        if h > 0 { return "\(h)h \(m)m" }
        if m > 0 { return "\(m)m" }
        return "\(s)s"
    }

    static func hours(_ h: Double) -> String {
        if h < 0.05 { return "0h" }
        return String(format: "%.1fh", h)
    }

    static func count(_ key: String, _ n: Int) -> String {
        let format = NSLocalizedString(key, bundle: LanguageBundle.current, comment: "")

        return String(format: format,
                      locale: Locale(identifier: LanguageBundle.currentCode),
                      n)
    }

    static func bytes(_ count: Int) -> String {
        let f = ByteCountFormatter()
        f.countStyle = .file
        f.allowsNonnumericFormatting = false
        return f.string(fromByteCount: Int64(max(0, count)))
    }

    static func clock(_ date: Date?) -> String {
        guard let date else { return "—" }
        return timeOnly.string(from: date)
    }

    private static let timeOnly: DateFormatter = {
        let f = DateFormatter()
        f.setLocalizedDateFormatFromTemplate("j:mm")
        return f
    }()

    private static let dayOnly: DateFormatter = {
        let f = DateFormatter()
        f.setLocalizedDateFormatFromTemplate("d MMMM")
        return f
    }()

    static func dayLabel(_ date: Date) -> String {
        let cal = Calendar.current
        if cal.isDateInToday(date) { return String(localized: "Today") }
        if cal.isDateInYesterday(date) { return String(localized: "Yesterday") }
        if cal.component(.year, from: date) != cal.component(.year, from: Date()) {
            return dayWithYear.string(from: date)
        }
        return dayOnly.string(from: date)
    }

    static func stamp(_ date: Date) -> String {
        "\(dayLabel(date)), \(timeOnly.string(from: date))"
    }

    private static let dayWithYear: DateFormatter = {
        let f = DateFormatter()
        f.setLocalizedDateFormatFromTemplate("d MMMM y")
        return f
    }()
}

extension Date {
    var agoText: String { Fmt.ago(self) }
}

nonisolated extension String {

    init(localized key: String) {
        self = LanguageBundle.current.localizedString(forKey: key, value: key, table: nil)
    }
}
