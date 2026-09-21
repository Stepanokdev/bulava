import Foundation
import UserNotifications

extension AppModel {

    var stuckInstances: [SupervisorInstance] {
        instances.filter { isStuck($0) }
    }

    private func isStuck(_ inst: SupervisorInstance) -> Bool { inst.looksStuck }

    func stuckReason(_ inst: SupervisorInstance) -> String {
        if inst.offline {
            if let since = inst.offlineSince {
                return String(format: String(localized: "No network for %@. It carries on by itself when the connection returns."),
                              Fmt.elapsed(Date().timeIntervalSince(since)))
            }
            return String(localized: "No network. It carries on by itself when the connection returns.")
        }
        if !inst.watchdogAlive && inst.doneResult == nil {
            return String(localized: "Its supervisor stopped running — it may be stuck.")
        }
        if let idle = inst.idleSeconds {
            return String(format: String(localized: "Silent for %@. Bulava gives up on it at four hours."),
                          Fmt.elapsed(idle))
        }
        return String(localized: "It went quiet.")
    }

    func stuckSlugs(in instances: [SupervisorInstance]) -> Set<String> {
        Set(instances.filter { isStuck($0) }.map { $0.slug })
    }

    func requestNotifyAuth() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    func pushNotification(title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: "ns-\(UUID().uuidString)", content: content, trigger: nil))
    }
}
