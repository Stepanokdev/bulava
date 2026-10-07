import SwiftUI
import UserNotifications
import BackgroundTasks
import OSLog
import Shared

@main
struct iOSApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @Environment(\.scenePhase) private var phase

    var body: some Scene {
        WindowGroup {
            ContentView()
                .ignoresSafeArea()
                // The pairing page on bulava.app hands the code over as bulava://pair#…
                .onOpenURL { url in _ = MainViewControllerKt.handleURL(url: url.absoluteString) }
        }
        .onChange(of: phase) { _, now in
            MainViewControllerKt.setForeground(foreground: now == .active)
            if now == .active { BulavaHost.shared.refreshNotificationState() }
        }
    }
}

final class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        BulavaHost.shared.refreshNotificationState()
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in
            BulavaHost.shared.refreshNotificationState()
        }
        // A token for waking this iPhone through Bulava's push relay when the Mac needs an answer
        // and the app is closed. It goes to the Mac over the link; the push itself says only
        // "Bulava needs you".
        application.registerForRemoteNotifications()
        // The Live Activity's tokens, including when a push has just started one and woken the app.
        LiveShift.shared.start()
        // iOS cannot keep a socket open for a closed app. It can wake the app now and then, and
        // each wake is a chance to hear what the Mac is waiting on.
        BGTaskScheduler.shared.register(forTaskWithIdentifier: BulavaHost.refreshTask, using: nil) { task in
            BulavaHost.shared.scheduleRefresh(active: true)
            MainViewControllerKt.backgroundCheck(host: BulavaHost.shared) { heard in
                task.setTaskCompleted(success: heard.boolValue)
            }
            task.expirationHandler = { task.setTaskCompleted(success: false) }
        }
        return true
    }

    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        let token = deviceToken.map { String(format: "%02x", $0) }.joined()
        MainViewControllerKt.setPushToken(token: token, environment: BulavaHost.apnsEnvironment)
    }

    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
        // Without a token the app still hears the Mac while open and on background refresh.
        Logger(subsystem: "com.stepanok.bulava", category: "host")
            .error("no push token: \(error.localizedDescription, privacy: .public)")
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        // Something the app itself marked passive stays in the list with the app open too.
        let quiet = notification.request.content.interruptionLevel == .passive
        completionHandler(quiet ? [.list] : [.banner, .sound, .list])
    }

    /// What a notification is about when it names no chat. The app's own says it (`about`: the
    /// Mac's setup). A push from the relay says it by the sentence it shows (`push-relay`'s
    /// `notifyKinds`): the Mac needs an answer, a report is in, a chat's answer is in. Every relay
    /// sends the sentence; only a newer one can also send the sealed route, and a push without one
    /// leads to the newest thing of its kind.
    static func about(_ info: [AnyHashable: Any]) -> String? {
        if let own = info["about"] as? String, !own.isEmpty { return own }
        let alert = (info["aps"] as? [String: Any])?["alert"] as? [String: Any]
        switch alert?["loc-key"] as? String {
        case "PUSH_BODY": return "attention"
        case "PUSH_BODY_DONE": return "finished"
        case "PUSH_BODY_REPLIED": return "done"
        default: return nil
        }
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        switch response.actionIdentifier {
        case UNNotificationDefaultActionIdentifier:
            let info = response.notification.request.content.userInfo
            // The relay's push says which chat only sealed, with the key this phone gave its Mac.
            let route = (info["sealed"] as? String).flatMap { LiveKey.open($0, as: LiveRoute.self) }
            let product = (route?.productID ?? info["productID"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            let chat = (route?.chatID ?? info["chatID"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            MainViewControllerKt.handleNotification(productID: product, chatID: chat, about: Self.about(info))
            completionHandler()
        case UNNotificationDismissActionIdentifier:
            completionHandler()
        default:
            // One of the request's own buttons, pressed after the phone was unlocked. It is pressed
            // on the Mac without opening the app; iOS waits for the answer, and so does this.
            let text = (response as? UNTextInputNotificationResponse)?.userText
            var task = UIBackgroundTaskIdentifier.invalid
            let finish = {
                if task != .invalid { UIApplication.shared.endBackgroundTask(task); task = .invalid }
                completionHandler()
            }
            task = UIApplication.shared.beginBackgroundTask(withName: "bulava.answer") {
                if task != .invalid { UIApplication.shared.endBackgroundTask(task); task = .invalid }
            }
            MainViewControllerKt.respondToNotification(
                host: BulavaHost.shared, notificationID: response.notification.request.identifier,
                actionID: response.actionIdentifier, text: text
            ) { _ in DispatchQueue.main.async { finish() } }
        }
    }
}
