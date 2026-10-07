import XCTest
@testable import Bulava

/// Model and depth belong to one conversation: a deep model in one chat, a light one in another,
/// and the default in Settings moving neither once they are under way.
nonisolated final class ChatRunChoicesTests: XCTestCase {

    @MainActor private func model() -> (AppModel, URL) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("bulava-runchoices-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        setenv("BULAVA_STATE_DIR", dir.path, 1)
        return (AppModel(), dir)
    }

    @MainActor
    func testTwoChatsKeepTheirOwnModelAndDepth() {
        let (m, dir) = model(); defer { try? FileManager.default.removeItem(at: dir) }
        let product = UUID()
        let deep = m.conversations.newChat(for: product)
        let light = m.conversations.newChat(for: product)

        m.chooseClaudeModel(.opus, for: deep.id)
        m.updateRunChoices(for: deep.id) { $0.codexEffort = .high }
        m.chooseClaudeModel(.haiku, for: light.id)
        m.updateRunChoices(for: light.id) { $0.codexEffort = .low }

        XCTAssertEqual(m.runChoices(for: deep.id).claudeModel, .opus)
        XCTAssertEqual(m.runChoices(for: deep.id).codexEffort, .high)
        XCTAssertEqual(m.runChoices(for: light.id).claudeModel, .haiku)
        XCTAssertEqual(m.runChoices(for: light.id).codexEffort, .low)
        XCTAssertNotEqual(m.engineChoices(for: deep.id), m.engineChoices(for: light.id),
                          "what each chat launches with differs, not only what its pill says")
    }

    /// What a send runs on is taken when he presses Send. Delivery awaits a good deal before it
    /// reaches the engine — the run starting, the review gate — and a change to the pill in that
    /// time belongs to the next message.
    @MainActor
    func testASendRunsOnTheChoicesItWasSentWith() throws {
        let (m, dir) = model(); defer { try? FileManager.default.removeItem(at: dir) }
        let chat = m.conversations.newChat(for: UUID())
        m.updateRunChoices(for: chat.id) { $0.codexEffort = .low }
        let taken = m.runChoices(for: chat.id)
        m.updateRunChoices(for: chat.id) { $0.codexEffort = .xhigh }
        XCTAssertEqual(m.engineChoices(run: taken), m.engineChoices(run: RunChoices(codexEffort: .low)))
        XCTAssertNotEqual(m.engineChoices(run: taken), m.engineChoices(for: chat.id))

        let source = try String(contentsOfFile: URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Night Shift/App/AppModel+DirectChat.swift").path, encoding: .utf8)
        guard let start = source.range(of: "private func deliverViaClaude("),
              let end = source.range(of: "\n    func engineChoices(", range: start.upperBound..<source.endIndex) else {
            return XCTFail("deliverViaClaude is no longer where this test can read it")
        }
        let body = source[start.lowerBound..<end.lowerBound]
        XCTAssertFalse(body.contains("engineChoices(for:"), "the delivery must not read the pill again")
        // The snapshot is what reaches the engine; an automation's send adds that nobody is there.
        XCTAssertTrue(body.contains("engineChoices(run: run)") || body.contains("engineChoices(run: run,"))
        XCTAssertTrue(body.contains("let run = snapshot ?? runChoices(for: chat.id)"))
        if let taken = body.range(of: "let run = snapshot ?? runChoices(for: chat.id)"),
           let firstAwait = body.range(of: "await ") {
            XCTAssertTrue(taken.lowerBound < firstAwait.lowerBound,
                          "the snapshot is taken before the first thing the send waits for")
        } else {
            XCTFail("the send no longer takes a snapshot of its chat's choices")
        }
    }

    /// Codex is answering, he changes the pill, and Codex then refuses for want of quota: Claude
    /// takes the message on what it was sent with, not on what the pill says by then.
    @MainActor
    func testAMessageCodexRefusedReachesClaudeOnItsOwnChoices() async throws {
        let (m, dir) = model(); defer { try? FileManager.default.removeItem(at: dir) }
        let folder = dir.appendingPathComponent("project")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let product = m.products.add(name: "P")
        let project = m.projects.add(path: folder.path)
        m.products.addResource(ProductResource(name: "project", kind: .folder, access: .workspace,
                                               projectID: project.id), to: product.id)
        m.settings.chatMode = .codex
        m.settings.claudeStandsInForCodex = true
        let chat = m.conversations.currentChat(for: product.id)
        m.updateRunChoices(for: chat.id) { $0.claudeEffort = .low; $0.codexEffort = .low }

        var release: CheckedContinuation<Void, Never>?
        var codexEffortAsked = ""
        m.runCodexTurn = { request in
            codexEffortAsked = request.effort
            await withCheckedContinuation { release = $0 }       // Codex still thinking…
            return CodexChatRunner.Outcome(threadID: nil, blocks: [],
                                           failure: "You've hit your usage limit.", usage: nil, exitCode: 1)
        }
        var claudeGot: RunChoices?
        m.claudeDeliveryStarted = { _, run in claudeGot = run }

        guard case .sent = m.sendDirectMessage("Перевір звіт", productID: product.id, chatID: chat.id) else {
            return XCTFail("the message was not sent")
        }
        for _ in 0..<100 where release == nil { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(codexEffortAsked, "low")

        // …and he changes this chat's choices while it is.
        m.updateRunChoices(for: chat.id) { $0.claudeEffort = .max; $0.codexEffort = .xhigh }
        release?.resume()
        for _ in 0..<200 where claudeGot == nil { try await Task.sleep(for: .milliseconds(10)) }

        XCTAssertEqual(claudeGot?.claudeEffort, .low, "Claude answers on what the message was sent with")
        XCTAssertEqual(claudeGot?.codexEffort, .low)
        XCTAssertEqual(m.runChoices(for: chat.id).claudeEffort, .max, "and the pill keeps his new choice")
    }

    @MainActor
    func testTheDefaultMovesNoChatAlreadyUnderWay() {
        let (m, dir) = model(); defer { try? FileManager.default.removeItem(at: dir) }
        let product = UUID()
        let chat = m.conversations.newChat(for: product)
        m.updateRunChoices(for: nil) { $0.codexEffort = .medium }

        // The first message is where a chat stops following the default.
        m.settleRunChoices(for: chat.id)
        m.updateRunChoices(for: nil) { $0.codexEffort = .xhigh }

        XCTAssertEqual(m.runChoices(for: chat.id).codexEffort, .medium)
        XCTAssertEqual(m.settings.codexEffort, .xhigh)

        let fresh = m.conversations.newChat(for: product)
        XCTAssertEqual(m.runChoices(for: fresh.id).codexEffort, .xhigh,
                       "a new chat starts from the default as it is now")
    }

    @MainActor
    func testAChoiceInOneChatLeavesTheDefaultAlone() {
        let (m, dir) = model(); defer { try? FileManager.default.removeItem(at: dir) }
        let chat = m.conversations.newChat(for: UUID())
        let before = m.defaultRunChoices
        m.chooseClaudeModel(.opus, for: chat.id)
        XCTAssertEqual(m.defaultRunChoices, before)
    }

    @MainActor
    func testChoicesSurviveARelaunch() {
        let base = FileManager.default.temporaryDirectory
        let a = base.appendingPathComponent("conv-\(UUID().uuidString).json")
        let b = base.appendingPathComponent("chats-\(UUID().uuidString).json")
        defer { [a, b].forEach { try? FileManager.default.removeItem(at: $0) } }
        let product = UUID()
        let first = ConversationStore(fileURL: a, chatsURL: b)
        first.appendUser("Привіт", productID: product)
        let chat = first.currentChat(for: product)
        first.setRunChoices(RunChoices(claudeModel: .opus, claudeEffort: .high,
                                       codexModel: "gpt-x", codexEffort: .low), for: chat.id)

        let again = ConversationStore(fileURL: a, chatsURL: b)
        XCTAssertEqual(again.chat(id: chat.id)?.run?.claudeModel, .opus)
        XCTAssertEqual(again.chat(id: chat.id)?.run?.codexModel, "gpt-x")
    }

    func testAChatSavedBeforeThisExistedHasNoChoicesOfItsOwn() throws {
        let old = """
        {"id":"\(UUID().uuidString)","productID":"\(UUID().uuidString)","title":"Old"}
        """
        XCTAssertNil(try JSONDecoder.iso.decode(Chat.self, from: Data(old.utf8)).run)
    }
}

/// A message parked for later delivery is unanswered, whatever the previous answer said.
nonisolated final class ParkedMessagePhaseTests: XCTestCase {

    func testParkedMessagesAreNeverShownAsReplied() {
        var instance = SupervisorInstance(slug: "p", projectPath: "/tmp/p", session: "night-p",
                                          watchdogAlive: true, hasPlan: false, hasResearch: false)
        XCTAssertEqual(DirectChatPhase.resolve(instance: instance, bindingHasOutcome: true), .ready)

        instance.queuedMessageCount = 2
        XCTAssertEqual(DirectChatPhase.resolve(instance: instance, bindingHasOutcome: true), .queued,
                       "two questions in the queue under «replied» is the bug he hit")
    }
}

/// The chat history is written in the background, and nothing that reads it can miss a write.
nonisolated final class CoalescedSaveTests: XCTestCase {

    @MainActor
    func testAReadSeesTheLastSaveEvenBeforeTheBackgroundWrite() {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("coalesced-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let file = JSONFile<[String]>(url: url)
        for n in 1...50 { file.saveSoon(["v\(n)"], delay: 5) }
        XCTAssertEqual(file.load(), ["v50"], "the newest value, written once, on the read")
    }

    @MainActor
    func testManySavesBecomeOneWrite() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("coalesced-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let file = JSONFile<[Int]>(url: url)
        for n in 1...200 { file.saveSoon([n], delay: 0.2) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path),
                       "nothing is written while the saves keep coming")
        let written = expectation(description: "written")
        DispatchQueue.global().asyncAfter(deadline: .now() + 1) { written.fulfill() }
        wait(for: [written], timeout: 3)
        let data = try Data(contentsOf: url)
        XCTAssertEqual(try JSONDecoder.iso.decode([Int].self, from: data), [200])
    }

    @MainActor
    func testASynchronousSaveIsNotOverwrittenByAnOlderPendingOne() {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("coalesced-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let file = JSONFile<[String]>(url: url)
        file.saveSoon(["old"], delay: 0.1)
        file.save(["new"])
        let settled = expectation(description: "settled")
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.5) { settled.fulfill() }
        wait(for: [settled], timeout: 2)
        XCTAssertEqual(file.load(), ["new"])
    }

    @MainActor
    func testQuittingWaitsForAWriteAlreadyUnderWay() {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("coalesced-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let started = DispatchSemaphore(value: 0)
        CoalescedWrites.shared.schedule(url, delay: 0) {
            started.signal()
            Thread.sleep(forTimeInterval: 0.5)     // a big history, still being encoded
            return Data("[\"slow\"]".utf8)
        }
        started.wait()
        CoalescedWrites.shared.flushAll()
        XCTAssertEqual(try? Data(contentsOf: url), Data("[\"slow\"]".utf8),
                       "the write that had already begun is on disk before quitting goes on")
    }

    @MainActor
    func testTheChatViewFollowsAChangeInsideAnEntry() {
        let base = FileManager.default.temporaryDirectory
        let a = base.appendingPathComponent("conv-\(UUID().uuidString).json")
        let b = base.appendingPathComponent("chats-\(UUID().uuidString).json")
        defer { [a, b].forEach { try? FileManager.default.removeItem(at: $0) } }
        let product = UUID()
        let store = ConversationStore(fileURL: a, chatsURL: b)
        let chat = store.currentChat(for: product)
        let turn = store.beginForemanTurn(productID: product, chatID: chat.id)
        XCTAssertEqual(store.entries(inChat: chat.id).first { $0.id == turn }?.text, "")
        store.updateBlocks(entryID: turn, blocks: [.markdown(id: "m", "Готово.")],
                           text: "Готово.", persist: false)
        XCTAssertEqual(store.entries(inChat: chat.id).first { $0.id == turn }?.text, "Готово.",
                       "a streamed answer is not served from before it grew")
    }

    @MainActor
    func testAStoreReopenedRightAfterAChangeSeesIt() {
        let base = FileManager.default.temporaryDirectory
        let a = base.appendingPathComponent("conv-\(UUID().uuidString).json")
        let b = base.appendingPathComponent("chats-\(UUID().uuidString).json")
        defer { [a, b].forEach { try? FileManager.default.removeItem(at: $0) } }
        let product = UUID()
        let first = ConversationStore(fileURL: a, chatsURL: b)
        let chat = first.currentChat(for: product)
        first.appendUser("перше", productID: product, chatID: chat.id)
        XCTAssertEqual(first.entries(inChat: chat.id).map(\.text), ["перше"])
        first.appendUser("друге", productID: product, chatID: chat.id)
        XCTAssertEqual(first.entries(inChat: chat.id).map(\.text), ["перше", "друге"],
                       "the per-chat view is not served stale after a change")

        let again = ConversationStore(fileURL: a, chatsURL: b)
        XCTAssertEqual(again.entries(inChat: chat.id).map(\.text), ["перше", "друге"])
    }
}

/// The history he has is about two thousand messages and twenty-five megabytes. A change to it
/// used to re-encode and rewrite all of that on the main thread, every time.
nonisolated final class LargeHistoryResponsivenessTests: XCTestCase {

    @MainActor
    func testAChangeToALargeHistoryDoesNotHoldTheMainThread() throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("bulava-large-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let a = base.appendingPathComponent("conversations.json")
        let b = base.appendingPathComponent("chats.json")
        let product = UUID()
        let chat = Chat(productID: product, title: "Довгий")
        let body = String(repeating: "Довга відповідь із кодом і поясненнями. ", count: 300)
        let history = (0..<2000).map { n in
            ConversationEntry(productID: product, chatID: chat.id,
                              kind: n % 2 == 0 ? .user : .foreman,
                              at: Date(timeIntervalSince1970: TimeInterval(n)), text: body)
        }
        try JSONEncoder.iso.encode(history).write(to: a)
        try JSONEncoder.iso.encode([chat]).write(to: b)

        let store = ConversationStore(fileURL: a, chatsURL: b)
        let started = Date()
        for n in 0..<20 { store.appendUser("ще \(n)", productID: product, chatID: chat.id) }
        let perChange = Date().timeIntervalSince(started) / 20
        XCTAssertLessThan(perChange, 0.05,
                          "each change held the main thread for \(Int(perChange * 1000)) ms")

        let reopened = ConversationStore(fileURL: a, chatsURL: b)
        XCTAssertEqual(reopened.entries(inChat: chat.id).count, 2020, "and nothing was lost")
    }
}

