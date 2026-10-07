import Foundation

/// Something working right now, as the Week's "now" face lists it.
nonisolated struct WeekNowLine: Equatable, Sendable {
    var name: String
    var since: Date?
    var waiting: Bool
}

/// Turns a week's numbers into the words every widget shows, in the Mac's interface language.
///
/// This is the only place a widget's text is decided. The widgets on the Mac, the iPhone and
/// Android lay out what this writes; none of them formats a number or chooses a plural.
nonisolated struct WeekPresenter {
    var raw: WeekRaw
    var capacity: CapacitySnapshot
    var running: [WeekNowLine]
    /// Weekly statistics switched off in Settings: the faces stay empty and say so.
    var off: Bool
    var now: Date
    var locale: Locale = Locale(identifier: LanguageBundle.currentCode)
    var calendar: Calendar = .bulavaWeek

    func snapshot() -> WeekSnapshot {
        WeekSnapshot(
            generatedMs: Int64(now.timeIntervalSince1970 * 1000),
            week: raw.isoWeek,
            period: periodText,
            days: dayLabels,
            today: raw.today,
            off: off,
            words: WeekWords(
                off: String(localized: "Weekly statistics are off"),
                offHint: String(localized: "The widget counts nothing until they are on."),
                turnOn: String(localized: "Turn on in Bulava"),
                appClosed: String(localized: "Bulava is closed"),
                macAway: String(localized: "The Mac is out of reach"),
                week: String(localized: "this calendar week"),
                now: String(localized: "now")),
            autonomy: autonomy, outcomes: outcomes, receipt: receipt, rhythm: rhythm,
            volume: volume, limits: limits, now: nowFace)
    }

    // MARK: Days

    /// A day after today is still ahead: drawn empty, never as zero.
    private func ahead(_ d: Int) -> Bool { d > raw.today }

    private func perDay<T>(_ make: (Int) -> T) -> [T?] { (0..<7).map { ahead($0) ? nil : make($0) } }

    var dayLabels: [String] {
        var c = calendar
        c.locale = locale
        let symbols = c.shortStandaloneWeekdaySymbols   // Sunday first
        return (0..<7).map { i in
            let s = symbols[(i + 1) % 7].replacingOccurrences(of: ".", with: "")
            return s.prefix(1).uppercased() + s.dropFirst()
        }
    }

    var periodText: String {
        let f = DateIntervalFormatter()
        f.locale = locale
        f.timeZone = calendar.timeZone
        f.dateTemplate = "dMMM"
        return f.string(from: raw.bounds[0], to: raw.bounds[6])
    }

    // MARK: Numbers into words

    private func number(_ n: Int) -> String { n.formatted(.number.locale(locale)) }

    private func compact(_ n: Int) -> String {
        n.formatted(.number.notation(.compactName).precision(.fractionLength(0...1)).locale(locale))
    }

    /// Agent-hours: whole above twenty, one decimal below.
    private func hours(_ seconds: Double) -> String {
        let h = seconds / 3600
        return h >= 20 ? Int(h.rounded()).formatted(.number.locale(locale))
            : h.formatted(.number.precision(.fractionLength(0...1)).locale(locale))
    }

    private func duration(_ seconds: Double) -> String {
        let f = DateComponentsFormatter()
        var c = calendar
        c.locale = locale
        f.calendar = c
        f.unitsStyle = .abbreviated
        f.allowedUnits = seconds >= 3600 ? [.hour, .minute] : [.minute]
        f.maximumUnitCount = 2
        f.zeroFormattingBehavior = .dropAll
        return f.string(from: max(60, seconds)) ?? ""
    }

    private func dollars(_ x: Double) -> String {
        "$" + Int(x.rounded()).formatted(.number.locale(locale))
    }

    private func clock(hour: Int) -> String {
        let f = DateFormatter()
        f.locale = locale
        f.timeZone = calendar.timeZone
        f.setLocalizedDateFormatFromTemplate("j:mm")
        let date = calendar.date(bySettingHour: hour, minute: 0, second: 0, of: raw.bounds[0]) ?? raw.bounds[0]
        return f.string(from: date)
    }

    /// A plural noun on its own, without the number that chose it: "агенти" for 2.
    private func word(_ key: String, _ n: Int) -> String {
        let whole = Fmt.count(key, n)
        let shown = String(format: "%lld", locale: locale, n)
        guard whole.hasPrefix(shown) else { return whole }
        return String(whole.dropFirst(shown.count)).trimmingCharacters(in: .whitespaces)
    }

    private func sum(_ a: [Int]) -> Int { a.reduce(0, +) }

    // MARK: A — without you

    var autonomy: AutonomyFace {
        let agent = raw.agentSec.reduce(0, +), wall = raw.wallSec.reduce(0, +)
        let prompts = sum(raw.prompts)
        let worked = agent >= 60
        var lines: [WeekLine] = []
        if worked {
            if prompts > 0 {
                lines.append(WeekLine(strong: duration(agent / Double(prompts)),
                                      text: String(localized: "of work for each of your messages")))
            } else {
                lines.append(WeekLine(text: String(localized: "and not a single message from you")))
            }
            lines.append(WeekLine(text: Fmt.count("%lld messages from you", prompts)))
            lines.append(WeekLine(text: String(format: String(localized: "%@ h by the clock"), hours(wall))))
        }
        let active = (0...raw.today).filter { raw.agentSec[$0] >= 60 }.count
        let facts = [
            WeekKV(label: String(localized: "Longest run"), value: raw.longestSec >= 60 ? duration(raw.longestSec) : "—"),
            WeekKV(label: String(localized: "Agents at once"),
                   value: raw.peakParallel > 0 ? String(format: String(localized: "up to %lld"), raw.peakParallel) : "—"),
            WeekKV(label: String(localized: "Active days"),
                   value: String(format: String(localized: "%lld of %lld"), active, raw.today + 1)),
        ]
        let empty = worked ? nil : String(localized: "The agents have not worked this week yet")
        let spoken = worked
            ? String(format: String(localized: "%@ agent-hours this week, %@ of work for each of your messages"),
                     hours(agent), prompts > 0 ? duration(agent / Double(prompts)) : "—")
            : (empty ?? "")
        return AutonomyFace(title: String(localized: "Without you"), hero: hours(agent),
                            unit: String(localized: "h"), lines: lines,
                            perDay: perDay { Int((raw.agentSec[$0] / 60).rounded()) },
                            facts: facts, empty: empty, spoken: spoken)
    }

    // MARK: B — how the runs ended

    var outcomes: OutcomesFace {
        let passed = sum(raw.passed), debt = sum(raw.debt), waiting = sum(raw.waiting)
        let accepted = passed + debt
        let any = accepted + waiting > 0
        let legend = [
            WeekLegend(key: "passed", text: String(format: String(localized: "%lld without remarks"), passed)),
            WeekLegend(key: "debt", text: String(format: String(localized: "%lld with remarks"), debt)),
            WeekLegend(key: "waiting", text: Fmt.count("%lld waited for you", waiting)),
        ]
        let lines = any ? [
            WeekLine(text: String(format: String(localized: "of them %lld with remarks"), debt)),
            WeekLine(text: Fmt.count("%lld waited for you", waiting)),
        ] : []
        let facts = [
            WeekKV(label: String(localized: "Tasks given to agents"), value: number(raw.tasksGiven)),
            WeekKV(label: String(localized: "Advice from Codex"), value: number(raw.codexConsults)),
            WeekKV(label: String(localized: "Questions to you"), value: number(raw.questions)),
            WeekKV(label: String(localized: "Commits"), value: number(raw.commits)),
        ]
        let empty = any ? nil : String(localized: "No run has ended this week yet")
        return OutcomesFace(
            title: String(localized: "How runs ended"), hero: number(accepted), unit: word("%lld accepted", accepted),
            legend: legend, perDay: perDay { [raw.passed[$0], raw.debt[$0], raw.waiting[$0]] },
            lines: lines, facts: facts, empty: empty,
            spoken: any ? String(format: String(localized: "%lld accepted, %lld of them with remarks, %lld waited for you"),
                                 accepted, debt, waiting) : (empty ?? ""))
    }

    // MARK: D — the receipt

    var receipt: ReceiptFace {
        let cost = raw.costPerDay.reduce(0, +)
        let plan = capacity.claude.plan.map { $0.prefix(1).uppercased() + $0.dropFirst() } ?? "—"
        var rows = [
            WeekKV(label: String(localized: "Agents' answers"), value: compact(raw.tokensOut)),
            WeekKV(label: String(localized: "Read from cache"), value: compact(raw.cacheRead)),
            WeekKV(label: String(localized: "Written to cache"), value: compact(raw.cacheWrite)),
        ]
        rows.append(WeekKV(label: String(localized: "Codex, tokens"), value: compact(raw.codexTokens)))
        let note = raw.unpriced.isEmpty ? String(localized: "an estimate, not spending")
            : String(localized: "an estimate, not spending; some models unpriced")
        return ReceiptFace(
            title: String(localized: "Receipt"), longTitle: String(localized: "Receipt of the week"),
            caption: String(localized: "at API prices"), hero: "≈ " + dollars(cost), rows: rows,
            total: WeekKV(label: String(localized: "Total, estimate"), value: "≈ " + dollars(cost)),
            note: note,
            tokens: raw.tokensOut > 0 ? String(format: String(localized: "%@ tokens"), compact(raw.tokensOut))
                : String(localized: "No tokens spent yet"),
            perDay: perDay { raw.costPerDay[$0] },
            footer: String(format: String(localized: "API prices · not spending · plan %@"), plan),
            spoken: String(format: String(localized: "About %@ at API prices, an estimate"), dollars(cost)))
    }

    // MARK: E — rhythm

    var rhythm: RhythmFace {
        let heat: [[Int]?] = perDay { d in raw.heatSec[d].map { Int(($0 / 60).rounded()) } }
        var byHour = Array(repeating: 0.0, count: 24)
        for d in 0...raw.today { for h in 0..<24 { byHour[h] += raw.heatSec[d][h] } }
        let top = byHour.max() ?? 0
        let peakHour = top >= 60 ? byHour.firstIndex(of: top) : nil
        let active = (0...raw.today).filter { raw.agentSec[$0] >= 60 }.count
        let peak = peakHour.map { clock(hour: $0) } ?? "—"
        let line = peakHour == nil ? String(localized: "The agents have not worked this week yet")
            : String(format: String(localized: "peak %@ · active days %lld/%lld"), peak, active, raw.today + 1)
        return RhythmFace(
            title: String(localized: "Rhythm"), longTitle: String(localized: "Rhythm of the week"),
            heat: heat, peakLabel: String(localized: "peak"), peak: peak,
            activeLabel: String(localized: "days with work"), active: number(active), activeOf: "/\(raw.today + 1)",
            line: line,
            spoken: peakHour == nil ? line : String(format: String(localized: "Busiest at %@, %lld active days of %lld"),
                                                    peak, active, raw.today + 1))
    }

    // MARK: F — volume

    var volume: VolumeFace {
        let added = sum(raw.added), removed = sum(raw.removed)
        let files = Fmt.count("%lld files", raw.files)
        return VolumeFace(
            title: String(localized: "Changes"), longTitle: String(localized: "Code changes"),
            added: "+" + compact(added), removed: "−" + compact(removed),
            line: String(format: String(localized: "lines · %@"), files),
            detail: files + " · " + Fmt.count("%lld commits", raw.commits),
            perDay: perDay { [raw.added[$0], raw.removed[$0]] },
            spoken: String(format: String(localized: "%@ lines added, %@ removed, %@"), number(added), number(removed), files))
    }

    // MARK: G — limits with the pace

    var limits: LimitsFace {
        var meters: [WeekMeter] = []
        for (name, usage) in [("Claude", capacity.claude), ("Codex", capacity.codex)] where usage.present {
            for (weekly, window, minutes) in [(false, Optional(usage.fiveHour), 300.0), (true, usage.sevenDay, 10080.0)] {
                guard let window, let used = window.shownPercent(now: now) else { continue }
                let pace = LimitPace(used: used, resetsAt: window.resetsAt, windowMinutes: minutes, now: now)
                let severity: String = switch UsagePressure(usedPercent: Double(used)) {
                case .comfortable: "ok"
                case .tight: "warn"
                case .nearlyOut: "bad"
                }
                meters.append(WeekMeter(
                    engine: name,
                    label: name + " · " + (weekly ? String(localized: "Weekly") : String(localized: "Session")).lowercased(with: locale),
                    weekly: weekly, used: used, usedText: "\(used)%", elapsed: pace?.elapsed,
                    pace: pace?.words, paceKey: pace?.key, severity: severity,
                    resets: Fmt.resetsCompact(window.resetsAt, now: now, locale: locale)))
            }
        }
        let claudeWeek = meters.first { $0.engine == "Claude" && $0.weekly } ?? meters.first { $0.weekly }
        let line = claudeWeek.flatMap { m in m.pace.map { "\(m.engine): \($0)" } } ?? ""
        let empty = meters.isEmpty ? String(localized: "Not known yet — it fills in when something runs") : nil
        let spoken = meters.filter(\.weekly).map { "\($0.engine) \($0.usedText)" + ($0.pace.map { ", \($0)" } ?? "") }
            .joined(separator: "; ")
        return LimitsFace(title: String(localized: "Limits"), meters: meters, line: line, empty: empty,
                          spoken: spoken.isEmpty ? (empty ?? "") : spoken)
    }

    // MARK: H — now

    var nowFace: NowFace {
        let runs = running.map { r in
            WeekRun(name: r.name,
                    time: r.waiting ? String(localized: "waits for you") : r.since.map { duration(now.timeIntervalSince($0)) } ?? "",
                    waiting: r.waiting,
                    sinceMs: r.waiting ? nil : r.since.map { Int64($0.timeIntervalSince1970 * 1000) })
        }
        let waitingCount = running.filter(\.waiting).count
        let working = running.filter { !$0.waiting }
        let empty = String(localized: "Nobody is working right now")
        var spoken = working.isEmpty ? empty
            : Fmt.count("%lld agents", working.count) + ": " + working.map(\.name).joined(separator: ", ")
        if waitingCount > 0 { spoken += ". " + Fmt.count("%lld runs wait for you", waitingCount) }
        return NowFace(
            title: String(localized: "Now"), longTitle: String(localized: "Working now"),
            count: number(working.count), unit: word("%lld agents", working.count), runs: runs,
            waiting: waitingCount > 0 ? Fmt.count("%lld runs wait for you", waitingCount) : nil,
            empty: empty, spoken: spoken)
    }
}
