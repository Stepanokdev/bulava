import Foundation

/// Whether the Codex the app runs is the newest one there is — and how to get the newer one.
///
/// The model menu is read from the CLI itself (`CodexModelCatalog`), so Bulava never needs a
/// release for a new model: GPT-6.1 Sol was in OpenAI's catalogue the day it came out. But the
/// service answers each CLI for ITS version, and 0.156 was never told about a model 0.160 knows.
/// Somebody who never opens Codex's own terminal UI — which is where Codex nags about updates —
/// would simply never see it. So the readiness screen asks the same place the install came from
/// and, when there is something newer, offers the update as a button.
///
/// It asks the source that will do the updating, not a website: npm for an npm install (the
/// `npm` beside the launcher, so the node it was installed with), Homebrew for the cask. An
/// install it cannot place is left alone and nothing is claimed about it.
nonisolated enum CodexUpdate {

    enum Source: Equatable, Sendable {
        /// Installed with npm; `npm` is the one in the same directory as the launcher.
        case npm(npm: String)
        /// Homebrew's cask, a native binary.
        case cask(brew: String)
    }

    struct Available: Equatable, Sendable {
        var installed: String
        var latest: String
        var command: String
    }

    /// Where the install at `codexPath` came from, or nil when that cannot be said.
    static func source(of codexPath: String,
                       exists: (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) },
                       linkTarget: (String) -> String? = { try? FileManager.default.destinationOfSymbolicLink(atPath: $0) },
                       isNative: (String) -> Bool = CodexInstalls.isInstall) -> Source? {
        if let target = linkTarget(codexPath), target.contains("@openai/codex/") {
            let npm = ((codexPath as NSString).deletingLastPathComponent as NSString)
                .appendingPathComponent("npm")
            return exists(npm) ? .npm(npm: npm) : nil
        }
        guard isNative(codexPath) else { return nil }
        let brew = ["/opt/homebrew/bin/brew", "/usr/local/bin/brew"].first(where: exists)
        return brew.map { .cask(brew: $0) }
    }

    /// The command that updates it, typed into a Terminal the person watches.
    static func command(for source: Source) -> String {
        switch source {
        // With its own directory first: the launcher is a node script, and the Terminal it runs
        // in may have another node on PATH, or none (nvm is loaded per shell).
        case .npm(let npm):
            "PATH=\"\((npm as NSString).deletingLastPathComponent):$PATH\" \"\(npm)\" install -g @openai/codex@latest"
        case .cask(let brew): "\(brew) upgrade --cask codex"
        }
    }

    /// `npm view @openai/codex version` prints the version and nothing else.
    static func parseNPM(_ output: String) -> String? {
        let line = output.split(whereSeparator: \.isNewline).last.map(String.init)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return isVersionString(line) ? line : nil
    }

    /// `brew info --cask --json=v2 codex`: `casks[0].version`.
    static func parseBrew(_ json: String) -> String? {
        guard let data = json.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let casks = obj["casks"] as? [[String: Any]],
              let version = casks.first?["version"] as? String,
              isVersionString(version) else { return nil }
        return version
    }

    static func isVersionString(_ s: String) -> Bool {
        !s.isEmpty && s.count <= 32 && s.first?.isNumber == true
            && s.allSatisfy { $0.isNumber || $0 == "." || $0 == "-" || $0.isLetter }
    }

    /// Something to offer, or nil when it is current — or when either side is not known.
    static func decide(installed: String?, latest: String?, source: Source?) -> Available? {
        guard let installed, let latest, let source,
              CodexInstalls.isVersion(installed, olderThan: latest) else { return nil }
        return Available(installed: installed, latest: latest, command: command(for: source))
    }

    /// Asks npm or Homebrew what the newest Codex is. At most every six hours: it is a network
    /// call, and the readiness screen refreshes far more often than Codex ships.
    static func latest(for source: Source) async -> String? {
        let key: String
        switch source {
        case .npm(let npm): key = "npm:" + npm
        case .cask(let brew): key = "brew:" + brew
        }
        if let cached = cache.value(for: key) { return cached }
        let result: String?
        switch source {
        case .npm(let npm):
            let r = await Shell.run("PATH=\"$(dirname \"$1\"):$PATH\" \"$1\" view @openai/codex version 2>/dev/null",
                                    args: [npm], timeout: 20)
            result = (r.launched && r.exitCode == 0) ? parseNPM(r.stdout) : nil
        case .cask(let brew):
            let r = await Shell.run("\"$1\" info --cask --json=v2 codex 2>/dev/null", args: [brew], timeout: 30)
            result = (r.launched && r.exitCode == 0) ? parseBrew(r.stdout) : nil
        }
        if let result { cache.store(result, for: key) }
        return result
    }

    private static let cache = Cache()

    private final class Cache: @unchecked Sendable {
        private let lock = NSLock()
        private var entries: [String: (String, Date)] = [:]
        func value(for key: String) -> String? {
            lock.lock(); defer { lock.unlock() }
            guard let (v, at) = entries[key], Date().timeIntervalSince(at) < 6 * 3600 else { return nil }
            return v
        }
        func store(_ v: String, for key: String) {
            lock.lock(); entries[key] = (v, Date()); lock.unlock()
        }
    }
}
