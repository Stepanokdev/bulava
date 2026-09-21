import XCTest
@testable import Bulava

nonisolated final class ChatTitleTests: XCTestCase {

    func testATitleComesFromWhatWasActuallySaid() {
        XCTAssertEqual(Chat.title(from: "Створи нову гілку і попрацюй з адмін панеллю"),
                       "Створи нову гілку і попрацюй з адмін панеллю")

        XCTAssertEqual(Chat.title(from: "Полагодь експорт CSV. Він падає на порожньому списку."),
                       "Полагодь експорт CSV")

        let long = Chat.title(from: String(repeating: "довге слово ", count: 20))
        XCTAssertLessThanOrEqual(long.count, 53)
        XCTAssertTrue(long.hasSuffix("…"))
        XCTAssertFalse(long.contains("  "))
    }

    func testAnEmptyMessageStillGetsAName() {
        XCTAssertFalse(Chat.title(from: "   \n ").isEmpty)
    }

    func testSessionBindingSurvivesEncodingAndOlderChatsStillDecode() throws {
        let projectID = UUID()
        let binding = ChatSessionBinding(primaryProjectID: projectID, projectPath: "/tmp/project",
                                         claudeSessionID: "session-123", activeRunID: "run-456",
                                         lastCompletedTurnKey: "turn-9",
                                         lastReportedTurnKey: "turn-8",
                                         reportPaths: ["/tmp/project/artifacts/report/index.html"])
        let chat = Chat(productID: UUID(), title: "Durable", session: binding)
        let roundTrip = try JSONDecoder.iso.decode(Chat.self, from: JSONEncoder.iso.encode(chat))
        XCTAssertEqual(roundTrip.session?.primaryProjectID, binding.primaryProjectID)
        XCTAssertEqual(roundTrip.session?.projectPath, binding.projectPath)
        XCTAssertEqual(roundTrip.session?.claudeSessionID, binding.claudeSessionID)
        XCTAssertEqual(roundTrip.session?.activeRunID, binding.activeRunID)
        XCTAssertEqual(roundTrip.session?.lastCompletedTurnKey, binding.lastCompletedTurnKey)
        XCTAssertEqual(roundTrip.session?.lastReportedTurnKey, binding.lastReportedTurnKey)
        XCTAssertEqual(roundTrip.session?.reportPaths, binding.reportPaths)

        let old = """
        {"id":"\(UUID().uuidString)","productID":"\(UUID().uuidString)","title":"Old"}
        """
        XCTAssertNil(try JSONDecoder.iso.decode(Chat.self, from: Data(old.utf8)).session)
    }
}

nonisolated final class ConversationChatTests: XCTestCase {

    @MainActor private func store() -> (ConversationStore, [URL]) {
        let base = FileManager.default.temporaryDirectory
        let a = base.appendingPathComponent("conv-\(UUID().uuidString).json")
        let b = base.appendingPathComponent("chats-\(UUID().uuidString).json")
        return (ConversationStore(fileURL: a, chatsURL: b), [a, b])
    }

    @MainActor
    func testAMessageJoinsTheOpenChatAndNamesIt() {
        let (s, urls) = store(); defer { urls.forEach { try? FileManager.default.removeItem(at: $0) } }
        let product = UUID()
        s.appendUser("Полагодь експорт CSV", productID: product)
        let chats = s.chats(for: product)
        XCTAssertEqual(chats.count, 1)
        XCTAssertEqual(chats[0].title, "Полагодь експорт CSV")
        XCTAssertEqual(s.entries(inChat: chats[0].id).count, 1)
    }

    @MainActor
    func testANewChatIsSeparateAndDoesNotStealTheOldTitle() {
        let (s, urls) = store(); defer { urls.forEach { try? FileManager.default.removeItem(at: $0) } }
        let product = UUID()
        s.appendUser("Перша робота", productID: product)
        let first = s.currentChat(for: product)
        let second = s.newChat(for: product)
        s.appendUser("Зовсім інша робота", productID: product)

        XCTAssertNotEqual(first.id, second.id)
        XCTAssertEqual(s.entries(inChat: first.id).count, 1)
        XCTAssertEqual(s.entries(inChat: second.id).count, 1)
        XCTAssertEqual(s.chat(id: first.id)?.title, "Перша робота")
        XCTAssertEqual(s.chat(id: second.id)?.title, "Зовсім інша робота")

        XCTAssertEqual(s.chats(for: product).map(\.id), [second.id, first.id])
    }

    @MainActor
    func testAReplyInAnOlderChatDoesNotMoveItsSidebarRow() {
        let (s, urls) = store(); defer { urls.forEach { try? FileManager.default.removeItem(at: $0) } }
        let product = UUID()
        s.appendUser("Перша робота", productID: product)
        let first = s.currentChat(for: product)
        let second = s.newChat(for: product)
        s.appendUser("Друга робота", productID: product)

        s.open(first.id, for: product)
        s.appendForeman("Пізня відповідь у першому діалозі", productID: product)

        XCTAssertEqual(s.chats(for: product).map(\.id), [second.id, first.id])
    }

    @MainActor
    func testEngineWritesLandInTheChatHeIsLookingAt() {
        let (s, urls) = store(); defer { urls.forEach { try? FileManager.default.removeItem(at: $0) } }
        let product = UUID()
        s.appendUser("Стара розмова", productID: product)
        let old = s.currentChat(for: product)
        let fresh = s.newChat(for: product)
        s.appendForeman("«Meetings Recorder» зупинився і чекає на твоє рішення.", productID: product)
        XCTAssertEqual(s.entries(inChat: fresh.id).count, 1)
        XCTAssertEqual(s.entries(inChat: old.id).count, 1)
    }

    @MainActor
    func testDirectQuestionIsStableAndScopedToItsChat() {
        let (s, urls) = store(); defer { urls.forEach { try? FileManager.default.removeItem(at: $0) } }
        let product = UUID()
        s.appendUser("Перша розмова", productID: product)
        let first = s.currentChat(for: product)
        let second = s.newChat(for: product)
        s.appendUser("Друга розмова", productID: product, chatID: second.id)

        let id = UUID()
        let initial = ConversationEntry(
            id: id, productID: product, chatID: first.id, kind: .question,
            text: "Обрати A чи B?", decision: DecisionRecord(
                headline: "Обрати A чи B?",
                items: [.init(question: "Який варіант?", header: "Варіант",
                              options: ["A", "B"], multiSelect: false,
                              optionDescriptions: ["A": "Оборотний", "B": "Змінює продукт"])]))
        s.syncDirectQuestion(initial, in: first.id)

        var enriched = initial
        enriched.decision?.recommendation = "Обрати A"
        s.syncDirectQuestion(enriched, in: first.id)

        XCTAssertEqual(s.entries(inChat: first.id).filter { $0.kind == .question }.count, 1)
        XCTAssertEqual(s.entry(id: id)?.decision?.recommendation, "Обрати A")
        XCTAssertFalse(s.entries(inChat: second.id).contains { $0.kind == .question })

        s.syncDirectQuestion(nil, in: first.id)
        XCTAssertNil(s.entry(id: id))
        XCTAssertEqual(s.entries(inChat: first.id).filter { $0.kind == .user }.count, 1,
                       "clearing the live card must not touch conversation history")
    }

    @MainActor
    func testArchivingHidesAChatWithoutLosingIt() {
        let (s, urls) = store(); defer { urls.forEach { try? FileManager.default.removeItem(at: $0) } }
        let product = UUID()
        s.appendUser("Робота", productID: product)
        let chat = s.currentChat(for: product)
        s.setArchived(chat.id, true)
        XCTAssertTrue(s.chats(for: product).isEmpty)
        XCTAssertEqual(s.archivedChats(for: product).map(\.id), [chat.id])
        XCTAssertEqual(s.entries(inChat: chat.id).count, 1, "archiving must not touch what was said")
    }

    @MainActor
    func testLegacyHistoryIsAdoptedRatherThanOrphaned() throws {
        let base = FileManager.default.temporaryDirectory
        let conv = base.appendingPathComponent("legacy-\(UUID().uuidString).json")
        let chatsURL = base.appendingPathComponent("legacy-chats-\(UUID().uuidString).json")
        defer { [conv, chatsURL].forEach { try? FileManager.default.removeItem(at: $0) } }

        let a = UUID(), b = UUID()
        let legacy = """
        [{"id":"\(UUID().uuidString)","productID":"\(a.uuidString)","kind":"user","at":760000000,"text":"Полагодь експорт","tone":"neutral","attachments":[]},
         {"id":"\(UUID().uuidString)","productID":"\(a.uuidString)","kind":"foreman","at":760000060,"text":"Беруся.","tone":"neutral","attachments":[]},
         {"id":"\(UUID().uuidString)","productID":"\(b.uuidString)","kind":"user","at":760000120,"text":"Інший продукт","tone":"neutral","attachments":[]}]
        """
        try Data(legacy.utf8).write(to: conv)

        let s = ConversationStore(fileURL: conv, chatsURL: chatsURL)
        XCTAssertEqual(s.entries.count, 3, "no entry may be dropped by the migration")
        XCTAssertEqual(s.chats.count, 2, "one chat per product, not one per entry")
        XCTAssertTrue(s.entries.allSatisfy { $0.chatID != nil }, "an entry with no chat has nowhere to render")
        let chatA = try XCTUnwrap(s.chats(for: a).first)
        XCTAssertEqual(chatA.title, "Полагодь експорт", "the thread is named for what he asked")
        XCTAssertEqual(s.entries(inChat: chatA.id).count, 2)

        let again = ConversationStore(fileURL: conv, chatsURL: chatsURL)
        XCTAssertEqual(again.chats.count, 2)
    }
}

// MARK: - Healing

nonisolated final class ConversationHealingTests: XCTestCase {

    @MainActor private func files() -> (URL, URL) {
        let base = FileManager.default.temporaryDirectory
        return (base.appendingPathComponent("heal-\(UUID().uuidString).json"),
                base.appendingPathComponent("heal-chats-\(UUID().uuidString).json"))
    }

    @MainActor
    func testEntriesPointingAtAVanishedChatAreAdoptedRatherThanLost() throws {
        let (conv, chatsURL) = files()
        defer { [conv, chatsURL].forEach { try? FileManager.default.removeItem(at: $0) } }
        let product = UUID(), ghost = UUID()
        let entries = """
        [{"id":"\(UUID().uuidString)","productID":"\(product.uuidString)","chatID":"\(ghost.uuidString)","kind":"user","at":760000000,"text":"Полагодь експорт","tone":"neutral","attachments":[]},
         {"id":"\(UUID().uuidString)","productID":"\(product.uuidString)","chatID":"\(ghost.uuidString)","kind":"foreman","at":760000060,"text":"Беруся.","tone":"neutral","attachments":[]}]
        """
        try Data(entries.utf8).write(to: conv)
        try Data("[]".utf8).write(to: chatsURL)

        let s = ConversationStore(fileURL: conv, chatsURL: chatsURL)
        XCTAssertEqual(s.entries.count, 2)
        let chat = try XCTUnwrap(s.chats(for: product).first)
        XCTAssertEqual(s.entries(inChat: chat.id).count, 2, "the orphaned entries found no home")
        XCTAssertEqual(chat.title, "Полагодь експорт")
    }

    @MainActor
    func testAnEmptyChatIsNotKept() {
        let (conv, chatsURL) = files()
        defer { [conv, chatsURL].forEach { try? FileManager.default.removeItem(at: $0) } }
        let product = UUID()
        do {
            let s = ConversationStore(fileURL: conv, chatsURL: chatsURL)
            s.appendUser("Справжня робота", productID: product)
            _ = s.newChat(for: product)
            _ = s.newChat(for: product)
        }
        let reopened = ConversationStore(fileURL: conv, chatsURL: chatsURL)
        XCTAssertEqual(reopened.chats(for: product).count, 1, "empty chats came back")
        XCTAssertEqual(reopened.chats(for: product).first?.title, "Справжня робота")
    }

    @MainActor
    func testAConcurrentWriterDoesNotEraseChats() {
        let (conv, chatsURL) = files()
        defer { [conv, chatsURL].forEach { try? FileManager.default.removeItem(at: $0) } }
        let product = UUID()
        let first = ConversationStore(fileURL: conv, chatsURL: chatsURL)
        first.appendUser("Перша", productID: product)

        let second = ConversationStore(fileURL: conv, chatsURL: chatsURL)
        second.appendUser("Друга", productID: product)

        let onDisk = ConversationStore(fileURL: conv, chatsURL: chatsURL)
        XCTAssertGreaterThanOrEqual(onDisk.chats(for: product).count, 1)
        XCTAssertTrue(onDisk.entries.allSatisfy { chat in
            onDisk.chats.contains { $0.id == chat.chatID }
        }, "an entry was left pointing at a chat that is not in the file")
    }
}

// MARK: - Answering a card that asks more than one thing

nonisolated final class MultiQuestionDecisionTests: XCTestCase {

    @MainActor private func store() -> (ConversationStore, [URL]) {
        let base = FileManager.default.temporaryDirectory
        let a = base.appendingPathComponent("mq-\(UUID().uuidString).json")
        let b = base.appendingPathComponent("mq-chats-\(UUID().uuidString).json")
        return (ConversationStore(fileURL: a, chatsURL: b), [a, b])
    }

    private func card(taskID: UUID, productID: UUID) -> ConversationEntry {
        let record = DecisionRecord(
            headline: "Вливати зараз чи перевірити на пристрої",
            situation: "Прогін виправив відкриття повідомлення й перевірив наживо; tg:// лишилось.",
            items: [.init(question: "Що робити з непокритим tg://?", header: nil,
                          options: ["Влити як є", "Спершу перевірити на пристрої"], multiSelect: false),
                    .init(question: "Чи лишати чесну помилку замість тихого фолбеку?", header: nil,
                          options: ["Лишити", "Повернути фолбек"], multiSelect: false)])
        return ConversationEntry(productID: productID, kind: .question,
                                 text: record.headline, taskID: taskID, decision: record)
    }

    @MainActor
    func testAnsweringOneQuestionLeavesTheOther() throws {
        let (s, urls) = store(); defer { urls.forEach { try? FileManager.default.removeItem(at: $0) } }
        let product = UUID(), task = UUID()
        s.append(card(taskID: task, productID: product))

        XCTAssertTrue(s.resolveQuestion(taskID: task, answered: 1), "the card should still be asking")
        let left = try XCTUnwrap(s.entries.last { $0.kind == .question }?.decision)
        XCTAssertEqual(left.items.count, 1)
        XCTAssertEqual(left.items[0].question, "Чи лишати чесну помилку замість тихого фолбеку?")

        XCTAssertEqual(s.entries.last { $0.kind == .question }?.text, left.items[0].question)
    }

    @MainActor
    func testAnsweringTheLastQuestionClosesTheCard() {
        let (s, urls) = store(); defer { urls.forEach { try? FileManager.default.removeItem(at: $0) } }
        let product = UUID(), task = UUID()
        s.append(card(taskID: task, productID: product))
        XCTAssertTrue(s.resolveQuestion(taskID: task, answered: 2))
        XCTAssertFalse(s.resolveQuestion(taskID: task, answered: 1), "the last answer closes it")
        XCTAssertNil(s.entries.first { $0.kind == .question })
    }

    @MainActor
    func testAFreeTextAnswerClosesTheWholeCard() {
        let (s, urls) = store(); defer { urls.forEach { try? FileManager.default.removeItem(at: $0) } }
        let product = UUID(), task = UUID()
        s.append(card(taskID: task, productID: product))
        XCTAssertFalse(s.resolveQuestion(taskID: task, answered: nil))
        XCTAssertNil(s.entries.first { $0.kind == .question })
    }

    func testTheOptionReplyCarriesItsQuestionNumber() {
        XCTAssertEqual(AppModel.answeredNumber(in: "2: влити як є"), 2)
        XCTAssertEqual(AppModel.answeredNumber(in: "1: перевірити на пристрої"), 1)
        XCTAssertNil(AppModel.answeredNumber(in: "влити як є"), "prose is not a question number")
        XCTAssertNil(AppModel.answeredNumber(in: "о 15:30 зроби деплой"), "a time is not a question number")
    }

    @MainActor
    func testEveryAnswerToACardIsGatheredForTheRun() {
        let (s, urls) = store(); defer { urls.forEach { try? FileManager.default.removeItem(at: $0) } }
        let product = UUID(), task = UUID()
        let entry = card(taskID: task, productID: product)
        s.append(entry)
        let at = s.entries.last { $0.kind == .question }!.at
        s.appendUser("1: Влити як є", productID: product, taskID: task)
        s.appendUser("2: Лишити", productID: product, taskID: task)
        XCTAssertEqual(s.answers(taskID: task, since: at), ["1: Влити як є", "2: Лишити"])
    }
}

// MARK: - One Bulava at a time

nonisolated final class SingleInstanceTests: XCTestCase {

    @MainActor
    func testAThrowawayCopyIsAllowedToRunBesideHis() {

        setenv("BULAVA_STATE_DIR", "/tmp/bulava-fixture-\(UUID().uuidString)", 1)
        defer { unsetenv("BULAVA_STATE_DIR") }
        XCTAssertFalse(SingleInstance.shouldYield())
    }

    @MainActor
    func testATestDrivenCopyIsAllowedToo() {
        setenv("BULAVA_TEST_INBOX", "/tmp/bulava-inbox-\(UUID().uuidString)", 1)
        defer { unsetenv("BULAVA_TEST_INBOX") }
        XCTAssertFalse(SingleInstance.shouldYield())
    }
}

// MARK: - The feed reads by the clock

nonisolated final class FeedIsChronologicalTests: XCTestCase {

    @MainActor private func store() -> (ConversationStore, [URL]) {
        let base = FileManager.default.temporaryDirectory
        let a = base.appendingPathComponent("conv-\(UUID().uuidString).json")
        let b = base.appendingPathComponent("chats-\(UUID().uuidString).json")
        return (ConversationStore(fileURL: a, chatsURL: b), [a, b])
    }

    @MainActor
    func testAVerdictFoundLateStillReadsWhereItHappened() {
        let (s, urls) = store(); defer { urls.forEach { try? FileManager.default.removeItem(at: $0) } }
        let product = UUID()
        let noon = Date(timeIntervalSince1970: 1_780_000_000)
        s.append(ConversationEntry(productID: product, kind: .user, at: noon,
                                   text: "Зроби вкладку"))
        let chat = s.currentChat(for: product)

        s.append(ConversationEntry(productID: product, chatID: chat.id, kind: .foreman,
                                   at: noon.addingTimeInterval(600), text: "Виправляю."))
        s.append(ConversationEntry(productID: product, chatID: chat.id, kind: .codex,
                                   at: noon.addingTimeInterval(300), text: "VERDICT: FAIL"))

        XCTAssertEqual(s.entries(inChat: chat.id).map(\.text),
                       ["Зроби вкладку", "VERDICT: FAIL", "Виправляю."])
    }

    @MainActor
    func testTwoThingsStampedTheSameMomentKeepTheOrderTheyWereWrittenIn() {
        let (s, urls) = store(); defer { urls.forEach { try? FileManager.default.removeItem(at: $0) } }
        let product = UUID()
        let at = Date(timeIntervalSince1970: 1_780_000_000)
        s.append(ConversationEntry(productID: product, kind: .user, at: at, text: "Перше"))
        let chat = s.currentChat(for: product)
        s.append(ConversationEntry(productID: product, chatID: chat.id, kind: .event,
                                   at: at, text: "Друге"))
        s.append(ConversationEntry(productID: product, chatID: chat.id, kind: .foreman,
                                   at: at, text: "Третє"))
        XCTAssertEqual(s.entries(inChat: chat.id).map(\.text), ["Перше", "Друге", "Третє"])
    }
}

// MARK: - A binding must survive one bad field

nonisolated final class BindingSurvivesBadDataTests: XCTestCase {

    private func chatJSON(session: String) -> Data {
        Data("""
        {"id":"\(UUID().uuidString)","productID":"\(UUID().uuidString)","title":"Робота",
         "createdAt":"2026-08-25T10:00:00Z","updatedAt":"2026-08-25T11:00:00Z",
         "archived":false,"pinned":false,"firstMessage":"Зроби",
         "session":\(session)}
        """.utf8)
    }

    func testASessionWithNoProjectIDStillDecodes() throws {
        let json = chatJSON(session: """
        {"projectPath":"/tmp/app","claudeSessionID":"abc-123","activeRunID":"RUN-1",
         "startedAt":"2026-08-25T10:00:00Z",
         "reportPaths":["/tmp/app/artifacts/latest/index.html"]}
        """)
        let chat = try JSONDecoder.iso.decode(Chat.self, from: json)
        let session = try XCTUnwrap(chat.session, "the whole binding must not vanish with one field")
        XCTAssertNil(session.primaryProjectID)
        XCTAssertEqual(session.claudeSessionID, "abc-123", "the resume id is the point of the binding")
        XCTAssertEqual(session.reportPaths, ["/tmp/app/artifacts/latest/index.html"])
    }

    func testAnUnreadableProjectIDCostsOnlyThatField() throws {
        let json = chatJSON(session: """
        {"primaryProjectID":"not-a-uuid","projectPath":"/tmp/app","claudeSessionID":"abc-123",
         "reportPaths":["/tmp/report.html"]}
        """)
        let session = try XCTUnwrap(try JSONDecoder.iso.decode(Chat.self, from: json).session)
        XCTAssertNil(session.primaryProjectID)
        XCTAssertEqual(session.claudeSessionID, "abc-123")
        XCTAssertEqual(session.reportPaths, ["/tmp/report.html"])
    }

    func testAGoodBindingStillRoundTrips() throws {
        let projectID = UUID()
        let binding = ChatSessionBinding(primaryProjectID: projectID, projectPath: "/tmp/app",
                                         claudeSessionID: "sid", activeRunID: "run",
                                         reportPaths: ["/tmp/r.html"])
        let chat = Chat(productID: UUID(), title: "T", session: binding)
        let back = try JSONDecoder.iso.decode(Chat.self, from: JSONEncoder.iso.encode(chat))
        XCTAssertEqual(back.session?.primaryProjectID, projectID)
        XCTAssertEqual(back.session?.reportPaths, ["/tmp/r.html"])
    }
}

// MARK: - A write must not forget a session

nonisolated final class SessionSurvivesWritesTests: XCTestCase {

    private func chat(_ id: UUID, session: ChatSessionBinding?, updatedAt: Date) -> Chat {
        Chat(id: id, productID: UUID(), title: "Робота", createdAt: Date(timeIntervalSince1970: 0),
             updatedAt: updatedAt, firstMessage: "Зроби", session: session)
    }

    private func binding(_ sid: String, report: String? = nil) -> ChatSessionBinding {
        ChatSessionBinding(primaryProjectID: UUID(), projectPath: "/tmp/app", claudeSessionID: sid,
                           reportPaths: report.map { [$0] } ?? [])
    }

    // MARK: the merge itself

    func testAMemoryCopyWithNoSessionKeepsTheStoredOne() {
        let id = UUID(), now = Date()
        let merged = ConversationStore.merge(
            memory: [chat(id, session: nil, updatedAt: now)],
            stored: [chat(id, session: binding("sid-1", report: "/tmp/r.html"),
                          updatedAt: now.addingTimeInterval(-60))])
        XCTAssertEqual(merged.count, 1)
        XCTAssertEqual(merged[0].session?.claudeSessionID, "sid-1",
                       "the newer copy wins on everything EXCEPT forgetting the binding")
        XCTAssertEqual(merged[0].session?.reportPaths, ["/tmp/r.html"])
    }

    func testAMemoryCopyWithItsOwnSessionWins() {
        let id = UUID(), now = Date()
        let merged = ConversationStore.merge(
            memory: [chat(id, session: binding("sid-new"), updatedAt: now)],
            stored: [chat(id, session: binding("sid-old"), updatedAt: now.addingTimeInterval(-60))])
        XCTAssertEqual(merged[0].session?.claudeSessionID, "sid-new")
    }

    func testPruningRemovesTheNamedChatAndKeepsTheOthersBindings() {
        let keep = UUID(), doomed = UUID(), now = Date()
        let merged = ConversationStore.merge(
            memory: [chat(keep, session: nil, updatedAt: now),
                     chat(doomed, session: nil, updatedAt: now)],
            stored: [chat(keep, session: binding("sid-keep", report: "/tmp/r.html"), updatedAt: now),
                     chat(doomed, session: nil, updatedAt: now)],
            removing: [doomed])
        XCTAssertEqual(merged.map(\.id), [keep], "the empty chat is gone")
        XCTAssertEqual(merged[0].session?.claudeSessionID, "sid-keep",
                       "and the survivor did not pay for its removal")
    }

    func testADeletionIsNotUndoneByTheUnion() {
        let doomed = UUID(), now = Date()
        let merged = ConversationStore.merge(memory: [], stored: [chat(doomed, session: nil,
                                                                      updatedAt: now)],
                                             removing: [doomed])
        XCTAssertTrue(merged.isEmpty)
    }

    // MARK: two stores, for real

    @MainActor
    func testAStoreThatLoadedFirstDoesNotEraseASessionBoundAfterIt() throws {
        let base = FileManager.default.temporaryDirectory
        let convURL = base.appendingPathComponent("conv-\(UUID().uuidString).json")
        let chatsURL = base.appendingPathComponent("chats-\(UUID().uuidString).json")
        defer { [convURL, chatsURL].forEach { try? FileManager.default.removeItem(at: $0) } }

        let product = UUID()
        let first = ConversationStore(fileURL: convURL, chatsURL: chatsURL)
        first.appendUser("Зроби аналіз", productID: product)
        let chatID = first.currentChat(for: product).id

        let stale = ConversationStore(fileURL: convURL, chatsURL: chatsURL)
        XCTAssertNil(stale.chat(id: chatID)?.session, "this is the stale copy the loss came from")

        first.bindSession(ChatSessionBinding(primaryProjectID: UUID(), projectPath: "/tmp/app",
                                             claudeSessionID: "sid-1",
                                             reportPaths: ["/tmp/report.html"]), to: chatID)

        stale.appendUser("І ще одне", productID: product)

        let onDisk = try JSONDecoder.iso.decode([Chat].self, from: try Data(contentsOf: chatsURL))
        let saved = try XCTUnwrap(onDisk.first { $0.id == chatID })
        XCTAssertEqual(saved.session?.claudeSessionID, "sid-1",
                       "a writer that never saw the binding must not be able to erase it")
        XCTAssertEqual(saved.session?.reportPaths, ["/tmp/report.html"])
    }

    @MainActor
    func testAPruneFromAStaleStoreKeepsABindingBoundAfterIt() throws {
        let base = FileManager.default.temporaryDirectory
        let convURL = base.appendingPathComponent("conv-\(UUID().uuidString).json")
        let chatsURL = base.appendingPathComponent("chats-\(UUID().uuidString).json")
        defer { [convURL, chatsURL].forEach { try? FileManager.default.removeItem(at: $0) } }

        let product = UUID()
        let first = ConversationStore(fileURL: convURL, chatsURL: chatsURL)
        first.appendUser("Зроби аналіз", productID: product)
        let chatID = first.currentChat(for: product).id

        let empty = first.newChat(for: product)
        first.bindSession(ChatSessionBinding(primaryProjectID: UUID(), projectPath: "/tmp/app",
                                             claudeSessionID: "sid-1",
                                             reportPaths: ["/tmp/report.html"]), to: empty.id)
        first.bindSession(ChatSessionBinding(primaryProjectID: UUID(), projectPath: "/tmp/app",
                                             claudeSessionID: "sid-keep",
                                             reportPaths: ["/tmp/keep.html"]), to: chatID)

        let restarted = ConversationStore(fileURL: convURL, chatsURL: chatsURL)
        XCTAssertNil(restarted.chat(id: empty.id), "an empty chat is not history")

        let onDisk = try JSONDecoder.iso.decode([Chat].self, from: try Data(contentsOf: chatsURL))
        XCTAssertNil(onDisk.first { $0.id == empty.id })
        let saved = try XCTUnwrap(onDisk.first { $0.id == chatID })
        XCTAssertEqual(saved.session?.claudeSessionID, "sid-keep")
        XCTAssertEqual(saved.session?.reportPaths, ["/tmp/keep.html"])
    }
}
