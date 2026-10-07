import Foundation
import UserNotifications

extension AppModel {

    func requestNotifyAuth() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }
}
