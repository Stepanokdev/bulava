import Foundation

/// A project that brings its own MCP servers (`.mcp.json`).
///
/// Claude Code asks which of them to enable before its session starts — and in the background
/// nobody could answer, so the start timed out and was rolled back as «the hooks did not confirm the
/// run id», with advice to reinstall them. One director met it eight times in a row, and found the
/// way out alone: open `claude` in every folder and answer. The engine now sees the question coming
/// (exit 78) and Bulava asks it here. An MCP server can run code, so nothing is enabled by default:
/// the director picks, the engine keeps the answer, and every worker gets it in its settings.
extension AppModel {

    func stopOnMcp(chatID: UUID, entryID: UUID, folder: String) async {
        let servers = await client.pendingMcpServers(projectPath: folder) ?? []
        mcpBlocked[chatID] = McpBlock(entryID: entryID, folder: folder, servers: servers)
        chatErrors[chatID] = nil
        toast = ToastMessage(text: String(localized: "This project brings MCP servers Claude has to ask about. Answer under the message."),
                             kind: .info)
    }

    /// Record the answer, then send the message that was waiting for it.
    func answerMcp(enable: Bool, entryID: UUID, in chatID: UUID) {
        guard let block = mcpBlocked[chatID], block.entryID == entryID else { return }
        mcpBlocked[chatID] = nil
        Task {
            let r = await client.decideMcp(projectPath: block.folder, enable: enable)
            guard r.launched, r.exitCode == 0 else {
                mcpBlocked[chatID] = block
                toast = ToastMessage(text: Self.firstLine(r.combined).isEmpty
                                     ? String(localized: "Could not record the answer.") : Self.firstLine(r.combined),
                                     kind: .error)
                return
            }
            retryDirectMessage(entryID: entryID)
        }
    }

    func answerMcpAndDispatch(_ ask: McpAsk, enable: Bool) {
        mcpAsk = nil
        Task {
            let r = await client.decideMcp(projectPath: ask.folder, enable: enable)
            guard r.launched, r.exitCode == 0 else {
                toast = ToastMessage(text: Self.firstLine(r.combined).isEmpty
                                     ? String(localized: "Could not record the answer.") : Self.firstLine(r.combined),
                                     kind: .error)
                return
            }
            launchFailures[ask.task.id] = nil
            dispatch(task: backlog.task(id: ask.task.id) ?? ask.task)
        }
    }

    /// The servers as a phrase for a sentence: «a, b and 3 more».
    nonisolated static func mcpServerList(_ servers: [String], limit: Int = 4) -> String {
        guard !servers.isEmpty else { return "" }
        let shown = servers.prefix(limit).joined(separator: ", ")
        return servers.count > limit
            ? shown + " " + String(format: String(localized: "and %lld more"), servers.count - limit)
            : shown
    }
}
