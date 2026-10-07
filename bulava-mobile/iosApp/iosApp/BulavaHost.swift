import UIKit
import WebKit
import Network
import PhotosUI
import Security
import UniformTypeIdentifiers
import UserNotifications
import BackgroundTasks
import CryptoKit
import OSLog
import Shared

/// Everything the shared Kotlin code asks of iOS. One instance for the life of the app.
final class BulavaHost: NSObject, IosHost {
    static let shared = BulavaHost()
    static let refreshTask = "com.stepanok.bulava.refresh"
    private let log = Logger(subsystem: "com.stepanok.bulava", category: "host")

    // MARK: About this phone

    func deviceName() -> String { UIDevice.current.name }
    func osVersion() -> String { "iOS \(UIDevice.current.systemVersion)" }
    func appVersion() -> String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
    }

    // MARK: The link

    func openSocket(url: String, pin: String, listener: TransportListener) -> IosSocket {
        PinnedSocket(url: url, pin: pin, listener: listener)
    }

    // MARK: Keychain

    private let service = "com.stepanok.bulava"

    private func query(_ key: String) -> [CFString: Any] {
        [kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecAttrAccount: key]
    }

    func keychainGet(key: String) -> String? {
        var q = query(key)
        q[kSecReturnData] = true
        q[kSecMatchLimit] = kSecMatchLimitOne
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let data = out as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    func keychainPut(key: String, value: String) {
        let data = Data(value.utf8)
        let q = query(key)
        // Readable after the first unlock, so a background wake can still present the credential;
        // never synced to another device, because the pairing belongs to this phone.
        let update: [CFString: Any] = [kSecValueData: data,
                                       kSecAttrAccessible: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        var status = SecItemUpdate(q as CFDictionary, update as CFDictionary)
        if status == errSecItemNotFound {
            var add = q
            add.merge(update) { _, new in new }
            status = SecItemAdd(add as CFDictionary, nil)
        }
        if status != errSecSuccess {
            // The pairing would be lost at the next launch; say so where it can be found.
            log.error("keychain write for \(key, privacy: .public) failed: \(status)")
        }
    }

    func keychainRemove(key: String) {
        SecItemDelete(query(key) as CFDictionary)
    }

    // MARK: Notifications

    /// Which APNs this build's tokens belong to.
    static var apnsEnvironment: String {
        #if DEBUG
        return "development"
        #else
        return "production"
        #endif
    }

    func notify(note: PhoneNotification) {
        let content = UNMutableNotificationContent()
        content.title = note.title
        content.body = note.body
        content.userInfo = ["productID": note.productID ?? "", "chatID": note.chatID ?? "", "about": note.about ?? ""]
        if note.quiet {
            content.interruptionLevel = .passive
            content.threadIdentifier = "bulava-done"
        } else if note.finished {
            // Work that finished — a report in, a chat's answer: what the director waits to hear.
            content.sound = .default
            content.interruptionLevel = .active
            content.threadIdentifier = "bulava-done"
        } else {
            content.sound = .default
            content.interruptionLevel = .timeSensitive
            content.threadIdentifier = note.chatID ?? "bulava"
        }
        let center = UNUserNotificationCenter.current()
        guard !note.buttons.isEmpty else {
            center.add(UNNotificationRequest(identifier: note.id, content: content, trigger: nil))
            return
        }
        let category = Self.category(for: note.buttons)
        content.categoryIdentifier = category.identifier
        register(category) {
            center.add(UNNotificationRequest(identifier: note.id, content: content, trigger: nil))
        }
    }

    /// A request's own buttons, for its notification. Each asks for the phone to be unlocked first:
    /// Face ID, Touch ID or the code — the lock screen is not somebody else's way into the Mac.
    static func category(for buttons: [NotificationButton]) -> UNNotificationCategory {
        let actions: [UNNotificationAction] = buttons.map { button in
            var options: UNNotificationActionOptions = [.authenticationRequired]
            if button.destructive { options.insert(.destructive) }
            if let placeholder = button.inputPlaceholder {
                return UNTextInputNotificationAction(identifier: button.id, title: button.label, options: options,
                                                     textInputButtonTitle: String(localized: "notification.send"),
                                                     textInputPlaceholder: placeholder)
            }
            return UNNotificationAction(identifier: button.id, title: button.label, options: options)
        }
        let signature = buttons.map { "\($0.id)|\($0.label)|\($0.inputPlaceholder ?? "")" }.joined(separator: "\n")
        let digest = SHA256.hash(data: Data(signature.utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
        return UNNotificationCategory(identifier: "bulava.ask.\(digest)", actions: actions, intentIdentifiers: [], options: [])
    }

    /// The categories in use, newest last. iOS keeps one set for the whole app, so each request's
    /// buttons are added to it, and the oldest dropped past a few dozen.
    private var categories: [UNNotificationCategory] = []

    private func register(_ category: UNNotificationCategory, then post: @escaping () -> Void) {
        DispatchQueue.main.async {
            self.categories.removeAll { $0.identifier == category.identifier }
            self.categories.append(category)
            if self.categories.count > 32 { self.categories.removeFirst(self.categories.count - 32) }
            let center = UNUserNotificationCenter.current()
            center.setNotificationCategories(Set(self.categories))
            // Reading them back answers only once they are in place, so the buttons are there when
            // the notification arrives.
            center.getNotificationCategories { _ in post() }
        }
    }

    // MARK: Live Activity

    func showSummary(working: Int32, waiting: Int32, ready: Int32, live: String?, macName: String) {
        let decoded = live.flatMap { try? JSONDecoder().decode(LiveShift.Live.self, from: Data($0.utf8)) }
        DispatchQueue.main.async {
            LiveShift.shared.show(working: Int(working), waiting: Int(waiting), ready: Int(ready), live: decoded)
        }
    }

    /// The Lock Screen's key, base64, for the Mac to seal names with. Made on first use.
    func liveKey() -> String? { LiveKey.readOrCreate()?.base64EncodedString() }

    /// The relay's pushes, once the app has heard from the Mac itself: they said only "something is
    /// there", and each thing is now told on its own or shown in the app.
    func clearWakeUps() {
        let center = UNUserNotificationCenter.current()
        center.getDeliveredNotifications { delivered in
            let wakeUps = delivered.filter { $0.request.trigger is UNPushNotificationTrigger }.map(\.request.identifier)
            if !wakeUps.isEmpty { center.removeDeliveredNotifications(withIdentifiers: wakeUps) }
        }
    }

    func cancelNotification(id: String) {
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [id])
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [id])
    }

    private var notificationsGranted = false

    func notificationsAllowed() -> Bool { notificationsGranted }

    func refreshNotificationState() {
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            let allowed = settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional
            DispatchQueue.main.async { self.notificationsGranted = allowed }
        }
    }

    func requestNotifications() {
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            if settings.authorizationStatus == .denied {
                DispatchQueue.main.async { self.openSettings() }
                return
            }
            UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { granted, _ in
                DispatchQueue.main.async { self.notificationsGranted = granted }
            }
        }
    }

    func openURL(url: String) {
        guard let target = URL(string: url) else { return }
        UIApplication.shared.open(target)
    }

    func openSettings() {
        guard let target = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(target)
    }

    // MARK: Camera and pickers

    private var scanning: ((String?) -> Void)?
    private var picking: ((String?, String?) -> Void)?

    func scanCode(onResult: @escaping (String?) -> Void) {
        DispatchQueue.main.async {
            let scanner = ScannerViewController { code in onResult(code) }
            scanner.modalPresentationStyle = .fullScreen
            Self.top()?.present(scanner, animated: true)
        }
    }

    func pickImage(onResult: @escaping (String?, String?) -> Void) {
        DispatchQueue.main.async {
            var configuration = PHPickerConfiguration()
            configuration.filter = .images
            configuration.selectionLimit = 1
            let picker = PHPickerViewController(configuration: configuration)
            picker.delegate = self
            self.picking = onResult
            Self.top()?.present(picker, animated: true)
        }
    }

    func pickFile(onResult: @escaping (String?, String?) -> Void) {
        DispatchQueue.main.async {
            let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.item], asCopy: true)
            picker.delegate = self
            self.picking = onResult
            Self.top()?.present(picker, animated: true)
        }
    }

    private func deliverPick(_ path: String?, _ name: String?) {
        let callback = picking
        picking = nil
        DispatchQueue.main.async { callback?(path, name) }
    }

    static func top() -> UIViewController? {
        let window = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows).first { $0.isKeyWindow }
        var top = window?.rootViewController
        while let presented = top?.presentedViewController { top = presented }
        return top
    }

    // MARK: Finding the Mac again

    private var browser: NWBrowser?

    /// Looks for the paired Mac by the id it advertises over Bonjour, and turns each match into a
    /// host and port by opening (and at once dropping) a plain TCP connection to it.
    func browse(desktopID: String, onFound: @escaping ([String]) -> Void) {
        browser?.cancel()
        let browser = NWBrowser(for: .bonjourWithTXTRecord(type: "_bulava-link._tcp", domain: nil), using: .tcp)
        self.browser = browser
        var found: [String] = []
        var finished = false
        let queue = DispatchQueue(label: "bulava.browse")
        func finish() {
            guard !finished else { return }
            finished = true
            browser.cancel()
            DispatchQueue.main.async { onFound(found) }
        }
        browser.browseResultsChangedHandler = { results, _ in
            for result in results {
                guard case .bonjour(let txt) = result.metadata, txt["id"] == desktopID else { continue }
                let connection = NWConnection(to: result.endpoint, using: .tcp)
                connection.stateUpdateHandler = { state in
                    if case .ready = state,
                       case .hostPort(let host, let port)? = connection.currentPath?.remoteEndpoint {
                        var text = "\(host)"
                        if let percent = text.firstIndex(of: "%") { text = String(text[..<percent]) }
                        queue.async { found.append("\(text):\(port.rawValue)") }
                        connection.cancel()
                    } else if case .failed = state {
                        connection.cancel()
                    }
                }
                connection.start(queue: queue)
            }
        }
        browser.start(queue: queue)
        queue.asyncAfter(deadline: .now() + 3.5) { finish() }
    }

    // MARK: Background

    func scheduleRefresh(active: Bool) {
        if !active {
            BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: Self.refreshTask)
            return
        }
        let request = BGAppRefreshTaskRequest(identifier: Self.refreshTask)
        request.earliestBeginDate = Date(timeIntervalSinceNow: 15 * 60)
        try? BGTaskScheduler.shared.submit(request)
    }
}

extension BulavaHost: PHPickerViewControllerDelegate {
    func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
        picker.dismiss(animated: true)
        guard let provider = results.first?.itemProvider, provider.canLoadObject(ofClass: UIImage.self) else {
            deliverPick(nil, nil)
            return
        }
        let base = (provider.suggestedName ?? "Photo").replacingOccurrences(of: "/", with: "-")
        // Sent as JPEG whatever the library holds: a HEIC is a file the agent on the Mac may not read.
        provider.loadObject(ofClass: UIImage.self) { [weak self] object, _ in
            guard let image = object as? UIImage, let data = image.jpegData(compressionQuality: 0.88) else {
                self?.deliverPick(nil, nil)
                return
            }
            let name = base + ".jpg"
            let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".jpg")
            do {
                try data.write(to: url)
                self?.deliverPick(url.path, name)
            } catch {
                self?.deliverPick(nil, nil)
            }
        }
    }
}

extension BulavaHost: UIDocumentPickerDelegate {
    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        guard let url = urls.first else { deliverPick(nil, nil); return }
        deliverPick(url.path, url.lastPathComponent)
    }

    func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
        deliverPick(nil, nil)
    }
}

// MARK: - Reports

extension BulavaHost {
    /// The rule list every report web view runs under: block every load, then let `data:` and
    /// `about:` through. Compiled once; a report opened before it is ready waits for it.
    private static let rules = """
    [{"trigger":{"url-filter":".*"},"action":{"type":"block"}},
     {"trigger":{"url-filter":"^data:"},"action":{"type":"ignore-previous-rules"}},
     {"trigger":{"url-filter":"^about:"},"action":{"type":"ignore-previous-rules"}}]
    """

    func reportView(html: String, onLink: @escaping (String) -> Void) -> UIView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.allowsInlineMediaPlayback = true
        // No window.open, no pop-ups: a page cannot make a second view to escape into.
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        let view = ReportWebView(frame: .zero, configuration: configuration)
        view.fence = ReportNavigation(onLink: onLink)
        view.navigationDelegate = view.fence
        view.uiDelegate = view.fence
        view.isOpaque = false
        WKContentRuleListStore.default().compileContentRuleList(forIdentifier: "bulava.report.offline",
                                                                encodedContentRuleList: Self.rules) { list, error in
            DispatchQueue.main.async {
                // Never shown without its fence: if the rules did not compile, the page is not loaded.
                guard let list, error == nil else {
                    self.log.error("report rules did not compile: \(error?.localizedDescription ?? "", privacy: .public)")
                    return
                }
                view.configuration.userContentController.add(list)
                view.loadHTMLString(html, baseURL: nil)
            }
        }
        return view
    }
}

/// A report's web view, holding on to its own fence (a web view's delegates are weak).
final class ReportWebView: WKWebView {
    var fence: ReportNavigation?
}

/// The report never navigates on its own. Its first load (the page itself) is allowed; anything
/// after that is cancelled. An http(s) link that was activated is handed back to the app, which
/// asks the reader before opening it in Safari — a script clicking a link gets the same question.
final class ReportNavigation: NSObject, WKNavigationDelegate, WKUIDelegate {
    private let onLink: (String) -> Void

    init(onLink: @escaping (String) -> Void) {
        self.onLink = onLink
    }

    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                 decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void) {
        let url = action.request.url
        if url?.scheme == "about" || url?.scheme == "data" {
            decisionHandler(action.navigationType == .other && action.targetFrame?.isMainFrame == true ? .allow : .cancel)
            return
        }
        if action.navigationType == .linkActivated, let url, ["http", "https"].contains(url.scheme ?? "") {
            onLink(url.absoluteString)
        }
        decisionHandler(.cancel)
    }

    /// `target="_blank"` and `window.open` ask for a new view; there is none to give.
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for action: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if action.navigationType == .linkActivated, let url = action.request.url,
           ["http", "https"].contains(url.scheme ?? "") {
            onLink(url.absoluteString)
        }
        return nil
    }
}

// MARK: - A report as a PDF

extension BulavaHost {
    /// The report on paper: A4 pages laid out by WebKit's own printing, which applies the report's
    /// `@media print` styles — white paper and dark text, whatever the phone's theme — keeps the
    /// text as text, so it can be searched and copied, and breaks pages where the styles allow.
    /// Written to a temporary file named after the report and offered with the share sheet: Files,
    /// Mail, AirDrop, print. The file goes once the sheet is done with it.
    func shareReportPdf(view: UIView, title: String, done: @escaping (KotlinBoolean) -> Void) {
        DispatchQueue.main.async {
            guard let web = view as? WKWebView else { done(false); return }
            // The report's pictures load lazily, and printing does not wait for the ones that were
            // never on screen: they would come out as empty frames. They are all inline already, so
            // loading them is only decoding; it is done now, for the paper, and not before.
            web.callAsyncJavaScript(Self.everyPicture, arguments: [:], in: nil, in: .defaultClient) { _ in
                self.renderPdf(web, title: title, done: done)
            }
        }
    }

    private static let everyPicture = """
    const pictures = Array.from(document.images);
    for (const p of pictures) p.loading = 'eager';
    await Promise.all(pictures.map(p => p.decode().catch(() => null)));
    return pictures.length;
    """

    private func renderPdf(_ web: WKWebView, title: String, done: @escaping (KotlinBoolean) -> Void) {
        guard let presenter = Self.top() else { done(false); return }
        let renderer = PaperRenderer()
        renderer.addPrintFormatter(web.viewPrintFormatter(), startingAtPageAt: 0)
        let data = NSMutableData()
        UIGraphicsBeginPDFContextToData(data, PaperRenderer.a4, [kCGPDFContextTitle as String: title,
                                                                  kCGPDFContextCreator as String: "Bulava"])
        let pages = renderer.numberOfPages
        renderer.prepare(forDrawingPages: NSRange(location: 0, length: pages))
        for page in 0..<pages {
            UIGraphicsBeginPDFPage()
            renderer.drawPage(at: page, in: UIGraphicsGetPDFContextBounds())
        }
        UIGraphicsEndPDFContext()
        guard pages > 0, data.length > 0 else { done(false); return }

        let name = Self.fileName(title)
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("report-\(UUID().uuidString)")
        let url = folder.appendingPathComponent(name + ".pdf")
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
        } catch {
            self.log.error("report PDF not written: \(error.localizedDescription, privacy: .public)")
            done(false)
            return
        }
        let sheet = UIActivityViewController(activityItems: [url], applicationActivities: nil)
        sheet.completionWithItemsHandler = { _, _, _, _ in try? FileManager.default.removeItem(at: folder) }
        // On an iPad the sheet is a popover and needs somewhere to point.
        sheet.popoverPresentationController?.sourceView = presenter.view
        sheet.popoverPresentationController?.sourceRect = CGRect(x: presenter.view.bounds.maxX - 44, y: 44, width: 1, height: 1)
        presenter.present(sheet, animated: true)
        done(true)
    }

    /// The report's title as a file name: no slashes or colons, not empty, not endless.
    static func fileName(_ title: String) -> String {
        let cleaned = title.components(separatedBy: CharacterSet(charactersIn: "/\\:?%*|\"<>\n"))
            .joined(separator: "-").trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? "Report" : String(cleaned.prefix(80))
    }
}

/// A4, with the margins a printed report wants. `UIPrintPageRenderer` reads its paper from these.
final class PaperRenderer: UIPrintPageRenderer {
    static let a4 = CGRect(x: 0, y: 0, width: 595.2, height: 841.8)

    override var paperRect: CGRect { Self.a4 }
    override var printableRect: CGRect { Self.a4.insetBy(dx: 36, dy: 40) }
}
