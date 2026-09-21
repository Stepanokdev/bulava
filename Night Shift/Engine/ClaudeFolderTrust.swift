import Foundation

nonisolated enum ClaudeFolderTrust {

    enum Verdict: Equatable, Sendable {

        case trusted

        case willAsk

        case unknown
    }

    static var configURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude.json")
    }

    static func verdict(forProjectPath path: String, configURL: URL = configURL) -> Verdict {
        guard let data = try? Data(contentsOf: configURL) else { return .unknown }
        return verdict(forProjectPath: path, config: data)
    }

    static func verdict(forProjectPath path: String, config: Data, repoRoot: String?) -> Verdict {
        guard let root = try? JSONSerialization.jsonObject(with: config) as? [String: Any],
              let projects = root["projects"] as? [String: Any] else { return .unknown }

        let boundary = repoRoot.map { Slug.canonicalPath($0) }
        var current = URL(fileURLWithPath: Slug.canonicalPath(path))
        while true {
            if let entry = projects[current.path] as? [String: Any],
               entry["hasTrustDialogAccepted"] as? Bool == true {
                return .trusted
            }
            if current.path == boundary { return .willAsk }
            let parent = current.deletingLastPathComponent()
            if parent.path == current.path || parent.path == "/" { break }
            current = parent
        }

        return .willAsk
    }

    static func verdict(forProjectPath path: String, config: Data) -> Verdict {
        verdict(forProjectPath: path, config: config, repoRoot: repoRoot(containing: path))
    }

    static func repoRoot(containing path: String) -> String? {
        var current = URL(fileURLWithPath: Slug.canonicalPath(path))
        while true {
            if FileManager.default.fileExists(atPath: current.appendingPathComponent(".git").path) {
                return current.path
            }
            let parent = current.deletingLastPathComponent()
            if parent.path == current.path || parent.path == "/" { return nil }
            current = parent
        }
    }

    static func folderNeedingTrust(forProjectPath path: String,
                                   configURL: URL = configURL) -> String? {
        guard verdict(forProjectPath: path, configURL: configURL) == .willAsk else { return nil }
        return repoRoot(containing: path) ?? Slug.canonicalPath(path)
    }

    @discardableResult
    static func grant(forProjectPath path: String, configURL: URL = configURL) -> Bool {
        let folder = repoRoot(containing: path) ?? Slug.canonicalPath(path)
        guard let data = try? Data(contentsOf: configURL),
              var root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else { return false }

        var projects = root["projects"] as? [String: Any] ?? [:]

        var entry = projects[folder] as? [String: Any] ?? [
            "allowedTools": [], "mcpContextUris": [], "mcpServers": [String: Any](),
            "enabledMcpjsonServers": [], "disabledMcpjsonServers": [],
            "hasClaudeMdExternalIncludesApproved": false,
            "hasClaudeMdExternalIncludesWarningShown": false,
        ]
        entry["hasTrustDialogAccepted"] = true
        projects[folder] = entry
        root["projects"] = projects

        guard let out = try? JSONSerialization.data(withJSONObject: root,
                                                    options: [.sortedKeys, .withoutEscapingSlashes])
        else { return false }
        do {
            try out.write(to: configURL, options: .atomic)

            try? FileManager.default.setAttributes([.posixPermissions: 0o600],
                                                   ofItemAtPath: configURL.path)
            return true
        } catch {
            return false
        }
    }

    static func problem(forProjectPath path: String) -> String? {
        guard verdict(forProjectPath: path) == .willAsk else { return nil }
        let name = ((repoRoot(containing: path) ?? Slug.canonicalPath(path)) as NSString).lastPathComponent
        return String(format: String(localized: "Claude Code has not been trusted with “%@” yet."),
                      name)
    }
}
