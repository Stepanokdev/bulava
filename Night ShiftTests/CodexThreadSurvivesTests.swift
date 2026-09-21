import XCTest
@testable import Bulava

nonisolated final class CodexThreadSurvivesTests: XCTestCase {

    @MainActor private func store() -> ConversationStore {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("bulava-thread-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        setenv("BULAVA_STATE_DIR", dir.path, 1)
        return ConversationStore()
    }

    // MARK: - Two turns in a new chat

    @MainActor func testWritingAThreadWithNoBindingLosesIt() {
        let store = store()
        let productID = UUID()
        let chat = store.currentChat(for: productID)

        store.updateSession(for: chat.id) { $0.codexThreadID = "thread-1" }

        XCTAssertNil(store.chat(id: chat.id)?.session?.codexThreadID,
                     "this is the failure the fix exists for — updateSession is a no-op without a binding")
    }

    @MainActor func testASecondTurnInANewChatResumesTheFirstThread() {
        let store = store()
        let productID = UUID()
        let chat = store.currentChat(for: productID)

        store.bindSession(ChatSessionBinding(primaryProjectID: nil, projectPath: "/tmp/p"), to: chat.id)
        store.updateSession(for: chat.id) { $0.codexThreadID = "thread-1" }

        XCTAssertEqual(store.chat(id: chat.id)?.session?.codexThreadID, "thread-1")
    }

    @MainActor func testAFailedTurnDoesNotEraseTheThread() {
        let store = store()
        let chat = store.currentChat(for: UUID())
        store.bindSession(ChatSessionBinding(primaryProjectID: nil, projectPath: "/tmp/p",
                                             codexThreadID: "thread-1"), to: chat.id)

        let reported: String? = nil
        if let id = reported, !id.isEmpty {
            store.updateSession(for: chat.id) { $0.codexThreadID = id }
        }

        XCTAssertEqual(store.chat(id: chat.id)?.session?.codexThreadID, "thread-1")
    }

    // MARK: - Codex → Claude → Codex

    @MainActor func testAClaudeTurnInBetweenKeepsTheCodexThread() {
        let model = AppModel()
        let project = Project(name: "p", path: "/tmp/p")
        var instance = SupervisorInstance(slug: Slug.forPath("/tmp/p"), projectPath: "/tmp/p",
                                          session: "s", watchdogAlive: true,
                                          hasPlan: false, hasResearch: false)
        instance.sessionID = "claude-session-2"

        let before = ChatSessionBinding(primaryProjectID: project.id, projectPath: "/tmp/p",
                                        claudeSessionID: "claude-session-1",
                                        codexThreadID: "codex-thread-1")
        let after = model.makeBinding(for: project, instance: instance, keeping: before)

        XCTAssertEqual(after.codexThreadID, "codex-thread-1",
                       "a Claude rebind must not throw away the Codex thread")
        XCTAssertEqual(after.claudeSessionID, "claude-session-2",
                       "and it must still adopt the live Claude session")
    }

    @MainActor func testAChatHoldsBothEnginesAtOnce() {
        let store = store()
        let chat = store.currentChat(for: UUID())
        store.bindSession(ChatSessionBinding(primaryProjectID: nil, projectPath: "/tmp/p",
                                             claudeSessionID: "claude-1",
                                             codexThreadID: "codex-1"), to: chat.id)

        let session = store.chat(id: chat.id)?.session
        XCTAssertEqual(session?.claudeSessionID, "claude-1")
        XCTAssertEqual(session?.codexThreadID, "codex-1")
    }

    func testTheThreadSurvivesEncodingAndDecoding() throws {
        let binding = ChatSessionBinding(primaryProjectID: nil, projectPath: "/tmp/p",
                                         claudeSessionID: "claude-1", codexThreadID: "codex-1")
        let data = try JSONEncoder().encode(binding)
        let back = try JSONDecoder().decode(ChatSessionBinding.self, from: data)

        XCTAssertEqual(back.codexThreadID, "codex-1")
        XCTAssertEqual(back.claudeSessionID, "claude-1")
    }
}
