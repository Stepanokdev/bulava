import XCTest
@testable import Bulava

nonisolated final class ReviewVerdictTests: XCTestCase {

    private func verdict(state: String = "COMPLETE", verdict v: String = "FAIL",
                         disposition: String = "remediation", round: Int = 1,
                         findings: String = "1. [acceptance_failure] щось не так",
                         at: String = "2026-08-31 10:00:00") -> ReviewVerdict {
        ReviewVerdict(state: state, verdict: v, disposition: disposition, round: round,
                      findings: findings, at: at)
    }

    // MARK: - What is worth showing

    func testAFailedRoundIsWorthShowing() {
        XCTAssertTrue(verdict().isWorthShowing)
    }

    func testAParkedRunIsWorthShowing() {
        XCTAssertTrue(verdict(verdict: "N/A", disposition: "needs-user").isWorthShowing)
    }

    func testQuarantinedScopeIsWorthShowing() {
        XCTAssertTrue(verdict(verdict: "PASS", disposition: "scope_violation").isWorthShowing)
    }

    func testAPassIsNotShown() {
        XCTAssertFalse(verdict(verdict: "PASS", disposition: "passed", findings: "").isWorthShowing)
    }

    func testAFailureWithNothingWrittenIsNotShown() {
        XCTAssertFalse(verdict(findings: "").isWorthShowing,
                       "there is no text to show, and a header alone says nothing")
    }

    // MARK: - Once, and only once

    func testTheSameVerdictHasTheSameIdentity() {
        XCTAssertEqual(verdict().identity, verdict().identity)
    }

    func testAnotherRoundIsAnotherVerdict() {
        XCTAssertNotEqual(verdict(round: 1).identity, verdict(round: 2).identity)
    }

    func testTheSameConclusionAtAnotherTimeIsAnotherVerdict() {
        XCTAssertNotEqual(verdict(at: "2026-08-31 10:00:00").identity,
                          verdict(at: "2026-08-31 11:00:00").identity)
    }

    func testAChangedVerdictIsAnotherVerdict() {
        XCTAssertNotEqual(verdict(verdict: "FAIL").identity, verdict(verdict: "PASS").identity)
    }
}

nonisolated final class ReviewVerdictDecodingTests: XCTestCase {

    private func client(_ dir: URL) async -> SupervisorClient {
        setenv("BULAVA_STATE_DIR", dir.path, 1)
        return SupervisorClient()
    }

    func testTheMachineryHeaderIsStripped() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("review-\(UUID().uuidString)")
        let reports = dir.appendingPathComponent("reports")
        try FileManager.default.createDirectory(at: reports, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let body = """
        STATE: COMPLETE
        VERDICT: FAIL

        1. [acceptance_failure] `File.swift:12` — щось конкретне.
        2. [scope_violation] інше.
        """
        let json: [String: Any] = ["state": "COMPLETE", "verdict": "FAIL",
                                   "disposition": "remediation", "round": 2,
                                   "findings": body, "ts": "2026-08-31 10:00:00"]
        try JSONSerialization.data(withJSONObject: json)
            .write(to: reports.appendingPathComponent("review.json"))

        let engine = await client(dir)
        let parsed = await engine.readReviewVerdictForTesting(reports.appendingPathComponent("review.json"))
        let read = try XCTUnwrap(parsed)
        XCTAssertEqual(read.round, 2)
        XCTAssertEqual(read.verdict, "FAIL")
        XCTAssertTrue(read.isWorthShowing)
        XCTAssertTrue(read.findings.hasPrefix("1. [acceptance_failure]"),
                      "the header is gone: \(read.findings.prefix(40))")
        XCTAssertFalse(read.findings.contains("VERDICT:"))
        XCTAssertTrue(read.findings.contains("2. [scope_violation]"), "and nothing else was dropped")
    }

    func testAMissingFileIsNotAVerdict() async {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let engine = await client(dir)
        let parsed = await engine.readReviewVerdictForTesting(dir.appendingPathComponent("nope.json"))
        XCTAssertNil(parsed)
    }
}
