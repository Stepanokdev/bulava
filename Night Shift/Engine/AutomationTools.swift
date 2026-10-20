import Foundation

/// The MCP servers a job may be let use with nobody there to approve a call
/// (`Automation.allowedTools`) — a task list, a tracker.
///
/// Read from Claude Code's own config: the servers he has added for every folder, and a product
/// folder's own. That is what is really on this Mac, and it is read at once — the inventory that
/// also asks each server how it is doing takes the better part of a minute. His browsers are not
/// offered: an unattended run is denied them whatever is chosen (`worker_settings_for`).
nonisolated enum AutomationTools {

    struct Server: Hashable, Identifiable, Sendable {
        /// As he named it.
        var name: String
        /// As Claude Code names its tools (`mcp__<rule>__…`), and as the engine's allow rule reads it.
        var rule: String
        var id: String { rule }
    }

    static func known(projectPaths: [String],
                      configURL: URL = ClaudeFolderTrust.configURL) -> [Server] {
        var found: [String: [String: Any]] = [:]
        if let data = try? Data(contentsOf: configURL),
           let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
            for (name, spec) in (root["mcpServers"] as? [String: Any]) ?? [:] {
                found[name] = spec as? [String: Any] ?? [:]
            }
            let projects = root["projects"] as? [String: Any] ?? [:]
            for path in projectPaths {
                let entry = (projects[path] ?? projects[Slug.canonicalPath(path)]) as? [String: Any]
                for (name, spec) in (entry?["mcpServers"] as? [String: Any]) ?? [:] {
                    found[name] = spec as? [String: Any] ?? [:]
                }
            }
        }
        for path in projectPaths {
            let file = URL(fileURLWithPath: path).appendingPathComponent(".mcp.json")
            guard let data = try? Data(contentsOf: file),
                  let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { continue }
            for (name, spec) in (root["mcpServers"] as? [String: Any]) ?? [:] {
                found[name] = spec as? [String: Any] ?? [:]
            }
        }
        return found.filter { !isBrowser(name: $0.key, spec: $0.value) }
            .map { Server(name: $0.key, rule: rule(for: $0.key)) }
            .filter { !$0.rule.isEmpty }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// The name as it stands in a tool's name: anything but a letter, a digit, `-` or `_` becomes
    /// `_` — "claude.ai Atlassian" is `claude_ai_Atlassian`.
    static func rule(for name: String) -> String {
        var out = ""
        for ch in name.trimmingCharacters(in: .whitespacesAndNewlines) {
            out.append(ch.isASCII && (ch.isLetter || ch.isNumber || ch == "-" || ch == "_") ? ch : "_")
        }
        guard let first = out.first, first.isLetter || first.isNumber else { return "" }
        return out
    }

    /// The servers a brief names in words — "add the tasks to memex" — as whole words, any case.
    static func mentioned(in brief: String, among servers: [Server]) -> [Server] {
        let words = Set(brief.lowercased()
            .split(whereSeparator: { !($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") })
            .map(String.init))
        return servers.filter { words.contains($0.name.lowercased()) || words.contains($0.rule.lowercased()) }
    }

    /// Chrome DevTools, Claude in Chrome, Playwright: they drive a real browser, and an unattended
    /// run gets its own instead.
    private static func isBrowser(name: String, spec: [String: Any]) -> Bool {
        let command = ([spec["command"] as? String ?? ""] + (spec["args"] as? [String] ?? []))
            .joined(separator: " ").lowercased()
        if ["chrome-devtools", "claude-in-chrome"].contains(name.lowercased()) { return true }
        return ["chrome-devtools-mcp", "@playwright/mcp", "playwright-mcp"].contains { command.contains($0) }
    }
}
