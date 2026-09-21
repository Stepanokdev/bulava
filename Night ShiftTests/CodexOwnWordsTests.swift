import XCTest
@testable import Bulava

/// When Claude asks Codex something, the thread has to show what Codex said — not only the
/// paraphrase of it.
///
/// The old stream kept a tool result's content only when it was an error, so the answer to every
/// successful consultation was discarded on the way in. What reached the conversation was "runs
/// codex exec …" in a collapsed step trace, and then a summary with nothing behind it.
nonisolated final class CodexOwnWordsTests: XCTestCase {

    // MARK: - Recognising the question

    func testRunningCodexIsRecognisedAsAskingIt() {
        let consult = AgentConsult.recognise(
            tool: "Bash",
            input: ["command": "codex exec --sandbox read-only 'review the diff on this branch'"])
        XCTAssertEqual(consult?.agent, "Codex")
        XCTAssertEqual(consult?.ask, "review the diff on this branch")
    }

    func testAFullPathToCodexIsStillCodex() {
        XCTAssertNotNil(AgentConsult.recognise(
            tool: "Bash",
            input: ["command": "/Users/me/.nvm/versions/node/v22/bin/codex exec 'is this safe to ship'"]))
    }

    /// A false positive pastes somebody's shell output into the conversation as if an agent had
    /// said it, so the word appearing in a command is not enough.
    func testTheWordAppearingInACommandIsNotAConsultation() {
        for command in ["grep -rn codex engine/bin",
                        "cat ~/.codex/config.toml",
                        "ls engine/bin/codex-usage.sh",
                        "echo 'codex is a tool'",
                        "git log --oneline | head"] {
            XCTAssertNil(AgentConsult.recognise(tool: "Bash", input: ["command": command]),
                         "‘\(command)’ is not a question to Codex")
        }
    }

    func testOnlyShellCallsCanBeAConsultation() {
        XCTAssertNil(AgentConsult.recognise(tool: "Read", input: ["file_path": "/tmp/codex"]))
        XCTAssertNil(AgentConsult.recognise(tool: "Bash", input: [:]))
    }

    /// Config flags carry `key=value`, and one of those read as the question in the first cut.
    func testAConfigFlagIsNotMistakenForTheQuestion() {
        let consult = AgentConsult.recognise(
            tool: "Bash",
            input: ["command": "codex exec -c model_reasoning_effort=\"low\" --json 'what changed in the review gate'"])
        XCTAssertEqual(consult?.ask, "what changed in the review gate")
    }

    func testAWrapperInFrontOfCodexIsStillCodex() {
        for command in ["timeout 180 codex exec 'does the fence still hold'",
                        "env -u OPENAI_API_KEY codex exec 'does the fence still hold'",
                        "SUPERVISOR_X=1 codex exec 'does the fence still hold'"] {
            XCTAssertEqual(
                AgentConsult.recognise(tool: "Bash", input: ["command": command])?.ask,
                "does the fence still hold", "‘\(command)’")
        }
    }

    func testCodexAsAnArgumentToAnotherCommandIsNotAnInvocation() {
        for command in ["rg codex 'engine/bin' --files-with-matches",
                        "head -c 200 codex exec",
                        "python3 tools/scan.py codex exec 'not a question'"] {
            XCTAssertNil(AgentConsult.recognise(tool: "Bash", input: ["command": command]),
                         "‘\(command)’")
        }
    }

    func testCodexAfterAPipeIsStillAnInvocation() {
        XCTAssertNotNil(AgentConsult.recognise(
            tool: "Bash", input: ["command": "cat prompt.md | codex exec --json"]))
    }

    /// Whatever the answer is piped THROUGH is not the question.
    func testWhatFollowsTheCallIsNotReadAsTheQuestion() {
        XCTAssertEqual(
            AgentConsult.recognise(
                tool: "Bash",
                input: ["command": "codex exec --json | jq -r 'select(.type == \"item.completed\")'"])?.ask,
            "")
    }

    func testAskingWithNoReadableQuestionStillCountsAsAsking() {
        let consult = AgentConsult.recognise(
            tool: "Bash", input: ["command": "codex exec --json < /tmp/prompt.txt"])
        XCTAssertNotNil(consult, "the consultation happened even if the question is in a file")
        XCTAssertEqual(consult?.ask, "", "a question that cannot be read is not invented")
    }

    // MARK: - Keeping the answer

    private func consultTurn(answer: String, isError: Bool = false) -> TurnReducer {
        var reducer = TurnReducer()
        let ask = "codex exec 'review the diff on this branch'"
        for event in AgentEvent.decode(line: #"""
        {"type":"assistant","message":{"id":"msg_1","content":[
          {"type":"tool_use","id":"toolu_9","name":"Bash","input":{"command":"\#(ask)"}}]}}
        """#) {
            reducer.accept(event)
        }
        reducer.accept(.toolResult(id: "toolu_9", isError: isError,
                                   detail: isError ? "exit 1" : nil, output: answer))
        return reducer
    }

    func testTheAnswerIsKeptAndAttributedToCodex() {
        let reducer = consultTurn(answer: "VERDICT: FAIL\n\nThe scope fence was widened.")
        guard let card = reducer.blocks.first(where: { $0.kind == .consult }) else {
            return XCTFail("expected a card holding what Codex said")
        }
        XCTAssertEqual(card.activity?.object, "Codex")
        XCTAssertEqual(card.activity?.detail, "review the diff on this branch")
        XCTAssertTrue(card.text.contains("VERDICT: FAIL"))
        XCTAssertEqual(card.activity?.status, .done)

        // And the step trace still has its own row, so nothing was taken away.
        XCTAssertTrue(reducer.blocks.contains { $0.kind == .activity && $0.id == "toolu_9" })
    }

    func testTheCardIsThereWhileTheAnswerIsStillComing() {
        var reducer = TurnReducer()
        for event in AgentEvent.decode(line: #"""
        {"type":"assistant","message":{"id":"m","content":[
          {"type":"tool_use","id":"t1","name":"Bash","input":{"command":"codex exec 'is the fence intact'"}}]}}
        """#) {
            reducer.accept(event)
        }
        let card = reducer.blocks.first { $0.kind == .consult }
        XCTAssertEqual(card?.activity?.status, .running)
        XCTAssertTrue(card?.isRenderable == true, "a two-minute wait must be visible")
    }

    func testAFailedConsultationSaysSoRatherThanLookingAnswered() {
        let reducer = consultTurn(answer: "You've hit your usage limit.", isError: true)
        XCTAssertEqual(reducer.blocks.first { $0.kind == .consult }?.activity?.status, .failed)
    }

    func testAnEmptyAnswerIsNamedRatherThanShownAsBlank() {
        let reducer = consultTurn(answer: "")
        XCTAssertFalse(reducer.blocks.first { $0.kind == .consult }?.text.isEmpty ?? true)
    }

    /// Output from calls that were NOT a consultation must not be kept: `ls` in the conversation
    /// store is noise, and a build log would be megabytes of it.
    func testOrdinaryCommandOutputIsNotKept() {
        var reducer = TurnReducer()
        for event in AgentEvent.decode(line: #"""
        {"type":"assistant","message":{"id":"m","content":[
          {"type":"tool_use","id":"t2","name":"Bash","input":{"command":"ls -la"}}]}}
        """#) {
            reducer.accept(event)
        }
        reducer.accept(.toolResult(id: "t2", isError: false, detail: nil,
                                   output: "a very long directory listing"))
        XCTAssertFalse(reducer.blocks.contains { $0.kind == .consult })
        XCTAssertFalse(reducer.blocks.contains { $0.text.contains("directory listing") })
    }

    /// One pathological answer must not be written into the store forever.
    func testAnEnormousAnswerIsCapped() {
        let huge = String(repeating: "x", count: AgentConsult.answerLimit * 2)
        let line = #"{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"t3","content":"\#(huge)"}]}}"#
        guard case .toolResult(_, _, _, let output)? = AgentEvent.decode(line: line).first else {
            return XCTFail("expected a tool result")
        }
        XCTAssertNotNil(output)
        XCTAssertLessThanOrEqual(output!.count, AgentConsult.answerLimit + 4)
    }

    // MARK: - Four cards a user photographed, none of them Codex speaking

    /// Every one of these was in the thread under "Codex replied". The user's reaction was that
    /// Codex's answers "look strange" — they were not answers at all.

    func testAskingCodexForItsHelpIsNotAConsultation() {
        XCTAssertNil(AgentConsult.recognise(tool: "Bash", input: ["command": "codex --help"]),
                     "its usage text was shown in the thread as a reply to a question nobody asked")
        XCTAssertNil(AgentConsult.recognise(tool: "Bash", input: ["command": "codex -h"]))
        XCTAssertNil(AgentConsult.recognise(tool: "Bash", input: ["command": "codex --version"]))
        XCTAssertNil(AgentConsult.recognise(tool: "Bash",
                                            input: ["command": "codex exec --help"]),
                     "still the manual, whatever subcommand it is attached to")
    }

    func testARealAskIsStillRecognised() {
        XCTAssertNotNil(AgentConsult.recognise(
            tool: "Bash", input: ["command": "codex exec resume --last 'does this hold up'"]))
        XCTAssertNotNil(AgentConsult.recognise(
            tool: "Bash", input: ["command": "codex review"]))
    }

    /// The screenshot of a card whose whole content was the harness saying it had backgrounded the
    /// command. The answer is not in this result and never will be.
    func testABackgroundedCallIsNotAnAnswer() {
        let notice = """
        Command running in background with ID: bk0ajk7fk. Output is being written to:         /private/tmp/claude-501/tasks/bk0ajk7fk.output. You will be notified when it completes.
        """
        XCTAssertEqual(AgentAnswer.classify(output: notice, isError: false), .startedInBackground)

        let reducer = consultTurn(answer: notice)
        let card = reducer.blocks.first { $0.kind == .consult }
        XCTAssertEqual(card?.activity?.status, .running, "it has not answered — it has been started")
        XCTAssertFalse(card?.text.contains("bk0ajk7fk") == true,
                       "a task id is not something Codex said")
    }

    /// `codex exec resume --sandbox …`: a flag that subcommand does not take. What came back was
    /// the CLI explaining itself, shown as a four-line answer from Codex.
    func testACommandLineErrorIsAFailureNotAnAnswer() {
        let cliError = """
        error: unexpected argument '--sandbox' found

          tip: to pass '--sandbox' as a value, use '-- --sandbox'

        Usage: codex exec resume <SESSION_ID> [PROMPT]

        For more information, try '--help'.
        """
        guard case .failed(let why) = AgentAnswer.classify(output: cliError, isError: false) else {
            return XCTFail("the CLI refusing its own arguments is not an answer")
        }
        XCTAssertTrue(why.contains("unexpected argument"), "say what went wrong: \(why)")

        let reducer = consultTurn(answer: cliError)
        let card = reducer.blocks.first { $0.kind == .consult }
        XCTAssertEqual(card?.activity?.status, .failed)
    }

    /// The first screenshot: forty-five lines of `codex exec --help`. Nothing recognises it as a
    /// consultation any more, and if a wrapper ever prints it anyway it is a failure, not a review.
    func testTheUsageTextIsNeverPresentedAsAnAnswer() {
        let help = """
        Run Codex non-interactively

        Usage: codex exec [OPTIONS] [PROMPT]

        Commands: resume  Resume a previous session by id
        Options: -c, --config <key=value>  Override a configuration value
        """
        guard case .failed = AgentAnswer.classify(output: help, isError: false) else {
            return XCTFail("a page of usage text was shown as Codex's reply")
        }
    }

    /// And the thing this whole mechanism exists for still works.
    func testARealReviewIsStillAnAnswer() {
        let review = "RECOMMENDATION\n\nRequest changes: the claim is still racy."
        XCTAssertEqual(AgentAnswer.classify(output: review, isError: false), .answered(review))
        let card = consultTurn(answer: review).blocks.first { $0.kind == .consult }
        XCTAssertEqual(card?.activity?.status, .done)
        XCTAssertTrue(card?.text.contains("still racy") == true)
    }

    // MARK: - What a second reading of this change turned up

    /// When a turn ends, every card still marked running is swept to done. A background card that
    /// said "the answer arrives when it finishes" would therefore finish, with a tick, promising
    /// something this thread never receives.
    func testABackgroundCardPromisesNothingItCannotDeliver() {
        var reducer = consultTurn(answer: "Command running in background with ID: bk0ajk7fk.")
        reducer.accept(.turnFinished(subtype: "success", sessionID: nil, isError: false))
        let card = reducer.blocks.first { $0.kind == .consult }
        XCTAssertEqual(card?.activity?.status, .done, "the turn is over — the card cannot stay busy")
        XCTAssertFalse(card?.text.contains("bk0ajk7fk") == true)
        XCTAssertTrue(card?.text.contains("background") == true || card?.text.contains("фон") == true,
                      "it has to say where the answer went: \(card?.text ?? "")")
    }

    /// A review is entitled to discuss an unexpected argument. Matching the phrase rather than the
    /// shape of a command-line failure threw such a review away as a failure.
    func testAReviewThatDiscussesAnArgumentErrorIsStillAnAnswer() {
        let review = """
        RECOMMENDATION

        The parser accepts an unexpected argument without complaint, which is how the bad flag
        reached production. Reject it instead.
        """
        guard case .answered = AgentAnswer.classify(output: review, isError: false) else {
            return XCTFail("Codex's review was discarded because of a phrase inside it")
        }
    }

    /// `codex exec 'review this' --help` prints the manual. Reading the question and returning
    /// early meant the flag that says so was never reached.
    func testAHelpFlagAfterTheQuestionStillCountsAsTheManual() {
        XCTAssertNil(AgentConsult.recognise(
            tool: "Bash", input: ["command": "codex exec 'review this change please' --help"]),
                     "what comes back is the usage text, whatever was asked before it")
    }
}
