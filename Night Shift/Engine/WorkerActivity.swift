import Foundation

nonisolated enum WorkerActivity {

    struct Line: Sendable, Equatable {

        var key: String

        var object: String?
        var at: Date
    }

    static let freshness: TimeInterval = 8 * 60

    static func current(projectPath: String, now: Date = Date()) -> Line? {
        guard let transcript = newestTranscript(projectPath: projectPath, now: now) else { return nil }

        guard let tail = tail(of: transcript.url, bytes: 256_000) else { return nil }
        return line(fromTranscriptTail: tail, at: transcript.modified)
    }

    static func transcriptDirName(for projectPath: String) -> String {
        String(projectPath.map { ch in
            (ch.isLetter && ch.isASCII) || ch.isNumber || ch == "-" ? ch : "-"
        })
    }

    private static func newestTranscript(projectPath: String, now: Date) -> (url: URL, modified: Date)? {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/projects")
            .appendingPathComponent(transcriptDirName(for: projectPath))
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else { return nil }
        var best: (URL, Date)?
        for name in names where name.hasSuffix(".jsonl") {
            let url = dir.appendingPathComponent(name)
            guard let m = (try? FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate]) as? Date
            else { continue }
            if now.timeIntervalSince(m) > freshness { continue }
            if best == nil || m > best!.1 { best = (url, m) }
        }
        return best.map { (url: $0.0, modified: $0.1) }
    }

    private static func tail(of url: URL, bytes: Int) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let end = try? handle.seekToEnd() else { return nil }
        let start = end > UInt64(bytes) ? end - UInt64(bytes) : 0
        try? handle.seek(toOffset: start)
        guard let data = try? handle.readToEnd() else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    static func line(fromTranscriptTail tail: String, at date: Date) -> Line? {

        for raw in tail.split(separator: "\n").reversed() {
            guard let data = raw.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let message = obj["message"] as? [String: Any],
                  let content = message["content"] as? [[String: Any]] else { continue }
            for block in content.reversed() where block["type"] as? String == "tool_use" {
                guard let name = block["name"] as? String else { continue }
                let input = block["input"] as? [String: Any] ?? [:]
                if let described = describe(tool: name, input: input) {
                    return Line(key: described.key, object: described.object, at: date)
                }
            }
        }
        return nil
    }

    static func describe(tool: String, input: [String: Any]) -> (key: String, object: String?)? {

        if tool.hasPrefix("mcp__") {
            let server = tool.dropFirst(5).components(separatedBy: "__").first ?? ""
            return (mcpPhrase(server: server), mcpObject(server: server))
        }
        let file = (input["file_path"] as? String).map { ($0 as NSString).lastPathComponent }
        switch tool {
        case "Read", "NotebookRead":
            return ("reads %@", file ?? (input["notebook_path"] as? String))
        case "Edit", "Write", "NotebookEdit", "MultiEdit":
            return ("edits %@", file ?? "")
        case "Grep", "Glob":
            return ("searches the code", input["pattern"] as? String)
        case "Bash", "BashOutput":

            let cmd = (input["command"] as? String) ?? ""
            return ("runs %@", shorten(command: cmd))
        case "Task", "Agent":
            return ("started a sub-agent", input["description"] as? String)
        case "Skill":
            return ("applies %@", input["skill"] as? String)
        case "WebFetch", "WebSearch":
            return ("reads documentation", nil)
        case "TodoWrite", "ExitPlanMode":
            return ("plans the next step", nil)
        default:
            return ("working", nil)
        }
    }

    private static func mcpPhrase(server: String) -> String {
        switch true {
        case server.contains("appium"):                                  "drives the app on a device"
        case server.contains("chrome") || server.contains("playwright"): "drives the browser"
        case server.contains("imagegen") || server.contains("image"):    "generates an image"
        case server.contains("deploy") || server.contains("ftp"):        "deploys"
        default:                                                         "works with %@"
        }
    }

    private static func mcpObject(server: String) -> String? {
        mcpPhrase(server: server) == "works with %@" ? server : nil
    }

    static func shorten(command: String) -> String {
        var text = command.replacingOccurrences(of: "\n", with: " ")

        if let range = text.range(of: "&&"), text.hasPrefix("cd ") {
            text = String(text[range.upperBound...])
        }
        text = text.trimmingCharacters(in: .whitespaces)
        while text.contains("  ") { text = text.replacingOccurrences(of: "  ", with: " ") }
        return text.count > 60 ? String(text.prefix(60)) + "…" : text
    }
}
