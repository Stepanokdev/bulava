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
    /// The same week is written again after this long all the same. A widget tells the age of what
    /// it shows by the moment the file was written, and a quiet afternoon — nothing running,
    /// nothing changing — left it unwritten for three hours, after which every widget said
    /// "Булава закрита" over a Bulava that was open. Well inside `WeekSnapshot.staleAfter`.
    static let weekRewriteEvery: TimeInterval = 3600

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
        if let previous, previous.saysTheSame(as: snapshot),
           now.timeIntervalSince(previous.generatedAt) < Self.weekRewriteEvery { return }
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

    /// At launch: a widget extension left running from before an update is ended, and the widgets
    /// are asked for a fresh timeline from the current one (`WidgetExtension`).
    func restartStaleWidgetExtension() {
        Task.detached(priority: .utility) {
            guard WidgetExtension.endStale() > 0 else { return }
            await MainActor.run { WidgetCenter.shared.reloadAllTimelines() }
        }
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

/// The widgets' extension as macOS keeps it: one process, started when a widget needs drawing and
/// then left alive for days.
///
/// An update replaces Bulava.app on disk, and nothing tells the extension process started from the
/// old copy to go: it keeps running the old file. Every reload after that was refused — "Bundle
/// version did not match; LaunchServices DB may need to be rebuilt" — so the faces froze: one kept
/// its last numbers until they went stale, the rest drew placeholders. On 8 Oct the extension from
/// 7 Oct's 1.12 was still running under 1.13.
///
/// So at launch, an extension process started from this copy's own path but no longer running the
/// file at that path is ended. macOS starts the current one at the next reload.
nonisolated enum WidgetExtension {
    static let name = "BulavaMacWidgets"

    /// This copy's extension executable, as the processes started from it name it.
    static var executable: String? {
        guard let plugins = Bundle.main.builtInPlugInsURL else { return nil }
        let path = plugins.appendingPathComponent("\(name).appex/Contents/MacOS/\(name)").path
        return FileManager.default.fileExists(atPath: path) ? canonical(path) : nil
    }

    /// Ends every stale one; how many it ended.
    @discardableResult
    static func endStale() -> Int {
        guard let ours = executable else { return 0 }
        var ended = 0
        for pid in processIDs() where pid != getpid() && processName(pid) == name {
            // Started from this copy's path — not a Bulava Dev's or another copy's, those are theirs.
            guard let launched = launchPath(pid), canonical(launched) == ours else { continue }
            // And no longer running what is there: macOS reports no path at all for a process whose
            // file was replaced under it.
            guard isStale(running: runningPath(pid), ours: ours) else { continue }
            if kill(pid, SIGTERM) == 0 {
                ended += 1
                Log.lifecycle.notice("ended a widget extension left over from before an update (pid \(pid, privacy: .public))")
            }
        }
        return ended
    }

    static func isStale(running: String?, ours: String) -> Bool {
        guard let running else { return true }
        return canonical(running) != ours
    }

    static func canonical(_ path: String) -> String {
        guard let real = realpath(path, nil) else { return (path as NSString).standardizingPath }
        defer { free(real) }
        return String(cString: real)
    }

    private static func processIDs() -> [pid_t] {
        let count = proc_listallpids(nil, 0)
        guard count > 0 else { return [] }
        var pids = [pid_t](repeating: 0, count: Int(count) + 32)
        let got = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size))
        return got > 0 ? Array(pids.prefix(Int(got))) : []
    }

    private static func processName(_ pid: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: 64)
        return proc_name(pid, &buffer, UInt32(buffer.count)) > 0 ? String(cString: buffer) : nil
    }

    private static func runningPath(_ pid: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        return proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 ? String(cString: buffer) : nil
    }

    /// The path the process was started by: the string after argc in its KERN_PROCARGS2.
    private static func launchPath(_ pid: pid_t) -> String? {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else { return nil }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0 else { return nil }
        let start = MemoryLayout<Int32>.size
        guard let end = buffer[start..<size].firstIndex(of: 0), end > start else { return nil }
        return String(decoding: buffer[start..<end], as: UTF8.self)
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
