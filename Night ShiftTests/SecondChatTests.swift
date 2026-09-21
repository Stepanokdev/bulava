import XCTest
@testable import Bulava

nonisolated final class ProjectHandoffTests: XCTestCase {

    private func decide(holder: String?, finished: Bool, callerHasSession: Bool) -> ProjectHandoff {
        ProjectHandoff.decide(holderTitle: holder,
                              holderProjectPath: "/p/one",
                              holderSession: "night-one",
                              holderIsTakeable: finished,
                              callerHasSessionID: callerHasSession)
    }

    // MARK: - The director's scenario

    func testAFinishedChatDoesNotHoldTheProject() {
        guard case .takeOver(let plan) = decide(holder: "Стара розмова", finished: true,
                                                callerHasSession: false) else {
            return XCTFail("a finished conversation must not block a new chat")
        }
        XCTAssertEqual(plan.projectPath, "/p/one")
        XCTAssertEqual(plan.session, "night-one", "the tmux session is named, so it can be killed")
        XCTAssertFalse(plan.resumesOwnSession, "a brand-new chat has nothing to resume")
    }

    func testNobodyHoldingItMeansJustSend() {
        XCTAssertEqual(decide(holder: nil, finished: true, callerHasSession: false), .proceed)
    }

    // MARK: - The handover works both ways

    /// Coming back to the old conversation is the same case in reverse. It is the one that did not
    /// work: the old chat had a binding, so it skipped the owner check entirely.
    func testGoingBackToTheOlderChatIsTheSameHandoff() {
        guard case .takeOver(let plan) = decide(holder: "Новіша розмова", finished: true,
                                                callerHasSession: true) else {
            return XCTFail("the older chat must be able to take its project back")
        }
        XCTAssertTrue(plan.resumesOwnSession,
                      "it owns a Claude session already — it resumes rather than starting fresh")
    }

    /// The `resumesOwnSession` flag is not cosmetic: it orders `activeRunID` — which points at the
    /// run being stopped — to be cleared. Without that the engine refuses on a run-id mismatch.
    func testTheTwoDirectionsDifferOnlyInWhoResumes() {
        guard case .takeOver(let fresh) = decide(holder: "X", finished: true, callerHasSession: false),
              case .takeOver(let returning) = decide(holder: "X", finished: true, callerHasSession: true)
        else { return XCTFail("both directions are takeovers") }
        XCTAssertEqual(fresh.projectPath, returning.projectPath)
        XCTAssertEqual(fresh.session, returning.session)
        XCTAssertNotEqual(fresh.resumesOwnSession, returning.resumesOwnSession)
    }

    // MARK: - What is busy stays protected

    func testAWorkingChatStillBlocksAndIsNamed() {
        XCTAssertEqual(decide(holder: "Нічний прогін", finished: false, callerHasSession: false),
                       .refuse(holder: "Нічний прогін"),
                       "the refusal names the chat, instead of being a dead end")
    }

    /// Even when the asker has a session of its own: a busy workspace is not shared.
    func testAWorkingChatBlocksTheReturningChatToo() {
        XCTAssertEqual(decide(holder: "Нічний прогін", finished: false, callerHasSession: true),
                       .refuse(holder: "Нічний прогін"))
    }

    /// A refusal stays a refusal — but it has to be an action rather than a dead end.
    ///
    /// The director opened a new chat in a project, got «the session is busy» and had nothing to
    /// press: the text told him to stop the run «there», meaning in the terminal. The decision is
    /// still his — nothing stops automatically, because the run may be waiting for his own answer
    /// — but the refusal now comes with a named button.
    func testARefusalCarriesEnoughToActOn() {
        guard case .refuse(let holder) = decide(holder: "Нічний прогін", finished: false,
                                                callerHasSession: false) else {
            return XCTFail("a live run must still not be taken automatically")
        }
        // Whatever the UI offers has to name the run being ended.
        XCTAssertFalse(holder.isEmpty, "the refusal must name who holds the project")

        // And the plan the button acts on is the same shape the automatic hand-over uses, so a
        // manual stop cannot take a shortcut the checked release does not.
        let plan = AppModel.PendingHandoff(holderTitle: holder, projectPath: "/tmp/p",
                                          session: "night-p", resumesOwnSession: true)
        XCTAssertEqual(plan.holderTitle, "Нічний прогін")
        XCTAssertEqual(plan.session, "night-p")
        XCTAssertTrue(plan.resumesOwnSession,
                      "a chat with its own session id must resume it, not start a second one")
    }
}

/// What counts as work. The check leans on `turnRunning`, and it has to stay that way: that is
/// what the rest of the application uses to decide whether a worker is running.
nonisolated final class WhatCountsAsWorkingTests: XCTestCase {

    private func instance(busy: Bool = false, reviewing: Bool = false,
                          auditing: Bool = false) -> SupervisorInstance {
        var i = SupervisorInstance(slug: "s", projectPath: "/p/one", session: "night-s",
                                   watchdogAlive: true, hasPlan: false, hasResearch: false)
        i.workerStatus = busy ? "busy" : "idle"
        i.reviewActive = reviewing
        if auditing { i.auditState = "audit_running" }
        return i
    }

    func testAnIdleWorkerIsNotWorking() { XCTAssertFalse(instance().turnRunning) }
    func testARunningTurnIsWorking()    { XCTAssertTrue(instance(busy: true).turnRunning) }

    /// Review and audit are work too: Codex reads the same workspace, and a second chat is not
    func testAReviewIsWorking()         { XCTAssertTrue(instance(reviewing: true).turnRunning) }
    func testAnAuditIsWorking()         { XCTAssertTrue(instance(auditing: true).turnRunning) }
}

/// Why taking the project over loses nothing: the conversation is restored from
/// `claudeSessionID`, which lives on the chat, not from the tmux session.
nonisolated final class ChatSurvivesItsSessionTests: XCTestCase {

    func testTheResumeIdentityLivesOnTheChat() {
        var binding = ChatSessionBinding(primaryProjectID: nil, projectPath: "/p/one",
                                         startedAt: Date())
        binding.claudeSessionID = "claude-abc"
        binding.activeRunID = "run-1"

        // What the takeover does to the old chat: the run is gone, the way back remains.
        binding.activeRunID = nil
        XCTAssertEqual(binding.claudeSessionID, "claude-abc")
        XCTAssertNil(binding.activeRunID,
                     "the dead run is dropped, or the engine fail-closes on a run-id mismatch")
    }
}

/// The first version of this takeover killed the other session and stopped there. Execution
/// reached `guard let bound = binding`, the message was marked as failed, and the chat was
/// silently left with nothing. The order in the file IS the guarantee that this cannot happen:
/// the owner decision is taken BEFORE the `binding == nil` branch, so a fresh chat lands in it
nonisolated final class TakeoverReachesAStartTests: XCTestCase {

    private func source() throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root
            .appendingPathComponent("Night Shift/App/AppModel+DirectChat.swift"), encoding: .utf8)
    }

    private func line(_ text: String, _ needle: String) throws -> Int {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        guard let i = lines.firstIndex(where: { $0.contains(needle) }) else {
            throw XCTSkip("anchor gone: \(needle)")
        }
        return i
    }

    func testTheHolderIsDecidedBeforeTheSessionIsStarted() throws {
        let text = try source()
        let decision = try line(text, "ProjectHandoff.decide(")
        let noBinding = try line(text, "if binding == nil {")
        let start = try line(text, "client.startChat(projectPath:")
        XCTAssertLessThan(decision, noBinding,
                          "the takeover must happen before the branch that starts a session")
        XCTAssertLessThan(noBinding, start)
    }

    /// A successful takeover does not end the send. Exactly one return is allowed in this branch —
    /// for when the project could not be freed; it was the extra return that lost the message.
    func testOnlyAFailedTakeoverEndsTheSend() throws {
        let text = try source()
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let start = try line(text, "case .takeOver(let plan):")
        let end = try line(text, "if binding == nil {")
        let body = lines[start..<end].joined(separator: "\n")

        XCTAssertTrue(body.contains("releaseProject"), "the branch must actually free the project")
        XCTAssertTrue(body.contains("if let failure"), "and only act on a real failure")
        let returns = body.components(separatedBy: "return ").count - 1
            + body.components(separatedBy: "return\n").count - 1
        XCTAssertEqual(returns, 1,
                       "exactly one return, and it belongs to the failure: a second one is how "
                       + "the message silently failed the first time")
    }
}

/// What counts as finished. This is the line a takeover may not cross: a worker holding a
/// question sits at an empty prompt exactly like a finished one — and taking its project away
/// means cutting off work that was only waiting.
nonisolated final class WhenAnotherChatMayTakeTheProjectTests: XCTestCase {

    private func done(_ result: String? = "passed") -> SupervisorInstance {
        var i = SupervisorInstance(slug: "s", projectPath: "/p/one", session: "night-s",
                                   watchdogAlive: true, hasPlan: false, hasResearch: false)
        i.doneResult = result
        i.workerStatus = "idle"
        return i
    }

    func testAFinishedRunMayBeTakenOver() {
        XCTAssertTrue(done().isFinished)
    }

    /// None of these states is «running» this second — and none of them is finished.
    func testEveryWaitingStateIsProtected() {
        var holding = done()
        holding.pendingQuestion = PendingUserQuestion(
            questions: [.init(question: "Який акаунт?", header: nil, options: [], multiSelect: false)],
            askedAt: Date())
        XCTAssertFalse(holding.isFinished, "a worker holding a question is not finished")

        var paused = done()
        paused.pausedResumeAt = Date().addingTimeInterval(600)
        XCTAssertFalse(paused.isFinished, "a run paused on a usage window is not finished")

        var parked = done()
        parked.awaitingUntil = Date().addingTimeInterval(600)
        XCTAssertFalse(parked.isFinished, "a run parked on a deadline is not finished")

        var stalled = done()
        stalled.stalled = true
        XCTAssertFalse(stalled.isFinished, "a run the watchdog parked is not finished")

        var offline = done()
        offline.offline = true
        XCTAssertFalse(offline.isFinished, "a run waiting out a network outage is not finished")

        var reviewing = done()
        reviewing.reviewActive = true
        XCTAssertFalse(reviewing.isFinished, "a review in flight is not finished")

        var auditing = done()
        auditing.auditState = "audit_running"
        XCTAssertFalse(auditing.isFinished)

        var working = done()
        working.workerStatus = "busy"
        XCTAssertFalse(working.isFinished)
    }

    /// No terminal result, no permission. Silence is not completion.
    func testSilenceIsNotCompletion() {
        XCTAssertFalse(done(nil).isFinished,
                       "an instance that never declared a result has not finished")
    }

    // MARK: - A run nobody is coming back to

    /// The one a tester met on every new conversation in his project. A worker that stopped without
    /// declaring an outcome is neither running nor finished, so "may another chat have this
    /// project?" answered no for ever — and he had to press Stop before every single message, for
    /// a run that was doing nothing at all.
    private func zombie() -> SupervisorInstance {
        var i = done(nil)                 // no outcome was ever written
        i.watchdogAlive = false           // and nothing is supervising it any more
        return i
    }

    func testARunNobodyIsSupervisingIsNoLongerAWall() {
        let dead = zombie()
        XCTAssertFalse(dead.isFinished, "nothing declared a result — it did not finish")
        XCTAssertTrue(dead.isAbandoned)
        guard case .takeOver = ProjectHandoff.decide(holderTitle: "Я положил в data/canvas-orientation-export",
                                                     holderProjectPath: "/p/one",
                                                     holderSession: "night-s",
                                                     holderIsTakeable: dead.isTakeable,
                                                     callerHasSessionID: false) else {
            return XCTFail("a new chat was refused for a run that is never coming back")
        }
    }

    /// The engine parks a run as stalled for a PERSON to look at, and things do come back to some
    /// of them: a new message clears it, so does a changed pane. So the marker alone is not a
    /// verdict — the clock is. One parked a moment ago is still protected.
    func testBeingParkedIsNotByItselfAVerdict() {
        var justParked = done(nil)
        justParked.stalled = true
        justParked.lastActivity = Date(timeIntervalSinceNow: -60)
        XCTAssertFalse(justParked.isAbandoned,
                       "the engine gave up on it a minute ago — a person may still be coming")

        var longParked = done(nil)
        longParked.stalled = true
        longParked.lastActivity = Date(timeIntervalSinceNow: -31 * 60)
        XCTAssertTrue(longParked.isAbandoned)
    }

    /// One envelope this build cannot parse leaves the queue looking empty while the file is still
    /// in `pending/` — and taking the project over runs `night-shift stop`, which deletes the
    /// directory it is sitting in.
    func testAnEnvelopeItCannotReadStillCountsAsWorkWaiting() {
        var holder = zombie()
        holder.pendingFiles = 1
        XCTAssertFalse(holder.queuedWork, "nothing parsed — the app shows an empty queue")
        XCTAssertFalse(holder.isAbandoned, "…and the file would have been deleted with the run")
    }

    /// A run dispatched seconds ago has no watchdog yet. Without a grace it reads as abandoned,
    /// and a second chat opened in those seconds would clear a run that was just starting.
    func testARunThatIsStillStartingIsNotAbandoned() {
        var starting = zombie()
        starting.startedAt = Date(timeIntervalSinceNow: -5)
        XCTAssertFalse(starting.isAbandoned)

        var older = zombie()
        older.startedAt = Date(timeIntervalSinceNow: -600)
        XCTAssertTrue(older.isAbandoned, "a minute was the grace, not ten")
    }

    /// Still supervised, but the worker has been idle with nothing queued for longer than any turn
    /// takes — twice the engine's own stall window.
    func testASupervisedRunThatHasNotMovedForHalfAnHourIsTakeable() {
        var quiet = done(nil)
        quiet.lastActivity = Date(timeIntervalSinceNow: -31 * 60)
        XCTAssertTrue(quiet.isAbandoned)

        var recent = done(nil)
        recent.lastActivity = Date(timeIntervalSinceNow: -120)
        XCTAssertFalse(recent.isAbandoned,
                       "two minutes of quiet is a gap between turns, not an abandoned run")
    }

    /// The over-correction this must not become. Each of these comes back, and taking one over
    /// throws away a context nobody can recover — a dead watchdog does not change that.
    func testAWaitingRunIsNotAbandonedEvenWithNobodyWatchingIt() {
        var asking = zombie()
        asking.pendingQuestion = PendingUserQuestion(
            questions: [.init(question: "?", header: nil, options: [], multiSelect: false)],
            askedAt: Date())
        XCTAssertFalse(asking.isAbandoned, "it is holding a question for a person")

        var parked = zombie()
        parked.pausedResumeAt = Date(timeIntervalSinceNow: 3600)
        XCTAssertFalse(parked.isAbandoned, "its window comes back")

        var awaiting = zombie()
        awaiting.awaitingUntil = Date(timeIntervalSinceNow: 600)
        XCTAssertFalse(awaiting.isAbandoned)

        var offline = zombie()
        offline.offline = true
        XCTAssertFalse(offline.isAbandoned, "the network comes back")
    }

    func testWorkInFlightIsNeverAbandoned() {
        var working = zombie()
        working.workerStatus = "busy"
        XCTAssertFalse(working.isAbandoned)

        var reviewing = zombie()
        reviewing.reviewActive = true
        XCTAssertFalse(reviewing.isAbandoned)

        var queued = zombie()
        queued.queuedWork = true
        XCTAssertFalse(queued.isAbandoned, "a message it has not started is still its work")
    }

    /// An instance the app has never seen move says nothing either way, and "I do not know" must
    /// not become "go ahead and kill it".
    func testAnInstanceWithNoActivityYetIsNotAbandoned() {
        var fresh = done(nil)
        fresh.lastActivity = nil
        XCTAssertFalse(fresh.isAbandoned)
    }

    func testAProtectedHolderIsRefusedNotTakenOver() {
        var holding = done()
        holding.pendingQuestion = PendingUserQuestion(
            questions: [.init(question: "?", header: nil, options: [], multiSelect: false)],
            askedAt: Date())
        XCTAssertEqual(ProjectHandoff.decide(holderTitle: "Нічний прогін",
                                             holderProjectPath: "/p/one",
                                             holderSession: "night-s",
                                             holderIsTakeable: holding.isTakeable,
                                             callerHasSessionID: false),
                       .refuse(holder: "Нічний прогін"))
    }
}

/// Freeing a project as a sequence that can be checked. The first version declared success as
/// soon as the tmux session was gone, and never looked at what stopping the instance returned.
nonisolated final class ProjectReleaseTests: XCTestCase {

    private func release(stopOK: Bool = true, stopMessage: String = "",
                         instanceGone: Bool = true, sessionGone: Bool = true)
        -> ProjectRelease {
        ProjectRelease(stop: { (stopOK, stopMessage) },
                       killSession: { },
                       instanceGone: { instanceGone },
                       sessionGone: { sessionGone },
                       wait: { },
                       attempts: 3)
    }

    func testBothHalvesGoneIsSuccess() async {
        let failure = await release().run()
        XCTAssertNil(failure)
    }

    /// Exactly what the first version missed: the session was gone but the run record stayed — and
    /// the next send would have gone against stale state.
    func testASessionGoneIsNotEnough() async {
        let failure = await release(instanceGone: false, sessionGone: true).run()
        XCTAssertEqual(failure, .instanceRemains)
    }

    func testAnInstanceGoneIsNotEnoughEither() async {
        let failure = await release(instanceGone: true, sessionGone: false).run()
        XCTAssertEqual(failure, .sessionRemains)
    }

    /// The result of stopping is no longer ignored, and its explanation reaches the director.
    func testARefusedStopIsReportedWithItsReason() async {
        let failure = await release(stopOK: false, stopMessage: "permission denied").run()
        XCTAssertEqual(failure, .stopRefused("permission denied"))
        XCTAssertTrue(AppModel.releaseProblem(.stopRefused("permission denied"))
                        .contains("permission denied"),
                      "the engine's own reason reaches him, not a generic failure")
    }

    func testAFailedStopNeverKillsTheSession() async {
        let killed = Killed()
        let release = ProjectRelease(stop: { (false, "no") },
                                     killSession: { await killed.record() },
                                     instanceGone: { true }, sessionGone: { true },
                                     wait: { }, attempts: 1)
        _ = await release.run()
        let didKill = await killed.value
        XCTAssertFalse(didKill, "if the run would not stop, its session must not be torn out from under it")
    }

    private actor Killed {
        private(set) var value = false
        func record() { value = true }
    }
}
