import Foundation

// MARK: - Framing

nonisolated struct NDJSONFramer {
    private var buffer = Data()

    private static let lineLimit = 32 * 1024 * 1024

    private static let newline = UInt8(ascii: "\n")

    mutating func feed(_ data: Data) -> [String] {
        buffer.append(data)
        guard buffer.contains(Self.newline) else {
            if buffer.count > Self.lineLimit { buffer.removeAll(keepingCapacity: false) }
            return []
        }
        var lines: [String] = []
        var start = buffer.startIndex
        while let nl = buffer[start...].firstIndex(of: Self.newline) {
            let slice = buffer[start..<nl]
            if !slice.isEmpty {

                let text = String(decoding: slice, as: UTF8.self)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if !text.isEmpty { lines.append(text) }
            }
            start = buffer.index(after: nl)
        }
        buffer = start < buffer.endIndex ? Data(buffer[start...]) : Data()
        if buffer.count > Self.lineLimit { buffer.removeAll(keepingCapacity: false) }
        return lines
    }

    mutating func flush() -> [String] {
        defer { buffer = Data() }
        let text = String(decoding: buffer, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? [] : [text]
    }
}

// MARK: - Events

nonisolated enum AgentEvent: Equatable, Sendable {

    case initialized(sessionID: String, tools: [String], mcpServers: [String], model: String?)

    case messageStart(messageID: String)

    case textBlockStart(index: Int)

    case textDelta(String)

    case assistantText(messageID: String, text: String)

    case toolUse(id: String, name: String, verbKey: String, object: String?)

    /// The worker asked another agent something. Emitted ALONGSIDE `.toolUse`, so the step trace
    /// is unchanged and the reducer additionally knows this call's answer is worth keeping.
    case consultStarted(id: String, agent: String, ask: String)

    /// `output` is the whole tool result, not just a failure line. Whether any of it is kept is
    /// the reducer's decision — it holds the ids of the consultations, and this event cannot know
    /// which call it belongs to.
    case toolResult(id: String, isError: Bool, detail: String?, output: String?)

    case permissionDenied(String?)

    case turnFinished(subtype: String, sessionID: String?, isError: Bool)

    case ignored

    static func decode(line: String) -> [AgentEvent] {
        guard let data = line.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = obj["type"] as? String else { return [] }

        switch type {
        case "system":
            switch obj["subtype"] as? String {
            case "init":
                return [.initialized(sessionID: obj["session_id"] as? String ?? "",
                                     tools: obj["tools"] as? [String] ?? [],
                                     mcpServers: mcpNames(obj["mcp_servers"]),
                                     model: obj["model"] as? String)]
            case "permission_denied":
                return [.permissionDenied(firstLine(obj["message"] ?? obj["reason"]))]
            default:
                return []
            }

        case "stream_event":
            guard let event = obj["event"] as? [String: Any],
                  let kind = event["type"] as? String else { return [] }
            switch kind {
            case "message_start":
                let id = (event["message"] as? [String: Any])?["id"] as? String
                return [.messageStart(messageID: id ?? "")]
            case "content_block_start":
                guard (event["content_block"] as? [String: Any])?["type"] as? String == "text"
                else { return [] }
                return [.textBlockStart(index: event["index"] as? Int ?? 0)]
            case "content_block_delta":
                guard let delta = event["delta"] as? [String: Any],
                      delta["type"] as? String == "text_delta",
                      let text = delta["text"] as? String else { return [] }
                return [.textDelta(text)]
            default:
                return []
            }

        case "assistant":
            guard let message = obj["message"] as? [String: Any],
                  let content = message["content"] as? [[String: Any]] else { return [] }
            let messageID = message["id"] as? String ?? ""
            var events: [AgentEvent] = []
            for block in content {
                switch block["type"] as? String {
                case "text":
                    let text = block["text"] as? String ?? ""

                    guard !text.isEmpty else { continue }
                    events.append(.assistantText(messageID: messageID, text: text))
                case "tool_use":
                    guard let id = block["id"] as? String,
                          let name = block["name"] as? String else { continue }
                    let input = block["input"] as? [String: Any] ?? [:]

                    let described = WorkerActivity.describe(tool: name, input: input)
                    events.append(.toolUse(id: id, name: name,
                                           verbKey: described?.key ?? "working",
                                           object: described?.object))
                    if let consult = AgentConsult.recognise(tool: name, input: input) {
                        events.append(.consultStarted(id: id, agent: consult.agent,
                                                      ask: consult.ask))
                    }
                default:
                    continue
                }
            }
            return events

        case "user":
            guard let message = obj["message"] as? [String: Any],
                  let content = message["content"] as? [[String: Any]] else { return [] }
            return content.compactMap { block in
                guard block["type"] as? String == "tool_result",
                      let id = block["tool_use_id"] as? String else { return nil }
                let isError = block["is_error"] as? Bool ?? false
                return .toolResult(id: id, isError: isError,
                                   detail: isError ? firstLine(block["content"]) : nil,
                                   output: wholeText(block["content"]))
            }

        case "result":
            let subtype = obj["subtype"] as? String ?? "unknown"
            return [.turnFinished(subtype: subtype,
                                  sessionID: obj["session_id"] as? String,
                                  isError: obj["is_error"] as? Bool ?? (subtype != "success"))]

        default:
            return []
        }
    }

    static let unrecognisedMCPShape = "«unrecognised»"

    private static func mcpNames(_ raw: Any?) -> [String] {

        guard let raw, !(raw is NSNull) else { return [unrecognisedMCPShape] }
        if let names = raw as? [String] { return names }
        if let objects = raw as? [[String: Any]] {

            return objects.map { $0["name"] as? String ?? unrecognisedMCPShape }
        }
        if let empty = raw as? [Any], empty.isEmpty { return [] }
        return [unrecognisedMCPShape]
    }

    /// A tool result's content, flattened. Capped, because the reducer that keeps it writes it
    /// into the conversation store.
    private static func wholeText(_ raw: Any?) -> String? {
        var text: String?
        if let s = raw as? String { text = s }
        else if let blocks = raw as? [[String: Any]] {
            let joined = blocks.compactMap { $0["text"] as? String }.joined(separator: "\n")
            text = joined.isEmpty ? nil : joined
        }
        guard let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        return text.count > AgentConsult.answerLimit
            ? String(text.prefix(AgentConsult.answerLimit)) + "\n\n…"
            : text
    }

    private static func firstLine(_ raw: Any?) -> String? {
        var text: String?
        if let s = raw as? String { text = s }
        else if let blocks = raw as? [[String: Any]] {
            text = blocks.compactMap { $0["text"] as? String }.first
        }
        guard let text else { return nil }
        let line = text.split(separator: "\n").first.map(String.init) ?? text
        let clean = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return nil }
        return clean.count > 200 ? String(clean.prefix(200)) + "…" : clean
    }
}
