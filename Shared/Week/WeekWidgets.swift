#if WEEK_WIDGETS
import SwiftUI
import WidgetKit

/// The week's widgets, the same on the Mac and the iPhone. Each extension supplies one thing of its
/// own — `WeekSource`, where it finds the snapshot — and lists these in its `WidgetBundle`.
///
/// Compiled only into the widget extensions (`WEEK_WIDGETS`); the Mac app draws the same faces on
/// its Week page without them.

struct WeekEntry: TimelineEntry {
    let date: Date
    let snapshot: WeekSnapshot?
}

struct WeekProvider: TimelineProvider {
    func placeholder(in context: Context) -> WeekEntry { WeekEntry(date: .now, snapshot: nil) }

    func getSnapshot(in context: Context, completion: @escaping (WeekEntry) -> Void) {
        completion(WeekEntry(date: .now, snapshot: WeekSource.read()))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<WeekEntry>) -> Void) {
        let now = Date.now
        let snapshot = WeekSource.read()
        var entries = [WeekEntry(date: now, snapshot: snapshot)]
        // A second entry for the moment it turns stale: the face then says how old the numbers are
        // even if nothing asks it to redraw.
        if let snapshot {
            let staleAt = snapshot.generatedAt.addingTimeInterval(WeekSnapshot.staleAfter + 1)
            if staleAt > now { entries.append(WeekEntry(date: staleAt, snapshot: snapshot)) }
        }
        // Bulava asks for a redraw when the week changes; this is only the fallback.
        completion(Timeline(entries: entries, policy: .after(now.addingTimeInterval(15 * 60))))
    }
}

struct WeekWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let kind: WeekFaceKind
    let entry: WeekEntry

    var body: some View {
        content
            .containerBackground(WeekPalette.field, for: .widget)
            .widgetURL(kind.link)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text(verbatim: spoken))
    }

    @ViewBuilder private var content: some View {
        switch family {
        #if os(iOS)
        case .accessoryRectangular: WeekAccessoryView(kind: kind, shape: .rectangular, snapshot: entry.snapshot)
        case .accessoryCircular: WeekAccessoryView(kind: kind, shape: .circular, snapshot: entry.snapshot)
        case .accessoryInline: WeekAccessoryView(kind: kind, shape: .inline, snapshot: entry.snapshot)
        #endif
        case .systemSmall: WeekFaceView(kind: kind, size: .small, snapshot: entry.snapshot, place: WeekSource.place, now: entry.date)
        case .systemMedium: WeekFaceView(kind: kind, size: .medium, snapshot: entry.snapshot, place: WeekSource.place, now: entry.date)
        default: WeekFaceView(kind: kind, size: .large, snapshot: entry.snapshot, place: WeekSource.place, now: entry.date)
        }
    }

    private var spoken: String {
        guard let s = entry.snapshot else { return "Bulava" }
        if s.off && kind != .limits { return s.words.off }
        switch kind {
        case .autonomy, .week: return s.autonomy.spoken
        case .outcomes: return s.outcomes.spoken
        case .receipt: return s.receipt.spoken
        case .rhythm: return s.rhythm.spoken
        case .volume: return s.volume.spoken
        case .limits: return s.limits.spoken
        case .now: return s.now.spoken
        }
    }
}

private func families(_ system: [WidgetFamily], accessories: [WidgetFamily] = []) -> [WidgetFamily] {
    #if os(iOS)
    system + accessories
    #else
    system
    #endif
}

private var accessoryFamilies: [WidgetFamily] {
    #if os(iOS)
    [.accessoryRectangular, .accessoryCircular, .accessoryInline]
    #else
    []
    #endif
}

struct AutonomyWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "bulava.week.autonomy", provider: WeekProvider()) { WeekWidgetView(kind: .autonomy, entry: $0) }
            .configurationDisplayName(Text("Without you"))
            .description(Text("How long the agents worked this week, and how much work each of your messages started."))
            .supportedFamilies(families([.systemSmall, .systemMedium, .systemLarge], accessories: accessoryFamilies))
    }
}

struct OutcomesWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "bulava.week.outcomes", provider: WeekProvider()) { WeekWidgetView(kind: .outcomes, entry: $0) }
            .configurationDisplayName(Text("How runs ended"))
            .description(Text("What review accepted this week, what it accepted with remarks, and what waited for you."))
            .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}

struct ReceiptWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "bulava.week.receipt", provider: WeekProvider()) { WeekWidgetView(kind: .receipt, entry: $0) }
            .configurationDisplayName(Text("Receipt of the week"))
            .description(Text("What the week's work would have cost at API prices. An estimate, not what you pay."))
            .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}

struct RhythmWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "bulava.week.rhythm", provider: WeekProvider()) { WeekWidgetView(kind: .rhythm, entry: $0) }
            .configurationDisplayName(Text("Rhythm of the week"))
            .description(Text("When the agents worked, day by day and hour by hour."))
            .supportedFamilies([.systemSmall, .systemMedium])
    }
}

struct VolumeWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "bulava.week.volume", provider: WeekProvider()) { WeekWidgetView(kind: .volume, entry: $0) }
            .configurationDisplayName(Text("Code changes"))
            .description(Text("Lines the agents added and removed this week."))
            .supportedFamilies([.systemSmall, .systemMedium])
    }
}

struct LimitsWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "bulava.week.limits", provider: WeekProvider()) { WeekWidgetView(kind: .limits, entry: $0) }
            .configurationDisplayName(Text("Limits"))
            .description(Text("Claude's and Codex's limits, with a tick where an even pace would be."))
            .supportedFamilies(families([.systemSmall, .systemMedium], accessories: accessoryFamilies))
    }
}

struct NowWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "bulava.week.now", provider: WeekProvider()) { WeekWidgetView(kind: .now, entry: $0) }
            .configurationDisplayName(Text("Working now"))
            .description(Text("Which agents are working and which runs wait for you."))
            .supportedFamilies(families([.systemSmall, .systemMedium, .systemLarge], accessories: accessoryFamilies))
    }
}

struct WeekAtAGlanceWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "bulava.week.glance", provider: WeekProvider()) { WeekWidgetView(kind: .week, entry: $0) }
            .configurationDisplayName(Text("The week at a glance"))
            .description(Text("Hours without you, accepted runs, the receipt and the week's rhythm on one face."))
            .supportedFamilies([.systemLarge])
    }
}
#endif
