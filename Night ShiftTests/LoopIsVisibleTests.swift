import XCTest
@testable import Bulava

nonisolated final class LoopIsVisibleTests: XCTestCase {

    private func executing() -> BacklogTask {
        var t = BacklogTask(title: "t", projectPath: "/tmp/p", type: .feature, priority: .p2, state: .executing)
        t.dispatchedAt = Date()
        return t
    }

    private func instance(_ progress: ReviewProgress?) -> SupervisorInstance {
        var i = SupervisorInstance(slug: "s", projectPath: "/tmp/p", session: "x",
                                   watchdogAlive: true, hasPlan: false, hasResearch: false)
        i.reviewProgress = progress
        return i
    }

    // MARK: - Converging or spinning

    func testFewerDefectsThanLastRoundIsConverging() {
        let p = ReviewProgress(kind: .review, round: 3, max: 8, findings: 4,
                               previousFindings: 9, stall: 0, stallLimit: 2)
        XCTAssertTrue(p.isConverging)
        XCTAssertFalse(p.isStalling)
    }

    func testTheSameDefectsRoundAfterRoundIsStalling() {
        let p = ReviewProgress(kind: .review, round: 5, max: 8, findings: 4,
                               previousFindings: 4, stall: 2, stallLimit: 2)
        XCTAssertFalse(p.isConverging)
        XCTAssertTrue(p.isStalling, "the gate is counting down to parking this for him")
    }

    func testAFirstRoundClaimsNoDirection() {
        let p = ReviewProgress(kind: .review, round: 1, max: 8, findings: 6,
                               previousFindings: nil, stall: 0, stallLimit: 2)
        XCTAssertFalse(p.isConverging)
        XCTAssertFalse(p.isStalling)
    }

    // MARK: - What the card says

    func testTheReviewLineCarriesTheRoundAndBothCounts() {
        var inst = instance(ReviewProgress(kind: .review, round: 3, max: 8, findings: 4,
                                           previousFindings: 9, stall: 0, stallLimit: 2))
        inst.reviewActive = true
        let line = WorkProgress.nowLine(task: executing(), instance: inst)
        XCTAssertEqual(line?.key, "Codex is reviewing the result.")
        let detail = try? XCTUnwrap(line?.detail)
        XCTAssertTrue(detail?.contains("3") ?? false, "the round is named")
        XCTAssertTrue(detail?.contains("8") ?? false, "so is the budget left")
        XCTAssertTrue(detail?.contains("4") ?? false, "and what is still open")
        XCTAssertTrue(detail?.contains("9") ?? false, "\"4 defects\" means nothing without \"was 9\"")
    }

    func testWorkSentBackKeepsItsActivityAndGainsTheRound() {
        let inst = instance(ReviewProgress(kind: .review, round: 2, max: 8, findings: 3,
                                           previousFindings: 5, stall: 0, stallLimit: 2))
        let line = WorkProgress.nowLine(task: executing(), instance: inst,
                                        activity: .init(key: "reads %@", object: "A.kt", at: Date()))
        XCTAssertEqual(line?.key, "reads %@", "the live activity is not replaced by the counter")
        XCTAssertTrue(line?.detail?.contains("2") ?? false)
    }

    func testANightNudgeIsVisible() {
        var inst = instance(ReviewProgress(kind: .nudge, round: 2, max: 8, findings: nil,
                                           previousFindings: nil, stall: nil, stallLimit: nil))
        inst.workerStatus = "busy"
        let line = WorkProgress.nowLine(task: executing(), instance: inst)
        XCTAssertNotNil(line?.detail)
        XCTAssertTrue(line?.detail?.contains("2") ?? false)
    }

    func testAScopedRunNamesItsSingleFixIteration() {
        let phrase = WorkProgress.loopPhrase(
            ReviewProgress(kind: .remediation, round: 1, max: 1, findings: nil,
                           previousFindings: nil, stall: nil, stallLimit: nil))
        XCTAssertNotNil(phrase)
        XCTAssertTrue(phrase?.contains("1") ?? false)
    }

    // MARK: - And what it must not say

    func testAnOrdinaryRunShowsNoRound() {
        XCTAssertNil(WorkProgress.loopPhrase(nil))
        let line = WorkProgress.nowLine(task: executing(), instance: instance(nil),
                                        activity: .init(key: "reads %@", object: "A.kt", at: Date()))
        XCTAssertNil(line?.detail, "nothing is looping, so nothing is claimed")
    }

    func testAMissingBudgetDoesNotPrintZero() {
        let phrase = WorkProgress.loopPhrase(
            ReviewProgress(kind: .review, round: 2, max: 0, findings: nil,
                           previousFindings: nil, stall: nil, stallLimit: nil))
        XCTAssertFalse(phrase?.contains("0") ?? false, "an unknown budget is not a budget of zero")
    }

    func testAHeldQuestionStillComesFirst() {
        var inst = instance(ReviewProgress(kind: .review, round: 3, max: 8, findings: 4,
                                           previousFindings: 9, stall: 0, stallLimit: 2))
        inst.pendingQuestion = PendingUserQuestion(
            questions: [.init(question: "Який акаунт?", header: nil, options: [], multiSelect: false)],
            askedAt: Date())
        XCTAssertEqual(WorkProgress.nowLine(task: executing(), instance: inst)?.key,
                       "A worker is waiting on your answer.")
    }
}
