import Foundation
import Security

/// The week the Home Screen and Lock Screen widgets draw, kept where they can read it while the
/// app is not running: the Keychain group the app already shares with its widget extension
/// (`BulavaLiveKeychainGroup`), under an account of its own. No App Group is needed for it.
///
/// The app writes it on every home that carries a newer week and removes it when the Mac is
/// forgotten; the widget only reads. Readable after the first unlock, so a locked phone's Lock
/// Screen can still draw it; before that first unlock a widget shows its placeholder.
enum WeekKey {
    private static let service = "com.stepanok.bulava.live"
    private static let account = "week"

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
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess else { return nil }
        return out as? Data
    }

    /// Keeps `json` unless what is kept is newer: a week that arrives late never replaces a newer one.
    /// Returns whether anything changed.
    @discardableResult
    static func write(_ json: Data) -> Bool {
        if let kept = read(), generated(kept) > generated(json) { return false }
        if read() == json { return false }
        let update: [CFString: Any] = [kSecValueData: json]
        var status = SecItemUpdate(query() as CFDictionary, update as CFDictionary)
        if status == errSecItemNotFound {
            var add = query()
            add[kSecValueData] = json
            add[kSecAttrAccessible] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            status = SecItemAdd(add as CFDictionary, nil)
        }
        return status == errSecSuccess
    }

    static func remove() { SecItemDelete(query() as CFDictionary) }

    private static func generated(_ json: Data) -> Int64 {
        guard let object = try? JSONSerialization.jsonObject(with: json) as? [String: Any] else { return 0 }
        return (object["generatedMs"] as? NSNumber)?.int64Value ?? 0
    }
}
