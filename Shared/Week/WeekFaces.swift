import SwiftUI
import WidgetKit

/// The faces of Bulava's week widgets — one SwiftUI implementation for the Mac's widgets, the
/// iPhone's widgets and the Mac's Week page.
///
/// A face lays out what `WeekSnapshot` says and draws its charts from the numbers beside the words.
/// It formats nothing of its own except the age of a stale snapshot, which the system says in the
/// device's language.

nonisolated enum WeekFaceKind: String, CaseIterable, Identifiable, Sendable {
    case autonomy, outcomes, receipt, rhythm, volume, limits, now, week
    var id: String { rawValue }

    /// Where a tap on the face leads: the Week page, opened at this face.
    var link: URL { URL(string: "bulava://week/\(rawValue)")! }
}

nonisolated enum WeekFaceSize: Sendable { case small, medium, large }

/// Which side of the link the face is drawn on: what a stale face says about why.
nonisolated enum WeekPlace: Sendable { case mac, phone }

// MARK: - Palette

/// The desktop's palette on the app icon's deep green, the same values as the Live Activity's.
enum WeekPalette {
    static let field = Color(light: Color(red: 0.953, green: 0.965, blue: 0.933), dark: Color(red: 0.086, green: 0.161, blue: 0.110))
    static let text = Color(light: Color(red: 0.082, green: 0.141, blue: 0.102), dark: Color(red: 0.949, green: 0.949, blue: 0.953))
    static let secondary = Color(light: Color(red: 0.302, green: 0.353, blue: 0.314), dark: Color(red: 0.710, green: 0.710, blue: 0.733))
    static let faint = Color(light: Color(red: 0.435, green: 0.478, blue: 0.443), dark: Color(red: 0.545, green: 0.545, blue: 0.573))
    static let accent = Color(light: Color(red: 0.298, green: 0.478, blue: 0.094), dark: Color(red: 0.780, green: 0.945, blue: 0.514))
    static let track = Color(light: Color.black.opacity(0.07), dark: Color.white.opacity(0.08))
    // Outcomes: three hues checked for colour-blind separation on both fields.
    static let passed = Color(light: Color(red: 0.184, green: 0.541, blue: 0.333), dark: Color(red: 0.263, green: 0.663, blue: 0.427))
    static let debt = Color(light: Color(red: 0.290, green: 0.455, blue: 0.788), dark: Color(red: 0.435, green: 0.573, blue: 0.890))
    static let waiting = Color(light: Color(red: 0.722, green: 0.412, blue: 0.122), dark: Color(red: 0.776, green: 0.478, blue: 0.208))
    static let warn = Color(light: Color(red: 0.659, green: 0.373, blue: 0.071), dark: Color(red: 0.910, green: 0.643, blue: 0.365))
    static let bad = Color(light: Color(red: 0.761, green: 0.271, blue: 0.243), dark: Color(red: 0.937, green: 0.467, blue: 0.439))

    static func outcome(_ key: String) -> Color {
        switch key {
        case "passed": passed
        case "debt": debt
        default: waiting
        }
    }

    static func severity(_ key: String) -> Color {
        switch key {
        case "bad": bad
        case "warn": warn
        default: accent
        }
    }
}

extension Color {
    init(light: Color, dark: Color) {
        #if os(macOS)
        self.init(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? NSColor(dark) : NSColor(light)
        })
        #else
        self.init(uiColor: UIColor { $0.userInterfaceStyle == .dark ? UIColor(dark) : UIColor(light) })
        #endif
    }
}

// MARK: - The mark

/// The Bulava mark, from the same outline as the Mac's glyph and the Live Activity's.
nonisolated struct WeekMark: Shape {
    private static let bounds = CGRect(x: 324, y: 216, width: 401.5, height: 591)
    private static let points: [CGPoint] = {
        let outline = "550.1 216 567.9 216 576.9 217.6 586.7 220.9 596.3 225.7 603.7 230.6 613.4 239.5 622.2 251.6 627.1 261.3 632 279.2 632 300.3 628.7 313.4 621.5 328.7 619.2 330.6 615 337.6 602.8 349 588.6 357.2 580.4 366.2 577.2 375.2 577.2 407.6 581.3 416.6 588.6 423.1 610 430.5 626.2 438.6 652 455.5 673 474.1 673.2 475.5 680.3 482.2 691.6 496.7 700.5 510.5 710.2 529.8 719.1 554.9 723.1 572.6 725.5 592.1 725.5 621.2 722.3 645.5 715.8 669.7 709.4 686.7 700.5 704.4 683.5 730.3 674.8 739.4 674.7 740.8 652.8 761.8 642.4 769.8 622.1 782.8 603.6 791.6 588.2 797.3 570.5 802.1 543 806.2 529.1 806.2 528.4 807 505 806.2 479.1 802.1 447.5 792.4 424.2 781.2 408.8 771.4 395.1 761 373.3 740 353.9 714.2 341.8 691.5 331.3 663.2 326.4 642.3 324 621.2 324 234.9 327.3 226.6 332.2 221.7 341.3 218.4 436.5 218.4 444.8 221.7 449.7 226.6 452.2 231.5 453 235.7 453 620.4 453.8 626.1 457.9 639.9 465.2 653.7 470 660.1 481.3 670.7 496.7 679.6 506.5 682.8 514.6 684.4 534.9 684.4 553.6 679.6 563.3 674.7 574.6 666.6 581.1 660.1 590 648 594.9 638.3 598.9 625.3 600.6 614.8 599.7 594.4 594.9 577.4 584.4 559.6 570.6 545.8 559.2 538.5 557.2 538.5 552 535.3 536.5 531.3 521.1 530.4 508.1 532.1 498.7 535.3 491.2 535.3 483.7 530.3 481.2 525.3 481.2 436.5 482.9 431.5 489.4 424.1 495.2 421.6 500.3 421.6 516.2 418.4 525.2 418.4 531 416.7 536.8 411.8 540.1 404.3 540.1 375.2 536.8 366.2 528.7 357.2 516.8 350.6 504.7 340 496.6 329.6 490.1 316.6 485.3 296.3 485.3 284.1 486.9 273.5 490.1 263 495.8 251.7 508 236.2 521.7 225.8 529.8 221.7"
        let n = outline.split(separator: " ").compactMap { Double($0) }
        return stride(from: 0, to: n.count - 1, by: 2).map { CGPoint(x: n[$0], y: n[$0 + 1]) }
    }()

    func path(in rect: CGRect) -> Path {
        let b = Self.bounds
        let scale = min(rect.width / b.width, rect.height / b.height)
        let dx = rect.midX - b.midX * scale, dy = rect.midY - b.midY * scale
        var path = Path()
        path.addLines(Self.points.map { CGPoint(x: $0.x * scale + dx, y: $0.y * scale + dy) })
        path.closeSubpath()
        return path
    }
}

// MARK: - A face

struct WeekFaceView: View {
    let kind: WeekFaceKind
    let size: WeekFaceSize
    let snapshot: WeekSnapshot?
    var place: WeekPlace = .mac
    var now: Date = .now

    var body: some View {
        Group {
            if let s = snapshot {
                if s.off && kind != .limits {
                    OffFace(snapshot: s, size: size)
                } else {
                    face(s)
                }
            } else {
                EmptyFace(place: place)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .foregroundStyle(WeekPalette.text)
    }

    private var stale: Bool { snapshot.map { $0.isStale(now: now) } ?? false }

    @ViewBuilder private func face(_ s: WeekSnapshot) -> some View {
        switch kind {
        case .autonomy: AutonomyView(s: s, size: size, header: header(s, s.autonomy.title))
        case .outcomes: OutcomesView(s: s, size: size, header: header(s, s.outcomes.title))
        case .receipt: ReceiptView(s: s, size: size, header: header(s, size == .small ? s.receipt.title : s.receipt.longTitle))
        case .rhythm: RhythmView(s: s, size: size, header: header(s, size == .small ? s.rhythm.title : s.rhythm.longTitle))
        case .volume: VolumeView(s: s, size: size, header: header(s, size == .small ? s.volume.title : s.volume.longTitle))
        case .limits: LimitsView(s: s, size: size, header: header(s, s.limits.title, trailing: size == .small ? "" : s.words.now))
        case .now: NowView(s: s, size: size, header: header(s, size == .small ? s.now.title : s.now.longTitle, trailing: ""))
        case .week: WeekAtAGlance(s: s, header: header(s, s.period, trailing: ""))
        }
    }

    private func header(_ s: WeekSnapshot, _ title: String, trailing: String? = nil) -> FaceHeader {
        FaceHeader(title: title, trailing: trailing ?? (size == .small ? "" : s.period),
                   time: size == .small ? nil : s.generatedAt, staleSince: stale ? s.generatedAt : nil,
                   staleWords: size == .small ? nil : (place == .mac ? s.words.appClosed : s.words.macAway))
    }
}

struct FaceHeader: View {
    let title: String
    var trailing: String
    var time: Date?
    var staleSince: Date?
    var staleWords: String?

    var body: some View {
        HStack(spacing: 5) {
            WeekMark().fill(WeekPalette.accent).frame(width: 8, height: 12).widgetAccentable()
            Text(verbatim: title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(WeekPalette.secondary)
                .lineLimit(1)
                .layoutPriority(1)
            Spacer(minLength: 4)
            if let staleSince {
                HStack(spacing: 3) {
                    Image(systemName: "clock")
                    if let staleWords { Text(verbatim: staleWords + " ·") }
                    Text(staleSince, format: .relative(presentation: .numeric, unitsStyle: .abbreviated))
                }
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(WeekPalette.warn)
                .lineLimit(1)
            } else {
                HStack(spacing: 0) {
                    Text(verbatim: trailing)
                    if let time {
                        if !trailing.isEmpty { Text(verbatim: " · ") }
                        Text(time, format: .dateTime.hour().minute())
                    }
                }
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(WeekPalette.faint)
                .lineLimit(1)
            }
        }
    }
}

// MARK: - Building blocks

private struct Hero: View {
    let value: String
    let unit: String
    var size: CGFloat = 36

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 3) {
            Text(verbatim: value)
                .font(.system(size: size, weight: .semibold, design: .rounded))
                .widgetAccentable()
            if !unit.isEmpty {
                Text(verbatim: unit)
                    .font(.system(size: size * 0.46, weight: .semibold, design: .rounded))
                    .foregroundStyle(WeekPalette.secondary)
            }
        }
        .lineLimit(1)
        .minimumScaleFactor(0.6)
    }
}

private struct LineText: View {
    let line: WeekLine
    var lines = 2

    var body: some View {
        (Text(verbatim: line.strong.map { $0 + " " } ?? "").fontWeight(.semibold).foregroundColor(WeekPalette.text)
         + Text(verbatim: line.text).foregroundColor(WeekPalette.secondary))
            .font(.system(size: 12))
            .lineLimit(lines)
            .fixedSize(horizontal: false, vertical: true)
    }
}

private struct Facts: View {
    let facts: [WeekKV]

    var body: some View {
        VStack(spacing: 4) {
            ForEach(facts.indices, id: \.self) { i in
                HStack {
                    Text(verbatim: facts[i].label).foregroundStyle(WeekPalette.secondary)
                    Spacer(minLength: 6)
                    Text(verbatim: facts[i].value).fontWeight(.semibold).monospacedDigit()
                }
                .font(.system(size: 11.5))
                .lineLimit(1)
            }
        }
    }
}

private struct FaceRule: View {
    var body: some View { Rectangle().fill(WeekPalette.track).frame(height: 1) }
}

/// Seven columns, Monday first. Today in the accent, earlier days muted, days ahead left empty.
private struct Columns: View {
    let values: [Double?]
    let days: [String]
    let today: Int
    var showLabels = true

    var body: some View {
        let top = max(1, values.compactMap { $0 }.max() ?? 1)
        HStack(alignment: .bottom, spacing: 4) {
            ForEach(0..<7, id: \.self) { i in
                VStack(spacing: 4) {
                    GeometryReader { g in
                        VStack {
                            Spacer(minLength: 0)
                            if let v = values[safe: i] ?? nil, v > 0 {
                                UnevenRoundedRectangle(topLeadingRadius: 3.5, topTrailingRadius: 3.5)
                                    .fill(WeekPalette.accent.opacity(i == today ? 1 : 0.42))
                                    .frame(height: max(3, g.size.height * v / top))
                            } else {
                                Capsule().fill(WeekPalette.track).frame(height: 2.5)
                            }
                        }
                        .frame(maxWidth: 22)
                        .frame(maxWidth: .infinity)
                    }
                    if showLabels {
                        Text(verbatim: days[safe: i] ?? "")
                            .font(.system(size: 9.5, weight: i == today ? .semibold : .regular))
                            .foregroundStyle(i == today ? WeekPalette.text : WeekPalette.faint)
                            .lineLimit(1)
                    }
                }
            }
        }
    }
}

/// Per day: passed, with remarks, waited for you — stacked with a hairline of field between.
private struct Stacks: View {
    let perDay: [[Int]?]
    let days: [String]
    let today: Int

    var body: some View {
        let top = max(1, perDay.compactMap { $0?.reduce(0, +) }.max() ?? 1)
        HStack(alignment: .bottom, spacing: 4) {
            ForEach(0..<7, id: \.self) { i in
                VStack(spacing: 4) {
                    GeometryReader { g in
                        VStack(spacing: 0) {
                            Spacer(minLength: 0)
                            let parts = perDay[safe: i] ?? nil
                            let total = parts?.reduce(0, +) ?? 0
                            if let parts, total > 0 {
                                VStack(spacing: 1.5) {
                                    ForEach([2, 1, 0], id: \.self) { k in
                                        if parts[safe: k] ?? 0 > 0 {
                                            Rectangle().fill(WeekPalette.outcome(["passed", "debt", "waiting"][k]))
                                                .frame(height: max(2, g.size.height * CGFloat(parts[k]) / CGFloat(top) - 1.5))
                                        }
                                    }
                                }
                                .clipShape(UnevenRoundedRectangle(topLeadingRadius: 3.5, topTrailingRadius: 3.5))
                            } else {
                                Capsule().fill(WeekPalette.track).frame(height: 2.5)
                            }
                        }
                        .frame(maxWidth: 22)
                        .frame(maxWidth: .infinity)
                    }
                    Text(verbatim: days[safe: i] ?? "")
                        .font(.system(size: 9.5, weight: i == today ? .semibold : .regular))
                        .foregroundStyle(i == today ? WeekPalette.text : WeekPalette.faint)
                        .lineLimit(1)
                }
            }
        }
    }
}

/// Added above the line, removed below it.
private struct Diverging: View {
    let perDay: [[Int]?]
    let days: [String]
    let today: Int

    var body: some View {
        let top = CGFloat(max(1, perDay.compactMap { $0?.max() }.max() ?? 1))
        HStack(alignment: .bottom, spacing: 4) {
            ForEach(0..<7, id: \.self) { i in
                VStack(spacing: 3) {
                    GeometryReader { g in
                        let up = g.size.height * 0.68, down = g.size.height * 0.32 - 1
                        let v = perDay[safe: i] ?? nil
                        VStack(spacing: 0) {
                            VStack {
                                Spacer(minLength: 0)
                                if let v, v[0] > 0 {
                                    UnevenRoundedRectangle(topLeadingRadius: 3, topTrailingRadius: 3)
                                        .fill(WeekPalette.accent.opacity(i == today ? 1 : 0.55))
                                        .frame(height: max(2, up * CGFloat(v[0]) / top))
                                }
                            }
                            .frame(height: up)
                            Rectangle().fill(WeekPalette.faint.opacity(0.5)).frame(height: 1)
                            VStack {
                                if let v, v[safe: 1] ?? 0 > 0 {
                                    UnevenRoundedRectangle(bottomLeadingRadius: 3, bottomTrailingRadius: 3)
                                        .fill(WeekPalette.bad.opacity(i == today ? 1 : 0.7))
                                        .frame(height: max(2, down * min(1, CGFloat(v[1]) / top * 2)))
                                }
                                Spacer(minLength: 0)
                            }
                            .frame(height: down)
                        }
                        .frame(maxWidth: 22)
                        .frame(maxWidth: .infinity)
                    }
                    Text(verbatim: days[safe: i] ?? "")
                        .font(.system(size: 9.5, weight: i == today ? .semibold : .regular))
                        .foregroundStyle(i == today ? WeekPalette.text : WeekPalette.faint)
                        .lineLimit(1)
                }
            }
        }
    }
}

/// Seven rows by twenty-four hours; a day ahead is left blank.
private struct HeatGrid: View {
    let heat: [[Int]?]
    let days: [String]
    var cell: CGFloat
    var gap: CGFloat = 1.5
    var labels = false

    var body: some View {
        let top = Double(max(1, heat.compactMap { $0?.max() }.max() ?? 1))
        VStack(alignment: .leading, spacing: gap) {
            ForEach(0..<7, id: \.self) { d in
                HStack(spacing: 4) {
                    if labels {
                        Text(verbatim: days[safe: d] ?? "").font(.system(size: 9)).foregroundStyle(WeekPalette.faint)
                            .frame(width: 21, alignment: .leading).lineLimit(1).minimumScaleFactor(0.8)
                    }
                    HStack(spacing: gap) {
                        ForEach(0..<24, id: \.self) { h in
                            RoundedRectangle(cornerRadius: 1.5)
                                .fill(color(heat[safe: d] ?? nil, h, top))
                                .frame(width: cell, height: labels ? cell + 2 : cell + 3)
                        }
                    }
                }
            }
            if labels {
                HStack {
                    ForEach(["00", "06", "12", "18", "24"], id: \.self) { t in
                        Text(verbatim: t).font(.system(size: 9)).foregroundStyle(WeekPalette.faint)
                        if t != "24" { Spacer(minLength: 0) }
                    }
                }
                .padding(.leading, 25)
                .frame(width: 25 + 24 * cell + 23 * gap)
            }
        }
    }

    private func color(_ row: [Int]?, _ h: Int, _ top: Double) -> Color {
        guard let row else { return WeekPalette.track.opacity(0.5) }
        let v = Double(row[safe: h] ?? 0)
        guard v > 0 else { return WeekPalette.track }
        let share = v / top
        return WeekPalette.accent.opacity(share > 0.75 ? 1 : share > 0.5 ? 0.7 : share > 0.22 ? 0.45 : 0.22)
    }
}

private struct Meter: View {
    let meter: WeekMeter
    var short = false

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(verbatim: short ? meter.engine : meter.label).foregroundStyle(WeekPalette.secondary)
                Spacer(minLength: 4)
                Text(verbatim: meter.usedText).fontWeight(.semibold).monospacedDigit()
            }
            .font(.system(size: 11))
            .lineLimit(1)
            GeometryReader { g in
                ZStack(alignment: .leading) {
                    Capsule().fill(WeekPalette.track)
                    Capsule().fill(WeekPalette.severity(meter.severity))
                        .frame(width: max(2, g.size.width * CGFloat(meter.used) / 100))
                        .widgetAccentable()
                    if let elapsed = meter.elapsed {
                        Capsule().fill(WeekPalette.text)
                            .frame(width: 2, height: 11)
                            .offset(x: max(0, min(g.size.width - 2, g.size.width * CGFloat(elapsed) / 100 - 1)))
                    }
                }
            }
            .frame(height: 5)
            .padding(.vertical, 3)
            if !short, let pace = meter.pace {
                Text(verbatim: pace)
                    .font(.system(size: 10))
                    .foregroundStyle(meter.paceKey == "ahead" ? WeekPalette.warn : WeekPalette.faint)
                    .lineLimit(1)
            }
        }
    }
}

private struct RunRow: View {
    let run: WeekRun

    var body: some View {
        HStack(spacing: 7) {
            Circle().fill(run.waiting ? WeekPalette.waiting : WeekPalette.accent).frame(width: 7, height: 7)
            Text(verbatim: run.name).lineLimit(1)
            Spacer(minLength: 4)
            Text(verbatim: run.time)
            .font(.system(size: 11))
            .foregroundStyle(WeekPalette.faint)
            .monospacedDigit()
            .lineLimit(1)
            .frame(maxWidth: 70, alignment: .trailing)
        }
        .font(.system(size: 12))
    }
}

private struct Tile: View {
    let value: String
    let label: String
    let note: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(verbatim: value).font(.system(size: 18, weight: .semibold, design: .rounded)).lineLimit(1).minimumScaleFactor(0.6)
            Text(verbatim: label).font(.system(size: 11)).foregroundStyle(WeekPalette.secondary).lineLimit(1)
            if let note { Text(verbatim: note).font(.system(size: 10)).foregroundStyle(WeekPalette.faint).lineLimit(1) }
        }
        .padding(.horizontal, 9).padding(.vertical, 7)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(WeekPalette.track, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
    }
}

// MARK: - The faces

private struct AutonomyView: View {
    let s: WeekSnapshot
    let size: WeekFaceSize
    let header: FaceHeader
    private var f: AutonomyFace { s.autonomy }
    private var values: [Double?] { f.perDay.map { $0.map(Double.init) } }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            switch size {
            case .small:
                Hero(value: f.hero, unit: f.unit, size: 34).padding(.top, 8)
                ViewThatFits(in: .vertical) {
                    VStack(alignment: .leading, spacing: 0) {
                        lead(lines: 3).padding(.top, 4)
                        Spacer(minLength: 6)
                        Columns(values: values, days: s.days, today: s.today, showLabels: false).frame(height: 15)
                    }
                    lead(lines: 3).padding(.top, 4)
                    lead(lines: 2).padding(.top, 4)
                }
            case .medium:
                HStack(alignment: .top, spacing: 14) {
                    VStack(alignment: .leading, spacing: 5) {
                        Hero(value: f.hero, unit: f.unit)
                        lead(lines: 2)
                        if f.empty == nil, f.lines.count > 1 {
                            LineText(line: f.lines[1], lines: 1).minimumScaleFactor(0.85)
                        }
                    }
                    .frame(width: 136, alignment: .leading)
                    Columns(values: values, days: s.days, today: s.today).padding(.top, 6)
                }
                .padding(.top, 8)
            case .large:
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Hero(value: f.hero, unit: f.unit, size: 40)
                    if f.empty == nil, f.lines.count > 2 { LineText(line: f.lines[2], lines: 1) }
                }
                .padding(.top, 8)
                lead(lines: 2).padding(.top, 3)
                Columns(values: values, days: s.days, today: s.today).padding(.top, 10)
                FaceRule().padding(.vertical, 9)
                Facts(facts: f.facts)
            }
        }
    }

    @ViewBuilder private func lead(lines: Int) -> some View {
        if let empty = f.empty {
            Text(verbatim: empty).font(.system(size: 12)).foregroundStyle(WeekPalette.secondary).lineLimit(lines)
        } else if let first = f.lines.first {
            LineText(line: first, lines: lines)
        }
    }
}

private struct OutcomesView: View {
    let s: WeekSnapshot
    let size: WeekFaceSize
    let header: FaceHeader
    private var f: OutcomesFace { s.outcomes }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            switch size {
            case .small:
                Hero(value: f.hero, unit: f.unit, size: 34).padding(.top, 8)
                if let empty = f.empty {
                    Text(verbatim: empty).font(.system(size: 12)).foregroundStyle(WeekPalette.secondary).lineLimit(3).padding(.top, 4)
                } else {
                    if let first = f.lines.first { LineText(line: first, lines: 2).padding(.top, 4) }
                    if f.lines.count > 1 {
                        HStack(spacing: 5) {
                            Circle().fill(WeekPalette.waiting).frame(width: 7, height: 7)
                            LineText(line: f.lines[1], lines: 1)
                        }
                        .padding(.top, 3)
                    }
                }
                Spacer(minLength: 0)
            case .medium:
                HStack(alignment: .top, spacing: 14) {
                    VStack(alignment: .leading, spacing: 7) {
                        Hero(value: f.hero, unit: f.unit)
                        legend
                    }
                    .frame(width: 132, alignment: .leading)
                    Stacks(perDay: f.perDay, days: s.days, today: s.today).padding(.top, 6)
                }
                .padding(.top, 8)
            case .large:
                Hero(value: f.hero, unit: f.unit, size: 40).padding(.top, 8)
                legend.padding(.top, 6)
                Stacks(perDay: f.perDay, days: s.days, today: s.today).padding(.top, 10)
                FaceRule().padding(.vertical, 9)
                Facts(facts: f.facts)
            }
        }
    }

    private var legend: some View {
        VStack(alignment: .leading, spacing: 3) {
            ForEach(f.legend.indices, id: \.self) { i in
                HStack(spacing: 5) {
                    RoundedRectangle(cornerRadius: 2).fill(WeekPalette.outcome(f.legend[i].key)).frame(width: 7, height: 7)
                    Text(verbatim: f.legend[i].text).font(.system(size: 11)).foregroundStyle(WeekPalette.secondary).lineLimit(1)
                }
            }
        }
    }
}

private struct ReceiptView: View {
    let s: WeekSnapshot
    let size: WeekFaceSize
    let header: FaceHeader
    private var f: ReceiptFace { s.receipt }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            switch size {
            case .small:
                Text(verbatim: f.caption).font(.system(size: 12)).foregroundStyle(WeekPalette.secondary).padding(.top, 8)
                Hero(value: f.hero, unit: "", size: f.hero.count > 7 ? 26 : 30).padding(.top, 2)
                Text(verbatim: f.tokens).font(.system(size: 12)).foregroundStyle(WeekPalette.secondary).lineLimit(1).padding(.top, 4)
                Spacer(minLength: 0)
                Text(verbatim: f.note).font(.system(size: 10.5)).foregroundStyle(WeekPalette.faint).lineLimit(2)
            case .medium:
                rows.padding(.top, 8)
                Spacer(minLength: 0)
                Text(verbatim: f.note).font(.system(size: 10, design: .monospaced)).foregroundStyle(WeekPalette.faint).lineLimit(1)
            case .large:
                rows.padding(.top, 10)
                let top = max(1, f.perDay.compactMap { $0 }.max() ?? 1)
                HStack(alignment: .bottom, spacing: 4) {
                    ForEach(0..<7, id: \.self) { i in
                        VStack(spacing: 3) {
                            GeometryReader { g in
                                VStack {
                                    Spacer(minLength: 0)
                                    if let v = f.perDay[safe: i] ?? nil, v > 0 {
                                        UnevenRoundedRectangle(topLeadingRadius: 3, topTrailingRadius: 3)
                                            .fill(WeekPalette.accent.opacity(i == s.today ? 1 : 0.5))
                                            .frame(height: max(3, g.size.height * v / top))
                                    } else {
                                        Capsule().fill(WeekPalette.track).frame(height: 2)
                                    }
                                }
                                .frame(maxWidth: 22).frame(maxWidth: .infinity)
                            }
                            Text(verbatim: s.days[safe: i] ?? "").font(.system(size: 9.5)).foregroundStyle(WeekPalette.faint)
                        }
                    }
                }
                .padding(.top, 12)
                Text(verbatim: f.footer).font(.system(size: 10, design: .monospaced)).foregroundStyle(WeekPalette.faint)
                    .lineLimit(1).padding(.top, 8)
            }
        }
    }

    private var rows: some View {
        VStack(spacing: 3) {
            ForEach(f.rows.indices, id: \.self) { i in row(f.rows[i], bold: false) }
            DashedRule().padding(.vertical, 3)
            row(f.total, bold: true)
        }
        .font(.system(size: 11, design: .monospaced))
    }

    private func row(_ kv: WeekKV, bold: Bool) -> some View {
        HStack {
            Text(verbatim: kv.label).foregroundStyle(bold ? WeekPalette.text : WeekPalette.secondary)
            Spacer(minLength: 6)
            Text(verbatim: kv.value).foregroundStyle(WeekPalette.text)
        }
        .fontWeight(bold ? .bold : .regular)
        .lineLimit(1)
    }
}

private struct DashedRule: View {
    var body: some View {
        GeometryReader { g in
            Path { p in p.move(to: .zero); p.addLine(to: CGPoint(x: g.size.width, y: 0)) }
                .stroke(WeekPalette.faint.opacity(0.6), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
        }
        .frame(height: 1)
    }
}

private struct RhythmView: View {
    let s: WeekSnapshot
    let size: WeekFaceSize
    let header: FaceHeader
    private var f: RhythmFace { s.rhythm }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if size == .small {
                HeatGrid(heat: f.heat, days: s.days, cell: 4, gap: 1).padding(.top, 10)
                Spacer(minLength: 4)
                Text(verbatim: f.line).font(.system(size: 11.5)).foregroundStyle(WeekPalette.secondary).lineLimit(2)
            } else {
                HStack(alignment: .top, spacing: 12) {
                    ViewThatFits(in: .horizontal) {
                        HeatGrid(heat: f.heat, days: s.days, cell: 8, labels: true)
                        HeatGrid(heat: f.heat, days: s.days, cell: 7, labels: true)
                        HeatGrid(heat: f.heat, days: s.days, cell: 6, labels: true)
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text(verbatim: f.peakLabel).font(.system(size: 11)).foregroundStyle(WeekPalette.secondary)
                        Text(verbatim: f.peak).font(.system(size: 20, weight: .semibold, design: .rounded)).lineLimit(1).minimumScaleFactor(0.6)
                        Text(verbatim: f.activeLabel).font(.system(size: 11)).foregroundStyle(WeekPalette.secondary).padding(.top, 6)
                        HStack(alignment: .firstTextBaseline, spacing: 0) {
                            Text(verbatim: f.active).font(.system(size: 20, weight: .semibold, design: .rounded))
                            Text(verbatim: f.activeOf).font(.system(size: 13)).foregroundStyle(WeekPalette.faint)
                        }
                    }
                    .frame(minWidth: 64, alignment: .leading)
                }
                .padding(.top, 9)
            }
        }
    }
}

private struct VolumeView: View {
    let s: WeekSnapshot
    let size: WeekFaceSize
    let header: FaceHeader
    private var f: VolumeFace { s.volume }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if size == .small {
                Text(verbatim: f.added).font(.system(size: f.added.count > 8 ? 24 : 27, weight: .semibold, design: .rounded))
                    .lineLimit(1).minimumScaleFactor(0.6).padding(.top, 9).widgetAccentable()
                Text(verbatim: f.removed).font(.system(size: 20, weight: .semibold, design: .rounded))
                    .foregroundStyle(WeekPalette.bad).lineLimit(1).padding(.top, 4)
                Text(verbatim: f.line).font(.system(size: 12)).foregroundStyle(WeekPalette.secondary).lineLimit(2).padding(.top, 4)
                Spacer(minLength: 0)
            } else {
                HStack(alignment: .top, spacing: 14) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(verbatim: f.added).font(.system(size: 26, weight: .semibold, design: .rounded))
                            .lineLimit(1).minimumScaleFactor(0.6).widgetAccentable()
                        Text(verbatim: f.removed).font(.system(size: 19, weight: .semibold, design: .rounded))
                            .foregroundStyle(WeekPalette.bad).lineLimit(1)
                        Text(verbatim: f.detail).font(.system(size: 12)).foregroundStyle(WeekPalette.secondary).lineLimit(2)
                    }
                    .frame(width: 132, alignment: .leading)
                    Diverging(perDay: f.perDay, days: s.days, today: s.today).padding(.top, 4)
                }
                .padding(.top, 8)
            }
        }
    }
}

private struct LimitsView: View {
    let s: WeekSnapshot
    let size: WeekFaceSize
    let header: FaceHeader
    private var f: LimitsFace { s.limits }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if let empty = f.empty {
                Text(verbatim: empty).font(.system(size: 12)).foregroundStyle(WeekPalette.secondary).lineLimit(3).padding(.top, 10)
                Spacer(minLength: 0)
            } else if size == .small {
                VStack(spacing: 8) {
                    ForEach(weekly.indices, id: \.self) { Meter(meter: weekly[$0], short: true) }
                }
                .padding(.top, 9)
                Spacer(minLength: 4)
                Text(verbatim: f.line).font(.system(size: 11.5)).foregroundStyle(WeekPalette.secondary).lineLimit(2)
            } else {
                let engines = Array(Set(f.meters.map(\.engine))).sorted()
                HStack(alignment: .top, spacing: 14) {
                    ForEach(engines, id: \.self) { e in
                        VStack(spacing: 8) {
                            ForEach(f.meters.indices.filter { f.meters[$0].engine == e }, id: \.self) { Meter(meter: f.meters[$0]) }
                        }
                    }
                }
                .padding(.top, 9)
            }
        }
    }

    private var weekly: [WeekMeter] {
        let w = f.meters.filter(\.weekly)
        return Array((w.isEmpty ? f.meters : w).prefix(2))
    }
}

private struct NowView: View {
    let s: WeekSnapshot
    let size: WeekFaceSize
    let header: FaceHeader
    private var f: NowFace { s.now }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if f.runs.isEmpty {
                Text(verbatim: f.empty).font(.system(size: size == .small ? 15 : 13, weight: .semibold))
                    .foregroundStyle(WeekPalette.secondary).lineLimit(3).padding(.top, 12)
                Spacer(minLength: 0)
            } else if size == .small {
                if f.count != "0" { Hero(value: f.count, unit: f.unit, size: 32).padding(.top, 8) }
                VStack(spacing: 6) {
                    ForEach(Array(f.runs.prefix(f.count == "0" ? 3 : 2).enumerated()), id: \.offset) { RunRow(run: $0.element) }
                }
                .padding(.top, 8)
                Spacer(minLength: 0)
            } else {
                VStack(spacing: 7) {
                    ForEach(Array(f.runs.prefix(size == .large ? 9 : 4).enumerated()), id: \.offset) { RunRow(run: $0.element) }
                }
                .padding(.top, 11)
                if let waiting = f.waiting {
                    Text(verbatim: waiting).font(.system(size: 11.5)).foregroundStyle(WeekPalette.waiting).lineLimit(1).padding(.top, 7)
                }
                Spacer(minLength: 0)
            }
        }
    }
}

/// I. The week on one large face.
private struct WeekAtAGlance: View {
    let s: WeekSnapshot
    let header: FaceHeader

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            HStack(alignment: .lastTextBaseline, spacing: 10) {
                Hero(value: s.autonomy.hero, unit: s.autonomy.unit, size: 44)
                VStack(alignment: .leading, spacing: 1) {
                    Text(verbatim: s.autonomy.title.lowercased()).font(.system(size: 12)).foregroundStyle(WeekPalette.secondary)
                    if let first = s.autonomy.lines.first, s.autonomy.empty == nil { LineText(line: first, lines: 2) }
                }
                .padding(.bottom, 5)
            }
            .padding(.top, 6)
            HStack(spacing: 8) {
                Tile(value: s.outcomes.hero, label: s.outcomes.unit, note: s.outcomes.legend.last?.text)
                Tile(value: s.receipt.hero, label: s.receipt.caption, note: s.receipt.note)
                Tile(value: s.volume.added, label: s.volume.title.lowercased(), note: s.volume.removed)
            }
            .padding(.top, 12)
            ViewThatFits(in: .horizontal) {
                HeatGrid(heat: s.rhythm.heat, days: s.days, cell: 10, labels: true)
                HeatGrid(heat: s.rhythm.heat, days: s.days, cell: 9, labels: true)
                HeatGrid(heat: s.rhythm.heat, days: s.days, cell: 8, labels: true)
            }
            .padding(.top, 12)
            Spacer(minLength: 0)
        }
    }
}

// MARK: - States without numbers

private struct OffFace: View {
    let snapshot: WeekSnapshot
    let size: WeekFaceSize

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            WeekMark().fill(WeekPalette.accent).frame(width: 8, height: 12)
            Spacer(minLength: 0)
            Text(verbatim: snapshot.words.off).font(.system(size: 15, weight: .semibold)).lineLimit(2)
            if size != .small {
                Text(verbatim: snapshot.words.offHint).font(.system(size: 12)).foregroundStyle(WeekPalette.secondary).lineLimit(2)
            }
            Text(verbatim: snapshot.words.turnOn + " →").font(.system(size: 12, weight: .semibold)).foregroundStyle(WeekPalette.accent)
            Spacer(minLength: 0)
        }
    }
}

private struct EmptyFace: View {
    let place: WeekPlace

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            WeekMark().fill(WeekPalette.accent).frame(width: 8, height: 12)
            Spacer(minLength: 0)
            Text(place == .mac ? "Open Bulava and this fills in within minutes." : "Connect to Bulava on your Mac and this fills in.")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(WeekPalette.secondary)
                .lineLimit(4)
            Spacer(minLength: 0)
        }
    }
}

// MARK: - Lock Screen and the Mac's accessories

/// The small monochrome faces: the iPhone's Lock Screen and StandBy.
struct WeekAccessoryView: View {
    enum Shape { case rectangular, circular, inline }
    let kind: WeekFaceKind
    let shape: Shape
    let snapshot: WeekSnapshot?

    var body: some View {
        if let s = snapshot, !(s.off && kind != .limits) {
            switch shape {
            case .inline: Text(verbatim: inline(s))
            case .circular: circular(s)
            case .rectangular: rectangular(s)
            }
        } else {
            switch shape {
            case .inline: Text(verbatim: "Bulava")
            default: WeekMark().frame(width: 12, height: 18)
            }
        }
    }

    private func inline(_ s: WeekSnapshot) -> String {
        switch kind {
        case .limits: s.limits.meters.filter(\.weekly).map { "\($0.engine) \($0.usedText)" }.joined(separator: " · ")
        case .now: s.now.runs.isEmpty ? s.now.empty : "\(s.now.count) \(s.now.unit)"
        default: "\(s.autonomy.hero) \(s.autonomy.unit) · \(s.autonomy.title.lowercased())"
        }
    }

    @ViewBuilder private func circular(_ s: WeekSnapshot) -> some View {
        switch kind {
        case .limits:
            if let m = s.limits.meters.first(where: \.weekly) ?? s.limits.meters.first {
                Gauge(value: Double(m.used), in: 0...100) { Text(verbatim: m.engine) } currentValueLabel: { Text(verbatim: "\(m.used)") }
                    .gaugeStyle(.accessoryCircularCapacity)
            } else {
                WeekMark().frame(width: 12, height: 18)
            }
        default:
            VStack(spacing: 0) {
                Text(verbatim: s.autonomy.hero).font(.system(size: 20, weight: .semibold, design: .rounded)).minimumScaleFactor(0.6)
                Text(verbatim: s.autonomy.unit).font(.system(size: 10))
            }
        }
    }

    @ViewBuilder private func rectangular(_ s: WeekSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            switch kind {
            case .limits:
                Text(verbatim: s.limits.title).font(.headline)
                Text(verbatim: inline(s)).font(.caption)
                if let m = s.limits.meters.first(where: \.weekly) {
                    Gauge(value: Double(m.used), in: 0...100) { EmptyView() }.gaugeStyle(.accessoryLinearCapacity)
                }
            case .now:
                Text(verbatim: s.now.title).font(.headline)
                Text(verbatim: s.now.runs.isEmpty ? s.now.empty : "\(s.now.count) \(s.now.unit)").font(.caption)
                if let first = s.now.runs.first { Text(verbatim: first.name).font(.caption).lineLimit(1) }
            default:
                Text(verbatim: s.autonomy.title).font(.headline)
                Text(verbatim: "\(s.autonomy.hero) \(s.autonomy.unit)").font(.caption)
                if let first = s.autonomy.lines.first, s.autonomy.empty == nil {
                    Text(verbatim: [first.strong, first.text].compactMap { $0 }.joined(separator: " ")).font(.caption).lineLimit(1)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

extension Array {
    subscript(safe i: Int) -> Element? { indices.contains(i) ? self[i] : nil }
}
