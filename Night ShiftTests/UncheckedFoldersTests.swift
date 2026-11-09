import XCTest
@testable import Bulava

/// The folder the work was done in, when the check after the answer did not look at it.
///
/// The check runs in the chat's folder only. A chat left in a product's heavy default folder whose
/// agent fixed something next door used to end with nothing checked there, the changed repository
/// never checked, and the screen silent about both. These are the promises of what the chat says
/// under the answer instead: only about the answer on screen, naming the folders the engine names,
/// turning into the result of a check made from the chat — and reading that result honestly.
nonisolated final class UncheckedFoldersTests: XCTestCase {

    private func evidence(_ json: String) throws -> Evidence {
        try XCTUnwrap(Evidence.decode(from: Data(json.utf8)))
    }

    private let untouchedPrimary = """
    {"project_dir":"/w/monorepo","session_id":"s","criteria":[
      {"criterion":"tests pass","command":"npm run test","exit_code":0,"artifact":"","status":"skipped",
       "note":"nothing in this folder changed since the run began, so its suite was not run"}],
     "overall_status":"inconclusive","primary_untouched":true,"unverified_elsewhere":["/w/billing","/w/nested/lib"]}
    """

    // MARK: - What the engine writes

    func testTheEvidenceSaysWhatWentUnchecked() throws {
        let e = try evidence(untouchedPrimary)
        XCTAssertTrue(e.primaryUntouched)
        XCTAssertEqual(e.unverifiedElsewhere, ["/w/billing", "/w/nested/lib"])
    }

    func testEvidenceFromAnOlderEngineReadsAsNothingUnchecked() throws {
        let e = try evidence(#"{"project_dir":"/w/a","criteria":[],"overall_status":"pass"}"#)
        XCTAssertFalse(e.primaryUntouched)
        XCTAssertTrue(e.unverifiedElsewhere.isEmpty)
        XCTAssertNil(UncheckedFolders.make(evidence: e, writtenAt: Date(), lastAskedAt: nil, primaryName: "a",
                                           names: [:], results: [:]))
    }

    // MARK: - Which answer it is about

    func testOnlyTheCheckOfTheAnswerOnScreenCounts() throws {
        let e = try evidence(untouchedPrimary)
        let checkedAt = Date()
        XCTAssertNil(UncheckedFolders.make(evidence: e, writtenAt: checkedAt,
                                           lastAskedAt: checkedAt.addingTimeInterval(30),
                                           primaryName: "monorepo", names: [:], results: [:]),
                     "a check written before his last message was about an earlier answer")

        let report = try XCTUnwrap(UncheckedFolders.make(
            evidence: e, writtenAt: checkedAt, lastAskedAt: checkedAt.addingTimeInterval(-120),
            primaryName: "monorepo", names: ["/w/billing": ("billing-service", UUID())], results: [:]))
        XCTAssertTrue(report.primaryUntouched)
        XCTAssertEqual(report.folders.map(\.name), ["billing-service", "lib"],
                       "the product's name for its folder; a nested repository by its own name")
        XCTAssertNotNil(report.folders[0].projectID, "a product folder can be moved to")
        XCTAssertNil(report.folders[1].projectID, "a nested repository cannot")
        XCTAssertTrue(report.needsAttention)
    }

    func testACheckFromTheChatTurnsTheOfferIntoItsResult() throws {
        let e = try evidence(untouchedPrimary)
        let checkedAt = Date()
        let failed = ElsewhereResult(verdict: .failed, checks: ["tests pass"], log: "/tmp/tests.log")
        let passed = ElsewhereResult(verdict: .passed, checks: ["tests pass"])

        let stale = try XCTUnwrap(UncheckedFolders.make(
            evidence: e, writtenAt: checkedAt, lastAskedAt: nil, primaryName: "monorepo", names: [:],
            results: ["/w/billing": (passed, checkedAt.addingTimeInterval(-600))]))
        XCTAssertNil(stale.folders[0].result, "a check made before this answer's review says nothing about it")

        let report = try XCTUnwrap(UncheckedFolders.make(
            evidence: e, writtenAt: checkedAt, lastAskedAt: nil, primaryName: "monorepo", names: [:],
            results: ["/w/billing": (failed, checkedAt.addingTimeInterval(60)),
                      "/w/nested/lib": (passed, checkedAt.addingTimeInterval(60))]))
        XCTAssertEqual(report.folders[0].result, failed)
        XCTAssertFalse(report.folders[0].isSettled, "a failure stays under the answer, with its log")
        XCTAssertTrue(report.folders[1].isSettled, "a pass has said so in the thread")
        XCTAssertTrue(report.needsAttention)

        let allGood = try XCTUnwrap(UncheckedFolders.make(
            evidence: e, writtenAt: checkedAt, lastAskedAt: nil, primaryName: "monorepo", names: [:],
            results: ["/w/billing": (passed, checkedAt.addingTimeInterval(60)),
                      "/w/nested/lib": (passed, checkedAt.addingTimeInterval(60))]))
        XCTAssertFalse(allGood.needsAttention, "nothing left to say under the answer")
    }

    // MARK: - Reading a check honestly

    private func result(_ criteria: String) throws -> ElsewhereResult {
        ElsewhereResult(try evidence(#"{"project_dir":"/w/billing","criteria":[\#(criteria)],"overall_status":"x"}"#))
    }

    func testAFailureNamesWhatFailedAndWhereItsLogIs() throws {
        let r = try result(#"""
        {"criterion":"tests pass","command":"npm run test","exit_code":1,"artifact":"/tmp/t.log","status":"fail","note":""},
        {"criterion":"lint clean","command":"npm run lint","exit_code":0,"artifact":"/tmp/l.log","status":"pass","note":""}
        """#)
        XCTAssertEqual(r.verdict, .failed)
        XCTAssertEqual(r.checks, ["tests pass"])
        XCTAssertEqual(r.log, "/tmp/t.log")
    }

    func testATimeoutIsNotAFailureAndNotAPass() throws {
        let r = try result(#"""
        {"criterion":"tests pass","command":"npm run test","exit_code":142,"artifact":"/tmp/t.log","status":"inconclusive","note":"timed out after 1800s"}
        """#)
        XCTAssertEqual(r.verdict, .unfinished)
        XCTAssertFalse(r.passed)
    }

    func testAStackWithNothingToRunIsSaidAsThat() throws {
        let r = try result(#"""
        {"criterion":"automated verification","command":"(none available)","exit_code":0,"artifact":"","status":"inconclusive","note":"no automated verification available for this stack"}
        """#)
        XCTAssertEqual(r.verdict, .nothingToRun, "not a check that stopped half way")
    }

    func testAPassListsWhatRan() throws {
        let r = try result(#"""
        {"criterion":"web build succeeds","command":"npm run build","exit_code":0,"artifact":"","status":"pass","note":""},
        {"criterion":"tests pass","command":"npm run test","exit_code":0,"artifact":"","status":"pass","note":""}
        """#)
        XCTAssertEqual(r.verdict, .passed)
        XCTAssertTrue(r.sentence(folder: "billing-service").contains("billing-service"))
        XCTAssertTrue(r.sentence(folder: "billing-service").contains("tests pass"))
    }

    // MARK: - Where the files are

    func testTheClientFindsTheAnswersCheckAndTheChecksMadeFromTheChat() async throws {
        let state = FileManager.default.temporaryDirectory.appendingPathComponent("unchecked-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: state) }
        let primary = "/w/monorepo-\(UUID().uuidString.prefix(6))"
        let paths = SupervisorPaths(stateDir: state)
        let instance = paths.instanceDir(slug: Slug.forPath(primary))
        func write(_ json: String, to relative: String) throws {
            let file = instance.appendingPathComponent(relative)
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try json.write(to: file, atomically: true, encoding: .utf8)
        }
        try write(untouchedPrimary.replacingOccurrences(of: "/w/monorepo", with: primary),
                  to: "evidence/SESSION/evidence.json")
        try write(#"{"project_dir":"/w/billing","criteria":[],"overall_status":"pass"}"#,
                  to: "elsewhere/billing-1234/evidence/check/evidence.json")
        try write(#"{"project_dir":"/w/other","criteria":[],"overall_status":"fail"}"#,
                  to: "elsewhere/other-5678/evidence/check/evidence.json")

        let client = SupervisorClient(paths: paths)
        let found = await client.chatEvidenceDated(projectPath: primary, runID: nil, sessionID: "SESSION")
        let dated = try XCTUnwrap(found)
        XCTAssertEqual(dated.evidence.unverifiedElsewhere, ["/w/billing", "/w/nested/lib"])
        XCTAssertEqual(dated.base.standardizedFileURL.path, instance.standardizedFileURL.path)

        let billing = await client.elsewhereEvidence(in: dated.base, repoPath: "/w/billing")
        XCTAssertEqual(billing?.evidence.projectDir, "/w/billing", "found by what it checked, not by a guessed name")
        let none = await client.elsewhereEvidence(in: dated.base, repoPath: "/w/nested/lib")
        XCTAssertNil(none, "a folder nobody checked from the chat has no result")
    }
}
