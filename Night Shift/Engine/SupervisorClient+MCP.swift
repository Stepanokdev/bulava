import Foundation

nonisolated struct MCPServer: Sendable, Equatable, Identifiable {
    enum Health: String, Sendable {
        case connected, failed, needsAuth = "needs_auth", unknown
    }

    enum Scope: Sendable, Equatable {
        case account, user, project(String), unknown

        init(raw: String) {
            switch raw {
            case "account": self = .account
            case "user":    self = .user
            case let s where s.hasPrefix("project:"):
                self = .project(String(s.dropFirst("project:".count)))
            default:        self = .unknown
            }
        }
    }

    var id: String { name }
    var name: String

    var target: String
    var health: Health
    var transport: String
    var scope: Scope

    var description: String
    var uses: Int
    var lastUsed: String?

    var isRemote: Bool { transport == "http" }
}

nonisolated struct MCPInventory: Sendable, Equatable {
    var servers: [MCPServer] = []

    var counted: Bool = false
    var loaded: Bool = false

    var unused: [MCPServer] { servers.filter { $0.uses == 0 } }
    var unhealthy: [MCPServer] { servers.filter { $0.health == .failed || $0.health == .needsAuth } }

    static let empty = MCPInventory()
}

extension SupervisorClient {

    func mcpInventory(fast: Bool) async -> MCPInventory {
        guard let home = OrchestratorHome.detect()?.path else { return .empty }
        let script = "\(home)/bin/mcp.sh"
        guard FileManager.default.fileExists(atPath: script) else { return .empty }

        let flags = fast ? "--json --fast --timeout=45" : "--json --timeout=45"
        let r = await Shell.run("bash \"$1\" list \(flags) 2>/dev/null",
                                args: [script], timeout: fast ? 90 : 240)
        guard let data = r.stdout.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rows = root["servers"] as? [[String: Any]] else { return .empty }

        var out: [MCPServer] = []
        for row in rows {
            guard let name = row["name"] as? String, !name.isEmpty else { continue }
            let last = (row["last"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            out.append(MCPServer(
                name: name,
                target: (row["target"] as? String) ?? "",
                health: MCPServer.Health(rawValue: (row["status"] as? String) ?? "") ?? .unknown,
                transport: (row["transport"] as? String) ?? "stdio",
                scope: MCPServer.Scope(raw: (row["scope"] as? String) ?? ""),
                description: (row["description"] as? String) ?? "",
                uses: (row["uses"] as? NSNumber)?.intValue ?? 0,
                lastUsed: last))
        }
        return MCPInventory(servers: out,
                            counted: (root["counted"] as? Bool) ?? !fast,
                            loaded: true)
    }
}
