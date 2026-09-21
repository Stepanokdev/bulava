import XCTest
@testable import Bulava

nonisolated final class ChatScopedWorkTests: XCTestCase {

    @MainActor private func model() -> (AppModel, URL) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("bulava-chatscope-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        setenv("BULAVA_STATE_DIR", dir.path, 1)
        return (AppModel(), dir)
    }

    @MainActor private func openTask(_ m: AppModel, _ title: String) -> BacklogTask {
        var t = BacklogTask(title: title, projectPath: "/tmp/p", type: .feature,
                            priority: .p2, state: .review)
        t.id = UUID()
        return m.backlog.add(t)
    }

    @MainActor
    func testANewChatDoesNotInheritTheOldChatsWork() {
        let (m, dir) = model(); defer { try? FileManager.default.removeItem(at: dir) }
        let product = UUID()

        m.conversations.appendUser("Перша робота", productID: product)
        let first = m.conversations.currentChat(for: product)
        let task = openTask(m, "Стара задача")
        m.workItems.add(WorkItem(productID: product, chatID: first.id, title: "Стара задача",
                                 streams: [.init(id: task.id, title: task.title, projectName: "p")]))

        let second = m.conversations.newChat(for: product)

        XCTAssertEqual(m.openItems(inChat: first.id, productID: product).map(\.title), ["Стара задача"],
                       "the thread it was asked in still shows it")
        XCTAssertTrue(m.openItems(inChat: second.id, productID: product).isEmpty,
                      "a new conversation starts empty — that is what «new» means")
        XCTAssertEqual(m.openItems(for: product).count, 1,
                       "the product still knows about it; only the feed is scoped")
    }

    @MainActor
    func testWorkWithNoChatBelongsToTheOldestThreadOnly() {
        let (m, dir) = model(); defer { try? FileManager.default.removeItem(at: dir) }
        let product = UUID()

        m.conversations.appendUser("Перша розмова", productID: product)
        let first = m.conversations.currentChat(for: product)
        let second = m.conversations.newChat(for: product)
        m.conversations.appendUser("Друга розмова", productID: product)

        let task = openTask(m, "Прогін із консолі")
        m.workItems.add(WorkItem(productID: product, title: "Прогін із консолі",
                                 streams: [.init(id: task.id, title: task.title, projectName: "p")]))

        XCTAssertEqual(m.openItems(inChat: first.id, productID: product).count, 1)
        XCTAssertTrue(m.openItems(inChat: second.id, productID: product).isEmpty)
    }

    @MainActor
    func testWorkShowsInAProductThatHasNoThreadYet() {
        let (m, dir) = model(); defer { try? FileManager.default.removeItem(at: dir) }
        let product = UUID()
        let task = openTask(m, "Стара пачка робіт")
        m.workItems.add(WorkItem(productID: product, title: "Стара пачка робіт",
                                 streams: [.init(id: task.id, title: task.title, projectName: "p")]))

        XCTAssertTrue(m.conversations.chats(for: product).isEmpty)
        XCTAssertEqual(m.openItems(inChat: nil, productID: product).count, 1,
                       "with nowhere to belong it still has to be reachable")

        m.conversations.appendUser("Перше слово", productID: product)
        let chat = m.conversations.currentChat(for: product)
        XCTAssertEqual(m.openItems(inChat: chat.id, productID: product).count, 1,
                       "the thread he just opened adopts it")
        XCTAssertTrue(m.openItems(inChat: m.conversations.newChat(for: product).id, productID: product).isEmpty)
    }

    @MainActor
    func testWorkWhoseThreadIsGoneFallsBackToTheHomeThread() {
        let (m, dir) = model(); defer { try? FileManager.default.removeItem(at: dir) }
        let product = UUID()
        m.conversations.appendUser("Перша розмова", productID: product)
        let home = m.conversations.currentChat(for: product)
        let ghost = UUID()
        let task = openTask(m, "Осиротіла робота")
        m.workItems.add(WorkItem(productID: product, chatID: ghost, title: "Осиротіла робота",
                                 streams: [.init(id: task.id, title: task.title, projectName: "p")]))

        XCTAssertEqual(m.openItems(inChat: home.id, productID: product).count, 1)
    }

    @MainActor
    func testALooseTaskAlsoStaysInOneThread() {
        let (m, dir) = model(); defer { try? FileManager.default.removeItem(at: dir) }
        let productID = m.products.add(name: "P").id

        m.conversations.appendUser("Перша розмова", productID: productID)
        let first = m.conversations.currentChat(for: productID)
        var t = BacklogTask(title: "Прогін із консолі", type: .feature, priority: .p2, state: .review)
        t.id = UUID()
        t.productID = productID
        m.backlog.add(t)

        let second = m.conversations.newChat(for: productID)

        XCTAssertEqual(m.looseTasks(inChat: first.id, productID: productID).map(\.title),
                       ["Прогін із консолі"])
        XCTAssertTrue(m.looseTasks(inChat: second.id, productID: productID).isEmpty)
    }
}

nonisolated final class ClosingWorkOutTests: XCTestCase {

    @MainActor private func model() -> (AppModel, URL) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("bulava-closeout-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        setenv("BULAVA_STATE_DIR", dir.path, 1)
        return (AppModel(), dir)
    }

    @MainActor
    func testClosingTakesItOutOfOpenWorkWithoutClaimingApproval() {
        let (m, dir) = model(); defer { try? FileManager.default.removeItem(at: dir) }
        var t = BacklogTask(title: "Опубліковані додатки", projectPath: "/tmp/p",
                            type: .feature, priority: .p2, state: .review)
        t.id = UUID()
        let task = m.backlog.add(t)

        m.closeOut(task: task)

        let after = m.backlog.task(id: task.id)
        XCTAssertEqual(after?.state, .closed)
        XCTAssertNotEqual(after?.state, .approved, "nobody reviewed this — the history must not say they did")
        XCTAssertTrue(m.isFinished(after!), "it leaves open work")
    }

    @MainActor
    func testClosingAnItemClosesEveryStream() {
        let (m, dir) = model(); defer { try? FileManager.default.removeItem(at: dir) }
        let product = UUID()
        let ids: [UUID] = (0..<3).map { i in
            var t = BacklogTask(title: "потік \(i)", projectPath: "/tmp/p", type: .feature,
                                priority: .p2, state: .review)
            t.id = UUID()
            return m.backlog.add(t).id
        }
        let item = m.workItems.add(WorkItem(
            productID: product, title: "Три потоки",
            streams: ids.map { .init(id: $0, title: "потік", projectName: "p") }))

        m.closeOut(item: item)

        XCTAssertTrue(ids.allSatisfy { m.backlog.task(id: $0)?.state == .closed })
        XCTAssertTrue(m.isItemFinished(item))
        XCTAssertTrue(m.openItems(for: product).isEmpty)
    }

    @MainActor
    func testClosedReadsAsDoneEverywhere() {
        XCTAssertEqual(TaskState.closed.column, .done)
        XCTAssertEqual(TaskBucket(.closed), .done)
        let t = BacklogTask(title: "x", type: .feature, priority: .p2, state: .closed)
        XCTAssertEqual(WorkProgress.state(task: t, instance: nil), .done)
    }
}

nonisolated final class ClosedWorkInHistoryTests: XCTestCase {

    @MainActor
    func testClosedWorkIsInPreviousWorkAndSaysWhoEndedIt() {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("bulava-hist-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        setenv("BULAVA_STATE_DIR", dir.path, 1)
        defer { try? FileManager.default.removeItem(at: dir) }
        let m = AppModel()

        let productID = m.products.add(name: "P").id
        var closed = BacklogTask(title: "Закінчив сам", type: .feature, priority: .p2, state: .review)
        closed.id = UUID(); closed.productID = productID
        var approved = BacklogTask(title: "Пройшло рев'ю", type: .feature, priority: .p2, state: .approved)
        approved.id = UUID(); approved.productID = productID
        let t = m.backlog.add(closed)
        m.backlog.add(approved)
        m.closeOut(task: t)

        let history = m.history(for: productID)
        XCTAssertEqual(history.count, 2, "closed work stays in the record")
        XCTAssertEqual(history.first { $0.title == "Закінчив сам" }?.closedByYou, true)
        XCTAssertEqual(history.first { $0.title == "Пройшло рев'ю" }?.closedByYou, false,
                       "only the tick that was earned")
    }
}

nonisolated final class SettledAssumptionTests: XCTestCase {

    func testHisInstructionAboutTheTreeSilencesTheDefault() {
        XCTAssertTrue(PlanReadiness.directorSettledTheTree(
            "Все що незакомічено, померджай, перемкни на main і вже з неї зроби гілку."))
        XCTAssertTrue(PlanReadiness.directorSettledTheTree("застешь текущие изменения"))
        XCTAssertTrue(PlanReadiness.directorSettledTheTree("commit what is there first"))
    }

    func testAnUnrelatedRequestKeepsTheAssumption() {
        XCTAssertFalse(PlanReadiness.directorSettledTheTree("Перенеси кнопку «Новий чат» у хедер"))
        XCTAssertFalse(PlanReadiness.directorSettledTheTree("Додай експорт у CSV"))
    }
}

// MARK: - A binding that names a dead run

nonisolated final class StaleBindingTests: XCTestCase {

    @MainActor private func store() -> (ConversationStore, [URL]) {
        let base = FileManager.default.temporaryDirectory
        let a = base.appendingPathComponent("conv-\(UUID().uuidString).json")
        let b = base.appendingPathComponent("chats-\(UUID().uuidString).json")
        return (ConversationStore(fileURL: a, chatsURL: b), [a, b])
    }

    @MainActor
    func testARunNoLongerAliveIsNotClaimedByTheChatThatNamesIt() {
        let (s, urls) = store(); defer { urls.forEach { try? FileManager.default.removeItem(at: $0) } }
        let product = UUID(), project = UUID()
        s.appendUser("Зроби аналіз", productID: product)
        let chat = s.currentChat(for: product)
        s.bindSession(ChatSessionBinding(primaryProjectID: project, projectPath: "/tmp/presale",
                                         claudeSessionID: nil, activeRunID: "DEAD-RUN"),
                      to: chat.id)

        let live = "LIVE-RUN"
        let binding = try? XCTUnwrap(s.chat(id: chat.id)?.session)
        XCTAssertEqual(binding?.activeRunID, "DEAD-RUN")
        XCTAssertNotEqual(binding?.activeRunID, live,
                          "this is exactly the mismatch the relay refuses on")

        s.updateSession(for: chat.id) { $0.activeRunID = live }
        XCTAssertEqual(s.chat(id: chat.id)?.session?.activeRunID, live)
        XCTAssertEqual(s.chat(id: chat.id)?.session?.primaryProjectID, project,
                       "adopting a run must not move the chat to another project")
        XCTAssertEqual(s.entries(inChat: chat.id).count, 1, "and must not touch what was said")
    }
}
