import Foundation
import CryptoKit
import Security

/// A phone this Mac has paired with.
nonisolated struct PairedDevice: Codable, Identifiable, Equatable, Sendable {
    var id: String
    var name: String
    var platform: String
    var appVersion: String
    /// SHA-256 of the secret the phone holds. The secret itself is never written on this Mac.
    var secretHash: String
    var pairedAt: Date
    var lastSeenAt: Date?
    /// The iPhone's APNs device token, for waking it when something needs the director and the
    /// app is not running. Android keeps its own connection and has none.
    var pushToken: String? = nil
    /// "development" or "production" — which APNs the token belongs to.
    var pushEnvironment: String? = nil
    /// An iPhone's token for starting a Live Activity with a push, and the token of the one that is
    /// running now, if any. Both go to the relay, which knows nothing else.
    var activityStartToken: String? = nil
    var activityToken: String? = nil
    /// The key the iPhone made for what its Lock Screen says by name (`LiveSeal`), base64. What is
    /// sealed with it reaches the relay only as an opaque string. Nil for a phone older than this.
    var sealKey: String? = nil
    /// Which pushes the phone has words for. A phone older than "done" is never sent one.
    var pushKinds: [String]? = nil
}

/// Which phones may talk to this Mac, and the one pairing code that is open right now.
///
/// Kept in a file only this user can read, not in the Keychain — see `LinkIdentity` for why. The
/// file holds hashes, so reading it does not let anyone impersonate a phone.
@MainActor
@Observable
final class LinkDevices {
    private(set) var devices: [PairedDevice] = []

    /// The code on screen right now, if any. One at a time: opening the pairing panel again
    /// replaces it, so a photographed code from yesterday is worth nothing.
    private(set) var pairing: PairingCode?

    nonisolated struct PairingCode: Equatable, Sendable {
        var token: String
        var expiresAt: Date
    }

    static let pairingLifetime: TimeInterval = 5 * 60

    private let url: URL

    init(url: URL) {
        self.url = url
        if let data = try? Data(contentsOf: url),
           let stored = try? JSONDecoder.iso.decode([PairedDevice].self, from: data) {
            devices = stored
        }
    }

    // MARK: Pairing codes

    /// A fresh one-time code, valid for five minutes.
    @discardableResult
    func openPairing(now: Date = Date()) -> PairingCode {
        let code = PairingCode(token: Self.randomToken(), expiresAt: now.addingTimeInterval(Self.pairingLifetime))
        pairing = code
        return code
    }

    func closePairing() { pairing = nil }

    enum PairingCheck: Equatable { case ok, expired, used }

    /// Spends the code. Exactly one phone gets through with it: the code is gone the moment it is
    /// checked, whether or not the rest of the pairing succeeds, and a second phone presenting it
    /// is told it has been used.
    func consumePairing(_ token: String, now: Date = Date()) -> PairingCheck {
        guard let open = pairing, Self.constantTimeEqual(open.token, token) else {
            return usedTokens.contains(token) ? .used : .expired
        }
        pairing = nil
        usedTokens.insert(token)
        guard open.expiresAt > now else { return .expired }
        return .ok
    }

    private var usedTokens: Set<String> = []

    // MARK: Devices

    /// Registers a phone and returns the credential it must keep. Called only after a code was
    /// spent successfully.
    func register(name: String, platform: String, appVersion: String, now: Date = Date()) -> LinkCredential {
        let secret = Self.randomToken()
        let device = PairedDevice(id: UUID().uuidString, name: Self.clean(name, fallback: platform),
                                  platform: platform, appVersion: appVersion,
                                  secretHash: Self.hash(secret), pairedAt: now, lastSeenAt: now)
        devices.append(device)
        save()
        return LinkCredential(deviceID: device.id, secret: secret)
    }

    func authenticate(_ credential: LinkCredential) -> PairedDevice? {
        guard let device = devices.first(where: { $0.id == credential.deviceID }) else { return nil }
        return Self.constantTimeEqual(device.secretHash, Self.hash(credential.secret)) ? device : nil
    }

    func touch(_ id: String, name: String, appVersion: String, now: Date = Date()) {
        guard let i = devices.firstIndex(where: { $0.id == id }) else { return }
        devices[i].lastSeenAt = now
        devices[i].name = Self.clean(name, fallback: devices[i].name)
        devices[i].appVersion = appVersion
        save()
    }

    func setPushToken(_ token: String?, environment: String?, for id: String) {
        guard let i = devices.firstIndex(where: { $0.id == id }) else { return }
        guard devices[i].pushToken != token || devices[i].pushEnvironment != environment else { return }
        devices[i].pushToken = token
        devices[i].pushEnvironment = environment
        save()
    }

    /// What a phone said it can take, with its token: its sealing key and the pushes it has words
    /// for. Left as they are when a phone does not say (an older build).
    func setPushAbilities(sealKey: String?, kinds: [String]?, for id: String) {
        guard let i = devices.firstIndex(where: { $0.id == id }) else { return }
        guard devices[i].sealKey != sealKey || devices[i].pushKinds != kinds else { return }
        devices[i].sealKey = sealKey
        devices[i].pushKinds = kinds
        save()
    }

    func setActivityToken(_ token: String?, start: Bool, for id: String) {
        guard let i = devices.firstIndex(where: { $0.id == id }) else { return }
        if start {
            guard devices[i].activityStartToken != token else { return }
            devices[i].activityStartToken = token
        } else {
            guard devices[i].activityToken != token else { return }
            devices[i].activityToken = token
        }
        save()
    }

    /// A token the relay was told is gone — the activity ended, or the app was removed.
    func forgetActivityToken(_ token: String) {
        var changed = false
        for i in devices.indices {
            if devices[i].activityToken == token { devices[i].activityToken = nil; changed = true }
            if devices[i].activityStartToken == token { devices[i].activityStartToken = nil; changed = true }
        }
        if changed { save() }
    }

    func forgetPushToken(_ token: String) {
        var changed = false
        for i in devices.indices where devices[i].pushToken == token {
            devices[i].pushToken = nil
            changed = true
        }
        if changed { save() }
    }

    func revoke(_ id: String) {
        devices.removeAll { $0.id == id }
        save()
    }

    private func save() {
        guard let data = try? JSONEncoder.iso.encode(devices) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        // Written whole and then narrowed: `.atomic` replaces the file, so the permission has to be
        // set on what is there afterwards, not on what was.
        try? data.write(to: url, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    // MARK: Helpers

    nonisolated static func randomToken() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return LinkIdentity.base64url(Data(bytes))
    }

    nonisolated static func hash(_ secret: String) -> String {
        LinkIdentity.base64url(Data(SHA256.hash(data: Data(secret.utf8))))
    }

    nonisolated static func constantTimeEqual(_ a: String, _ b: String) -> Bool {
        let x = Array(a.utf8), y = Array(b.utf8)
        guard x.count == y.count else { return false }
        var diff: UInt8 = 0
        for i in x.indices { diff |= x[i] ^ y[i] }
        return diff == 0
    }

    private nonisolated static func clean(_ name: String, fallback: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? fallback : String(trimmed.prefix(60))
    }
}
