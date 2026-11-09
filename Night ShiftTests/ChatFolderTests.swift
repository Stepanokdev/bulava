import XCTest
@testable import Bulava

/// A chat's own folder: chosen before the first message, changed after it.
///
/// A product of several folders starts every chat in its default — the first writable repository,
/// often the heaviest — and the check after each answer runs in the chat's folder. These are the
/// promises that make choosing another one mean something: the label, the start, the slash
/// commands and the context all follow the chat's choice; the product's default does not move; a
/// moved chat keeps its history and loses the sessions that belonged to the old folder; and a chat
/// that is busy, in a copy, or an automation's run is not moved at all.
nonisolated final class ChatFolderTests: XCTestCase {

    private var root: URL!
    private var state: URL!

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("chat-folder-\(UUID().uuidString)", isDirectory: true)
        state = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("chat-folder-state-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: state, withIntermediateDirectories: true)
        setenv("BULAVA_STATE_DIR", state.path, 1)
    }

    override func tearDownWithError() throws {
        unsetenv("BULAVA_STATE_DIR")
        try? FileManager.default.removeItem(at: root)
        try? FileManager.default.removeItem(at: state)
    }

    private func makeRepo(_ name: String) -> String {
        let dir = root.appendingPathComponent(name, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? "x".write(to: dir.appendingPathComponent("file.txt"), atomically: true, encoding: .utf8)
        for argv in [["git", "init", "-q"], ["git", "config", "user.email", "t@t"],
                     ["git", "config", "user.name", "t"], ["git", "add", "-A"], ["git", "commit", "-qm", "init"]] {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            p.arguments = argv
            p.currentDirectoryURL = dir
            p.standardOutput = FileHandle.nullDevice
            p.standardError = FileHandle.nullDevice
            try? p.run()
            p.waitUntilExit()
        }
        return dir.path
    }

    /// A product of three folders: the heavy monorepo first (so it is the default), a small service,
    /// and a reference folder he marked "ask before editing".
    @MainActor
    private func product() -> (AppModel, Product, heavy: Project, light: Project, reference: Project) {
        let model = AppModel()
        let heavy = model.projects.add(path: makeRepo("monorepo"))
        let light = model.projects.add(path: makeRepo("billing-service"))
        let reference = model.projects.add(path: makeRepo("design-docs"))
        let product = model.products.add(name: "Платформа", resources: [
            ProductResource(name: "monorepo", kind: .repository, access: .workspace, projectID: heavy.id),
            ProductResource(name: "billing", kind: .repository, access: .workspace, projectID: light.id),
            ProductResource(name: "design-docs", kind: .repository, access: .source, projectID: reference.id),
        ])
        return (model, product, heavy, light, reference)
    }

    // MARK: - Before the first message

    @MainActor
    func testANewChatStartsInTheProductsDefaultWithoutAskingAnything() {
        let (model, product, heavy, _, _) = product()
        let chat = model.conversations.newChat(for: product.id)
        XCTAssertEqual(model.chatFolder(productID: product.id, chatID: chat.id)?.id, heavy.id,
                       "choosing is optional: a chat nobody chose for works in the default")
        XCTAssertNil(model.conversations.chat(id: chat.id)?.session, "and nothing was written for it")
    }

    @MainActor
    func testChoosingBeforeTheFirstMessageMovesTheStartTheLabelAndTheCommands() async {
        let (model, product, heavy, light, _) = product()
        let chat = model.conversations.newChat(for: product.id)

        let problem = await model.chooseChatFolder(light.id, productID: product.id, chatID: chat.id)

        XCTAssertNil(problem)
        XCTAssertEqual(model.chatFolder(productID: product.id, chatID: chat.id)?.id, light.id,
                       "the label under the composer names the chosen folder")
        XCTAssertEqual(model.chatPrimary(for: product, chatID: chat.id)?.id, light.id,
                       "the send starts the agent there — and that is where the check runs")
        XCTAssertEqual(model.slashCommandRoots(for: product.id, chatID: chat.id).primaryProject?.path,
                       Slug.canonicalPath(light.path), "slash commands come from the folder the agent is in")
        XCTAssertEqual(model.products.product(id: product.id)?.defaultProjectID, heavy.id,
                       "a chat's choice is the chat's: the product's default does not move")
        let session = model.conversations.chat(id: chat.id)?.session
        XCTAssertNil(session?.claudeSessionID)
        XCTAssertNil(session?.movedFrom, "nothing was said yet, so there is nothing to hand over")
        XCTAssertTrue(model.conversations.entries(inChat: chat.id).isEmpty,
                      "a choice before the start is not a move, and says nothing in the chat")
    }

    @MainActor
    func testTwoChatsOfOneProductWorkInDifferentFolders() async {
        let (model, product, heavy, light, _) = product()
        let first = model.conversations.newChat(for: product.id)
        let second = model.conversations.newChat(for: product.id)

        await model.chooseChatFolder(light.id, productID: product.id, chatID: second.id)

        XCTAssertEqual(model.chatFolder(productID: product.id, chatID: first.id)?.id, heavy.id)
        XCTAssertEqual(model.chatFolder(productID: product.id, chatID: second.id)?.id, light.id)
    }

    @MainActor
    func testTheChoiceSurvivesARestart() async {
        let (model, product, _, light, _) = product()
        let chat = model.conversations.newChat(for: product.id)
        await model.chooseChatFolder(light.id, productID: product.id, chatID: chat.id)

        // The same files the app reads at launch.
        let reopened = ConversationStore()
        XCTAssertEqual(reopened.chat(id: chat.id)?.session?.primaryProjectID, light.id)
        XCTAssertEqual(reopened.chat(id: chat.id).map { Slug.canonicalPath($0.session?.projectPath ?? "") },
                       Slug.canonicalPath(light.path))
    }

    @MainActor
    func testChoosingWithNoChatYetMakesTheChat() async {
        let (model, product, _, light, _) = product()
        XCTAssertNil(model.conversations.currentChatID(for: product.id))

        await model.chooseChatFolder(light.id, productID: product.id, chatID: nil)

        let made = try? XCTUnwrap(model.conversations.currentChatID(for: product.id))
        XCTAssertEqual(model.chatFolder(productID: product.id, chatID: made)?.id, light.id)
    }

    @MainActor
    func testTheMenuOffersEveryFolderAndMarksTheOnesThatAskFirst() {
        let (model, product, heavy, light, reference) = product()
        let choices = model.chatFolderChoices(productID: product.id)
        XCTAssertEqual(choices.map(\.id), [heavy.id, light.id, reference.id], "in the product's own order")
        XCTAssertEqual(choices.map(\.name), ["monorepo", "billing", "design-docs"],
                       "named as the product names them")
        XCTAssertEqual(choices.map(\.asksBeforeEditing), [false, false, true])
    }

    // MARK: - Moving a conversation

    /// A chat with a conversation and the ids of sessions it had in the heavy folder — none of them
    /// running now.
    @MainActor
    private func conversationIn(_ model: AppModel, _ product: Product, _ folder: Project) -> Chat {
        let chat = model.conversations.newChat(for: product.id)
        model.conversations.appendUser("Почини округление в счетах", productID: product.id, chatID: chat.id)
        model.conversations.appendForeman("Нашёл: округление в `billing/round.ts`, а не в монорепо.",
                                          productID: product.id, chatID: chat.id)
        model.conversations.bindSession(
            ChatSessionBinding(primaryProjectID: folder.id, projectPath: folder.path,
                               claudeSessionID: "SESSION-IN-THE-MONOREPO", codexThreadID: "THREAD-IN-THE-MONOREPO",
                               codexContextDigest: "DIGEST", activeRunID: "RUN-1",
                               reportPaths: ["/tmp/report-1.html"]),
            to: chat.id)
        return model.conversations.chat(id: chat.id)!
    }

    @MainActor
    func testAMovedChatKeepsItsHistoryAndStartsANewSessionInTheNewFolder() async throws {
        let (model, product, heavy, light, _) = product()
        let chat = conversationIn(model, product, heavy)
        let historyBefore = model.conversations.entries(inChat: chat.id).filter { $0.kind != .event }.map(\.id)

        let problem = await model.chooseChatFolder(light.id, productID: product.id, chatID: chat.id)

        XCTAssertNil(problem)
        let session = try XCTUnwrap(model.conversations.chat(id: chat.id)?.session)
        XCTAssertEqual(session.primaryProjectID, light.id)
        XCTAssertEqual(Slug.canonicalPath(session.projectPath), Slug.canonicalPath(light.path))
        XCTAssertNil(session.claudeSessionID, "a Claude session belongs to the folder it was started in")
        XCTAssertNil(session.codexThreadID, "so does a Codex thread")
        XCTAssertNil(session.codexContextDigest, "the new thread is given the context again")
        XCTAssertNil(session.activeRunID)
        XCTAssertEqual(session.reportPaths, ["/tmp/report-1.html"], "earlier reports stay reachable")
        XCTAssertEqual(session.movedFrom, heavy.path)
        XCTAssertEqual(model.conversations.entries(inChat: chat.id).filter { $0.kind != .event }.map(\.id),
                       historyBefore, "the conversation stays on screen as it was")
        XCTAssertEqual(model.chatPrimary(for: product, chatID: chat.id)?.id, light.id)

        let notice = model.visibleEntries(inChat: chat.id).last
        XCTAssertEqual(notice?.kind, .event)
        XCTAssertTrue(notice?.text.contains("billing") == true, "the chat says where it works now: \(notice?.text ?? "nil")")
    }

    @MainActor
    func testTheFirstMessageAfterAMoveCarriesTheConversationAndTheOneAfterDoesNot() async throws {
        let (model, product, heavy, light, _) = product()
        let chat = conversationIn(model, product, heavy)
        await model.chooseChatFolder(light.id, productID: product.id, chatID: chat.id)

        let carried = try XCTUnwrap(model.folderMoveHandoff(chatID: chat.id, before: nil))
        XCTAssertTrue(carried.contains(heavy.path) && carried.contains(light.path), carried)
        XCTAssertTrue(carried.contains("Почини округление в счетах"), "what he asked")
        XCTAssertTrue(carried.contains("billing/round.ts"), "what the agent had found")

        // The new folder's session starts: from then on it remembers the conversation itself.
        var instance = SupervisorInstance(slug: "light", projectPath: light.path, session: "night-light",
                                          watchdogAlive: true, hasPlan: false, hasResearch: false)
        instance.sessionID = "SESSION-IN-BILLING"
        let bound = model.makeBinding(for: light, instance: instance,
                                      keeping: model.conversations.chat(id: chat.id)?.session)
        model.conversations.bindSession(bound, to: chat.id)
        XCTAssertNil(model.folderMoveHandoff(chatID: chat.id, before: nil))
        XCTAssertNil(bound.movedFrom)
    }

    @MainActor
    func testAStartThatHasNoSessionYetStillCarriesTheConversation() async throws {
        let (model, product, heavy, light, _) = product()
        let chat = conversationIn(model, product, heavy)
        await model.chooseChatFolder(light.id, productID: product.id, chatID: chat.id)

        let starting = SupervisorInstance(slug: "light", projectPath: light.path, session: "night-light",
                                          watchdogAlive: true, hasPlan: false, hasResearch: false)
        let bound = model.makeBinding(for: light, instance: starting,
                                      keeping: model.conversations.chat(id: chat.id)?.session)
        XCTAssertEqual(bound.movedFrom, heavy.path,
                       "a retry before the session id arrives must still hand the conversation over")
    }

    @MainActor
    func testARetriedMessageDoesNotQuoteItself() async throws {
        let (model, product, heavy, light, _) = product()
        let chat = conversationIn(model, product, heavy)
        await model.chooseChatFolder(light.id, productID: product.id, chatID: chat.id)
        let retried = model.conversations.appendUser("И проверь тесты биллинга", productID: product.id, chatID: chat.id)

        let carried = try XCTUnwrap(model.folderMoveHandoff(chatID: chat.id, before: retried.id))
        XCTAssertFalse(carried.contains("И проверь тесты биллинга"))
        XCTAssertTrue(carried.contains("Почини округление в счетах"))
    }

    @MainActor
    func testMovingThereAndBackSaysSoBothTimes() async {
        let (model, product, heavy, light, _) = product()
        let chat = conversationIn(model, product, heavy)

        await model.chooseChatFolder(light.id, productID: product.id, chatID: chat.id)
        await model.chooseChatFolder(heavy.id, productID: product.id, chatID: chat.id)
        await model.chooseChatFolder(light.id, productID: product.id, chatID: chat.id)

        let notices = model.visibleEntries(inChat: chat.id).filter { $0.kind == .event }
        XCTAssertEqual(notices.count, 3, "each move is its own line, even back to a folder it was in")
        XCTAssertEqual(model.conversations.chat(id: chat.id)?.session?.movedFrom, heavy.path,
                       "no session started in between, so the conversation still left the first folder")
    }

    @MainActor
    func testChoosingTheFolderItIsAlreadyInChangesNothing() async {
        let (model, product, heavy, _, _) = product()
        let chat = conversationIn(model, product, heavy)
        let before = model.conversations.chat(id: chat.id)?.session

        let problem = await model.chooseChatFolder(heavy.id, productID: product.id, chatID: chat.id)

        XCTAssertNil(problem)
        XCTAssertEqual(model.conversations.chat(id: chat.id)?.session, before,
                       "picking the current folder must not throw a working session away")
        XCTAssertFalse(model.visibleEntries(inChat: chat.id).contains { $0.kind == .event })
    }

    // MARK: - When it is not moved

    @MainActor
    func testAChatWithAMessageWaitingIsNotMoved() async {
        let (model, product, heavy, light, _) = product()
        let chat = conversationIn(model, product, heavy)
        let waiting = model.conversations.appendUser("ещё одно", productID: product.id, chatID: chat.id)
        model.conversations.updateDelivery(entryID: waiting.id, .queued)
        let before = model.conversations.chat(id: chat.id)?.session

        let problem = await model.chooseChatFolder(light.id, productID: product.id, chatID: chat.id)

        XCTAssertNotNil(problem)
        XCTAssertEqual(model.chatFolderLock(chatID: chat.id), .working)
        XCTAssertEqual(model.conversations.chat(id: chat.id)?.session, before, "the old binding is kept whole")
    }

    @MainActor
    func testAChatBeingSentFromIsNotMoved() async {
        let (model, product, heavy, light, _) = product()
        let chat = conversationIn(model, product, heavy)
        model.sendingChatIDs.insert(chat.id)

        let problem = await model.chooseChatFolder(light.id, productID: product.id, chatID: chat.id)

        XCTAssertNotNil(problem)
        XCTAssertEqual(model.chatFolder(productID: product.id, chatID: chat.id)?.id, heavy.id)
    }

    @MainActor
    func testAChatInACopyAndAnAutomationsRunKeepTheirFolder() async {
        let (model, product, heavy, light, _) = product()
        let inCopy = conversationIn(model, product, heavy)
        model.conversations.setWorkCopy(UUID(), for: inCopy.id)
        let run = model.conversations.newAutomationChat(id: UUID(), for: product.id, runID: UUID(),
                                                        copyID: nil, title: "Weekly SEO")

        XCTAssertEqual(model.chatFolderLock(chatID: inCopy.id), .inCopy)
        XCTAssertEqual(model.chatFolderLock(chatID: run.id), .automationRun)
        let a = await model.chooseChatFolder(light.id, productID: product.id, chatID: inCopy.id)
        let b = await model.chooseChatFolder(light.id, productID: product.id, chatID: run.id)
        XCTAssertNotNil(a)
        XCTAssertNotNil(b)
        XCTAssertEqual(model.chatFolder(productID: product.id, chatID: inCopy.id)?.id, heavy.id)
    }

    @MainActor
    func testAFolderOutsideTheProductIsRefused() async {
        let (model, product, heavy, _, _) = product()
        let stranger = model.projects.add(path: makeRepo("someone-else"))
        let chat = conversationIn(model, product, heavy)

        let problem = await model.chooseChatFolder(stranger.id, productID: product.id, chatID: chat.id)

        XCTAssertNotNil(problem)
        XCTAssertEqual(model.chatFolder(productID: product.id, chatID: chat.id)?.id, heavy.id)
    }

    @MainActor
    func testAMessageSentWhileTheChatIsMovingIsNotStartedInTheOldFolder() {
        let (model, product, heavy, _, _) = product()
        let chat = conversationIn(model, product, heavy)
        model.movingChatFolders.insert(chat.id)

        let sent = model.sendDirectMessage("быстрее", productID: product.id, chatID: chat.id)

        guard case .sent(let entryID) = sent else { return XCTFail("\(sent)") }
        XCTAssertEqual(model.conversations.entry(id: entryID)?.delivery, .failed,
                       "it waits for him to send it again, into the new folder")
        XCTAssertFalse(model.sendingChatIDs.contains(chat.id), "nothing was started")
    }

    // MARK: - The pieces, without an app

    func testTheStep() {
        let a = UUID(), b = UUID()
        XCTAssertEqual(ChatFolderMove.step(current: a, target: a, hasConversation: true), .nothing)
        XCTAssertEqual(ChatFolderMove.step(current: a, target: b, hasConversation: false), .choose)
        XCTAssertEqual(ChatFolderMove.step(current: nil, target: b, hasConversation: false), .choose)
        XCTAssertEqual(ChatFolderMove.step(current: a, target: b, hasConversation: true), .move)
    }

    func testTheExcerptIsBoundedAndKeepsTheNewest() {
        let product = UUID()
        var entries: [ConversationEntry] = []
        for n in 1...30 {
            entries.append(ConversationEntry(productID: product, kind: n.isMultiple(of: 2) ? .foreman : .user,
                                             text: "message \(n) " + String(repeating: "x", count: 2000)))
        }
        entries.append(ConversationEntry(productID: product, kind: .event, text: "bookkeeping"))

        let lines = ChatFolderMove.excerpt(entries)

        XCTAssertLessThanOrEqual(lines.count, ChatFolderMove.carriedMessages)
        XCTAssertTrue(lines.last?.text.hasPrefix("message 30") == true, "the newest exchange is the one kept")
        XCTAssertTrue(lines.allSatisfy { $0.text.count <= ChatFolderMove.carriedCharactersPerMessage + 1 })
        XCTAssertLessThanOrEqual(lines.reduce(0) { $0 + $1.text.count },
                                 ChatFolderMove.carriedCharacters + ChatFolderMove.carriedCharactersPerMessage)
        XCTAssertFalse(lines.contains { $0.text == "bookkeeping" }, "app events are not the conversation")
    }

    func testThePreambleNamesBothFolders() {
        let text = ChatFolderMove.preamble(from: "/w/monorepo", to: "/w/billing",
                                           lines: [.init(mine: true, text: "почини\nокругление")])
        XCTAssertTrue(text.contains("`/w/monorepo`") && text.contains("`/w/billing`"))
        XCTAssertTrue(text.contains("> почини\n> округление"), "a quoted message keeps every line quoted")
    }
}
