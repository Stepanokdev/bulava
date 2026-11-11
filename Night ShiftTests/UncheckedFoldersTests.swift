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
            results: ["/w/billing": .init(passed, at: checkedAt.addingTimeInterval(-600))]))
        XCTAssertNil(stale.folders[0].result, "a check made before this answer's review says nothing about it")

        let report = try XCTUnwrap(UncheckedFolders.make(
            evidence: e, writtenAt: checkedAt, lastAskedAt: nil, primaryName: "monorepo", names: [:],
            results: ["/w/billing": .init(failed, at: checkedAt.addingTimeInterval(60)),
                      "/w/nested/lib": .init(passed, at: checkedAt.addingTimeInterval(60))]))
        XCTAssertEqual(report.folders[0].result, failed)
        XCTAssertFalse(report.folders[0].isSettled, "a failure stays under the answer, with its log")
        XCTAssertTrue(report.folders[1].isSettled, "a pass has said so in the thread")
        XCTAssertTrue(report.needsAttention)

        let allGood = try XCTUnwrap(UncheckedFolders.make(
            evidence: e, writtenAt: checkedAt, lastAskedAt: nil, primaryName: "monorepo", names: [:],
            results: ["/w/billing": .init(passed, at: checkedAt.addingTimeInterval(60)),
                      "/w/nested/lib": .init(passed, at: checkedAt.addingTimeInterval(60))]))
        XCTAssertFalse(allGood.needsAttention, "nothing left to say under the answer")
    }

    /// The engine names a repository after every answer while it differs from the start of the run.
    /// A check made from the chat since, of the very tree this answer's check found, still stands:
    /// "not checked" under an answer that never touched it would be untrue.
    func testACheckOfTheSameTreeStillStandsUnderALaterAnswer() throws {
        let e = try evidence("""
        {"project_dir":"/w/monorepo","criteria":[],"overall_status":"inconclusive",
         "unverified_elsewhere":["/w/billing"],"unverified_elsewhere_digests":{"/w/billing":"TREE-A"}}
        """)
        XCTAssertEqual(e.unverifiedElsewhereDigests, ["/w/billing": "TREE-A"])
        let answeredAt = Date()
        let passed = ElsewhereResult(verdict: .passed, checks: ["tests pass"])

        let same = try XCTUnwrap(UncheckedFolders.make(
            evidence: e, writtenAt: answeredAt, lastAskedAt: nil, primaryName: "monorepo", names: [:],
            results: ["/w/billing": .init(passed, at: answeredAt.addingTimeInterval(-600), digest: "TREE-A")]))
        XCTAssertEqual(same.folders[0].result, passed)
        XCTAssertFalse(same.needsAttention, "checked, and nothing changed there since")

        let changed = try XCTUnwrap(UncheckedFolders.make(
            evidence: e, writtenAt: answeredAt, lastAskedAt: nil, primaryName: "monorepo", names: [:],
            results: ["/w/billing": .init(passed, at: answeredAt.addingTimeInterval(-600), digest: "TREE-B")]))
        XCTAssertNil(changed.folders[0].result, "the tree moved on since that check: it says nothing now")

        let older = try evidence(untouchedPrimary)
        let noDigest = try XCTUnwrap(UncheckedFolders.make(
            evidence: older, writtenAt: answeredAt, lastAskedAt: nil, primaryName: "monorepo", names: [:],
            results: ["/w/billing": .init(passed, at: answeredAt.addingTimeInterval(-600), digest: "")]))
        XCTAssertNil(noDigest.folders[0].result, "no digest on either side proves nothing")
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
        let reworded = try result(#"""
        {"criterion":"automated verification","command":"(none available)","exit_code":0,"artifact":"","status":"inconclusive","note":"nothing here to run"}
        """#)
        XCTAssertEqual(reworded.verdict, .nothingToRun, "known by the command it names, not by the prose after it")
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

        XCTAssertTrue(dated.runIsLive)
        let billing = await client.elsewhereEvidence(in: dated.checkRoots, repoPath: "/w/billing")
        XCTAssertEqual(billing?.evidence.projectDir, "/w/billing", "found by what it checked, not by a guessed name")
        let none = await client.elsewhereEvidence(in: dated.checkRoots, repoPath: "/w/nested/lib")
        XCTAssertNil(none, "a folder nobody checked from the chat has no result")
    }

    /// The run was stopped: the engine moved its evidence and its checks to the run's archive and
    /// removed the instance. What was checked is still read; nothing more can be checked from it.
    func testAStoppedRunKeepsItsChecksAndOffersNoNewOne() async throws {
        let state = FileManager.default.temporaryDirectory.appendingPathComponent("unchecked-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: state) }
        let primary = "/w/monorepo-\(UUID().uuidString.prefix(6))"
        let paths = SupervisorPaths(stateDir: state)
        let archive = paths.runDir(runID: "RUN-1")
        func write(_ text: String, to relative: String) throws {
            let file = archive.appendingPathComponent(relative)
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try text.write(to: file, atomically: true, encoding: .utf8)
        }
        try write(untouchedPrimary.replacingOccurrences(of: "/w/monorepo", with: primary),
                  to: "evidence/SESSION/evidence.json")
        // Its log named where it was before the stop: inside the instance, which is gone.
        let gone = paths.instanceDir(slug: Slug.forPath(primary))
            .appendingPathComponent("elsewhere/billing-1234/evidence/check/tests-pass.log").path
        try write(#"{"project_dir":"/w/billing","criteria":[{"criterion":"tests pass","command":"npm run test","exit_code":1,"artifact":"\#(gone)","status":"fail","note":""}],"overall_status":"fail"}"#,
                  to: "elsewhere/billing-1234/evidence/check/evidence.json")
        try write("1 failing", to: "elsewhere/billing-1234/evidence/check/tests-pass.log")

        let client = SupervisorClient(paths: paths)
        let found = await client.chatEvidenceDated(projectPath: primary, runID: "RUN-1", sessionID: "SESSION")
        let dated = try XCTUnwrap(found)
        XCTAssertFalse(dated.runIsLive, "nothing holds the folder for this run any more")
        XCTAssertEqual(dated.runID, "RUN-1")

        let checked = await client.elsewhereEvidence(in: dated.checkRoots, repoPath: "/w/billing")
        let billing = try XCTUnwrap(checked)
        let log = try XCTUnwrap(ElsewhereResult(billing.evidence).log)
        XCTAssertTrue(FileManager.default.fileExists(atPath: log), "its log opens from the archive: \(log)")

        let report = try XCTUnwrap(UncheckedFolders.make(
            evidence: dated.evidence, writtenAt: dated.at, lastAskedAt: nil, primaryName: "monorepo", names: [:],
            results: [:], runID: dated.runID, canCheck: dated.runIsLive))
        XCTAssertFalse(report.canCheck, "a stopped run has nothing left to check from")
    }

    /// Another chat started in the folder since: the folder's run is not this answer's.
    func testAFolderNowHeldByAnotherRunIsNotThisAnswersToCheckIn() async throws {
        let state = FileManager.default.temporaryDirectory.appendingPathComponent("unchecked-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: state) }
        let primary = "/w/monorepo-\(UUID().uuidString.prefix(6))"
        let paths = SupervisorPaths(stateDir: state)
        let archive = paths.runDir(runID: "RUN-1")
        let file = archive.appendingPathComponent("evidence/SESSION/evidence.json")
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try untouchedPrimary.replacingOccurrences(of: "/w/monorepo", with: primary)
            .write(to: file, atomically: true, encoding: .utf8)
        let instance = paths.instanceDir(slug: Slug.forPath(primary))
        try FileManager.default.createDirectory(at: instance, withIntermediateDirectories: true)
        try "RUN-2".write(to: instance.appendingPathComponent("run-id"), atomically: true, encoding: .utf8)

        let client = SupervisorClient(paths: paths)
        let found = await client.chatEvidenceDated(projectPath: primary, runID: "RUN-1", sessionID: "SESSION")
        let dated = try XCTUnwrap(found)
        XCTAssertFalse(dated.runIsLive)
        XCTAssertFalse(dated.checkRoots.contains { $0.standardizedFileURL == instance.standardizedFileURL },
                       "the other run's checks are not this answer's")
    }
}
