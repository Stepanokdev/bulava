import AppKit
import UserNotifications

/// What waits for the director, told on the Mac by Bulava itself whenever Bulava is not the app in
/// front of him.
///
/// Only automations used to say anything on the Mac (`AppModel.notify`). A question, a permission
/// dialog or a request in an ordinary chat stayed silent until he happened to look at Bulava: the
/// phone in his pocket was woken, the Mac he sat at was not. These come from the very list the
/// phone is woken for (`LinkProjection`'s attention, read by `MobileLink.watchDesktop`), so the two
/// never disagree about what is waiting. A click opens the chat it is about.
@MainActor
final class DesktopNotices: NSObject, UNUserNotificationCenterDelegate {
    weak var model: AppModel?
    /// What was waiting at the last reading; nil until the first, which is the starting line —
    /// whatever was there when Bulava started is in front of him the moment he opens it.
    private(set) var seen: Set<String>?
    private var authorized = false

    /// Whether Bulava is the app in front, and how a notification is handed to macOS. Tests
    /// replace both: the test host is the real app with nobody in front of it.
    var isAppActive: () -> Bool = { NSApp.isActive }
    var post: (UNNotificationRequest) -> Void = { request in
        UNUserNotificationCenter.current().add(request) { _ in }
    }
    /// How many notices one reading may raise; anything beyond is folded into one more.
    static let perReading = 3

    func attach(_ model: AppModel) {
        self.model = model
        UNUserNotificationCenter.current().delegate = self
    }

    /// One reading of what waits for him. Returns what was posted, for the tests.
    @discardableResult
    func changed(_ items: [AttentionDTO]) -> [UNNotificationRequest] {
        let ids = Set(items.map(\.id))
        defer { seen = ids }
        guard let seen, !isAppActive() else { return [] }
        let new = items
            .filter { !seen.contains($0.id) && tells($0) }
            .sorted { $0.atMs > $1.atMs }
        guard !new.isEmpty else { return [] }
        var requests = new.prefix(Self.perReading).map(request(for:))
        if new.count > Self.perReading {
            let content = UNMutableNotificationContent()
            content.title = "Bulava"
            content.body = String(format: String(localized: "More waiting for you: %lld."), new.count - Self.perReading)
            content.sound = nil
            requests.append(UNNotificationRequest(identifier: "bulava.more.\(UUID().uuidString)", content: content, trigger: nil))
        }
        askOnce()
        requests.forEach(post)
        return requests
    }

    /// An automation's chat says it itself (`AppModel.notify`), and the Mac's own setup is a
    /// banner inside Bulava, not news.
    private func tells(_ item: AttentionDTO) -> Bool {
        guard item.kind != "readiness" else { return false }
        if let raw = item.chatID, let id = UUID(uuidString: raw),
           model?.conversations.chat(id: id)?.isAutomationRun == true { return false }
        return true
    }

    private func request(for item: AttentionDTO) -> UNNotificationRequest {
        let content = UNMutableNotificationContent()
        let product = UUID(uuidString: item.productID).flatMap { model?.products.product(id: $0)?.name }
        content.title = item.title.isEmpty ? String(localized: "Bulava needs your answer") : item.title
        if let product, !product.isEmpty { content.subtitle = product }
        content.body = String(item.body.prefix(240))
        content.sound = .default
        content.threadIdentifier = item.chatID ?? item.productID
        content.userInfo = ["productID": item.productID, "chatID": item.chatID ?? ""]
        // One notice per thing waiting: the same item read again replaces, never repeats.
        return UNNotificationRequest(identifier: "bulava.attention.\(item.id)", content: content, trigger: nil)
    }

    /// macOS asks the director once, the first time there is actually something to tell — not at
    /// every launch of an app he may never leave in the background.
    private func askOnce() {
        guard !authorized, NSClassFromString("XCTestCase") == nil else { return }
        authorized = true
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    // MARK: UNUserNotificationCenterDelegate

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                            withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        // In front of him already: into the list, no banner over what he is doing.
        completionHandler([.list])
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                            withCompletionHandler completionHandler: @escaping () -> Void) {
        let info = response.notification.request.content.userInfo
        let chatID = (info["chatID"] as? String).flatMap(UUID.init(uuidString:))
        let productID = (info["productID"] as? String).flatMap(UUID.init(uuidString:))
        completionHandler()
        Task { @MainActor in
            NSApp.activate()
            guard let model = self.model else { return }
            if let chatID, let chat = model.conversations.chat(id: chatID) {
                model.openChat(chat)
            } else if let productID, model.products.product(id: productID) != nil {
                model.open(product: productID)
            }
        }
    }
}
