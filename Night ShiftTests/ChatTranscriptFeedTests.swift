import XCTest
@testable import Bulava

nonisolated final class ChatTranscriptFeedTests: XCTestCase {
    private var directory: URL!

    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("bulava-direct-feed-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func user(_ id: String, _ text: String, second: Int = 0) -> String {
        #"{"type":"user","uuid":"\#(id)","timestamp":"2026-08-20T12:00:0\#(second).000Z","message":{"role":"user","content":[{"type":"text","text":"\#(text)"}]}}"#
    }

    private func assistant(_ id: String, _ text: String, endTurn: Bool = false,
                           second: Int = 0) -> String {
        let stop = endTurn ? #", "stop_reason":"end_turn""# : ""
        return #"{"type":"assistant","timestamp":"2026-08-20T12:00:0\#(second)Z","message":{"id":"\#(id)","content":[{"type":"text","text":"\#(text)"}]\#(stop)}}"#
    }

    private var toolResult: String {
        #"{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"tool-1","is_error":false}]}}"#
    }

    @MainActor
    func testInteractiveTranscriptBecomesOneAgentEntryPerHumanTurn() async throws {
        let transcript = directory.appendingPathComponent("session.jsonl")
        let lines = [
            user("u1", "First", second: 1),
            assistant("a1", "Reading."),
            toolResult,
            assistant("a2", "Done."),
            user("u2", "And one more thing", second: 2),
            assistant("a3", "Continuing in context."),
        ]
        try (lines.joined(separator: "\n") + "\n").write(to: transcript, atomically: true, encoding: .utf8)

        let store = ConversationStore(fileURL: directory.appendingPathComponent("entries.json"),
                                      chatsURL: directory.appendingPathComponent("chats.json"))
        let productID = UUID()
        let chat = store.newChat(for: productID)
        store.appendUser("First", productID: productID, chatID: chat.id)
        let feed = ChatTranscriptFeed(chatID: chat.id, productID: productID,
                                      sessionID: "session", transcript: transcript, store: store)
        await feed.drain()

        let agent = store.entries(inChat: chat.id).filter { $0.kind == .foreman }
        XCTAssertEqual(agent.count, 2, "a tool result must not open a fake chat turn")
        XCTAssertEqual(agent[0].text, "Reading.\n\nDone.")
        XCTAssertEqual(agent[1].text, "Continuing in context.")
    }

    @MainActor
    func testRereadingTheSameSessionDoesNotDuplicateTurns() async throws {
        let transcript = directory.appendingPathComponent("session.jsonl")
        try ([user("u1", "Question", second: 1), assistant("a1", "Answer")]
            .joined(separator: "\n") + "\n").write(to: transcript, atomically: true, encoding: .utf8)
        let store = ConversationStore(fileURL: directory.appendingPathComponent("entries.json"),
                                      chatsURL: directory.appendingPathComponent("chats.json"))
        let productID = UUID(), chat = store.newChat(for: productID)

        await ChatTranscriptFeed(chatID: chat.id, productID: productID, sessionID: "session",
                                 transcript: transcript, store: store).drain()
        await ChatTranscriptFeed(chatID: chat.id, productID: productID, sessionID: "session",
                                 transcript: transcript, store: store).drain()

        XCTAssertEqual(store.entries(inChat: chat.id).filter { $0.kind == .foreman }.count, 1)
    }

    func testToolResultIsNotAUserPrompt() {
        XCTAssertNil(ChatTranscriptFeed.userPrompt(in: toolResult))
    }

    func testTranscriptBookkeepingIsNotAHumanTurn() {
        let hook = #"{"type":"user","uuid":"meta","isMeta":true,"message":{"content":"Stop hook feedback"}}"#
        let task = #"{"type":"user","uuid":"task","promptSource":"system","origin":{"kind":"task-notification"},"message":{"content":"<task-notification>done</task-notification>"}}"#
        let interrupted = #"{"type":"user","uuid":"interrupt","interruptedMessageId":"msg-1","message":{"content":[{"type":"text","text":"[Request interrupted by user]"}]}}"#
        XCTAssertNil(ChatTranscriptFeed.userPrompt(in: hook))
        XCTAssertNil(ChatTranscriptFeed.userPrompt(in: task))
        XCTAssertNil(ChatTranscriptFeed.userPrompt(in: interrupted))
    }

    @MainActor
    func testEndTurnOffersAReportOnceEvenAfterTranscriptReplay() async throws {
        let transcript = directory.appendingPathComponent("session.jsonl")
        try ([user("u1", "Question", second: 1),
              assistant("a1", "Answer", endTurn: true, second: 2)]
            .joined(separator: "\n") + "\n").write(to: transcript, atomically: true, encoding: .utf8)

        let store = ConversationStore(fileURL: directory.appendingPathComponent("entries.json"),
                                      chatsURL: directory.appendingPathComponent("chats.json"))
        let productID = UUID(), projectID = UUID(), chat = store.newChat(for: productID)
        store.appendUser("Question", productID: productID, chatID: chat.id)
        store.bindSession(ChatSessionBinding(primaryProjectID: projectID,
                                             projectPath: directory.path,
                                             claudeSessionID: "session"), to: chat.id)

        await ChatTranscriptFeed(chatID: chat.id, productID: productID, sessionID: "session",
                                 transcript: transcript, store: store).drain()
        XCTAssertEqual(store.chat(id: chat.id)?.session?.lastCompletedTurnKey, "u1")
        XCTAssertNotNil(store.chat(id: chat.id)?.session?.outcomeAt)

        store.addReport(directory.appendingPathComponent("artifacts/report/index.html").path,
                        to: chat.id)
        XCTAssertEqual(store.chat(id: chat.id)?.session?.lastReportedTurnKey, "u1")
        XCTAssertNil(store.chat(id: chat.id)?.session?.outcomeAt)

        await ChatTranscriptFeed(chatID: chat.id, productID: productID, sessionID: "session",
                                 transcript: transcript, store: store).drain()
        XCTAssertNil(store.chat(id: chat.id)?.session?.outcomeAt)
    }
}

// MARK: - One card per stretch of work

nonisolated final class ChatTranscriptSegmentTests: XCTestCase {
    private var directory: URL!

    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("bulava-segments-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func stamp(_ time: String) -> String { "2026-08-20T\(time)Z" }

    private func date(_ time: String) -> Date {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: stamp(time))!
    }

    private func prompt(_ id: String, _ text: String, at time: String) -> String {
        #"{"type":"user","uuid":"\#(id)","promptSource":"typed","origin":{"kind":"human"},"timestamp":"\#(stamp(time))","message":{"role":"user","content":[{"type":"text","text":"\#(text)"}]}}"#
    }

    private func says(_ id: String, _ text: String, at time: String, endTurn: Bool = false) -> String {
        let stop = endTurn ? #","stop_reason":"end_turn""# : ""
        return #"{"type":"assistant","timestamp":"\#(stamp(time))","message":{"id":"\#(id)","content":[{"type":"text","text":"\#(text)"}]\#(stop)}}"#
    }

    private func asks(_ id: String, call: String, at time: String) -> String {
        #"{"type":"assistant","timestamp":"\#(stamp(time))","message":{"id":"\#(id)","content":[{"type":"tool_use","id":"\#(call)","name":"AskUserQuestion","input":{"questions":[]}}]}}"#
    }

    private func runs(_ id: String, call: String, at time: String, endTurn: Bool = false) -> String {
        let stop = endTurn ? #","stop_reason":"end_turn""# : ""
        return #"{"type":"assistant","timestamp":"\#(stamp(time))","message":{"id":"\#(id)","content":[{"type":"tool_use","id":"\#(call)","name":"Bash","input":{"command":"make test"}}]\#(stop)}}"#
    }

    private func answers(_ call: String, at time: String) -> String {
        #"{"type":"user","timestamp":"\#(stamp(time))","message":{"content":[{"type":"tool_result","tool_use_id":"\#(call)","content":"Your questions have been answered"}]}}"#
    }

    private func finished(_ call: String, at time: String) -> String {
        #"{"type":"user","timestamp":"\#(stamp(time))","message":{"content":[{"type":"tool_result","tool_use_id":"\#(call)","is_error":false,"content":"334 tests, 0 failures"}]}}"#
    }

    private func injected(_ text: String, at time: String) -> String {
        #"{"type":"user","uuid":"meta-1","isMeta":true,"timestamp":"\#(stamp(time))","message":{"content":"\#(text)"}}"#
    }

    @MainActor
    private func feed(_ lines: [String]) throws -> (ConversationStore, Chat, ChatTranscriptFeed) {
        let transcript = directory.appendingPathComponent("session.jsonl")
        try (lines.joined(separator: "\n") + "\n").write(to: transcript, atomically: true,
                                                         encoding: .utf8)
        let store = ConversationStore(fileURL: directory.appendingPathComponent("entries.json"),
                                      chatsURL: directory.appendingPathComponent("chats.json"))
        let productID = UUID()
        let chat = store.newChat(for: productID)
        store.append(ConversationEntry(productID: productID, chatID: chat.id, kind: .user,
                                       at: date("12:00:01"), text: "Зроби вкладку"))
        return (store, chat, ChatTranscriptFeed(chatID: chat.id, productID: productID,
                                                sessionID: "session", transcript: transcript,
                                                store: store))
    }

    @MainActor
    func testHisAnswerAndAnInjectedVerdictEachStartANewCard() async throws {
        let (store, chat, feed) = try feed([
            prompt("u1", "Зроби вкладку", at: "12:00:01"),
            says("a1", "Починаю.", at: "12:00:02"),
            asks("a2", call: "ask-1", at: "12:00:03"),
            answers("ask-1", at: "15:00:00"),
            says("a3", "Обсяг зрозумілий.", at: "15:00:05"),
            says("a4", "Готово.", at: "15:30:00", endTurn: true),
            injected("Stop hook feedback: VERDICT FAIL", at: "15:40:00"),
            says("a5", "Виправляю.", at: "15:41:00"),
        ])
        await feed.drain()

        let cards = store.entries(inChat: chat.id).filter { $0.kind == .foreman }
        XCTAssertEqual(cards.map(\.text),
                       ["Починаю.", "Обсяг зрозумілий.\n\nГотово.", "Виправляю."],
                       "one card must not swallow the work that answers a later message")

        XCTAssertGreaterThan(cards[1].at, date("15:00:00"))
        XCTAssertGreaterThan(cards[2].at, date("15:40:00"))
    }

    @MainActor
    func testTheFirstCardKeepsTheIdAnEarlierBuildGaveIt() async throws {
        let (store, chat, feed) = try feed([
            prompt("u1", "Зроби вкладку", at: "12:00:01"),
            says("a1", "Починаю.", at: "12:00:02"),
            says("a2", "Готово.", at: "12:05:00", endTurn: true),
            injected("Stop hook feedback: VERDICT FAIL", at: "12:10:00"),
            says("a3", "Виправляю.", at: "12:11:00"),
        ])
        await feed.drain()

        let cards = store.entries(inChat: chat.id).filter { $0.kind == .foreman }
        XCTAssertEqual(cards.count, 2)
        XCTAssertEqual(cards[0].id, ChatTranscriptFeed.entryID(chatID: chat.id,
                                                               sessionID: "session",
                                                               turnKey: "u1"),
                       "a journal written by an earlier build keeps its entry, not a second copy")
    }

    @MainActor
    func testAToolResultAfterTheReplyEndedDoesNotOpenACardOfItsOwn() async throws {
        let (store, chat, feed) = try feed([
            prompt("u1", "Зроби вкладку", at: "12:00:01"),
            says("a1", "Перевіряю тести.", at: "12:00:02"),
            runs("a2", call: "tool-1", at: "12:00:03", endTurn: true),
            finished("tool-1", at: "12:04:00"),
            says("a3", "Тести зелені.", at: "12:05:00"),
        ])
        await feed.drain()

        let cards = store.entries(inChat: chat.id).filter { $0.kind == .foreman }
        XCTAssertEqual(cards.count, 2)
        XCTAssertEqual(cards[0].blocks.filter { $0.kind == .activity }.count, 1,
                       "the finished call belongs to the card that started it")
        XCTAssertEqual(cards[0].blocks.first { $0.kind == .activity }?.activity?.status, .done)
        XCTAssertEqual(cards[1].text, "Тести зелені.")
        XCTAssertTrue(cards[1].blocks.allSatisfy { $0.kind == .markdown },
                      "a fresh card must not open with a stray finished call")
    }

    private func interrupted(at time: String) -> String {
        #"{"type":"user","uuid":"int-1","interruptedMessageId":"msg-1","timestamp":"\#(stamp(time))","message":{"content":[{"type":"text","text":"[Request interrupted by user]"}]}}"#
    }

    @MainActor
    func testAScreenshotsOwnBookkeepingDoesNotCutTheCard() async throws {
        let (store, chat, feed) = try feed([
            prompt("u1", "Зроби вкладку", at: "12:00:01"),
            says("a1", "Знімаю екран.", at: "12:00:02"),
            runs("a2", call: "tool-1", at: "12:00:03"),
            finished("tool-1", at: "12:00:20"),
            injected("[Image: original 1206x2622, displayed at 920x2000.]", at: "12:00:21"),
            says("a3", "Кадр зроблено.", at: "12:00:25"),
        ])
        await feed.drain()

        let cards = store.entries(inChat: chat.id).filter { $0.kind == .foreman }
        XCTAssertEqual(cards.count, 1, "a note about an image is not an instruction")
        XCTAssertEqual(cards[0].text, "Знімаю екран.\n\nКадр зроблено.")
    }

    @MainActor
    func testStoppingTheAnswerStartsAFreshCard() async throws {
        let (store, chat, feed) = try feed([
            prompt("u1", "Зроби вкладку", at: "12:00:01"),
            says("a1", "Починаю.", at: "12:00:02"),
            interrupted(at: "12:00:30"),
            says("a2", "Зупинився.", at: "12:01:00"),
        ])
        await feed.drain()

        XCTAssertEqual(store.entries(inChat: chat.id).filter { $0.kind == .foreman }.map(\.text),
                       ["Починаю.", "Зупинився."])
    }

    @MainActor
    func testAReplayRetiresTheCardAnOlderSegmentationLeftBehind() async throws {
        let (store, chat, feed) = try feed([
            prompt("u1", "Зроби вкладку", at: "12:00:01"),
            says("a1", "Починаю.", at: "12:00:02"),
            asks("a2", call: "ask-1", at: "12:00:03"),
            answers("ask-1", at: "13:00:00"),
            says("a3", "Обсяг зрозумілий.", at: "13:00:05"),
            runs("a4", call: "tool-1", at: "13:00:10"),
            finished("tool-1", at: "13:00:30"),
            injected("[Image: original 1206x2622, displayed at 920x2000.]", at: "13:00:31"),
            says("a5", "Кадр зроблено.", at: "13:00:40"),
        ])

        let stale = ChatTranscriptFeed.entryID(chatID: chat.id, sessionID: "session",
                                               turnKey: "u1#2")
        store.append(ConversationEntry(id: stale, productID: chat.productID, chatID: chat.id,
                                       kind: .foreman, at: date("13:00:40"),
                                       text: "Кадр зроблено.",
                                       blocks: [.markdown(id: "msg-a5#0", "Кадр зроблено.")]))

        let verdict = ChatTranscriptFeed.entryID(chatID: chat.id, sessionID: "codex-review",
                                                 turnKey: "round-1")
        store.append(ConversationEntry(id: verdict, productID: chat.productID, chatID: chat.id,
                                       kind: .codex, at: date("13:00:45"), text: "VERDICT: FAIL"))
        store.append(ConversationEntry(productID: chat.productID, chatID: chat.id, kind: .user,
                                       at: date("13:00:50"), text: "Добре, виправляй"))

        await feed.drain()

        let cards = store.entries(inChat: chat.id).filter { $0.kind == .foreman }
        XCTAssertEqual(cards.map(\.text), ["Починаю.", "Обсяг зрозумілий.\n\nКадр зроблено."],
                       "six cards, not seven: the stale one is retired, not left beside its copy")
        XCTAssertNil(store.entry(id: stale))
        XCTAssertEqual(cards.flatMap { $0.blocks }.filter { $0.text == "Кадр зроблено." }.count, 1,
                       "nothing may be said twice across the cards")
        XCTAssertNotNil(store.entry(id: verdict), "a Codex verdict is not the feed's to retire")
        XCTAssertEqual(store.entries(inChat: chat.id).filter { $0.kind == .user }.map(\.text),
                       ["Зроби вкладку", "Добре, виправляй"])
    }

    @MainActor
    func testASegmentStillBeingWrittenIsNotRetired() async throws {
        let (store, chat, feed) = try feed([
            prompt("u1", "Зроби вкладку", at: "12:00:01"),
            says("a1", "Починаю.", at: "12:00:02", endTurn: true),
            injected("Stop hook feedback: VERDICT FAIL", at: "12:10:00"),
            says("a2", "Виправляю.", at: "12:11:00"),
        ])
        await feed.drain()
        let live = ChatTranscriptFeed.entryID(chatID: chat.id, sessionID: "session", turnKey: "u1#1")
        XCTAssertNotNil(store.entry(id: live))

        await feed.drain()
        XCTAssertNotNil(store.entry(id: live))
        XCTAssertEqual(store.entries(inChat: chat.id).filter { $0.kind == .foreman }.count, 2)
    }

    @MainActor
    func testAFinishedAndReportedChatIsNotAskedForTheSameReportAgain() async throws {
        let (store, chat, feed) = try feed([
            prompt("u1", "Зроби вкладку", at: "12:00:01"),
            says("a1", "Починаю.", at: "12:00:02"),
            says("a2", "Готово.", at: "12:05:00", endTurn: true),
            injected("Stop hook feedback: VERDICT FAIL", at: "12:10:00"),
            says("a3", "Виправив.", at: "12:11:00", endTurn: true),
        ])

        store.bindSession(ChatSessionBinding(primaryProjectID: UUID(), projectPath: directory.path,
                                             claudeSessionID: "session",
                                             lastCompletedTurnKey: "u1",
                                             lastReportedTurnKey: "u1",
                                             reportPaths: ["/x/artifacts/report/index.html"]),
                          to: chat.id)

        await feed.drain()

        let session = try XCTUnwrap(store.chat(id: chat.id)?.session)
        XCTAssertNil(session.outcomeAt, "the report for this work was already written")
        XCTAssertEqual(session.lastCompletedTurnKey, session.lastReportedTurnKey,
                       "and the app must not read a renamed key as work nobody reported")
        XCTAssertEqual(session.reportPaths.count, 1)
    }

    @MainActor
    func testWorkThatArrivesAfterTheReportIsStillOffered() async throws {
        let (store, chat, feed) = try feed([
            prompt("u1", "Зроби вкладку", at: "12:00:01"),
            says("a1", "Починаю.", at: "12:00:02"),
            says("a2", "Готово.", at: "12:05:00", endTurn: true),
        ])
        store.bindSession(ChatSessionBinding(primaryProjectID: UUID(), projectPath: directory.path,
                                             claudeSessionID: "session",
                                             lastCompletedTurnKey: "u1",
                                             lastReportedTurnKey: "u1"), to: chat.id)
        await feed.drain()
        XCTAssertNil(store.chat(id: chat.id)?.session?.outcomeAt, "nothing new yet")

        let transcript = directory.appendingPathComponent("session.jsonl")
        let more = [injected("Stop hook feedback: VERDICT FAIL", at: "12:10:00"),
                    says("a3", "Виправив.", at: "12:11:00", endTurn: true)]
        let handle = try FileHandle(forWritingTo: transcript)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data((more.joined(separator: "\n") + "\n").utf8))
        try handle.close()
        await feed.drain()

        let session = try XCTUnwrap(store.chat(id: chat.id)?.session)
        XCTAssertNotNil(session.outcomeAt, "this work is not in any report")
        XCTAssertEqual(session.lastCompletedTurnKey, "u1#1")
        XCTAssertNotEqual(session.lastCompletedTurnKey, session.lastReportedTurnKey)
    }
}
