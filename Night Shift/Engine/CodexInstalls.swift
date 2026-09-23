import Foundation

/// Which Codex the app runs, when this Mac has more than one.
///
/// A second install is the ordinary state of a developer's machine: an npm-global one under
/// Homebrew's node and another under nvm's, one kept up to date and the other forgotten. PATH picks
/// whichever directory comes first, and the service answers each CLI for its own version — GPT-6
/// Sol and Luna were offered to 0.156 and did not exist for the 0.153 that Homebrew's entry put
/// first. The model menu could not show them, and a chat told to use one would have been refused.
///
/// The answer is a directory holding one symlink, `codex`, to the newest install, put at the front
/// of the PATH every child process gets. Nothing else in that PATH moves: node, npm and every
/// other tool resolve exactly as before. The engine does the same for the processes it starts
/// itself (`codex_prefer_newest` in `supervisor-lib.sh`), by the same rule.
///
/// Only real installs are compared — the npm package's launcher, or a native binary. Anything else
/// first on PATH is somebody's deliberate choice and is left alone without being run.
nonisolated enum CodexInstalls {

    static var shimDirectory: URL { AppSupport.root.appendingPathComponent("codex-bin", isDirectory: true) }

    /// `path` with the shim in front when it changes which Codex answers; otherwise `path` as given.
    static func preferNewest(in path: String, shim: URL = shimDirectory,
                             version: (String) -> String? = reportedVersion) -> String {
        let link = shim.appendingPathComponent("codex")
        let candidates = path.split(separator: ":").map(String.init)
            .filter { !$0.isEmpty && $0 != shim.path }
            .map { ($0 as NSString).appendingPathComponent("codex") }
            .filter { FileManager.default.isExecutableFile(atPath: $0) }
        guard candidates.count >= 2, let first = candidates.first, isInstall(first) else { return path }

        let installs = candidates.filter(isInstall)
        let ranked = installs.compactMap { candidate in version(candidate).map { (candidate, $0) } }
        guard installs.count >= 2,
              let best = ranked.max(by: { isVersion($0.1, olderThan: $1.1) })?.0 else { return path }

        let fm = FileManager.default
        if (try? fm.destinationOfSymbolicLink(atPath: link.path)) != best {
            try? fm.createDirectory(at: shim, withIntermediateDirectories: true)
            let staging = shim.appendingPathComponent("codex.\(ProcessInfo.processInfo.processIdentifier)")
            try? fm.removeItem(at: staging)
            guard (try? fm.createSymbolicLink(atPath: staging.path, withDestinationPath: best)) != nil,
                  rename(staging.path, link.path) == 0 else { return path }
        }
        return shim.path + ":" + path
    }

    /// The npm package's launcher is a symlink into `@openai/codex`; the cask and the standalone
    /// download are native binaries.
    static func isInstall(_ candidate: String) -> Bool {
        if let target = try? FileManager.default.destinationOfSymbolicLink(atPath: candidate),
           target.contains("@openai/codex/") { return true }
        guard let handle = FileHandle(forReadingAtPath: candidate) else { return false }
        defer { try? handle.close() }
        let magic = [UInt8](handle.readData(ofLength: 4))
        let machO: Set<[UInt8]> = [[0xcf, 0xfa, 0xed, 0xfe], [0xca, 0xfe, 0xba, 0xbe],
                                   [0xce, 0xfa, 0xed, 0xfe], [0xbe, 0xba, 0xfe, 0xca]]
        return machO.contains(magic)
    }

    /// "0.156.0" from `codex-cli 0.156.0`, or nil for an install that cannot say — one that lost its
    /// native binary prints nothing, and is not a candidate for anything.
    static func reportedVersion(_ candidate: String) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: candidate)
        process.arguments = ["--version"]
        let out = Pipe()
        process.standardOutput = out
        process.standardError = FileHandle.nullDevice
        var env = ProcessInfo.processInfo.environment
        // The npm launcher is a node script: it needs a node beside it, and the one in its own
        // directory is the one it was installed with.
        env["PATH"] = (candidate as NSString).deletingLastPathComponent + ":/usr/bin:/bin"
        process.environment = env
        let done = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in done.signal() }
        do { try process.run() } catch { return nil }
        if done.wait(timeout: .now() + 10) == .timedOut { process.terminate(); return nil }
        let text = String(decoding: (try? out.fileHandleForReading.readToEnd()) ?? Data(), as: UTF8.self)
        guard let line = text.split(separator: "\n").first, line.hasPrefix("codex-cli ") else { return nil }
        let number = line.dropFirst("codex-cli ".count).split(separator: " ").first.map(String.init) ?? ""
        return number.first?.isNumber == true ? number : nil
    }

    static func isVersion(_ have: String, olderThan want: String) -> Bool {
        ClaudeModelCatalog.isVersion(have, olderThan: want)
    }
}
