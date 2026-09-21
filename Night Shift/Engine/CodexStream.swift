import Foundation

// MARK: - Events

nonisolated struct CodexUsage: Equatable, Sendable {
    var inputTokens: Int = 0
    var cachedInputTokens: Int = 0
    var outputTokens: Int = 0
    var reasoningOutputTokens: Int = 0
}

nonisolated struct CodexItem: Equatable, Sendable {
    var id: String

    var type: String
    var text: String?
    var command: String?
    var output: String?
    var exitCode: Int?

    var status: String?

    var finished: Bool

    var raw: String
}

nonisolated enum CodexEvent: Equatable, Sendable {
    case threadStarted(threadID: String)
    case turnStarted
    case item(CodexItem)
    case turnCompleted(CodexUsage)

    case failed(String)

    case ignored
}

// MARK: - Decoding

nonisolated extension CodexEvent {

    static func decode(line: String) -> [CodexEvent] {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let data = trimmed.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = root["type"] as? String else { return [.ignored] }

        switch type {
        case "thread.started":
            guard let id = root["thread_id"] as? String, !id.isEmpty else { return [.ignored] }
            return [.threadStarted(threadID: id)]

        case "turn.started":
            return [.turnStarted]

        case "item.started", "item.completed":
            guard let item = root["item"] as? [String: Any] else { return [.ignored] }
            return [.item(decodeItem(item, finished: type == "item.completed"))]

        case "turn.completed":
            let u = root["usage"] as? [String: Any] ?? [:]
            return [.turnCompleted(CodexUsage(
                inputTokens: u["input_tokens"] as? Int ?? 0,
                cachedInputTokens: u["cached_input_tokens"] as? Int ?? 0,
                outputTokens: u["output_tokens"] as? Int ?? 0,
                reasoningOutputTokens: u["reasoning_output_tokens"] as? Int ?? 0))]

        case "turn.failed", "error":

            let message = (root["message"] as? String)
                ?? ((root["error"] as? [String: Any])?["message"] as? String)
                ?? (root["error"] as? String)
                ?? trimmed
            return [.failed(message)]

        default:
            return [.ignored]
        }
    }

    private static func decodeItem(_ item: [String: Any], finished: Bool) -> CodexItem {
        let raw = (try? JSONSerialization.data(withJSONObject: item))
            .flatMap { String(data: $0, encoding: .utf8) } ?? ""
        return CodexItem(

            id: (item["id"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "item-\(UUID().uuidString)",
            type: item["type"] as? String ?? "unknown",
            text: item["text"] as? String,
            command: item["command"] as? String,
            output: item["aggregated_output"] as? String,
            exitCode: item["exit_code"] as? Int,
            status: item["status"] as? String,
            finished: finished,
            raw: raw)
    }
}

// MARK: - Reducing

nonisolated struct CodexTurnReducer {

    private(set) var blocks: [ConversationBlock] = []

    private(set) var threadID: String?
    private(set) var isFinished = false
    private(set) var usage: CodexUsage?
    private(set) var failure: String?

    init() {}

    mutating func accept(_ event: CodexEvent) -> Bool {
        switch event {
        case .threadStarted(let id):
            threadID = id
            return false

        case .turnStarted:
            return false

        case .item(let item):
            guard let block = Self.block(for: item) else { return false }
            let before = blocks
            blocks.upsert(block)
            return blocks != before

        case .turnCompleted(let u):
            usage = u
            isFinished = true
            return false

        case .failed(let message):
            failure = message
            isFinished = true
            let before = blocks
            blocks.upsert(.error(id: "codex-failure", message))
            return blocks != before

        case .ignored:
            return false
        }
    }

    static func block(for item: CodexItem) -> ConversationBlock? {
        switch item.type {
        case "agent_message":
            let text = item.text ?? ""

            return text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? nil : .markdown(id: item.id, text)

        case "command_execution":
            let command = (item.command ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let failed = (item.exitCode ?? 0) != 0 || item.status == "failed"
            let status: BlockActivity.Status = !item.finished ? .running : (failed ? .failed : .done)
            return .activity(BlockActivity(
                toolCallID: item.id,
                verbKey: "runs %@",
                object: Self.firstLine(command),
                status: status,

                detail: failed ? Self.lastMeaningfulLine(item.output) : nil))

        default:

            return ConversationBlock(id: item.id, kind: .unknown, text: item.raw)
        }
    }

    private static func firstLine(_ s: String) -> String? {
        guard let line = s.split(separator: "\n", omittingEmptySubsequences: true).first else { return nil }
        let text = String(line)
        return text.count > 120 ? String(text.prefix(119)) + "…" : text
    }

    private static func lastMeaningfulLine(_ s: String?) -> String? {
        guard let s else { return nil }
        let line = s.split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .last(where: { !$0.isEmpty })
        guard let line, !line.isEmpty else { return nil }
        return line.count > 200 ? String(line.prefix(199)) + "…" : line
    }
}
