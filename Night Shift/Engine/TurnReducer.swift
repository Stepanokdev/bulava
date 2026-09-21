import Foundation

nonisolated struct TurnReducer {

    private(set) var blocks: [ConversationBlock] = []

    private(set) var observedTools: [String] = []
    private(set) var observedMCPServers: [String] = []
    private(set) var sessionID: String?
    private(set) var model: String?

    private(set) var isFinished = false

    private(set) var failed = false

    private var messageID = ""

    private var streamingTextCount = 0

    private var authoritativeTextCount = 0

    private var openStreamKey: String?

    private var looseCount = 0

    /// Tool calls that were a question to another agent, and what was asked. The reducer keeps
    /// the ANSWER for these and for nothing else — an ordinary command's output has no business
    /// in the conversation.
    private var consults: [String: (agent: String, ask: String)] = [:]

    init() {}

    @discardableResult
    mutating func accept(_ event: AgentEvent) -> Bool {
        switch event {

        case .initialized(let session, let tools, let mcp, let model):
            sessionID = session
            observedTools = tools
            observedMCPServers = mcp
            self.model = model
            return false

        case .messageStart(let id):
            messageID = id
            streamingTextCount = 0
            authoritativeTextCount = 0
            openStreamKey = nil
            return false

        case .textBlockStart:
            openStreamKey = proseKey(messageID, streamingTextCount)
            streamingTextCount += 1
            return false

        case .textDelta(let text):

            let key = openStreamKey ?? {
                let k = proseKey(messageID, streamingTextCount)
                streamingTextCount += 1
                openStreamKey = k
                return k
            }()
            let existing = blocks.first { $0.id == key }?.text ?? ""
            blocks.upsert(.markdown(id: key, existing + text))
            return true

        case .assistantText(let id, let text):

            if id != messageID {
                messageID = id
                streamingTextCount = 0
                authoritativeTextCount = 0
                openStreamKey = nil
            }

            let key = proseKey(id, authoritativeTextCount)
            authoritativeTextCount += 1
            blocks.upsert(.markdown(id: key, text))
            return true

        case .toolUse(let id, _, let verbKey, let object):
            blocks.upsert(.activity(BlockActivity(toolCallID: id, verbKey: verbKey,
                                                  object: object, status: .running)))
            return true

        case .consultStarted(let id, let agent, let ask):
            consults[id] = (agent, ask)
            // The step trace keeps its own row for the call; this is the card that will hold the
            // answer, and it appears immediately so the wait is visible.
            blocks.upsert(.consult(id: Self.consultKey(id), agent: agent, ask: ask,
                                   answer: "", status: .running))
            return true

        case .toolResult(let id, let isError, let detail, let output):

            var activity = blocks.first { $0.id == id }?.activity
                ?? BlockActivity(toolCallID: id, verbKey: "working")
            activity.status = isError ? .failed : .done
            activity.detail = detail
            blocks.upsert(.activity(activity))

            if let consult = consults[id] {
                // Not everything that comes back from a command with `codex` in it is Codex
                // speaking. A backgrounded call returns the harness's note; a mistyped flag
                // returns the CLI's error; both used to be shown under Codex's name as its answer.
                switch AgentAnswer.classify(output: output, isError: isError) {
                case .answered(let text):
                    blocks.upsert(.consult(id: Self.consultKey(id), agent: consult.agent,
                                           ask: consult.ask, answer: text, status: .done))
                case .failed(let why):
                    blocks.upsert(.consult(id: Self.consultKey(id), agent: consult.agent,
                                           ask: consult.ask, answer: why, status: .failed))
                case .startedInBackground:
                    // Running somewhere this stream cannot see. The card cannot promise the answer:
                    // when the turn ends, every card still marked running is swept to done, and a
                    // finished card saying "the answer arrives when it finishes" is a lie with a
                    // tick next to it.
                    blocks.upsert(.consult(
                        id: Self.consultKey(id), agent: consult.agent, ask: consult.ask,
                        answer: String(localized: "Started in the background — its answer does not come back here."),
                        status: .running))
                }
            }
            return true

        case .permissionDenied(let reason):
            looseCount += 1
            blocks.upsert(.error(id: "denied-\(looseCount)",
                                 reason ?? String(localized: "A permission was refused.")))
            return true

        case .turnFinished(let subtype, let session, let isError):
            if let session { sessionID = session }
            isFinished = true
            failed = isError
            if isError {
                looseCount += 1
                blocks.upsert(.error(id: "failed-\(looseCount)", failureText(subtype)))
            }

            for i in blocks.indices where blocks[i].activity?.status == .running {
                blocks[i].activity?.status = isError ? .failed : .done
            }
            return true

        case .ignored:
            return false
        }
    }

    var renderable: [ConversationBlock] { blocks.renderable }

    var plainText: String {
        blocks.filter { $0.kind == .markdown }
            .map(\.text)
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .joined(separator: "\n\n")
    }

    func hasExactly(tools expected: Set<String>) -> Bool {
        Set(observedTools) == expected && observedMCPServers.isEmpty
    }

    /// The consult card's own id, distinct from the tool call's activity row so both can exist.
    static func consultKey(_ toolCallID: String) -> String { "consult:" + toolCallID }

    private func proseKey(_ messageID: String, _ index: Int) -> String {
        proseKeyPrefix(messageID) + "\(index)"
    }

    private func proseKeyPrefix(_ messageID: String) -> String {
        "\(messageID.isEmpty ? "msg" : messageID)#"
    }

    private func failureText(_ subtype: String) -> String {
        switch subtype {
        case "error_max_turns":
            String(localized: "He hit the limit on steps for one answer and stopped there.")
        case "error_during_execution":
            String(localized: "The session failed part-way through.")
        default:
            String(localized: "The session ended without an answer.")
        }
    }
}
