import Foundation

/// Jev — TypeSafe's fast classifier — as the engine has it set up: on or off, whether a key is
/// stored, how a test call went.
///
/// Everything goes through the engine's own `jev.sh`. The key is handed to that one process on its
/// stdin, never in its arguments or its environment, and it stores the key in the Keychain itself — through the
/// `security` tool, which is what lets the engine read it back later without a dialog nobody is
/// there to click at night.
nonisolated struct JevStatus: Decodable, Equatable, Sendable {
    var mode: String
    var key: Bool
    var model: String
    var decisions: Int

    /// Asked, whether or not its answer decides: "shadow" is on, only quieter.
    var isOn: Bool { mode == "on" || mode == "shadow" }
}

nonisolated struct JevTestResult: Decodable, Equatable, Sendable {
    var ok: Bool
    var model: String?
    var seconds: Double?
    var inputTokens: Int?
    var verdict: String?
    var error: String?

    enum CodingKeys: String, CodingKey {
        case ok, model, seconds, verdict, error
        case inputTokens = "input_tokens"
    }
}

enum JevClient {

    /// The engine's switch, when this engine has one. An engine from before Jev answers nil, and
    /// the section says so instead of offering a switch that would change nothing.
    nonisolated static var script: String? {
        guard let home = OrchestratorHome.detect() else { return nil }
        let path = home.appendingPathComponent("bin/jev.sh").path
        return FileManager.default.fileExists(atPath: path) ? path : nil
    }

    static func status(script: String? = JevClient.script) async -> JevStatus? {
        guard let script else { return nil }
        let r = await Shell.run("bash \"$1\" status --json", args: [script], timeout: 15)
        guard r.ok, let data = r.stdout.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(JevStatus.self, from: data)
    }

    @discardableResult
    static func setEnabled(_ on: Bool, script: String? = JevClient.script) async -> Bool {
        guard let script else { return false }
        let r = await Shell.run("bash \"$1\" mode \"$2\"", args: [script, on ? "on" : "off"], timeout: 15)
        return r.ok
    }

    /// After a key is stored. Jev is switched on only when he switched it on and it was waiting for
    /// this key. A key replaced leaves the mode as it was: in shadow Jev only writes down what it
    /// would have decided, and a new key must not make it start deciding.
    static func keyStored(waitingForKey: Bool, script: String? = JevClient.script) async {
        guard waitingForKey else { return }
        await setEnabled(true, script: script)
    }

    /// Stores the key; the reason it was refused otherwise.
    static func storeKey(_ key: String) async -> String? {
        guard let script else { return String(localized: "This engine has no Jev yet.") }
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return String(localized: "Paste the key first.") }
        // On stdin: in the environment it would reach every process the script starts.
        let r = await Shell.run("bash \"$1\" key set --stdin", args: [script],
                                timeout: 20, stdin: Data(trimmed.utf8))
        if r.ok { return nil }
        if r.combined.contains("does not look like an API key") {
            return String(localized: "That does not look like a TypeSafe API key.")
        }
        return String(localized: "The Keychain did not take the key.")
    }

    static func removeKey() async {
        guard let script else { return }
        await Shell.run("bash \"$1\" key remove", args: [script], timeout: 15)
    }

    static func test() async -> JevTestResult? {
        guard let script else { return nil }
        let r = await Shell.run("bash \"$1\" test --json", args: [script], timeout: 30)
        guard let data = r.stdout.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(JevTestResult.self, from: data)
    }
}
