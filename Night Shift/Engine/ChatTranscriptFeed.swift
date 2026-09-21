import Foundation
import CryptoKit

@MainActor
final class ChatTranscriptFeed {
    static let interval: Duration = .seconds(1)

    let chatID: UUID
    let productID: UUID
    let sessionID: String
    private let transcript: URL
    private let store: ConversationStore
    private var reading = Reading()
    private var folding = false
    private var pump: Task<Void, Never>?
    private var lastPersist = Date.distantPast

    private var legacyReportAdopted = false

    init(chatID: UUID, productID: UUID, sessionID: String, transcript: URL,
         store: ConversationStore) {
        self.chatID = chatID
        self.productID = productID
        self.sessionID = sessionID
        self.transcript = transcript
        self.store = store
    }

    func start() {
        guard pump == nil else { return }
        pump = Task { [weak self] in
            while !Task.isCancelled {
                await self?.drain()
                try? await Task.sleep(for: Self.interval)
            }
        }
    }

    func stop() {
        pump?.cancel()
        pump = nil
        publish(persist: true)
    }

    nonisolated struct Turn: Sendable {

        var promptKey: String

        var segment: Int
        var at: Date
        var finishedAt: Date? = nil
        var reducer = TurnReducer()

        var key: String { segment == 0 ? promptKey : "\(promptKey)#\(segment)" }
    }

    nonisolated struct Reading: Sendable {
        var offset: UInt64 = 0
        var framer = NDJSONFramer()
        var turns: [Turn] = []
        var current: Int?

        var pendingAsks: Set<String> = []

        var split = false
    }

    func drain() async {
        guard !folding else { return }
        folding = true
        defer { folding = false }
        let (next, changed) = await Self.foldOffMain(transcript: transcript, from: reading)
        reading = next
        guard changed else { return }
        let persist = Date().timeIntervalSince(lastPersist) > 20
        publish(persist: persist)
        if persist { lastPersist = Date() }
    }

    @concurrent
    nonisolated static func foldOffMain(transcript: URL, from reading: Reading) async -> (Reading, Bool) {
        fold(transcript: transcript, from: reading)
    }

    nonisolated static func fold(transcript: URL, from previous: Reading,
                                 final: Bool = false) -> (Reading, Bool) {
        var state = previous
        var changed = false

        func take(_ lines: [String]) {
            for line in lines {
                if let prompt = userPrompt(in: line) {

                    if let existing = state.turns.firstIndex(where: { $0.promptKey == prompt.key
                                                                     && $0.segment == 0 }) {
                        state.current = existing
                    } else {
                        state.turns.append(Turn(promptKey: prompt.key, segment: 0, at: prompt.at))
                        state.current = state.turns.indices.last
                    }
                    state.split = false
                    continue
                }
                state.pendingAsks.formUnion(askedQuestionIDs(in: line))
                let ended = transcriptTurnEnded(in: line)
                guard var index = state.current else { continue }

                let movedOn = answersQuestion(in: line, pending: &state.pendingAsks)
                    || wasInterrupted(in: line)
                    || (isInjectedInstruction(in: line) && state.turns[index].reducer.isFinished)
                let events = AgentEvent.decode(line: line).filter {
                    if case .initialized = $0 { return false }
                    return true
                }

                let opensWork = events.contains {
                    if case .toolResult = $0 { return false }
                    return true
                }
                if state.split, opensWork {
                    let previous = state.turns[index]
                    state.turns.append(Turn(promptKey: previous.promptKey,
                                            segment: previous.segment + 1,
                                            at: timestamp(in: line) ?? previous.finishedAt
                                                ?? previous.at))
                    index = state.turns.index(before: state.turns.endIndex)
                    state.current = index
                    state.split = false
                }
                for event in events {
                    if state.turns[index].reducer.accept(event) { changed = true }
                    if case .turnFinished = event {
                        state.turns[index].finishedAt = timestamp(in: line) ?? state.turns[index].at
                    }
                }

                if ended, !state.turns[index].reducer.isFinished {
                    if state.turns[index].reducer.accept(.turnFinished(subtype: "success",
                                                                       sessionID: nil,
                                                                       isError: false)) {
                        changed = true
                    }
                    state.turns[index].finishedAt = timestamp(in: line) ?? state.turns[index].at
                }
                if ended || movedOn { state.split = true }
            }
        }

        guard let handle = try? FileHandle(forReadingFrom: transcript) else { return (state, false) }
        defer { try? handle.close() }
        let size = (try? FileManager.default.attributesOfItem(atPath: transcript.path)[.size]) as? UInt64 ?? 0
        if size < state.offset { state = Reading() }
        if size > state.offset {
            try? handle.seek(toOffset: state.offset)
            while let chunk = try? handle.read(upToCount: 1 << 20), !chunk.isEmpty {
                state.offset += UInt64(chunk.count)
                take(state.framer.feed(chunk))
            }
        }
        if final { take(state.framer.flush()) }
        return (state, changed)
    }

    nonisolated static func userPrompt(in line: String) -> (key: String, at: Date)? {
        guard let data = line.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              object["type"] as? String == "user",
              let message = object["message"] as? [String: Any] else { return nil }

        if object["isMeta"] as? Bool == true || object["isSidechain"] as? Bool == true
            || object["interruptedMessageId"] != nil { return nil }
        if let source = object["promptSource"] as? String, source != "typed" { return nil }
        if let origin = object["origin"] as? [String: Any],
           let kind = origin["kind"] as? String, kind != "human" { return nil }

        let texts: [String]
        if let text = message["content"] as? String {
            texts = [text]
        } else if let blocks = message["content"] as? [[String: Any]] {
            texts = blocks.compactMap { $0["type"] as? String == "text" ? $0["text"] as? String : nil }
        } else {
            texts = []
        }
        let clean = texts.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        guard !clean.isEmpty else { return nil }
        let syntheticPrefixes = ["[Request interrupted by user", "<task-notification>",
                                 "<system-reminder>", "<local-command-stdout>",
                                 "<local-command-caveat>"]
        guard !clean.allSatisfy({ text in syntheticPrefixes.contains { text.hasPrefix($0) } })
        else { return nil }

        let rawDate = object["timestamp"] as? String
        let at = timestamp(in: object) ?? Date()
        let key = (object["uuid"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            ?? "\(rawDate ?? "unknown"):\(object["sessionId"] as? String ?? "session")"
        return (key, at)
    }

    nonisolated static func askedQuestionIDs(in line: String) -> Set<String> {
        guard let object = json(line), object["type"] as? String == "assistant",
              let message = object["message"] as? [String: Any],
              let content = message["content"] as? [[String: Any]] else { return [] }
        return Set(content.compactMap { block in
            block["type"] as? String == "tool_use" && block["name"] as? String == "AskUserQuestion"
                ? block["id"] as? String : nil
        })
    }

    nonisolated static func answersQuestion(in line: String, pending: inout Set<String>) -> Bool {
        guard !pending.isEmpty, let object = json(line), object["type"] as? String == "user",
              let message = object["message"] as? [String: Any],
              let content = message["content"] as? [[String: Any]] else { return false }
        let answered = content.compactMap { block in
            block["type"] as? String == "tool_result" ? block["tool_use_id"] as? String : nil
        }.filter(pending.contains)
        guard !answered.isEmpty else { return false }
        pending.subtract(answered)
        return true
    }

    nonisolated static func wasInterrupted(in line: String) -> Bool {
        guard let object = json(line), object["type"] as? String == "user" else { return false }
        if object["interruptedMessageId"] != nil { return true }
        guard let message = object["message"] as? [String: Any] else { return false }
        if let text = message["content"] as? String { return text.hasPrefix("[Request interrupted") }
        guard let blocks = message["content"] as? [[String: Any]] else { return false }
        return blocks.contains { block in
            block["type"] as? String == "text"
                && (block["text"] as? String)?.hasPrefix("[Request interrupted") == true
        }
    }

    nonisolated static func isInjectedInstruction(in line: String) -> Bool {
        guard let object = json(line), object["type"] as? String == "user",
              let message = object["message"] as? [String: Any] else { return false }

        if let blocks = message["content"] as? [[String: Any]],
           blocks.contains(where: { $0["type"] as? String == "tool_result" }) { return false }
        if object["isMeta"] as? Bool == true { return true }
        if object["interruptedMessageId"] != nil { return true }
        if let source = object["promptSource"] as? String, source != "typed" { return true }
        if let origin = object["origin"] as? [String: Any],
           let kind = origin["kind"] as? String, kind != "human" { return true }
        return false
    }

    private nonisolated static func json(_ line: String) -> [String: Any]? {
        guard let data = line.data(using: .utf8) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    nonisolated static func transcriptTurnEnded(in line: String) -> Bool {
        guard let data = line.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              object["type"] as? String == "assistant",
              let message = object["message"] as? [String: Any] else { return false }
        return message["stop_reason"] as? String == "end_turn"
    }

    nonisolated static func timestamp(in line: String) -> Date? {
        guard let data = line.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return timestamp(in: object)
    }

    private nonisolated static func timestamp(in object: [String: Any]) -> Date? {
        guard let raw = object["timestamp"] as? String else { return nil }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return fractional.date(from: raw) ?? plain.date(from: raw)
    }

    private func publish(persist: Bool) {
        for turn in reading.turns {
            let blocks = turn.reducer.renderable
            guard !blocks.isEmpty else { continue }
            let id = Self.entryID(chatID: chatID, sessionID: sessionID, turnKey: turn.key)
            if store.entry(id: id) == nil {
                let entry = ConversationEntry(id: id, productID: productID, chatID: chatID,
                                              kind: .foreman,
                                              at: turn.at.addingTimeInterval(0.001))
                store.append(entry)
            }
            store.updateBlocks(entryID: id, blocks: blocks,
                               text: turn.reducer.plainText, persist: persist)
        }
        retireStaleSegments()
        adoptLegacyReportKey()
        if let finished = reading.turns.last(where: { $0.reducer.isFinished }),
           let finishedAt = finished.finishedAt {
            store.completeTurn(finished.key, at: finishedAt, in: chatID)
        }
    }

    private func adoptLegacyReportKey() {
        guard !legacyReportAdopted else { return }
        legacyReportAdopted = true
        guard let session = store.chat(id: chatID)?.session,
              let reported = session.lastReportedTurnKey, !reported.contains("#"),
              let top = reading.turns.filter({ $0.promptKey == reported }).map(\.segment).max(),
              top > 0 else { return }
        store.updateSession(for: chatID) { $0.lastReportedTurnKey = "\(reported)#\(top)" }
    }

    private func retireStaleSegments() {
        var highest: [String: Int] = [:]
        for turn in reading.turns {
            highest[turn.promptKey] = max(highest[turn.promptKey] ?? 0, turn.segment)
        }
        for (promptKey, top) in highest {

            var segment = top + 1, misses = 0
            while misses < 3 {
                let id = Self.entryID(chatID: chatID, sessionID: sessionID,
                                      turnKey: "\(promptKey)#\(segment)")
                if store.entry(id: id) == nil {
                    misses += 1
                } else {
                    store.remove(entryID: id)
                    misses = 0
                }
                segment += 1
            }
        }
    }

    nonisolated static func entryID(chatID: UUID, sessionID: String, turnKey: String) -> UUID {
        let seed = "bulava.chat-feed:\(chatID.uuidString):\(sessionID):\(turnKey)"
        var bytes = Array(SHA256.hash(data: Data(seed.utf8)).prefix(16))
        bytes[6] = (bytes[6] & 0x0F) | 0x50
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6],
                           bytes[7], bytes[8], bytes[9], bytes[10], bytes[11], bytes[12],
                           bytes[13], bytes[14], bytes[15]))
    }
}
