import Foundation

nonisolated struct WorkerEnvironment: Codable, Sendable, Equatable {

    nonisolated struct Server: Codable, Sendable, Equatable {
        var name: String

        var status: String

        var usable: Bool { status == "connected" }
    }

    var servers: [Server] = []

    var tools: [String] = []
    var checkedAt: Date?

    var usableServers: [String] { servers.filter(\.usable).map(\.name).sorted() }
    var unusableServers: [Server] { servers.filter { !$0.usable } }
    var isEmpty: Bool { servers.isEmpty && tools.isEmpty }

    var brief: String {
        guard !isEmpty else { return "" }
        var lines: [String] = ["<worker-environment source=\"recorded by bulava; this is what the NIGHT RUN can reach, not what you can reach right now\">"]
        if !usableServers.isEmpty {
            lines.append("MCP servers available to the run: " + usableServers.joined(separator: ", "))
        }
        let broken = unusableServers
        if !broken.isEmpty {
            lines.append("Configured but not usable: "
                         + broken.map { "\($0.name) (\($0.status == "needs_auth" ? "needs sign-in" : "failing"))" }
                             .joined(separator: ", "))
        }
        if !tools.isEmpty { lines.append("Command-line tools on PATH: " + tools.joined(separator: ", ")) }
        lines.append("</worker-environment>")
        return lines.joined(separator: "\n")
    }

    // MARK: - Probing

    static let interestingTools = ["git", "gh", "docker", "xcodebuild", "xcrun", "adb", "swift",
                                   "go", "node", "npm", "python3", "ffmpeg", "jq", "rsync", "ssh"]

    static func probe(shell: @Sendable (String, [String], TimeInterval) async -> (String, Bool)) async -> WorkerEnvironment? {
        let (mcp, ok) = await shell("claude mcp list 2>&1 || true", [], 45)
        guard ok else { return nil }
        var env = WorkerEnvironment()
        env.servers = parseServers(mcp)

        let (found, _) = await shell(
            "printf '%s' \"$1\" | tr ' ' '\\n' | while read -r t; do "
            + "[ -n \"$t\" ] && command -v \"$t\" >/dev/null 2>&1 && printf '%s\\n' \"$t\"; done; true",
            [interestingTools.joined(separator: " ")], 20)
        env.tools = found.split(separator: "\n").map(String.init).filter { !$0.isEmpty }
        env.checkedAt = Date()
        return env.isEmpty ? nil : env
    }

    nonisolated static func parseServers(_ output: String) -> [Server] {
        var out: [Server] = []
        for raw in output.split(separator: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard let colon = line.firstIndex(of: ":"), colon > line.startIndex else { continue }
            let name = String(line[line.startIndex..<colon]).trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty, !name.contains("Checking") else { continue }
            let status: String
            if line.contains("✔") { status = "connected" }
            else if line.contains("!") { status = "needs_auth" }
            else if line.contains("✘") { status = "failed" }
            else { continue }
            out.append(Server(name: name, status: status))
        }
        return out
    }
}
