import XCTest
@testable import Bulava

nonisolated final class CodexStreamTests: XCTestCase {

    private enum Fixture {
        static let threadStarted = #"{"type":"thread.started","thread_id":"01a04f9e-8705-7503-9416-8b88192e2ed9"}"#
        static let turnStarted   = #"{"type":"turn.started"}"#
        static let message       = #"{"type":"item.completed","item":{"id":"item_0","type":"agent_message","text":"готово"}}"#
        static let commandBegun  = #"{"type":"item.started","item":{"id":"item_1","type":"command_execution","command":"cat a.txt","aggregated_output":"","exit_code":null,"status":"in_progress"}}"#
        static let commandDone   = #"{"type":"item.completed","item":{"id":"item_1","type":"command_execution","command":"cat a.txt","aggregated_output":"hello\n","exit_code":0,"status":"completed"}}"#
        static let commandFailed = #"{"type":"item.completed","item":{"id":"item_1","type":"command_execution","command":"cat nope.txt","aggregated_output":"cat: nope.txt: No such file or directory\n","exit_code":1,"status":"failed"}}"#
        static let turnCompleted = #"{"type":"turn.completed","usage":{"input_tokens":15754,"cached_input_tokens":9984,"output_tokens":6,"reasoning_output_tokens":0}}"#

        static let unknownItem   = #"{"type":"item.completed","item":{"id":"item_7","type":"file_change","changes":[{"path":"a.swift"}]}}"#
    }

    // MARK: - Decoding

    func testAThreadIdIsWhatMakesTheNextMessageAResume() {
        guard case .threadStarted(let id)? = CodexEvent.decode(line: Fixture.threadStarted).first else {
            return XCTFail("thread.started did not decode")
        }
        XCTAssertEqual(id, "01a04f9e-8705-7503-9416-8b88192e2ed9")
    }

    func testAnAgentMessageDecodesWithItsId() {
        guard case .item(let item)? = CodexEvent.decode(line: Fixture.message).first else {
            return XCTFail("agent_message did not decode")
        }
        XCTAssertEqual(item.id, "item_0")
        XCTAssertEqual(item.type, "agent_message")
        XCTAssertEqual(item.text, "готово")
        XCTAssertTrue(item.finished)
    }

    func testACommandCarriesItsExitCodeAndStatus() {
        guard case .item(let item)? = CodexEvent.decode(line: Fixture.commandDone).first else {
            return XCTFail("command_execution did not decode")
        }
        XCTAssertEqual(item.command, "cat a.txt")
        XCTAssertEqual(item.exitCode, 0)
        XCTAssertEqual(item.status, "completed")
    }

    func testUsageComesOffTheCompletedTurn() {
        guard case .turnCompleted(let usage)? = CodexEvent.decode(line: Fixture.turnCompleted).first else {
            return XCTFail("turn.completed did not decode")
        }
        XCTAssertEqual(usage.inputTokens, 15754)
        XCTAssertEqual(usage.cachedInputTokens, 9984)
        XCTAssertEqual(usage.outputTokens, 6)
    }

    func testNothingUnreadableThrowsOrEndsTheStream() {
        for line in ["", "   ", "not json at all", "{}", #"{"type":"something.new"}"#, #"{"type":"item.completed"}"#] {
            XCTAssertEqual(CodexEvent.decode(line: line), [.ignored], "unreadable line must be ignored: \(line)")
        }
    }

    // MARK: - Reducing

    func testACommandThatStartsAndFinishesIsOneBlockNotTwo() {
        var reducer = CodexTurnReducer()
        _ = reducer.accept(CodexEvent.decode(line: Fixture.commandBegun)[0])
        XCTAssertEqual(reducer.blocks.count, 1)
        XCTAssertEqual(reducer.blocks[0].activity?.status, .running)

        _ = reducer.accept(CodexEvent.decode(line: Fixture.commandDone)[0])
        XCTAssertEqual(reducer.blocks.count, 1, "same item id must rewrite the block, not append a second")
        XCTAssertEqual(reducer.blocks[0].activity?.status, .done)
    }

    func testAFailedCommandSaysWhyAndOnlyThen() {
        var reducer = CodexTurnReducer()
        _ = reducer.accept(CodexEvent.decode(line: Fixture.commandFailed)[0])
        XCTAssertEqual(reducer.blocks[0].activity?.status, .failed)
        XCTAssertEqual(reducer.blocks[0].activity?.detail, "cat: nope.txt: No such file or directory")

        var ok = CodexTurnReducer()
        _ = ok.accept(CodexEvent.decode(line: Fixture.commandDone)[0])
        XCTAssertNil(ok.blocks[0].activity?.detail,
                     "a successful command's output belongs in the log, not in the conversation")
    }

    func testAnUnknownItemKindIsKeptVerbatim() {
        var reducer = CodexTurnReducer()
        _ = reducer.accept(CodexEvent.decode(line: Fixture.unknownItem)[0])

        XCTAssertEqual(reducer.blocks.count, 1)
        XCTAssertEqual(reducer.blocks[0].kind, .unknown)
        XCTAssertTrue(reducer.blocks[0].text.contains("file_change"),
                      "the raw item must survive so nothing is lost from the transcript")
    }

    func testOnlyACompletedTurnEndsTheTurn() {
        var reducer = CodexTurnReducer()
        _ = reducer.accept(CodexEvent.decode(line: Fixture.threadStarted)[0])
        _ = reducer.accept(CodexEvent.decode(line: Fixture.turnStarted)[0])
        _ = reducer.accept(CodexEvent.decode(line: Fixture.message)[0])
        _ = reducer.accept(CodexEvent.decode(line: Fixture.commandBegun)[0])
        XCTAssertFalse(reducer.isFinished, "a message and a running command do not end a turn")

        _ = reducer.accept(CodexEvent.decode(line: Fixture.turnCompleted)[0])
        XCTAssertTrue(reducer.isFinished)
        XCTAssertEqual(reducer.threadID, "01a04f9e-8705-7503-9416-8b88192e2ed9")
    }

    func testTheWholeTurnKeepsArrivalOrder() {
        var reducer = CodexTurnReducer()
        for line in [Fixture.threadStarted, Fixture.turnStarted, Fixture.message,
                     Fixture.commandBegun, Fixture.commandDone, Fixture.turnCompleted] {
            for event in CodexEvent.decode(line: line) { _ = reducer.accept(event) }
        }
        XCTAssertEqual(reducer.blocks.map(\.kind), [.markdown, .activity])
        XCTAssertEqual(reducer.blocks.map(\.id), ["item_0", "item_1"])
    }

    func testAFailureEndsTheTurnAndIsVisible() {
        var reducer = CodexTurnReducer()
        let events = CodexEvent.decode(line: #"{"type":"turn.failed","message":"You've hit your usage limit."}"#)
        for event in events { _ = reducer.accept(event) }

        XCTAssertTrue(reducer.isFinished)
        XCTAssertEqual(reducer.failure, "You've hit your usage limit.")
        XCTAssertEqual(reducer.blocks.first?.kind, .error)
    }

    // MARK: - The command

    func testGlobalFlagsComeBeforeTheResumeSubcommand() {
        let args = CodexChatRunner.arguments(threadID: "01a0-thread", effort: "", prompt: "hi")
        guard let resume = args.firstIndex(of: "resume"),
              let sandbox = args.firstIndex(of: "--sandbox") else {
            return XCTFail("expected both a sandbox flag and a resume subcommand")
        }
        XCTAssertLessThan(sandbox, resume, "a global flag after `resume` is rejected by the CLI")
        XCTAssertEqual(args[resume + 1], "01a0-thread", "the thread id must follow `resume`")
    }

    func testAFirstMessageStartsAThreadRatherThanResumingNothing() {
        let args = CodexChatRunner.arguments(threadID: nil, effort: "", prompt: "hi")
        XCTAssertFalse(args.contains("resume"))
        XCTAssertEqual(args.last, "hi")
    }

    func testAnEmptyThreadIdIsTreatedAsNoThread() {
        XCTAssertFalse(CodexChatRunner.arguments(threadID: "", effort: "", prompt: "hi").contains("resume"))
    }

    /// Silence is not neutral. `codex` with no effort flag reads `~/.codex/config.toml`, and that
    /// file is where a person's own `xhigh` lives — so "Automatic" was quietly the most expensive
    /// setting the app had. Every command names a depth.
    func testEveryMessageNamesItsOwnDepth() {
        let auto = CodexChatRunner.arguments(threadID: nil, effort: "", prompt: "hi").joined(separator: " ")
        XCTAssertTrue(auto.contains("model_reasoning_effort="),
                      "no effort flag means the machine's global default takes over")
        XCTAssertTrue(auto.contains("model_reasoning_effort=\"\(CodexEffortChoice.conversationDefault.rawValue)\""))

        let pinned = CodexChatRunner.arguments(threadID: nil, effort: "high", prompt: "hi")
        XCTAssertTrue(pinned.joined(separator: " ").contains("model_reasoning_effort=\"high\""))
    }

    func testTheDepthMenuOffersOnlyLevelsTheModelsSupport() {
        // `minimal` was in the menu and no gpt-5.6 model accepts it; `xhigh` and `max` are what
        // the CLI's own catalogue lists and they were missing.
        let offered = Set(CodexEffortChoice.allCases.map(\.rawValue))
        XCTAssertFalse(offered.contains("minimal"))
        for level in ["low", "medium", "high", "xhigh", "max"] {
            XCTAssertTrue(offered.contains(level), "\(level) is a level Codex supports")
        }
    }

    func testAutomaticResolvesToANamedDepth() {
        XCTAssertFalse(CodexEffortChoice.auto.flagValue.isEmpty)
        XCTAssertEqual(CodexEffortChoice.auto.flagValue,
                       CodexEffortChoice.conversationDefault.rawValue)
        for choice in CodexEffortChoice.allCases {
            XCTAssertFalse(choice.flagValue.isEmpty, "\(choice.rawValue) must name a depth")
        }
    }

    /// A stored `minimal` from an older build must not crash or resurrect itself.
    func testARetiredDepthFallsBackToAutomatic() throws {
        let json = #"{"stateDirPath":"/tmp","pollSeconds":4,"codexEffort":"minimal"}"#
        let settings = try JSONDecoder().decode(AppSettings.self, from: Data(json.utf8))
        XCTAssertEqual(settings.codexEffort, .auto)
    }

    func testApprovalsAreNeverEscalated() {
        XCTAssertTrue(CodexChatRunner.arguments(threadID: nil, effort: "", prompt: "hi")
            .joined(separator: " ").contains("approval_policy=\"never\""))
    }

    // MARK: - The mode

    func testOnlyCodexModeSkipsClaudeEntirely() {
        XCTAssertFalse(ChatEngineMode.codex.usesClaude)
        XCTAssertTrue(ChatEngineMode.claude.usesClaude)
        XCTAssertTrue(ChatEngineMode.claudeAndCodex.usesClaude)
    }

    func testCodexOnlyDoesNotClaimToReviewAnything() {
        XCTAssertFalse(ChatEngineMode.codex.reviewsWork)
    }

    func testAChatCanHoldBothASessionAndAThread() {
        var binding = ChatSessionBinding(primaryProjectID: nil, projectPath: "/tmp/p")
        binding.claudeSessionID = "claude-1"
        binding.codexThreadID = "codex-1"
        XCTAssertEqual(binding.claudeSessionID, "claude-1")
        XCTAssertEqual(binding.codexThreadID, "codex-1")
    }

    func testItemsWithoutIdsDoNotOverwriteEachOther() {
        var reducer = CodexTurnReducer()
        let line = #"{"type":"item.completed","item":{"type":"agent_message","text":"one"}}"#
        let other = #"{"type":"item.completed","item":{"type":"agent_message","text":"two"}}"#
        for event in CodexEvent.decode(line: line) { _ = reducer.accept(event) }
        for event in CodexEvent.decode(line: other) { _ = reducer.accept(event) }

        XCTAssertEqual(reducer.blocks.count, 2)
        XCTAssertEqual(reducer.blocks.map(\.text), ["one", "two"])
    }
}
