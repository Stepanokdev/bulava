import XCTest
@testable import Bulava

nonisolated final class ParkedRunReportTests: XCTestCase {

    func testEveryStoppedRunHasSomethingToShow() {
        func task(_ state: TaskState) -> BacklogTask {
            BacklogTask(title: "t", projectPath: "/tmp/p", type: .feature, priority: .p2, state: state)
        }
        XCTAssertTrue(AppModel.hasStopped(task(.review)),  "a result waiting to be read")
        XCTAssertTrue(AppModel.hasStopped(task(.blocked)), "parked on an external wall — still a result")
        XCTAssertTrue(AppModel.hasStopped(task(.failed)),  "a failure is a result too")

        XCTAssertFalse(AppModel.hasStopped(task(.executing)), "still moving")
        XCTAssertFalse(AppModel.hasStopped(task(.ready)),     "not started")
        XCTAssertFalse(AppModel.hasStopped(task(.approved)),  "already accepted and folded away")
    }
}

nonisolated final class ReviewReasonTests: XCTestCase {

    @MainActor
    private func client(_ dir: URL) -> SupervisorClient {
        SupervisorClient(paths: SupervisorPaths(stateDir: dir))
    }

    @MainActor
    func testTheVerdictHeaderIsMachineryAndTheNumberedPointsAreTheReason() async {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("bulava-review-\(UUID().uuidString)")
        let slug = Slug.forPath("/tmp/pocket-ledger")
        let reports = dir.appendingPathComponent("instances/\(slug)/reports")
        try? FileManager.default.createDirectory(at: reports, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let findings = """
        STATE: COMPLETE
        VERDICT: FAIL

        1. Посилання з листа відкриває Safari — lawria.ai не віддає .well-known файли.
        2. AC-006 недоведено: немає запису, що гілка не тягне зміни з main.
        """
        let json = try! JSONSerialization.data(withJSONObject: ["findings": findings, "verdict": "FAIL"])
        try? json.write(to: reports.appendingPathComponent("review.json"))

        let reason = await client(dir).reviewReason(slug: slug)
        guard let reason else { return XCTFail("the reviewer's reason was not read") }
        XCTAssertTrue(reason.hasPrefix("1."), "starts at the first real point")
        XCTAssertFalse(reason.contains("VERDICT:"), "the header is machinery, not a reason")
        XCTAssertTrue(reason.contains(".well-known"), "and it carries what he actually has to act on")
    }

    @MainActor
    func testNoReviewFileMeansNoInventedReason() async {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("bulava-review-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let none = await client(dir).reviewReason(slug: "nothing-here")
        XCTAssertNil(none)
    }
}
