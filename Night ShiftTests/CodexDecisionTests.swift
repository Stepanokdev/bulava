import XCTest
@testable import Bulava

/// Codex has no window left, and the run is standing still until he says what to do about it.
///
/// The failure these pin down is one bug wearing two coats. In the engine, a spent Codex window
/// finished the night as REVIEW-DEBT.md and the work shipped unreviewed. In the app, the same
/// reflex answered a message as Claude and mentioned the substitution underneath the answer it had
/// already given. Both carried on a hand short rather than stopping and saying the hand was
/// missing, and both are now a question with a button — and, crucially, no default.
nonisolated final class CodexDecisionTests: XCTestCase {

    private let project = "/tmp/bulava-codex-decision"

    private func decision(state: String = "exhausted", resetsAt: Date? = nil,
                          choices: [String] = ["wait", "claude"]) -> CodexDecision {
        CodexDecision(id: "REQ-1", stage: "review", state: state, resetsAt: resetsAt,
                      reason: "codex зараз недоступний — вичерпано вікно", askedAt: Date(),
                      choices: choices)
    }

    // MARK: - The card

    /// The answer travels back by POSITION, so the options must keep the engine's order. Matching
    /// on the words would make what a press means depend on the interface language.
    func testTheOptionsKeepTheOrderTheEngineOfferedThemIn() {
        let question = SupervisorClient.question(forCodex: decision())
        let options = try? XCTUnwrap(question.questions.first?.options)
        XCTAssertEqual(options?.count, 2)
        XCTAssertEqual(question.questions.first?.options.count,
                       decision().choices.count,
                       "one button per choice, or the index the answer is read back by is wrong")
    }

    func testTheCardIsAddressedToOneRequestAndSaysWhatItIsAbout() {
        let question = SupervisorClient.question(forCodex: decision())
        XCTAssertEqual(question.reasonCode, "codex_unavailable")
        XCTAssertEqual(question.toolUseID, "codex-decision:REQ-1",
                       "a permission must name the question it answers, or a leftover file unlocks the next run")
    }

    /// A weekly window five days out, printed as a bare clock time, reads as minutes away. That
    /// exact sentence once had the director asking why Codex was being called out of window.
    func testAResetDaysAwayIsShownWithItsDayNotJustTheTime() {
        let inFiveDays = Date().addingTimeInterval(5 * 86_400)
        let headline = SupervisorClient.question(forCodex: decision(resetsAt: inFiveDays)).headline
        XCTAssertTrue(headline.contains(Fmt.stamp(inFiveDays)), headline)
        XCTAssertFalse(headline.isEmpty)
    }

    /// Zero is the engine saying "it would not tell me". Rendering that as 1 Jan 1970 and calling
    /// it a reset time is worse than admitting there is none.
    func testAMissingResetIsSaidInWordsRatherThanShownAsATime() {
        let headline = SupervisorClient.question(forCodex: decision(resetsAt: nil)).headline
        XCTAssertFalse(headline.contains("1970"), headline)
    }

    /// Nothing on this card may read as "and if you say nothing, we carry on". That is precisely
    /// the behaviour it replaces, and the ask-user channel — which does time out — is deliberately
    /// a different file for the same reason.
    func testDoingNothingLeavesTheRunParked() {
        let question = SupervisorClient.question(forCodex: decision())
        let fallback = try? XCTUnwrap(question.defaultAction)
        XCTAssertNotNil(fallback)
        XCTAssertFalse((fallback ?? "").isEmpty,
                       "the card has to say what happens if he never answers, and the answer is: nothing")
    }

    /// Every failure used to come up as "Codex has no window left", which sends the reader off to
    /// wait out a limit while the real problem is a dead login or a call that never came back —
    /// and waiting fixes neither.
    func testEachKindOfUnavailableSaysWhatItActuallyIs() {
        var seen: Set<String> = []
        for state in ["exhausted", "signed_out", "timeout", "silent", "tampered", "failed"] {
            let headline = SupervisorClient.question(forCodex: decision(state: state)).headline
            XCTAssertFalse(headline.isEmpty, state)
            XCTAssertTrue(seen.insert(headline).inserted,
                          "\(state) shares its wording with another cause: \(headline)")
        }
    }

    /// Built from the same resource the app renders, so the claim holds in any interface language.
    ///
    /// The first version of this looked for the English word "window". It passed on a machine
    /// whose bundle resolved to English and failed on the Ukrainian one — a claim about wording
    /// that was only true in one locale, which is worse than no claim at all: it reported green
    /// here and red in the verifier.
    func testOnlyASpentWindowIsDescribedAsASpentWindow() {
        let template = String(localized: "Codex has no window left (%@) — wait for it, or go on with Claude?")
        let stem = String(template.prefix(while: { $0 != "(" }))
        XCTAssertFalse(stem.trimmingCharacters(in: .whitespaces).isEmpty,
                       "the template changed shape — this check needs updating with it")

        let spent = SupervisorClient.question(forCodex: decision(state: "exhausted")).headline
        XCTAssertTrue(spent.hasPrefix(stem), spent)

        for other in ["signed_out", "timeout", "silent", "tampered", "failed"] {
            let headline = SupervisorClient.question(forCodex: decision(state: other)).headline
            XCTAssertFalse(headline.hasPrefix(stem),
                           "\(other) is described as a spent window, and waiting will not fix it: \(headline)")
        }
    }

    /// The engine writes down exactly what went wrong. It was being stored and never shown, so the
    /// card carried a classification and no evidence for it.
    func testTheEngineOwnReasonReachesTheCard() {
        let question = SupervisorClient.question(forCodex: decision(state: "timeout"))
        XCTAssertEqual(question.situation, decision().reason)
        XCTAssertEqual(question.record.situation, decision().reason,
                       "the card reads `situation`; a reason that stops here is a reason nobody sees")
    }

    // MARK: - Held before it starts

    /// Not a pause with a countdown — nothing has started, so there is no marker to read a time
    /// off. Calling it "in line" is the silence this whole change exists to remove.
    func testAMessageHeldForCodexSaysSoWithNoTimeToShow() {
        var inst = idleRun()
        inst.queuedWork = true
        inst.queuedMessageCount = 1
        inst.queueWaitReason = "codex"
        let phase = DirectChatPhase.resolve(instance: inst, bindingHasOutcome: false)
        XCTAssertEqual(phase, .waitingForCodex(nil))
        XCTAssertNotEqual(phase, .queued)
    }

    /// An engine in two halves is not a wait: waiting does not make the installed hook newer.
    func testAMismatchedEngineAsksToBeReinstalledRatherThanWaitedOut() {
        var inst = idleRun()
        inst.queuedWork = true
        inst.queuedMessageCount = 1
        inst.queueWaitReason = "engine-mismatch"
        let phase = DirectChatPhase.resolve(instance: inst, bindingHasOutcome: false)
        XCTAssertEqual(phase, .engineMismatch)
        XCTAssertTrue(phase.wantsAttention, "nothing will prepare until somebody reinstalls it")
        XCTAssertFalse(phase.label.isEmpty)
    }

    // MARK: - Reading the engine's file

    func testADecisionWithNoChoicesIsNotACard() async throws {
        let (client, stateDir) = makeClient()
        let dir = instanceDir(stateDir)
        try #"{"id":"REQ-9","choices":[]}"#.write(to: dir.appendingPathComponent("codex-decision.json"),
                                                  atomically: true, encoding: .utf8)
        let inst = await client.snapshot().instances.first { $0.slug == Slug.forPath(project) }
        XCTAssertNil(inst?.codexDecision,
                     "a question with nothing to press is a run parked with no way out")
    }

    func testTheAnswerNamesTheRequestItAnswers() async throws {
        let (client, stateDir) = makeClient()
        let dir = instanceDir(stateDir)
        await client.answerCodexDecision(slug: Slug.forPath(project), requestID: "REQ-1",
                                         choice: "claude")
        let data = try Data(contentsOf: dir.appendingPathComponent("codex-decision-answer.json"))
        let obj = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(obj["request_id"] as? String, "REQ-1")
        XCTAssertEqual(obj["choice"] as? String, "claude")
    }

    // MARK: - A parked run must look parked

    /// The app used to hide a Codex pause outright, and it was right to while a spent Codex window
    /// stopped nothing. Now that nothing finishes without Codex, hiding it leaves a run standing
    /// still under a label that says it is merely in line.
    func testARunParkedOnCodexSaysSoOnScreen() {
        var inst = idleRun()
        inst.pausedResumeAt = Date().addingTimeInterval(4 * 86_400)
        inst.pauseProvider = "codex"
        let phase = DirectChatPhase.resolve(instance: inst, bindingHasOutcome: false)
        XCTAssertEqual(phase, .waitingForCodex(inst.pausedResumeAt))
        XCTAssertNotEqual(phase, .waitingForLimit(inst.pausedResumeAt),
                          "Claude was never stopped — that label belongs to his own window")
        XCTAssertFalse(phase.label.isEmpty)
        XCTAssertTrue(phase.isActive, "an idle-looking header would read as finished")
    }

    /// And the question outranks the wait: a card with a button is not "waiting", it is waiting
    /// for HIM.
    func testAPendingDecisionOutranksTheWaitItCameFrom() {
        var inst = idleRun()
        inst.pausedResumeAt = Date().addingTimeInterval(4 * 86_400)
        inst.pauseProvider = "codex"
        inst.codexDecision = decision()
        inst.pendingQuestion = SupervisorClient.question(forCodex: decision())
        XCTAssertEqual(DirectChatPhase.resolve(instance: inst, bindingHasOutcome: false),
                       .needsAttention)
    }

    // MARK: - The offer in a direct chat

    @MainActor
    private func conversationStore() -> (ConversationStore, [URL]) {
        let dir = FileManager.default.temporaryDirectory
        let a = dir.appendingPathComponent("conv-\(UUID().uuidString).json")
        let b = dir.appendingPathComponent("chats-\(UUID().uuidString).json")
        return (ConversationStore(fileURL: a, chatsURL: b), [a, b])
    }

    /// It lived in a dictionary keyed by chat and held only in memory. Overnight the explanation
    /// and the button were gone and the message just sat there marked "not delivered".
    @MainActor
    func testTheOfferToUseClaudeSurvivesARelaunch() throws {
        let (store, files) = conversationStore()
        defer { files.forEach { try? FileManager.default.removeItem(at: $0) } }
        let product = UUID(), chat = UUID()
        let entry = store.appendUser("почни", productID: product, chatID: chat)
        store.updateDelivery(entryID: entry.id, .failed)
        store.setCodexWall(entryID: entry.id, "Codex витратив 100% тижня.")

        let reopened = ConversationStore(fileURL: files[0], chatsURL: files[1])
        XCTAssertEqual(reopened.entry(id: entry.id)?.codexWall, "Codex витратив 100% тижня.",
                       "the offer has to be on disk, or it does not exist tomorrow morning")
    }

    /// One key per chat meant the second refused message showed the first one's offer, and
    /// pressing it re-sent the wrong text.
    @MainActor
    func testTwoRefusedMessagesEachKeepTheirOwnOffer() {
        let (store, files) = conversationStore()
        defer { files.forEach { try? FileManager.default.removeItem(at: $0) } }
        let product = UUID(), chat = UUID()
        let first = store.appendUser("перше", productID: product, chatID: chat)
        let second = store.appendUser("друге", productID: product, chatID: chat)
        store.setCodexWall(entryID: first.id, "перша стіна")
        store.setCodexWall(entryID: second.id, "друга стіна")
        XCTAssertEqual(store.entry(id: first.id)?.codexWall, "перша стіна")
        XCTAssertEqual(store.entry(id: second.id)?.codexWall, "друга стіна")

        XCTAssertEqual(store.consumeCodexWall(entryID: first.id), "перша стіна")
        XCTAssertNil(store.entry(id: first.id)?.codexWall, "using one must not leave it usable")
        XCTAssertEqual(store.entry(id: second.id)?.codexWall, "друга стіна",
                       "and must not touch the other message's offer")
    }

    /// A second press, or a button still on screen in a window that has not refreshed, must come
    /// to nothing rather than send the message a second time.
    @MainActor
    func testAnOfferIsUsableExactlyOnce() {
        let (store, files) = conversationStore()
        defer { files.forEach { try? FileManager.default.removeItem(at: $0) } }
        let entry = store.appendUser("почни", productID: UUID(), chatID: UUID())
        store.setCodexWall(entryID: entry.id, "стіна")
        XCTAssertNotNil(store.consumeCodexWall(entryID: entry.id))
        XCTAssertNil(store.consumeCodexWall(entryID: entry.id))
        XCTAssertNil(store.consumeCodexWall(entryID: UUID()), "and an unknown entry offers nothing")
    }

    // MARK: - Fixtures

    private func makeClient() -> (SupervisorClient, URL) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("bulava-codex-decision-\(UUID().uuidString)")
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

    private func idleRun() -> SupervisorInstance {
        var inst = SupervisorInstance(slug: Slug.forPath(project), projectPath: project,
                                      session: "night-test", watchdogAlive: true,
                                      hasPlan: false, hasResearch: false)
        inst.runID = "RUN-1"
        inst.workerStatus = "idle"
        return inst
    }
}
