import Foundation

/// Whether Claude Code has been through its first run on this Mac, and marking that it has.
///
/// A Claude Code that was installed and signed in with `claude auth login` — which is what the
/// readiness screen offers — has never been opened interactively, and the first interactive start
/// opens on a theme picker. Nothing runs past it: no SessionStart hook, so the engine never hears
/// the run-id confirmed and rolls the start back twelve seconds later. The picker sits in a tmux
/// pane nobody sees, so the person is told about hooks instead. The CLI decides by one flag in
/// `~/.claude.json`, `hasCompletedOnboarding`, read out of 2.1.281: while it is `true` the
/// onboarding step is skipped and the start goes on to the folder-trust question, which
/// `ClaudeFolderTrust` already answers.
nonisolated enum ClaudeOnboarding {

    static var configURL: URL { ClaudeFolderTrust.configURL }

    /// True when a worker started now would stop on the first-run screens.
    ///
    /// A config that exists but cannot be read as JSON is not claimed either way: the CLI repairs
    /// such files itself, and blocking a send on a guess would be worse than the wall it prevents.
    static func needsSetup(configURL: URL = configURL) -> Bool {
        guard let data = try? Data(contentsOf: configURL) else {
            // No file at all: Claude Code has never run here, and its first start is the picker.
            return !FileManager.default.fileExists(atPath: configURL.path)
        }
        return needsSetup(config: data)
    }

    static func needsSetup(config: Data) -> Bool {
        guard let root = try? JSONSerialization.jsonObject(with: config) as? [String: Any] else {
            return false
        }
        return root["hasCompletedOnboarding"] as? Bool != true
    }

    /// The same answer the picker would have recorded. The theme itself is left unset, and the
    /// CLI's default then applies — the choice is still there under `/theme`.
    @discardableResult
    static func complete(configURL: URL = configURL) -> Bool {
        var root: [String: Any] = [:]
        if let data = try? Data(contentsOf: configURL) {
            guard let parsed = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            else { return false }
            root = parsed
        }
        root["hasCompletedOnboarding"] = true

        guard let out = try? JSONSerialization.data(withJSONObject: root,
                                                    options: [.sortedKeys, .withoutEscapingSlashes])
        else { return false }
        do {
            try out.write(to: configURL, options: .atomic)
            // It holds the account's session, so it stays readable by its owner alone.
            try? FileManager.default.setAttributes([.posixPermissions: 0o600],
                                                   ofItemAtPath: configURL.path)
            return true
        } catch {
            return false
        }
    }

    /// What the engine says when the worker it started was found on the first-run screen.
    static func engineSawIt(_ output: String) -> Bool {
        output.split(whereSeparator: \.isNewline).contains { $0 == "handshake-blocked=onboarding" }
    }
}
