import SwiftUI

/// How an automation and its runs read on screen — one place, so the list, the detail page and
/// the sidebar never word the same thing two ways.
@MainActor
enum AutomationPresentation {

    // MARK: Triggers

    static func triggerLine(_ trigger: AutomationTrigger) -> String {
        switch trigger {
        case .manual:
            return String(localized: "Only when you start it")
        case .schedule(let s):
            return scheduleLine(s)
        case .watch(let w):
            let every = intervalWord(w.everyMinutes)
            switch w.source {
            case .commits(let repo, let branch):
                let name = (repo as NSString).lastPathComponent
                return String(format: String(localized: "New commits in %@ · checked %@"),
                              branch.map { "\(name) · \($0)" } ?? name, every)
            case .feed:
                return String(format: String(localized: "New entries in a feed · checked %@"), every)
            case .huggingFace(let author, _):
                return String(format: String(localized: "New models from %@ on Hugging Face · checked %@"), author, every)
            case .webPage(let url):
                let host = URL(string: url)?.host() ?? url
                return String(format: String(localized: "%@ changes · checked %@"), host, every)
            }
        case .event(let e):
            switch e.kind {
            case .mail(let from, let subject):
                if !from.isEmpty { return String(format: String(localized: "A letter from %@ arrives in Mail"), from) }
                if !subject.isEmpty { return String(format: String(localized: "A letter about “%@” arrives in Mail"), subject) }
                return String(localized: "A new letter arrives in Mail")
            case .folder(let path):
                return String(format: String(localized: "A new file appears in %@"), (path as NSString).lastPathComponent)
            case .meetingEnded(let title):
                return title.isEmpty ? String(localized: "A meeting in your calendar ends")
                    : String(format: String(localized: "A meeting called “%@” ends"), title)
            }
        }
    }

    static func scheduleLine(_ s: AutomationSchedule) -> String {
        let time = clock(hour: s.hour, minute: s.minute)
        var line: String
        switch s.cadence {
        case .hourly(let every):
            line = every <= 1 ? String(format: String(localized: "Every hour at :%@"), String(format: "%02d", s.minute))
                : Fmt.count("Every %lld hours", every)
        case .daily:
            line = String(format: String(localized: "Every day at %@"), time)
        case .weekdays:
            line = String(format: String(localized: "Weekdays at %@"), time)
        case .weekly(let days):
            line = String(format: String(localized: "Every %@ at %@"), dayList(days), time)
        case .biweekly(let day, _):
            line = String(format: String(localized: "Every other %@ at %@"), dayName(day), time)
        case .monthly(let day):
            line = String(format: String(localized: "Monthly on day %@ at %@"), String(day), time)
        }
        if s.waitUntilAway { line += " · " + String(localized: "once you step away") }
        // Named only when it is a different clock from his: Europe/Kiev and Europe/Kyiv are the
        // same zone under two names, and saying "Ukraine time" to someone in Ukraine is noise.
        let zone = TimeZone(identifier: s.timeZoneID) ?? .current
        if zone.secondsFromGMT() != TimeZone.current.secondsFromGMT()
            || zone.nextDaylightSavingTimeTransition != TimeZone.current.nextDaylightSavingTimeTransition {
            line += " · " + (TimeZone(identifier: s.timeZoneID)?.localizedName(for: .shortGeneric, locale: .current) ?? s.timeZoneID)
        }
        return line
    }

    static func intervalWord(_ minutes: Int) -> String {
        switch minutes {
        case ..<60: return Fmt.count("every %lld min", minutes)
        case 60: return String(localized: "hourly")
        case 1440: return String(localized: "daily")
        default: return Fmt.count("every %lld h", minutes / 60)
        }
    }

    static func clock(hour: Int, minute: Int) -> String {
        var c = DateComponents(); c.hour = hour; c.minute = minute
        let date = Calendar.current.date(from: c) ?? Date()
        return date.formatted(date: .omitted, time: .shortened)
    }

    /// Weekday names in his interface language: 1 is Sunday.
    static func dayName(_ weekday: Int) -> String {
        let symbols = calendar.weekdaySymbols
        return symbols.indices.contains(weekday - 1) ? symbols[weekday - 1] : "?"
    }

    static func shortDayName(_ weekday: Int) -> String {
        let symbols = calendar.shortWeekdaySymbols
        return symbols.indices.contains(weekday - 1) ? symbols[weekday - 1] : "?"
    }

    static func dayList(_ days: [Int]) -> String {
        let sorted = days.sorted { order($0) < order($1) }
        if sorted.count == 1 { return dayName(sorted[0]) }
        return sorted.map(shortDayName).joined(separator: ", ")
    }

    /// Monday first, the way the week is read where he is.
    static func order(_ weekday: Int) -> Int { (weekday - calendar.firstWeekday + 7) % 7 }

    static var weekOrder: [Int] { (1...7).sorted { order($0) < order($1) } }

    private static var calendar: Calendar {
        var cal = Calendar.current
        cal.locale = Locale(identifier: LanguageBundle.currentCode)
        return cal
    }

    // MARK: Runs

    struct Look {
        var word: String
        var symbol: String
        var tint: Color
        var wash: Color
    }

    static func look(_ run: AutomationRun, phase: DirectChatPhase?) -> Look {
        switch run.state {
        case .awaitingApproval:
            return Look(word: String(localized: "Asks to start"), symbol: "hand.raised", tint: Palette.blue, wash: Palette.blueSoft)
        case .awaitingAway:
            return Look(word: String(localized: "Waiting for you to step away"), symbol: "moon.zzz", tint: Palette.textSecondary, wash: Palette.panelMuted)
        case .preparing:
            return Look(word: String(localized: "Getting its copy ready"), symbol: "square.on.square.dashed", tint: Palette.accent, wash: Palette.accentSoft)
        case .running:
            if let phase, phase.wantsAttention {
                return Look(word: String(localized: "Needs your answer"), symbol: "questionmark.circle", tint: Palette.blue, wash: Palette.blueSoft)
            }
            return Look(word: String(localized: "Running"), symbol: "circle.dotted", tint: Palette.accent, wash: Palette.accentSoft)
        case .skipped:
            return Look(word: String(localized: "Skipped"), symbol: "forward", tint: Palette.textFaint, wash: Palette.panelMuted)
        case .failed:
            if run.stoppedByHand {
                return Look(word: String(localized: "Stopped by you"), symbol: "stop.circle", tint: Palette.textTertiary, wash: Palette.panelMuted)
            }
            return Look(word: String(localized: "Failed"), symbol: "exclamationmark.triangle", tint: Palette.red, wash: Palette.redSoft)
        case .finished:
            switch run.result {
            case .changes?:
                switch run.handoff {
                case .merged?:
                    return Look(word: String(localized: "Merged"), symbol: "arrow.triangle.merge", tint: Palette.green, wash: Palette.greenSoft)
                case .discarded?:
                    return Look(word: String(localized: "Discarded"), symbol: "trash", tint: Palette.textFaint, wash: Palette.panelMuted)
                default:
                    return Look(word: String(localized: "Changes wait for you"), symbol: "arrow.triangle.branch", tint: Palette.orange, wash: Palette.orangeSoft)
                }
            case .noChange?:
                return Look(word: String(localized: "Nothing new"), symbol: "checkmark", tint: Palette.textTertiary, wash: Palette.panelMuted)
            case .report?:
                return Look(word: String(localized: "Report"), symbol: "doc.text", tint: Palette.green, wash: Palette.greenSoft)
            case .unverified?:
                return Look(word: String(localized: "Done, not reviewed"), symbol: "checkmark.circle.trianglebadge.exclamationmark", tint: Palette.orange, wash: Palette.orangeSoft)
            case .needsYou?:
                return Look(word: String(localized: "Needs you"), symbol: "questionmark.circle", tint: Palette.blue, wash: Palette.blueSoft)
            case .failed?:
                return Look(word: String(localized: "Failed"), symbol: "exclamationmark.triangle", tint: Palette.red, wash: Palette.redSoft)
            case nil:
                return Look(word: String(localized: "Finished"), symbol: "checkmark", tint: Palette.textTertiary, wash: Palette.panelMuted)
            }
        }
    }

    /// What started a run, in a few words.
    static func reasonWord(_ reason: AutomationRun.Reason) -> String {
        switch reason {
        case .scheduled: return String(localized: "on schedule")
        case .caughtUp(let at): return String(format: String(localized: "caught up · was due %@"), Fmt.stamp(at))
        case .manual: return String(localized: "started by you")
        case .changed(let n): return Fmt.count("%lld new things", n)
        case .event(let n): return Fmt.count("%lld events", n)
        }
    }

    /// The first line of what a run said about itself, or why it did not run.
    static func gist(_ run: AutomationRun) -> String? {
        let text = run.summary?.split(whereSeparator: \.isNewline).first.map(String.init) ?? run.note
        guard let text, !text.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        return text
    }
}
