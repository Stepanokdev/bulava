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
///
/// The Lock Screen face is `LockScreenShift`, kept in its own file free of ActivityKit so its exact
/// layout can be rendered and measured off a device.
struct ShiftActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: ShiftAttributes.self) { context in
            LockScreenShift(names: context.state.names, stale: context.isStale,
                            working: context.state.working)
                .activityBackgroundTint(Palette.field)
                .activitySystemActionForegroundColor(Palette.lime)
                .widgetURL(context.state.names?.link)
        } dynamicIsland: { context in
            let names = context.state.names
            let running = names?.count ?? context.state.working
            let over = names?.over ?? (context.state.working == 0)
            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    BrandLabel().padding(.leading, 4)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Headline(running: running, over: over, stale: context.isStale)
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
