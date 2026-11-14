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

        // A later default for new chats does not move it.
        m.choosePipeline("my-research", forChat: nil)
        XCTAssertEqual(m.pipelineID(forChat: chat.id), builtin)
        // And the default itself can go back to the built-in: then it is stored as no default.
        m.choosePipeline(builtin, forChat: nil)
        XCTAssertNil(m.settings.defaultPipelineID)
    }

    /// He picked the Codex team in one chat, opened the next one, and it was back on the single
    /// reviewer: every new chat had to be set again, and sometimes he forgot.
    @MainActor
    func testWhatAChatPicksIsWhereTheNextNewChatStarts() throws {
        let (m, dir) = model()
        defer { try? FileManager.default.removeItem(at: dir) }
        let first = m.conversations.newChat(for: UUID())
        m.choosePipeline("my-research", forChat: first.id)
        XCTAssertEqual(m.pipelineID(forChat: first.id), "my-research")
        XCTAssertEqual(m.settings.defaultPipelineID, "my-research", "the pick is remembered for new chats")
        let next = m.conversations.newChat(for: UUID())
        XCTAssertEqual(m.pipelineID(forChat: next.id), "my-research")

        // Remembered across a relaunch: it lives in the settings file.
        m.settings.save()
        XCTAssertEqual(AppModel().settings.defaultPipelineID, "my-research")
    }

    /// A conversation already going keeps the pipeline it started with when another chat picks a
    /// different one: the remembered choice is for chats that have not started yet.
    @MainActor
    func testAStartedChatKeepsItsPipelineWhenAnotherChatPicksAnother() throws {
        let (m, dir) = model()
        defer { try? FileManager.default.removeItem(at: dir) }
        let productID = UUID()
        let going = m.conversations.newChat(for: productID)
        _ = m.conversations.appendUser("перше повідомлення", productID: productID, chatID: going.id)
        m.settlePipeline(for: going.id)
        XCTAssertEqual(m.conversations.chat(id: going.id)?.pipelineID, m.builtinChatPipeline,
                       "its first message fixed the pipeline it runs on")

        let other = m.conversations.newChat(for: UUID())
        m.choosePipeline("my-research", forChat: other.id)
        XCTAssertEqual(m.pipelineID(forChat: going.id), m.builtinChatPipeline)
        XCTAssertEqual(m.pipelineID(forChat: other.id), "my-research")

        // Settling never overrides a choice the chat already made.
        m.settlePipeline(for: other.id)
        XCTAssertEqual(m.pipelineID(forChat: other.id), "my-research")
    }

    /// A chat he had been writing in, with no pipeline of its own, followed the default on every
    /// message. Picking something else in another chat must not move it: it is pinned to what it
    /// ran on before the default changes.
    @MainActor
    func testAChatAlreadyGoingWithNoChoiceKeepsItsPipelineWhenTheDefaultMoves() throws {
        let (m, dir) = model()
        defer { try? FileManager.default.removeItem(at: dir) }
        let productID = UUID()
        let going = m.conversations.newChat(for: productID)
        _ = m.conversations.appendUser("перше", productID: productID, chatID: going.id)
        XCTAssertNil(m.conversations.chat(id: going.id)?.pipelineID, "an old chat: nothing chosen")
        let before = m.pipelineID(forChat: going.id)

        let other = m.conversations.newChat(for: UUID())
        m.choosePipeline("my-research", forChat: other.id)
        XCTAssertEqual(m.pipelineID(forChat: going.id), before, "the chat already going did not move")
        m.settlePipeline(for: going.id)
        XCTAssertEqual(m.relayPipeline(forChat: going.id), before, "and its next message goes through the same one")

        // The same from the library's «Use for new chats».
        m.setDefaultPipeline("another")
        XCTAssertEqual(m.pipelineID(forChat: going.id), before)
        XCTAssertEqual(m.pipelineID(forChat: other.id), "my-research")
    }

    /// Before this version a chat with nothing chosen ran on Claude + Codex, and the built-in has
    /// since become the Codex team. A conversation already going keeps its reviewer across the
    /// update; a chat with no messages yet starts on the new default.
    @MainActor
    func testAnUpdateKeepsOldChatsOnThePipelineTheyRanOn() throws {
        let (m, dir) = model()
        defer { try? FileManager.default.removeItem(at: dir) }
        let productID = UUID()
        let old = m.conversations.newChat(for: productID)
        _ = m.conversations.appendUser("давнє повідомлення", productID: productID, chatID: old.id)
        let empty = m.conversations.newChat(for: productID)
        _ = m.conversations.appendUser("ще одне", productID: productID, chatID: empty.id)
        m.conversations.setPipeline("", for: empty.id)
        let untouched = m.conversations.newChat(for: UUID())
        // As an older version left it: nothing chosen anywhere, nothing settled yet.
        AppSettings.startedChatsKeepPipeline = false
        m.settings.defaultPipelineID = nil
        m.conversations.setPipeline(nil, for: old.id)

        // The next launch on the same files.
        let relaunched = AppModel()
        XCTAssertEqual(relaunched.conversations.chat(id: old.id)?.pipelineID, "adaptive-peer")
        XCTAssertEqual(relaunched.relayPipeline(forChat: old.id), "adaptive-peer")
        XCTAssertEqual(relaunched.conversations.chat(id: empty.id)?.pipelineID, "adaptive-peer",
                       "an empty choice is no choice: it is settled too")
        XCTAssertTrue(AppSettings.startedChatsKeepPipeline)
        XCTAssertEqual(relaunched.pipelineID(forChat: untouched.id), "review-team",
                       "a chat nobody wrote in yet starts on the new default")

        // Done once: a later choice of his is not overwritten by a second launch.
        relaunched.choosePipeline("my-research", forChat: old.id)
        XCTAssertEqual(AppModel().conversations.chat(id: old.id)?.pipelineID, "my-research")
    }

    @MainActor
    func testANewChatStartsOnTheCodexTeamWhenNothingWasChosen() {
        let (m, dir) = model()
        defer { try? FileManager.default.removeItem(at: dir) }
        XCTAssertNil(m.settings.defaultPipelineID)
        XCTAssertEqual(m.pipelineID(forChat: m.conversations.newChat(for: UUID()).id), "review-team")
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
