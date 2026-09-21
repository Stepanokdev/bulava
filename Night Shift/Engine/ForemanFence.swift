import Foundation

nonisolated enum ForemanFence {

    // MARK: - Reads

    private static func configFiles(home: String) -> [String] {
        [
            ".claude.json",
            ".claude/settings.json",
            ".claude/settings.local.json",
            ".claude/mcp.json",
            ".claude/policy-limits.json",
            ".claude/remote-settings.json",
            ".claude/remote-settings-consent.json",
            ".claude/stats-cache.json",
            ".claude/mcp-needs-auth-cache.json",
        ].map { home + "/" + $0 }
    }

    private static func supportDirectories(home: String) -> [String] {
        [
            ".nvm", ".local",
            "Library/Caches", "Library/Preferences",
            "Library/Keychains",
        ].map { home + "/" + $0 }
    }

    private static func denyRoots(home: String) -> [String] {
        [
            "/Users",
            home,
            "/Volumes", "/Network", "/mnt", "/media",
            "/tmp", "/private/tmp",
            "/var/folders", "/private/var/folders",
        ]
    }

    static func runtimeParents() -> [String] {
        let uid = getuid()
        return ["/private/tmp/claude-\(uid)", "/tmp/claude-\(uid)"]
    }

    static func runtimeDirectories(forRoot root: String) -> [String] {
        let uid = getuid()
        var names = [WorkerActivity.transcriptDirName(for: realPath(root))]
        let asGiven = WorkerActivity.transcriptDirName(for: root)
        if asGiven != names[0] { names.append(asGiven) }
        return names.flatMap { ["/private/tmp/claude-\(uid)/" + $0, "/tmp/claude-\(uid)/" + $0] }
    }

    // MARK: - Writes

    private static func writable(home: String, sessionDirectory: String?,
                                 runtime: [String] = []) -> [String] {
        var out = [
            home + "/.claude/sessions", home + "/.claude/debug", home + "/.claude/cache",
            home + "/.claude/session-env", home + "/.claude/paste-cache",
            home + "/Library/Caches",
            "/private/var/folders", "/var/folders",
            "/dev",
        ]
        if let sessionDirectory { out.append(sessionDirectory) }
        return out + runtime
    }

    // MARK: - Profile

    static func profile(root: String, home: String = NSHomeDirectory()) -> String {

        let canonical = realPath(root)
        let sessionDirectory = sessionDirectory(forRoot: canonical, home: home)
        let runtime = runtimeDirectories(forRoot: root)

        var lines = [
            "(version 1)",
            "(allow default)",
            "",
            ";; Reads: nothing of his own except this product.",
            "(deny file-read-data " + denyRoots(home: home).map(subpath).joined(separator: " ") + ")",
            "(allow file-read-data",
            "  " + configFiles(home: home).map(literal).joined(separator: " "),
            "  " + supportDirectories(home: home).map(subpath).joined(separator: " "),
            "  " + runtime.map(subpath).joined(separator: " "),
            "  " + subpath(sessionDirectory) + ")",
            "",
            ";; The CLI opens its scratch ROOT to find its own folder in it. A LITERAL, so it can",
            ";; open and list that one directory — and not the contents of the projects inside it.",
            ";; `file-write-create` on the same literal lets it make its own folder if this app's",
            ";; guess at the name is ever wrong, without reaching into anyone else's.",
            "(allow file-read-data file-read-metadata file-write-create",
            "  " + runtimeParents().map(literal).joined(separator: " ") + ")",
            "",
            ";; The product itself, last, so it survives living inside a denied root.",
            "(allow file-read-data " + subpath(canonical) + ")",
        ]
        if canonical != root {

            lines.append("(allow file-read-data " + subpath(root) + ")")
        }
        lines += [
            "",
            ";; Writes: only the CLI's own scratch and this product's session storage. The foreman",
            ";; holds no tool that writes, and a project hook must not be able to change anything.",
            "(deny file-write*)",
            "(allow file-write*",
            "  " + writable(home: home, sessionDirectory: sessionDirectory, runtime: runtime)
                .map(subpath).joined(separator: "\n  ") + ")",
        ]
        return lines.joined(separator: "\n") + "\n"
    }

    static func sessionDirectory(forRoot root: String, home: String = NSHomeDirectory()) -> String {
        home + "/.claude/projects/" + WorkerActivity.transcriptDirName(for: root)
    }

    static func realPath(_ path: String) -> String {
        guard let resolved = realpath(path, nil) else { return path }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    private static func subpath(_ path: String) -> String { "(subpath \"\(escaped(path))\")" }

    private static func literal(_ path: String) -> String { "(literal \"\(escaped(path))\")" }

    private static func escaped(_ path: String) -> String {
        path.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }

    static func writeProfile(root: String, into directory: URL) -> URL? {
        let dir = directory.appendingPathComponent("fences", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let name = "fence-" + String(abs(root.hashValue)) + ".sb"
        let url = dir.appendingPathComponent(name)
        guard let data = profile(root: root).data(using: .utf8) else { return nil }

        try? FileManager.default.createDirectory(
            at: URL(fileURLWithPath: sessionDirectory(forRoot: realPath(root))),
            withIntermediateDirectories: true)

        for path in runtimeDirectories(forRoot: root) {
            try? FileManager.default.createDirectory(at: URL(fileURLWithPath: path),
                                                     withIntermediateDirectories: true)
        }
        do {
            try data.write(to: url, options: .atomic)
            return url
        } catch {
            return nil
        }
    }

    static var isAvailable: Bool {
        FileManager.default.isExecutableFile(atPath: "/usr/bin/sandbox-exec")
    }
}
