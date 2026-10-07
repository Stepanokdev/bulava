import Foundation
import WidgetKit

/// The weekly usage summary for Bulava's author (`UsageReport`): a setting, on unless turned off, and
/// never sent for a week that began before this Mac had the setting.
extension AppModel {

    /// After each collection of the week: notes when the setting was first there, and sends last
    /// week's report once that week is over.
    func considerUsageReport(now: Date = Date()) {
        guard settings.shareUsage, settings.weeklyStats else { return }
        guard let since = settings.usageSince else {
            settings.usageSince = now
            return
        }
        let calendar = Calendar.bulavaWeek
        guard usageTask == nil,
              let due = UsageReport.due(now: now, since: since, reportedWeek: settings.usageReportedWeek,
                                        calendar: calendar) else { return }
        let lastWeek = due.week, lastWeekStart = due.start, thisWeek = due.end

        let phone = !mobileLink.devices.devices.isEmpty
        let automationsRan = automations.runs.contains { run in
            guard let started = run.startedAt else { return false }
            return started >= lastWeekStart && started < thisWeek
        }
        let language = LanguageBundle.currentCode
        usageTask = Task { [weak self] in
            // A collector of its own, so the current week's cache is left as it is.
            let raw = await Task.detached(priority: .utility) {
                await WeekCollector().collect(now: thisWeek.addingTimeInterval(-1), calendar: calendar)
            }.value
            let widgets = await Self.placedWidgets()
            let info = Bundle.main.infoDictionary ?? [:]
            let os = ProcessInfo.processInfo.operatingSystemVersion
            let report = UsageReport.make(
                raw: raw, widgets: widgets, phone: phone, automations: automationsRan,
                app: "\(info["CFBundleShortVersionString"] as? String ?? "?") (\(info["CFBundleVersion"] as? String ?? "?"))",
                os: "\(os.majorVersion).\(os.minorVersion)",
                channel: AppChannel.current.isDev ? "dev" : "production", language: language)
            let outcome = await UsageOutbox().send(report)
            guard let self else { return }
            if outcome != .later, self.settings.shareUsage { self.settings.usageReportedWeek = lastWeek }
            self.usageTask = nil
        }
    }

    /// Which of the week's widgets are on this Mac's desktop, by face.
    nonisolated static func placedWidgets() async -> [String] {
        await withCheckedContinuation { cont in
            WidgetCenter.shared.getCurrentConfigurations { result in
                let kinds = (try? result.get())?.map(\.kind) ?? []
                cont.resume(returning: Array(Set(kinds.compactMap { $0.hasPrefix("bulava.week.") ? String($0.dropFirst(12)) : nil })))
            }
        }
    }

    /// What this week's summary would hold, for Settings to show before anything is sent.
    func usageReportPreview() -> UsageReport? {
        guard let raw = weekRaw else { return nil }
        let info = Bundle.main.infoDictionary ?? [:]
        let os = ProcessInfo.processInfo.operatingSystemVersion
        return UsageReport.make(
            raw: raw, widgets: [], phone: !mobileLink.devices.devices.isEmpty,
            automations: automations.runs.contains { ($0.startedAt ?? .distantPast) >= raw.weekStart },
            app: "\(info["CFBundleShortVersionString"] as? String ?? "?") (\(info["CFBundleVersion"] as? String ?? "?"))",
            os: "\(os.majorVersion).\(os.minorVersion)",
            channel: AppChannel.current.isDev ? "dev" : "production", language: LanguageBundle.currentCode)
    }
}
