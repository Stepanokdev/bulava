import AppKit
import Foundation
import OSLog
import WidgetKit

/// The calendar week, kept current for the widgets, the Week page and the phone.
///
/// Collecting reads files and runs git, so it happens off the main actor, never twice at once, and
/// at most every ten minutes. Between collections the faces are said again from the numbers already
/// read — who is working, the limits — which costs nothing. Statistics never keep the Mac awake.
extension AppModel {

    static let weekCollectEvery: TimeInterval = 600
    /// The widgets are asked to redraw at most this often for numbers that merely grew; what is
    /// working now, and statistics switched on or off, redraw them at once.
    static let weekReloadEvery: TimeInterval = 900

    /// One step of the refresh loop.
    func tickWeek(now: Date = Date()) {
        let due = weekCollectedAt.map { now.timeIntervalSince($0) >= Self.weekCollectEvery } ?? true
        if due {
            collectWeek()
        } else {
            presentWeek(now: now)
        }
    }

    /// Reads the week again. Statistics switched off: nothing is read at all.
    func collectWeek() {
        guard weekTask == nil else { return }
        let collector = weekCollector
        let on = settings.weeklyStats
        weekTask = Task { [weak self] in
            let raw: WeekRaw? = on
                ? await Task.detached(priority: .utility) { await collector.collect() }.value
                : nil
            guard let self, !Task.isCancelled else { return }
            self.weekRaw = raw ?? WeekRaw.empty(now: Date())
            self.weekCollectedAt = Date()
            self.weekTask = nil
            self.presentWeek(now: Date())
            self.considerUsageReport()
        }
    }

    /// Says the week again from what was read, and hands it on when it says something new.
    func presentWeek(now: Date = Date()) {
        guard var raw = weekRaw else { return }
        // A new week began since the last reading: what we hold is last week's.
        if raw.isoWeek != WeekCollector.isoWeek(of: now, calendar: .bulavaWeek) {
            weekCollectedAt = nil
            collectWeek()
            return
        }
        let off = !settings.weeklyStats
        if off { raw = WeekRaw.empty(now: now) }
        raw.today = WeekRaw.dayIndex(of: now, bounds: raw.bounds)
        let snapshot = WeekPresenter(raw: raw, capacity: capacity, running: off ? [] : weekRunningLines,
                                     off: off, now: now).snapshot()
        let previous = week
        if let previous, previous.saysTheSame(as: snapshot) { return }
        week = snapshot

        // Redraw the widgets for what matters at once; let growing numbers wait their turn.
        let urgent = previous == nil || previous?.off != snapshot.off
            || previous?.now.runs.map(\.name) != snapshot.now.runs.map(\.name)
            || previous?.limits.meters.map(\.severity) != snapshot.limits.meters.map(\.severity)
        let reload = urgent || weekWidgetsReloadedAt.map { now.timeIntervalSince($0) >= Self.weekReloadEvery } ?? true
        if reload { weekWidgetsReloadedAt = now }
        Task.detached(priority: .utility) {
            WeekPublisher.write(snapshot)
            if reload { await MainActor.run { WidgetCenter.shared.reloadAllTimelines() } }
        }
    }

    /// A link from one of Bulava's widgets: `bulava://week/<face>`. A tap on a widget opens Bulava,
    /// as it is; anything else is not ours to open.
    @discardableResult
    func open(link url: URL) -> Bool {
        guard url.scheme == "bulava", url.host == "week" else { return false }
        NSApp.activate(ignoringOtherApps: true)
        return true
    }

    /// Statistics switched on or off in Settings.
    func weeklyStatsChanged() {
        weekCollectedAt = nil
        weekRaw = nil
        collectWeek()
    }

    /// What is working now and what waits for the person, by the names the menu bar and the
    /// Live Activity use.
    var weekRunningLines: [WeekNowLine] {
        var lines = LinkProjection.runningLines(self).map {
            WeekNowLine(name: $0.title, since: $0.sinceMs.map { Date(timeIntervalSince1970: TimeInterval($0) / 1000) },
                        waiting: false)
        }
        let running = Set(lines.map(\.name))
        for product in products.sorted {
            for chat in conversations.chats(for: product.id, includingAutomationRuns: true)
            where directPhase(for: chat.id).wantsAttention && !running.contains(chat.title) {
                lines.append(WeekNowLine(name: chat.title, since: nil, waiting: true))
            }
        }
        return lines
    }
}

/// Puts the week where the Mac's widgets read it.
nonisolated enum WeekPublisher {
    static func write(_ snapshot: WeekSnapshot) {
        guard let data = snapshot.encoded() else { return }
        let url = WeekStore.fileURL()
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
        } catch {
            Log.lifecycle.error("week snapshot not written: \(error.localizedDescription, privacy: .public)")
        }
    }
}
