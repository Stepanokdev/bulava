import CryptoKit
import Foundation
import Security

/// What the Lock Screen says by name: the Mac's `LiveSeal.Box`, key for key. Short keys, because
/// every byte of it travels inside an ActivityKit push.
struct LiveBox: Codable, Hashable {
    struct Line: Codable, Hashable {
        var title: String
        var product: String
        /// When it started, for a running line; the Lock Screen counts up from it by itself.
        var sinceMs: Int64?
        /// For an ended line: done | attention | failed | stopped.
        var outcome: String?

        enum CodingKeys: String, CodingKey {
            case title = "t", product = "p", sinceMs = "s", outcome = "o"
        }

        var since: Date? { sinceMs.map { Date(timeIntervalSince1970: TimeInterval($0) / 1000) } }
    }

    var running: [Line]
    /// How many are running in all; `running` names at most three.
    var count: Int
    var ended: [Line]
    /// The stretch of work is over: nothing has run for a while.
    var over: Bool
    /// The product and chat the first line is about, for a tap on the activity.
    var productID: String?
    var chatID: String?

    enum CodingKeys: String, CodingKey {
        case running = "r", count = "n", ended = "e", over = "x", productID = "pi", chatID = "ci"
    }

    /// Where a tap on the activity leads: the chat it is about, opened by the app.
    var link: URL? {
        guard let productID else { return nil }
        var parts = URLComponents(string: "bulava://open")
        parts?.queryItems = [URLQueryItem(name: "product", value: productID)]
            + (chatID.map { [URLQueryItem(name: "chat", value: $0)] } ?? [])
        return parts?.url
    }
}

/// Where a tap on a push leads, sealed by the Mac the same way.
struct LiveRoute: Codable {
    var productID: String?
    var chatID: String?

    enum CodingKeys: String, CodingKey { case productID = "pi", chatID = "ci" }
}

/// The key the names are sealed with, and the opening of what the Mac sealed.
///
/// Made once by the app, kept in a Keychain group the app shares with its Lock Screen widget
/// (`BulavaLiveKeychainGroup` in each Info.plist) and nothing else — the widget cannot see the
/// pairing credential, only this. Readable after the first unlock, so a locked phone's Lock Screen
/// can still open what arrives. The widget only ever reads; a missing key there means the counts,
/// never a new key.
enum LiveKey {
    private static let service = "com.stepanok.bulava.live"
    private static let account = "seal"
    static let aad = Data("bulava.live.v1".utf8)

    private static var group: String? {
        guard let raw = Bundle.main.object(forInfoDictionaryKey: "BulavaLiveKeychainGroup") as? String,
              !raw.isEmpty, !raw.contains("$(") else { return nil }
        return raw
    }

    private static func query() -> [CFString: Any] {
        var q: [CFString: Any] = [kSecClass: kSecClassGenericPassword, kSecAttrService: service,
                                  kSecAttrAccount: account]
        if let group { q[kSecAttrAccessGroup] = group }
        return q
    }

    static func read() -> Data? {
        var q = query()
        q[kSecReturnData] = true
        q[kSecMatchLimit] = kSecMatchLimitOne
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let data = out as? Data,
              data.count == 32 else { return nil }
        return data
    }

    /// The app's side: the key, made and stored the first time. Nil when it could not be stored —
    /// then the Mac is given none, and the Lock Screen shows counts.
    static func readOrCreate() -> Data? {
        if let key = read() { return key }
        var bytes = Data(count: 32)
        let made = bytes.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, 32, $0.baseAddress!) }
        guard made == errSecSuccess else { return nil }
        var add = query()
        add[kSecValueData] = bytes
        add[kSecAttrAccessible] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        guard SecItemAdd(add as CFDictionary, nil) == errSecSuccess else { return read() }
        return bytes
    }

    static func open<T: Decodable>(_ sealed: String, as type: T.Type) -> T? {
        guard let key = read(), let data = Data(base64Encoded: sealed),
              let box = try? AES.GCM.SealedBox(combined: data),
              let plain = try? AES.GCM.open(box, using: SymmetricKey(data: key), authenticating: aad) else { return nil }
        return try? JSONDecoder().decode(type, from: plain)
    }
}

extension ShiftAttributes.ContentState {
    /// What this state says by name: the app's own box, or the Mac's opened with the key. Opened
    /// once per sealed string, since the Lock Screen draws the same state many times.
    var names: LiveBox? {
        if let box { return box }
        guard let sealed else { return nil }
        return LiveNamesCache.shared.open(sealed)
    }
}

final class LiveNamesCache: @unchecked Sendable {
    static let shared = LiveNamesCache()
    private let lock = NSLock()
    private var last: (sealed: String, box: LiveBox)?

    func open(_ sealed: String) -> LiveBox? {
        lock.lock(); defer { lock.unlock() }
        if let last, last.sealed == sealed { return last.box }
        // A failure is not remembered: the key may simply not be readable yet.
        guard let box = LiveKey.open(sealed, as: LiveBox.self) else { return nil }
        last = (sealed, box)
        return box
    }
}
