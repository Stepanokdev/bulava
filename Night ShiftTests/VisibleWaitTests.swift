import XCTest
@testable import Bulava

nonisolated final class VisibleWaitTests: XCTestCase {

    private func instance(reason: String?, until: Date?) -> SupervisorInstance {
        var inst = SupervisorInstance(slug: "s", projectPath: "/tmp/p", session: "x",
                                      watchdogAlive: true, hasPlan: false, hasResearch: false)
        inst.awaitingUntil = until
        inst.awaitingReason = reason
        return inst
    }

    private func executing() -> BacklogTask {
        var task = BacklogTask(title: "t", projectPath: "/tmp/p", type: .feature,
                               priority: .p2, state: .executing)
        task.dispatchedAt = Date()
        return task
    }

    // MARK: - Which wait is it

    func testCodexWindowWaitIsNotAboutHim() {
        let until = Date().addingTimeInterval(900)
        let wait = instance(reason: "waiting for codex window reset", until: until).awaitingWait
        XCTAssertEqual(wait?.kind, .codexWindow)
        XCTAssertEqual(wait?.until, until)
    }

    func testDirectorWaitIsAboutHim() {
        let wait = instance(reason: "awaiting director decision",
                            until: Date().addingTimeInterval(60)).awaitingWait
        XCTAssertEqual(wait?.kind, .director, "a question that cleared the gates is his to answer")
    }

    func testAnUnlabelledWaitIsTreatedAsNeedingHim() {
        XCTAssertEqual(instance(reason: nil, until: Date().addingTimeInterval(60)).awaitingWait?.kind,
                       .director)
    }

    func testNoDeadlineIsNoWait() {
        XCTAssertNil(instance(reason: "waiting for codex window reset", until: nil).awaitingWait)
    }

    // MARK: - The card says it

    func testTheCodexWindowWaitGetsItsOwnSentenceAndDeadline() {
        let until = Date().addingTimeInterval(1_200)
        let line = WorkProgress.nowLine(task: executing(),
                                        instance: instance(reason: "waiting for codex window reset",
                                                           until: until))
        XCTAssertEqual(line?.key, "Codex is out of usage. Picks up by itself.")
        XCTAssertEqual(line?.until, until, "the deadline reaches the view, not just the model")
    }

    func testTheDirectorWaitSaysSo() {
        let line = WorkProgress.nowLine(task: executing(),
                                        instance: instance(reason: "awaiting director decision",
                                                           until: Date().addingTimeInterval(300)))
        XCTAssertEqual(line?.key, "Holding for your decision.")
    }

    func testAHeldQuestionStillOutranksItsOwnDeadline() {
        var inst = instance(reason: "awaiting director decision", until: Date().addingTimeInterval(300))
        inst.pendingQuestion = PendingUserQuestion(
            questions: [.init(question: "Який акаунт брати?", header: nil, options: [], multiSelect: false)],
            askedAt: Date())
        XCTAssertEqual(WorkProgress.nowLine(task: executing(), instance: inst)?.key,
                       "A worker is waiting on your answer.")
    }

    func testTheUsagePauseNowCarriesItsDeadline() {
        let at = Date().addingTimeInterval(3_600)
        var inst = SupervisorInstance(slug: "s", projectPath: "/tmp/p", session: "x",
                                      watchdogAlive: true, hasPlan: false, hasResearch: false)
        inst.pausedResumeAt = at
        let line = WorkProgress.nowLine(task: executing(), instance: inst)
        XCTAssertEqual(line?.key, "Paused on a usage limit. Resumes automatically.")
        XCTAssertEqual(line?.until, at)
    }

    func testWorkingHasNoCountdown() {
        let inst = SupervisorInstance(slug: "s", projectPath: "/tmp/p", session: "x",
                                      watchdogAlive: true, hasPlan: false, hasResearch: false)
        XCTAssertNil(WorkProgress.nowLine(task: executing(), instance: inst)?.until)
    }

    // MARK: - The readout stays honest

    func testAPassedDeadlineDoesNotCountBackwards() {
        let text = Fmt.resetsCompact(Date().addingTimeInterval(-500))
        XCTAssertEqual(text, String(localized: "now"))
        XCTAssertFalse(text?.contains("-") ?? false)
    }

    func testAFutureDeadlineReadsAsTimeLeft() {
        XCTAssertNotNil(Fmt.resetsCompact(Date().addingTimeInterval(4_000)))
        XCTAssertNotEqual(Fmt.resetsCompact(Date().addingTimeInterval(4_000)), String(localized: "now"))
    }
}
