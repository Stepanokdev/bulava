import XCTest
@testable import Bulava

/// Which pipeline a chat's message goes through, from the pick in the composer to the argument
/// `worker-send.sh` is started with.
nonisolated final class PipelineChoiceTests: XCTestCase {

    @MainActor private func model() -> (AppModel, URL) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("bulava-pipeline-choice-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        setenv("BULAVA_STATE_DIR", dir.path, 1)
        return (AppModel(), dir)
    }

    @MainActor
    func testABuiltInChosenForAChatStaysChosenWhenNewChatsDefaultToAnother() throws {
        let (m, dir) = model()
        defer { try? FileManager.default.removeItem(at: dir) }
        let builtin = m.builtinChatPipeline
        let productID = UUID()
        let chat = m.conversations.newChat(for: productID)

        // New chats default to one of his own pipelines.
        m.choosePipeline("my-research", forChat: nil)
        XCTAssertEqual(m.settings.defaultPipelineID, "my-research")
        XCTAssertEqual(m.pipelineID(forChat: chat.id), "my-research", "a chat that chose nothing follows the default")

        // This chat goes back to the built-in one.
        m.choosePipeline(builtin, forChat: chat.id)
        XCTAssertEqual(m.conversations.chat(id: chat.id)?.pipelineID, builtin,
                       "the built-in is kept as a choice, not as «nothing chosen»")
        XCTAssertEqual(m.pipelineID(forChat: chat.id), builtin)
        XCTAssertEqual(m.relayPipeline(forChat: chat.id), builtin)

        // Another chat that chose nothing still follows the default.
        let other = m.conversations.newChat(for: UUID())
        XCTAssertEqual(m.pipelineID(forChat: other.id), "my-research")
        // And the default itself can go back to the built-in: then it is stored as no default.
        m.choosePipeline(builtin, forChat: nil)
        XCTAssertNil(m.settings.defaultPipelineID)
        XCTAssertEqual(m.pipelineID(forChat: other.id), builtin)
    }

    @MainActor
    func testTheChoiceSurvivesTheChatBeingOpenedAgain() throws {
        let (m, dir) = model()
        defer { try? FileManager.default.removeItem(at: dir) }
        let productID = UUID()
        let talked = m.conversations.newChat(for: productID)
        _ = m.conversations.appendUser("перше повідомлення", productID: productID, chatID: talked.id)
        m.choosePipeline("my-research", forChat: nil)
        m.choosePipeline(m.builtinChatPipeline, forChat: talked.id)
        // A chat nobody has written in yet, set up before its first message.
        let fresh = m.conversations.newChat(for: UUID())
        m.choosePipeline(m.builtinChatPipeline, forChat: fresh.id)

        // A second model on the same folder reads what the first one wrote — a relaunch.
        let reopened = AppModel()
        reopened.settings.defaultPipelineID = "my-research"
        for chat in [talked, fresh] {
            XCTAssertEqual(reopened.conversations.chat(id: chat.id)?.pipelineID, m.builtinChatPipeline)
            XCTAssertEqual(reopened.relayPipeline(forChat: chat.id), m.builtinChatPipeline)
        }
    }

    @MainActor
    func testWhatTheChatPicksIsWhatWorkerSendIsStartedWith() async throws {
        let (m, dir) = model()
        defer { try? FileManager.default.removeItem(at: dir) }
        let chat = m.conversations.newChat(for: UUID())
        m.choosePipeline("my-research", forChat: nil)
        m.choosePipeline(m.builtinChatPipeline, forChat: chat.id)

        // A stand-in for worker-send.sh that only says which pipeline it was given.
        let stub = dir.appendingPathComponent("worker-send.sh")
        try """
        while [ $# -gt 0 ]; do
          case "$1" in --pipeline) echo "PIPELINE=$2"; shift 2 ;; *) shift ;; esac
        done
        """.write(to: stub, atomically: true, encoding: .utf8)
        let call = SupervisorClient.workerSendInvocation(
            script: stub.path, projectPath: "/tmp/project", sessionID: nil, branch: nil, runID: nil,
            message: "привіт", messageID: UUID(), intent: .conversation,
            pipeline: m.relayPipeline(forChat: chat.id))
        let r = await Shell.run(call.command, args: call.args, timeout: 20)
        XCTAssertTrue(r.ok, r.combined)
        XCTAssertEqual(r.stdout.trimmingCharacters(in: .whitespacesAndNewlines), "PIPELINE=\(m.builtinChatPipeline)")
    }

    func testANameTheEngineCouldMisreadNeverReachesIt() {
        let call = SupervisorClient.workerSendInvocation(
            script: "/x", projectPath: "/p", sessionID: nil, branch: nil, runID: nil, message: "m",
            messageID: nil, intent: .conversation, pipeline: "../../etc")
        XCTAssertEqual(call.args[8], "plain")
    }
}
