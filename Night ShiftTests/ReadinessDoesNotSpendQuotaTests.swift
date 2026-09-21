import XCTest
@testable import Bulava

/// Two of the readiness checks are paid calls — `claude -p` and `codex exec` — and the Codex one
/// costs about sixteen thousand input tokens. They ran on the twenty-minute background refresh,
/// which on an ordinary day meant forty-five unasked-for Codex sessions out of the same weekly
/// quota as the real work. This pins down when they are allowed to run.
nonisolated final class ReadinessDoesNotSpendQuotaTests: XCTestCase {

    func testTheBackgroundRefreshDoesNotProbeAgainstAFreshVerdict() {
        let proven = Date()
        XCTAssertFalse(PreflightRunner.paidProbesAreDue(
            provenAt: proven, now: proven.addingTimeInterval(20 * 60), depth: .free))
        XCTAssertFalse(PreflightRunner.paidProbesAreDue(
            provenAt: proven, now: proven.addingTimeInterval(6 * 60 * 60), depth: .free))
    }

    func testAVerdictOlderThanADayIsProvenAgain() {
        let proven = Date()
        XCTAssertTrue(PreflightRunner.paidProbesAreDue(
            provenAt: proven,
            now: proven.addingTimeInterval(PreflightRunner.paidProbeTTL + 1), depth: .free))
    }

    func testNothingProvenYetAlwaysProbes() {
        XCTAssertTrue(PreflightRunner.paidProbesAreDue(provenAt: nil, depth: .free))
    }

    /// Opening the readiness screen, or being about to start work, is someone waiting on the
    /// answer. That always asks for real.
    func testAPersonWaitingAlwaysGetsAFreshAnswer() {
        XCTAssertTrue(PreflightRunner.paidProbesAreDue(provenAt: Date(), depth: .full))
    }
}
