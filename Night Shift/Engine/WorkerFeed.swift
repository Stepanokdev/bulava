import Foundation
import CryptoKit

@MainActor
final class WorkerFeed {

    static let blockCeiling = 300

    static let interval: Duration = .seconds(2)

    let taskID: UUID
    let productID: UUID
    private let transcript: URL
    private let store: ConversationStore
    private let chatID: UUID?

    private lazy var entryID: UUID = Self.entryID(taskID: taskID, transcript: transcript)
    private var state = Reading()
    private var folding = false
    private var dropped = 0
    private var pump: Task<Void, Never>?
    private var lastPersist = Date.distantPast

    init(taskID: UUID, productID: UUID, chatID: UUID?, transcript: URL, store: ConversationStore) {
        self.taskID = taskID
        self.productID = productID
        self.chatID = chatID
        self.transcript = transcript
        self.store = store
    }

    func start() {
        guard pump == nil else { return }
        pump = Task { [weak self] in
            while !Task.isCancelled {
                await self?.drain()
                try? await Task.sleep(for: WorkerFeed.interval)
            }
        }
    }

    func stop() {
        pump?.cancel()
        pump = nil

        let size = (try? FileManager.default.attributesOfItem(atPath: transcript.path)[.size]) as? UInt64 ?? 0
        if size - min(size, state.offset) < 2_000_000 {
            state = Self.fold(transcript: transcript, from: state, final: true).0
        }
        publish(persist: true)
    }

    // MARK: - Reading

    nonisolated struct Reading: Sendable {
        var offset: UInt64 = 0
        var framer = NDJSONFramer()
        var reducer = TurnReducer()
    }

    func drain() async {

        guard !folding else { return }
        folding = true
        defer { folding = false }

        let (next, changed) = await Self.foldOffTheMainActor(transcript: transcript, from: state)
        state = next
        guard changed else { return }

        let due = Date().timeIntervalSince(lastPersist) > 30
        publish(persist: due)
        if due { lastPersist = Date() }
    }

    @concurrent
    nonisolated static func foldOffTheMainActor(transcript: URL,
                                                from previous: Reading) async -> (Reading, Bool) {
        fold(transcript: transcript, from: previous)
    }

    nonisolated static func fold(transcript: URL, from previous: Reading,
                                 final isFinal: Bool = false) -> (Reading, Bool) {
        var state = previous
        var changed = false
        func take(_ lines: [String]) {
            for line in lines {
                for event in AgentEvent.decode(line: line) where !event.isTurnBoundary {
                    if state.reducer.accept(event) { changed = true }
                }
            }
        }

        func done() -> (Reading, Bool) {
            if isFinal { take(state.framer.flush()) }
            return (state, changed)
        }

        guard let handle = try? FileHandle(forReadingFrom: transcript) else { return done() }
        defer { try? handle.close() }

        let size = (try? FileManager.default.attributesOfItem(atPath: transcript.path)[.size]) as? UInt64 ?? 0
        if size < state.offset { state = Reading() }
        guard size > state.offset else { return done() }

        try? handle.seek(toOffset: state.offset)
        while let chunk = try? handle.read(upToCount: 1 << 20), !chunk.isEmpty {
            state.offset += UInt64(chunk.count)
            take(state.framer.feed(chunk))
        }
        return done()
    }

    private func publish(persist: Bool) {
        var blocks = state.reducer.renderable
        guard !blocks.isEmpty else { return }
        if blocks.count > Self.blockCeiling {
            dropped = blocks.count - Self.blockCeiling
            blocks = Array(blocks.suffix(Self.blockCeiling))
        }
        if dropped > 0 {

            blocks.insert(.markdown(id: "feed-omitted",
                                    String(format: String(localized: "%@ earlier steps are past the window"),
                                           String(dropped))),
                          at: 0)
        }

        if store.entry(id: entryID) == nil {
            var entry = ConversationEntry(id: entryID, productID: productID, kind: .foreman,
                                          taskID: taskID)
            entry.chatID = chatID
            store.append(entry)
        }
        store.updateBlocks(entryID: entryID, blocks: blocks, text: state.reducer.plainText, persist: persist)
    }
}

extension WorkerFeed {

    static func entryID(taskID: UUID, transcript: URL) -> UUID {
        let seed = "bulava.worker-feed:\(taskID.uuidString):\(transcript.lastPathComponent)"
        var bytes = Array(SHA256.hash(data: Data(seed.utf8)).prefix(16))
        bytes[6] = (bytes[6] & 0x0F) | 0x50
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6],
                           bytes[7], bytes[8], bytes[9], bytes[10], bytes[11], bytes[12],
                           bytes[13], bytes[14], bytes[15]))
    }
}

nonisolated extension AgentEvent {

    var isTurnBoundary: Bool {
        switch self {
        case .initialized, .turnFinished: true
        default: false
        }
    }
}
