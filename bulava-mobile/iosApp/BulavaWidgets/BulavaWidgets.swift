import ActivityKit
import SwiftUI
import WidgetKit

@main
struct BulavaWidgets: WidgetBundle {
    var body: some Widget {
        ShiftActivity()
        AutonomyWidget()
        OutcomesWidget()
        ReceiptWidget()
        RhythmWidget()
        VolumeWidget()
        LimitsWidget()
        NowWidget()
        WeekAtAGlanceWidget()
    }
}

/// What the Mac is working on, on the Lock Screen and in the Dynamic Island: each piece of work by
/// name with the time it has been going, then how it ended. The menu bar's "Working now", in a
/// pocket. From a Mac that sends no names, or before the key can be read, a count stands in.
struct ShiftActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: ShiftAttributes.self) { context in
            LockScreenShift(state: context.state, stale: context.isStale)
                .activityBackgroundTint(Palette.field)
                .activitySystemActionForegroundColor(Palette.lime)
                .widgetURL(context.state.names?.link)
        } dynamicIsland: { context in
            let names = context.state.names
            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    BrandLabel().padding(.leading, 4)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Headline(state: context.state, names: names, stale: context.isStale)
                        .padding(.trailing, 4)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    if let line = names?.running.first ?? names?.ended.first {
                        Row(line: line, ended: names?.running.isEmpty ?? true)
                            .padding(.horizontal, 4)
                            .padding(.top, 2)
                    }
                }
            } compactLeading: {
                Mark().fill(Palette.lime).frame(width: 10, height: 15)
            } compactTrailing: {
                Compact(state: context.state, names: names)
            } minimal: {
                Compact(state: context.state, names: names, minimal: true)
            }
            .widgetURL(names?.link)
            .keylineTint(Palette.lime)
        }
    }
}

// MARK: - Lock Screen

private struct LockScreenShift: View {
    let state: ShiftAttributes.ContentState
    let stale: Bool

    var body: some View {
        let names = state.names
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                BrandLabel()
                Spacer(minLength: 8)
                Headline(state: state, names: names, stale: stale)
            }
            if let names {
                let lines = names.running.isEmpty ? names.ended : names.running
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(Array(lines.prefix(3).enumerated()), id: \.offset) { _, line in
                        Row(line: line, ended: names.running.isEmpty)
                    }
                }
                if names.running.count < names.count {
                    Text(String(format: String(localized: "live.more"), names.count - names.running.count))
                        .font(.caption)
                        .foregroundStyle(Palette.secondary)
                }
            }
            if stale {
                Text("live.stale")
                    .font(.caption)
                    .foregroundStyle(Palette.secondary)
                    .lineLimit(2)
            }
        }
        .padding(16)
    }
}

// MARK: - Pieces

/// The corner word: working (and how many), or done. Without names, the count is all there is.
private struct Headline: View {
    let state: ShiftAttributes.ContentState
    let names: LiveBox?
    let stale: Bool

    var body: some View {
        let running = names.map { $0.count } ?? state.working
        let over = names?.over ?? (state.working == 0)
        HStack(spacing: 6) {
            if stale {
                Image(systemName: "moon.zzz").foregroundStyle(Palette.secondary)
            } else if over {
                Image(systemName: "checkmark").foregroundStyle(Palette.green)
            } else {
                Circle().fill(Palette.lime).frame(width: 6, height: 6)
            }
            Text(over ? String(localized: "live.done")
                 : running > 1 ? String(format: String(localized: "live.working"), running) : String(localized: "live.working.one"))
                .foregroundStyle(over ? Palette.green : Palette.text)
        }
        .font(.subheadline.weight(.semibold))
        .lineLimit(1)
    }
}

/// One piece of work: its name and product, and either the time it has been going — counted up by
/// the Lock Screen itself, no push needed — or how it ended.
private struct Row: View {
    let line: LiveBox.Line
    let ended: Bool

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            if ended {
                Image(systemName: Outcome(line.outcome).symbol)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Outcome(line.outcome).tint)
                    .frame(width: 18)
            } else {
                Circle().fill(Palette.lime).frame(width: 7, height: 7).frame(width: 18)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(verbatim: line.title)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(Palette.text)
                    .lineLimit(1)
                Text(verbatim: ended ? "\(line.product) · \(Outcome(line.outcome).word)" : line.product)
                    .font(.caption)
                    .foregroundStyle(Palette.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            if !ended, let since = line.since {
                Text(timerInterval: since...Date.distantFuture, countsDown: false)
                    .font(.system(.subheadline, design: .rounded).monospacedDigit())
                    .foregroundStyle(Palette.secondary)
                    .multilineTextAlignment(.trailing)
                    .frame(maxWidth: 72, alignment: .trailing)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

private struct Outcome {
    let code: String?
    init(_ code: String?) { self.code = code }

    var symbol: String {
        switch code {
        case "done": "checkmark.circle.fill"
        case "attention": "questionmark.circle.fill"
        case "failed": "exclamationmark.triangle.fill"
        default: "stop.circle"
        }
    }

    var tint: Color {
        switch code {
        case "done": Palette.green
        case "attention": Palette.orange
        case "failed": Palette.red
        default: Palette.secondary
        }
    }

    var word: String {
        switch code {
        case "done": String(localized: "live.outcome.done")
        case "attention": String(localized: "live.outcome.attention")
        case "failed": String(localized: "live.outcome.failed")
        default: String(localized: "live.outcome.stopped")
        }
    }
}

/// In the island's corner: the one running piece's time, how many run, or that it is done.
private struct Compact: View {
    let state: ShiftAttributes.ContentState
    let names: LiveBox?
    var minimal = false

    var body: some View {
        let over = names?.over ?? (state.working == 0)
        let running = names.map { $0.count } ?? state.working
        Group {
            if over {
                Image(systemName: "checkmark").foregroundStyle(Palette.green)
            } else if !minimal, running == 1, let since = names?.running.first?.since {
                Text(timerInterval: since...Date.distantFuture, countsDown: false)
                    .monospacedDigit()
                    .frame(maxWidth: 48)
                    .foregroundStyle(Palette.lime)
            } else {
                Text(running, format: .number)
                    .monospacedDigit()
                    .foregroundStyle(Palette.lime)
            }
        }
        .font(.system(size: 14, weight: .semibold, design: .rounded))
    }
}

private struct BrandLabel: View {
    var body: some View {
        HStack(spacing: 6) {
            Mark().fill(Palette.lime).frame(width: 11, height: 16)
            Text(verbatim: "Bulava")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Palette.text)
        }
    }
}

/// The desktop's palette on the app icon's deep green — the same values as the phone's dark theme.
private enum Palette {
    static let field = Color(red: 0x16 / 255, green: 0x29 / 255, blue: 0x1C / 255)
    static let lime = Color(red: 0xC7 / 255, green: 0xF1 / 255, blue: 0x83 / 255)
    static let text = Color(red: 0xF2 / 255, green: 0xF2 / 255, blue: 0xF3 / 255)
    static let secondary = Color(red: 0xB5 / 255, green: 0xB5 / 255, blue: 0xBB / 255)
    static let faint = Color(red: 0x7C / 255, green: 0x7C / 255, blue: 0x83 / 255)
    static let orange = Color(red: 0xE8 / 255, green: 0xA4 / 255, blue: 0x5D / 255)
    static let green = Color(red: 0x69 / 255, green: 0xC5 / 255, blue: 0x8C / 255)
    static let red = Color(red: 0xEF / 255, green: 0x77 / 255, blue: 0x70 / 255)
}

/// The Bulava mark, from the same outline as the Mac's `BulavaGlyph`.
struct Mark: Shape {
    private static let bounds = CGRect(x: 324, y: 216, width: 401.5, height: 591)
    private static let outline =
        "M550.1 216 L567.9 216 L576.9 217.6 L586.7 220.9 L596.3 225.7 L603.7 230.6 L613.4 239.5 L622.2"
        + " 251.6 L627.1 261.3 L632 279.2 L632 300.3 L628.7 313.4 L621.5 328.7 L619.2 330.6 L615 337.6"
        + " L602.8 349 L588.6 357.2 L580.4 366.2 L577.2 375.2 L577.2 407.6 L581.3 416.6 L588.6 423.1 L610"
        + " 430.5 L626.2 438.6 L652 455.5 L673 474.1 L673.2 475.5 L680.3 482.2 L691.6 496.7 L700.5 510.5"
        + " L710.2 529.8 L719.1 554.9 L723.1 572.6 L725.5 592.1 L725.5 621.2 L722.3 645.5 L715.8 669.7"
        + " L709.4 686.7 L700.5 704.4 L683.5 730.3 L674.8 739.4 L674.7 740.8 L652.8 761.8 L642.4 769.8"
        + " L622.1 782.8 L603.6 791.6 L588.2 797.3 L570.5 802.1 L543 806.2 L529.1 806.2 L528.4 807 L505"
        + " 806.2 L479.1 802.1 L447.5 792.4 L424.2 781.2 L408.8 771.4 L395.1 761 L373.3 740 L353.9 714.2"
        + " L341.8 691.5 L331.3 663.2 L326.4 642.3 L324 621.2 L324 234.9 L327.3 226.6 L332.2 221.7 L341.3"
        + " 218.4 L436.5 218.4 L444.8 221.7 L449.7 226.6 L452.2 231.5 L453 235.7 L453 620.4 L453.8 626.1"
        + " L457.9 639.9 L465.2 653.7 L470 660.1 L481.3 670.7 L496.7 679.6 L506.5 682.8 L514.6 684.4 L534.9"
        + " 684.4 L553.6 679.6 L563.3 674.7 L574.6 666.6 L581.1 660.1 L590 648 L594.9 638.3 L598.9 625.3"
        + " L600.6 614.8 L599.7 594.4 L594.9 577.4 L584.4 559.6 L570.6 545.8 L559.2 538.5 L557.2 538.5 L552"
        + " 535.3 L536.5 531.3 L521.1 530.4 L508.1 532.1 L498.7 535.3 L491.2 535.3 L483.7 530.3 L481.2 525.3"
        + " L481.2 436.5 L482.9 431.5 L489.4 424.1 L495.2 421.6 L500.3 421.6 L516.2 418.4 L525.2 418.4 L531"
        + " 416.7 L536.8 411.8 L540.1 404.3 L540.1 375.2 L536.8 366.2 L528.7 357.2 L516.8 350.6 L504.7 340"
        + " L496.6 329.6 L490.1 316.6 L485.3 296.3 L485.3 284.1 L486.9 273.5 L490.1 263 L495.8 251.7 L508"
        + " 236.2 L521.7 225.8 L529.8 221.7 Z"

    /// The outline's corners, in the order drawn.
    private static let points: [CGPoint] = {
        let numbers = outline.split(whereSeparator: { " MLZ".contains($0) }).compactMap { Double($0) }
        return stride(from: 0, to: numbers.count - 1, by: 2).map { CGPoint(x: numbers[$0], y: numbers[$0 + 1]) }
    }()

    func path(in rect: CGRect) -> Path {
        let b = Self.bounds
        let scale = min(rect.width / b.width, rect.height / b.height)
        let dx = rect.midX - (b.minX + b.width / 2) * scale
        let dy = rect.midY - (b.minY + b.height / 2) * scale
        var path = Path()
        path.addLines(Self.points.map { CGPoint(x: $0.x * scale + dx, y: $0.y * scale + dy) })
        path.closeSubpath()
        return path
    }
}

#Preview("Lock Screen", as: .content, using: ShiftAttributes()) {
    ShiftActivity()
} contentStates: {
    ShiftAttributes.ContentState(working: 2, waiting: 1, ready: 0, box: LiveBox(
        running: [.init(title: "Why does the export button stay grey", product: "Narada",
                        sinceMs: Int64(Date().addingTimeInterval(-754).timeIntervalSince1970 * 1000), outcome: nil),
                  .init(title: "Import speed", product: "Narada",
                        sinceMs: Int64(Date().addingTimeInterval(-3_100).timeIntervalSince1970 * 1000), outcome: nil)],
        count: 2, ended: [], over: false, productID: nil, chatID: nil))
    ShiftAttributes.ContentState(working: 0, waiting: 0, ready: 1, box: LiveBox(
        running: [], count: 0,
        ended: [.init(title: "Why does the export button stay grey", product: "Narada", sinceMs: nil, outcome: "done"),
                .init(title: "Import speed", product: "Narada", sinceMs: nil, outcome: "attention")],
        over: true, productID: nil, chatID: nil))
    ShiftAttributes.ContentState(working: 1, waiting: 0, ready: 0)
}
