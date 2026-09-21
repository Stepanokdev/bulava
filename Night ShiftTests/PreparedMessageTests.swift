import XCTest
@testable import Bulava

/// A chat message that has to be prepared before the worker may read it.
///
/// The regression behind these: the composer said "Claude + Codex", the engine's environment said
/// `adaptive_peer`, and the first thing the worker was handed was the director's raw sentence. The
/// app's half of that was believing it had been delivered — and, separately, never telling the
/// engine which model or depth the composer was showing, so everything the engine started later
/// ran on its own defaults.
nonisolated final class PreparedMessageTests: XCTestCase {

    private let project = "/tmp/bulava-prepared-message"

    private func client() -> (SupervisorClient, URL) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("bulava-prepared-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(atPath: project, withIntermediateDirectories: true)
        return (SupervisorClient(paths: SupervisorPaths(stateDir: dir)), dir)
    }

    private func instanceDir(_ stateDir: URL) -> URL {
        let dir = stateDir.appendingPathComponent("instances")
            .appendingPathComponent(Slug.forPath(project))
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? project.write(to: dir.appendingPathComponent("project"),
                           atomically: true, encoding: .utf8)
        try? "night-test".write(to: dir.appendingPathComponent("session"),
                                atomically: true, encoding: .utf8)
        return dir
    }

    // MARK: - Which route a message takes

    func testOnlyTheTwoEngineModePaysForTwoIndependentPositions() {
        XCTAssertEqual(ChatEngineMode.claudeAndCodex.messagePipeline, "adaptive-peer")
        XCTAssertEqual(ChatEngineMode.claude.messagePipeline, "plain",
                       "Claude alone has no second engine to disagree with — it must not pay for one")
        XCTAssertEqual(ChatEngineMode.codex.messagePipeline, "plain")
    }

    func testClaudeOnlyDoesNotAskTheEngineForAConsultationChannel() {
        XCTAssertEqual(ChatEngineMode.claudeAndCodex.collaborationMode, "adaptive_peer")
        XCTAssertEqual(ChatEngineMode.claude.collaborationMode, "legacy",
                       "offering consult-codex in a chat Codex is not part of would be a dead link")
    }

    // MARK: - Codex-only never reaches the supervisor

    func testACodexOnlyChatDoesNotGoThroughTheEngineAtAll() {
        let route = ChatRoute.decide(mode: .codex, standIn: nil)
        XCTAssertEqual(route, .codex)
        XCTAssertFalse(route.usesSupervisor,
                       "a Codex-only message must never reach worker-send.sh — it cannot be prepared, queued or withdrawn")
    }

    func testBothClaudeModesGoThroughTheEngine() {
        for mode in [ChatEngineMode.claudeAndCodex, .claude] {
            let route = ChatRoute.decide(mode: mode, standIn: nil)
            XCTAssertEqual(route, .claude(standIn: nil))
            XCTAssertTrue(route.usesSupervisor, "\(mode) answers through the supervised session")
        }
    }

    func testCodexOutOfQuotaHandsTheMessageToClaudeOnThePlainRoute() {
        let reason = CodexStandIn.Reason.weeklyQuotaSpent(percent: 100, resetsAt: nil)
        let route = ChatRoute.decide(mode: .codex, standIn: reason)
        XCTAssertEqual(route, .claude(standIn: reason),
                       "the wall is answered by Claude, and the thread is told")
        XCTAssertTrue(route.usesSupervisor)
        XCTAssertEqual(ChatEngineMode.codex.messagePipeline, "plain",
                       "standing in for Codex must not start paying for two independent positions")
    }

    func testAClaudeModeIgnoresAnIrrelevantStandInReason() {
        let reason = CodexStandIn.Reason.weeklyQuotaSpent(percent: 100, resetsAt: nil)
        XCTAssertEqual(ChatRoute.decide(mode: .claudeAndCodex, standIn: reason), .claude(standIn: nil),
                       "Codex's quota says nothing about a chat Claude was always going to answer")
    }

    func testAPipelineNameThatIsNotOneFallsBackToPlain() {
        XCTAssertEqual(SupervisorClient.safePipelineName("adaptive-peer"), "adaptive-peer")
        XCTAssertEqual(SupervisorClient.safePipelineName("plain"), "plain")
        XCTAssertEqual(SupervisorClient.safePipelineName("../../etc/passwd"), "plain")
        XCTAssertEqual(SupervisorClient.safePipelineName("adaptive peer; rm -rf /"), "plain")
        XCTAssertEqual(SupervisorClient.safePipelineName(""), "plain")
    }

    // MARK: - What the engine is told to run on

    func testEveryChoiceTheComposerShowsIsHandedToTheEngine() {
        let env = SupervisorClient.runEnv(claudeEffort: "xhigh", claudeModel: "opus",
                                          codexEffort: "low", codexModel: "gpt-5-codex",
                                          collaboration: "adaptive_peer")
        XCTAssertEqual(env["SUPERVISOR_CLAUDE_EFFORT"], "xhigh")
        XCTAssertEqual(env["SUPERVISOR_CLAUDE_MODEL"], "opus")
        XCTAssertEqual(env["SUPERVISOR_CODEX_EFFORT"], "low",
                       "Codex's depth never left the app, so every preflight and review ran on the engine's default")
        XCTAssertEqual(env["SUPERVISOR_CODEX_MODEL"], "gpt-5-codex")
        XCTAssertEqual(env["SUPERVISOR_COLLABORATION_MODE"], "adaptive_peer")
        XCTAssertEqual(env["SUPERVISOR_RUN_ENV_FROM_APP"], "1",
                       "without this the engine cannot tell the director's choice from its own default")
    }

    func testAnUnsetChoiceIsNotSentAsAnEmptyOne() {
        let env = SupervisorClient.runEnv(claudeEffort: "", claudeModel: "",
                                          codexEffort: "", codexModel: "", collaboration: "")
        XCTAssertNil(env["SUPERVISOR_CLAUDE_EFFORT"])
        XCTAssertNil(env["SUPERVISOR_CODEX_MODEL"])
        XCTAssertEqual(env["SUPERVISOR_RUN_ENV_FROM_APP"], "1")
    }

    func testStartingAChatCarriesBothEnginesChoices() {
        let env = SupervisorClient.chatEnv(contextFile: "/tmp/ctx", extraDirsFile: "/tmp/dirs",
                                           claudeEffort: "high", claudeModel: "opus",
                                           codexEffort: "medium", codexModel: "gpt-5-codex",
                                           collaboration: "adaptive_peer")
        XCTAssertEqual(env["SUPERVISOR_CHAT_CONTEXT_FILE"], "/tmp/ctx")
        XCTAssertEqual(env["SUPERVISOR_CODEX_EFFORT"], "medium")
        XCTAssertEqual(env["SUPERVISOR_COLLABORATION_MODE"], "adaptive_peer")
    }

    // MARK: - What the app says while it waits

    private func run(preparing: Bool, busy: Bool = false) -> SupervisorInstance {
        var inst = SupervisorInstance(slug: Slug.forPath(project), projectPath: project,
                                      session: "night-test", watchdogAlive: true,
                                      hasPlan: false, hasResearch: false)
        inst.runID = "RUN-1"
        inst.preparing = preparing
        inst.queuedWork = preparing
        inst.workerStatus = busy ? "busy" : "idle"
        return inst
    }

    /// Accepted and in line, with nothing started on it.
    private func queuedRun(waiting reason: String?, pausedUntil: Date? = nil,
                           provider: String? = nil) -> SupervisorInstance {
        var inst = run(preparing: false)
        inst.queuedWork = true
        inst.queuedMessageCount = 1
        inst.queueWaitReason = reason
        inst.pausedResumeAt = pausedUntil
        inst.pauseProvider = provider
        return inst
    }

    func testPreparingIsNotCalledWorking() {
        let phase = DirectChatPhase.resolve(instance: run(preparing: true), bindingHasOutcome: false)
        XCTAssertEqual(phase, .preparing(PeerReading()),
                       "the worker has been given nothing; saying it is working is the app's version of the bug")
    }

    func testPreparingIsStillAnActivePhase() {
        XCTAssertTrue(DirectChatPhase.preparing(PeerReading()).isActive,
                      "an idle-looking header would read as finished")
        XCTAssertFalse(DirectChatPhase.preparing(PeerReading()).wantsAttention)
        XCTAssertFalse(DirectChatPhase.preparing(PeerReading()).label.isEmpty)
    }

    /// The header named both engineers whatever actually happened. A message Claude read alone,
    /// because Codex had no window left, said "Claude and Codex are reading this first" — which
    /// is the same untruth as the hour-long wait, just quieter.
    func testAMessageReadWithoutCodexSaysSo() {
        var inst = run(preparing: true)
        inst.codexUnavailable = "codex зараз недоступний — вичерпано вікно, відновлення близько 04:10"
        let phase = DirectChatPhase.resolve(instance: inst, bindingHasOutcome: false)
        XCTAssertEqual(phase, .preparing(PeerReading(codexOut: true)))
        XCTAssertNotEqual(phase.label, DirectChatPhase.preparing(PeerReading()).label,
                          "working a hand short has to read differently from working with both")
    }

    func testTheDegradationItselfIsAvailableToShow() {
        var inst = run(preparing: true)
        inst.codexUnavailable = "codex зараз недоступний — вичерпано вікно"
        XCTAssertEqual(inst.degradation, "codex зараз недоступний — вичерпано вікно")
        XCTAssertNil(run(preparing: true).degradation,
                     "nothing to say when both engineers are in")
    }

    func testAProjectBeingPreparedIsNotFreeForAnotherChatToTake() {
        XCTAssertTrue(run(preparing: true).turnRunning,
                      "two model calls are already running against this project")
        XCTAssertFalse(run(preparing: false).turnRunning)
    }

    func testWorkStillReadsAsWorkOnceItActuallyStarts() {
        let phase = DirectChatPhase.resolve(instance: run(preparing: false, busy: true),
                                            bindingHasOutcome: false)
        XCTAssertEqual(phase, .working)
    }

    func testAMessageQueuedBehindARunningTurnDoesNotRenameWhatTheWorkerIsDoing() {
        let phase = DirectChatPhase.resolve(instance: run(preparing: true, busy: true),
                                            bindingHasOutcome: false)
        XCTAssertEqual(phase, .working,
                       "the next message is waiting; the header describes the turn that is running")
    }

    // MARK: - Waiting is not reading

    /// The hour-long lie, pinned.
    ///
    /// A message sat in the queue behind a usage window that was not even Claude's, and the header
    /// said "Claude and Codex are reading this first" the whole time. Neither engine had seen it.
    func testAQueuedMessageIsNotDescribedAsBeingRead() {
        let phase = DirectChatPhase.resolve(instance: queuedRun(waiting: "turn"),
                                            bindingHasOutcome: false)
        XCTAssertEqual(phase, .queued,
                       "nothing has started on it; saying two engines are reading it is untrue")
        XCTAssertNotEqual(phase, .preparing(PeerReading()))
    }

    func testAMessageParkedBehindAUsageWindowSaysSo() {
        let back = Date().addingTimeInterval(3600)
        let phase = DirectChatPhase.resolve(instance: queuedRun(waiting: "limit", pausedUntil: back,
                                                                provider: "claude"),
                                            bindingHasOutcome: false)
        XCTAssertEqual(phase, .waitingForLimit(back))
        XCTAssertTrue(phase.label.contains(Fmt.clock(back)),
                      "the director should be able to see when it comes back")
    }

    /// Codex running out is not Claude running out, and the conversation must not look stopped.
    func testCodexRunningOutDoesNotFreezeTheConversationOnScreen() {
        var inst = run(preparing: false)
        inst.pausedResumeAt = Date().addingTimeInterval(3600)
        inst.pauseProvider = "codex"
        let phase = DirectChatPhase.resolve(instance: inst, bindingHasOutcome: false)
        XCTAssertNotEqual(phase, .waitingForLimit(inst.pausedResumeAt),
                          "Claude was never stopped; the header must not say the run is parked")
    }

    func testClaudeRunningOutDoesSayTheRunIsParked() {
        var inst = run(preparing: false)
        inst.pausedResumeAt = Date().addingTimeInterval(3600)
        inst.pauseProvider = "claude"
        XCTAssertEqual(DirectChatPhase.resolve(instance: inst, bindingHasOutcome: false),
                       .waitingForLimit(inst.pausedResumeAt))
    }

    /// A Codex window sitting in the run while the queue is really waiting for the message in
    /// front of it. Putting the wrong engine's limit on screen is the same lie in a new place.
    func testAQueueHeldByAnotherMessageDoesNotBlameAUsageWindow() {
        let inst = queuedRun(waiting: "another-message",
                             pausedUntil: Date().addingTimeInterval(3600), provider: "codex")
        XCTAssertEqual(DirectChatPhase.resolve(instance: inst, bindingHasOutcome: false), .queued)
    }

    func testWaitingStatesStillReadAsActiveWork() {
        XCTAssertTrue(DirectChatPhase.queued.isActive)
        XCTAssertTrue(DirectChatPhase.waitingForLimit(nil).isActive)
        XCTAssertFalse(DirectChatPhase.queued.wantsAttention,
                       "a queue is not a question for the director")
        XCTAssertFalse(DirectChatPhase.waitingForLimit(nil).label.isEmpty)
    }

    func testAQueuedMessageStillHoldsTheProject() {
        XCTAssertTrue(queuedRun(waiting: "turn").turnRunning,
                      "another chat taking the project would strand a message already accepted")
    }

    // MARK: - Taking a message back asks once

    /// One press of Take Back must reach the engine once.
    ///
    /// Stopping what is running and withdrawing the message are two paths in the app, and once
    /// preparation counted as running they both fired. The first took the message back; the second
    /// found nothing left and reported it read — so a message the worker had never seen was marked
    /// as read and hidden. The engine is idempotent now, and the app asks it first and stops the
    /// turn only on the strength of its answer.
    func testTakeBackAsksTheEngineBeforeStoppingAnything() throws {
        let source = try String(contentsOfFile: Self.directChatSource, encoding: .utf8)
        guard let body = Self.functionBody("func takeBackMessage(", in: source) else {
            return XCTFail("takeBackMessage is no longer where this test can read it")
        }
        let withdraw = body.range(of: "withdrawQueuedMessage")
        let stop = body.range(of: "stopDirectChat(chatID)", options: .backwards)
        XCTAssertNotNil(withdraw, "taking a message back must still ask the engine")
        if let withdraw, let stop {
            XCTAssertTrue(withdraw.lowerBound < stop.lowerBound,
                          "the engine's answer decides; stopping a turn comes after it, not before")
        }
        XCTAssertEqual(body.components(separatedBy: "withdrawQueuedMessage").count - 1, 1,
                       "the engine must be asked exactly once for one press of the button")
    }

    private static let directChatSource =
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Night Shift/App/AppModel+DirectChat.swift").path

    /// The body of a function, by brace balance from its signature.
    private static func functionBody(_ signature: String, in source: String) -> String? {
        guard let start = source.range(of: signature) else { return nil }
        var depth = 0, started = false
        var out = ""
        for ch in source[start.lowerBound...] {
            if ch == "{" { depth += 1; started = true }
            if started { out.append(ch) }
            if ch == "}" { depth -= 1; if started && depth == 0 { return out } }
        }
        return nil
    }

    // MARK: - What the app reads off disk

    func testAMessageWaitingToBePreparedCountsAsQueued() async throws {
        let (client, dir) = client()
        defer { try? FileManager.default.removeItem(at: dir) }
        let inst = instanceDir(dir)
        let pending = inst.appendingPathComponent("pending")
        try FileManager.default.createDirectory(at: pending, withIntermediateDirectories: true)
        let id = UUID()
        try #"{"seq":"00000001","pipeline":"adaptive-peer","message":"hi","message_id":"\#(id.uuidString)"}"#
            .write(to: pending.appendingPathComponent("00000001-\(id.uuidString).json"),
                   atomically: true, encoding: .utf8)

        let read = await client.readInstances().first { $0.projectPath == project }
        XCTAssertEqual(read?.queuedMessageCount, 1,
                       "the composer showed nothing waiting while a message sat unprepared")
        XCTAssertEqual(read?.queuedMessageIDs, [id],
                       "without the id there is nothing for Take Back to find")
        // The pump is started detached, so between the send and its first marker there IS no
        // preparation yet — and the app must not say "working" either. That gap now has a name of
        // its own: accepted and in line. What must never happen is the gap reading as two engines
        // already deep in the message, which is what an hour behind a usage window looked like.
        XCTAssertEqual(read?.queuedWork, true,
                       "a message accepted and not yet started still holds the conversation")
        XCTAssertEqual(read?.preparing, false,
                       "no pipeline is running yet; claiming both engines are reading it is the lie")
    }

    func testAPreparationMarkerLeftByADeadProcessIsNotBelieved() async throws {
        let (client, dir) = client()
        defer { try? FileManager.default.removeItem(at: dir) }
        let inst = instanceDir(dir)

        try #"{"pid":2147480000,"stage":"peers","message_id":"\#(UUID().uuidString)"}"#
            .write(to: inst.appendingPathComponent("pipeline-active.json"),
                   atomically: true, encoding: .utf8)
        let dead = await client.readInstances().first { $0.projectPath == project }
        XCTAssertEqual(dead?.preparing, false,
                       "a marker from a killed pipeline would leave the conversation waiting for ever")

        try #"{"pid":\#(ProcessInfo.processInfo.processIdentifier),"stage":"peers"}"#
            .write(to: inst.appendingPathComponent("pipeline-active.json"),
                   atomically: true, encoding: .utf8)
        let live = await client.readInstances().first { $0.projectPath == project }
        XCTAssertEqual(live?.preparing, true)
    }
}
