import Foundation
import CryptoKit
import Security

/// Proof that a decision about Codex came from the app, and not from the worker the decision is
/// about.
///
/// Everything else in this handshake is a file, and a file is something the worker can write. The
/// write gate refuses the obvious spellings and a second guard notices when the control files move
/// under a shell — but both of those are guessing, and guessing about text loses eventually: a
/// redirect the strip did not know about, a filename assembled at runtime. What cannot be guessed
/// around is a signature over the answer, made with a key the worker does not have.
///
/// The private key lives in the login keychain, created by this app, so another binary asking for
/// it raises a prompt rather than reading it. The public half is written next to the engine's own
/// state, where anything may read it and nothing can sign with it. The engine verifies with
/// `openssl`, which is on every Mac — no third-party crypto on either side of the line.
nonisolated enum DecisionSigner {

    /// Where the engine looks for the public half. One file, overwritten whenever the key changes.
    static func publicKeyURL(stateDir: URL) -> URL {
        stateDir.appendingPathComponent("decision-key.pem")
    }

    private static let account = "codex-decision-signing-key"
    private static let service = "app.bulava.decisions"

    /// Sign `request|choice` and return the signature, DER-encoded, base64 for a JSON field.
    ///
    /// Nil when the key cannot be reached — a locked keychain, a denied prompt. The caller must
    /// treat that as "cannot answer" rather than sending an unsigned answer: an answer the engine
    /// will refuse is better than a channel that accepts unsigned ones.
    static func sign(requestID: String, choice: String, runID: String, dispatchID: String) -> String? {
        sign(payload: canonical(requestID: requestID, choice: choice,
                                runID: runID, dispatchID: dispatchID))
    }

    /// Sign any sentence the engine will rebuild and check. Used for the decision about Codex and
    /// for the marker that turns the review off — both are permissions, and a permission that
    /// cannot say where it came from is not one.
    static func sign(payload: String) -> String? {
        guard let key = loadOrCreateKey() else { return nil }
        guard let signature = try? key.signature(for: Data(payload.utf8)) else { return nil }
        return signature.derRepresentation.base64EncodedString()
    }

    /// What is signed. The engine rebuilds this string from its OWN view of the run, so the two
    /// have to agree character for character.
    ///
    /// The work is inside the signature and not merely beside it. Over the question alone, a
    /// signed answer would still verify if the file were replayed against a run that had moved on
    /// — and "which piece of work" is the whole difference between a decision and a leftover.
    static func canonical(requestID: String, choice: String,
                          runID: String, dispatchID: String) -> String {
        "\(requestID)|\(choice)|\(runID)|\(dispatchID)"
    }

    /// Make sure the engine can verify us. Called at launch, cheap, and idempotent.
    @discardableResult
    static func publishPublicKey(stateDir: URL) -> Bool {
        guard let key = loadOrCreateKey() else { return false }
        let der = key.publicKey.derRepresentation
        let body = der.base64EncodedString(options: [.lineLength64Characters, .endLineWithLineFeed])
        let pem = "-----BEGIN PUBLIC KEY-----\n\(body)\n-----END PUBLIC KEY-----\n"
        let url = publicKeyURL(stateDir: stateDir)
        // Same bytes as last time is the common case, and rewriting the file would churn its
        // timestamp for nothing.
        if let existing = try? String(contentsOf: url, encoding: .utf8), existing == pem { return true }
        try? FileManager.default.createDirectory(at: stateDir, withIntermediateDirectories: true)
        return (try? pem.write(to: url, atomically: true, encoding: .utf8)) != nil
    }

    // MARK: - The key itself

    /// Under XCTest the key never touches the login keychain.
    ///
    /// The item there was created by the signed app, and the keychain answers another binary's
    /// request for it with a prompt. A test build is exactly that: ad-hoc signed, under its own
    /// identifier, a different code identity on every build — so the first test to sign a decision
    /// raised a dialog nobody unattended could answer, and the whole suite sat on
    /// `CodexDecisionTests` until the verifier's ten-minute ceiling killed it. A key made once per
    /// test process signs, publishes and verifies exactly as the stored one does; what the tests
    /// prove is the signing, and the keychain was never the thing under test.
    private static let testProcessKey: P256.Signing.PrivateKey? = {
        let env = ProcessInfo.processInfo.environment
        guard env["XCTestConfigurationFilePath"] != nil || env["XCTestSessionIdentifier"] != nil
                || env["XCTestBundlePath"] != nil else { return nil }
        return P256.Signing.PrivateKey()
    }()

    private static func loadOrCreateKey() -> P256.Signing.PrivateKey? {
        if let testProcessKey { return testProcessKey }
        if let raw = read(), let key = try? P256.Signing.PrivateKey(rawRepresentation: raw) {
            return key
        }
        let key = P256.Signing.PrivateKey()
        guard store(key.rawRepresentation) else { return nil }
        return key
    }

    private static func read() -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess else { return nil }
        return item as? Data
    }

    private static func store(_ data: Data) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
        var add = query
        add[kSecValueData as String] = data
        // This machine only, and only while it is unlocked: a signing key for a local decision has
        // no business syncing anywhere or being readable from a locked Mac.
        add[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        return SecItemAdd(add as CFDictionary, nil) == errSecSuccess
    }
}
