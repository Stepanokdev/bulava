import XCTest
@testable import Bulava

nonisolated final class ReviewGateModeTests: XCTestCase {

    private func client() -> (SupervisorClient, URL) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("bulava-gate-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return (SupervisorClient(paths: SupervisorPaths(stateDir: dir)), dir)
    }

    private func marker(_ dir: URL, _ projectPath: String) -> URL {
        dir.appendingPathComponent("instances")
            .appendingPathComponent(Slug.forPath(projectPath))
            .appendingPathComponent("review-off")
    }

    // MARK: - The switch

    func testClaudeOnlyLeavesAMarkerTheHookCanRead() async throws {
        let (client, dir) = client()
        let project = "/tmp/bulava-test-project"

        try await client.setReviewGate(enabled: false, projectPath: project)

        XCTAssertTrue(FileManager.default.fileExists(atPath: marker(dir, project).path),
                      "Claude-only mode must leave the marker the Stop hook looks for")
    }

    func testTurningTheGateBackOnRemovesTheMarker() async throws {
        let (client, dir) = client()
        let project = "/tmp/bulava-test-project"

        try await client.setReviewGate(enabled: false, projectPath: project)
        try await client.setReviewGate(enabled: true, projectPath: project)

        XCTAssertFalse(FileManager.default.fileExists(atPath: marker(dir, project).path),
                       "Claude + Codex must clear the marker, or the gate stays off for good")
    }

    func testAProjectNobodyTouchedIsReviewed() {
        let (_, dir) = client()
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker(dir, "/tmp/never-seen").path))
    }

    func testTheModeIsPerProjectNotGlobal() async throws {
        let (client, dir) = client()
        let quiet = "/tmp/bulava-project-a"
        let reviewed = "/tmp/bulava-project-b"

        try await client.setReviewGate(enabled: false, projectPath: quiet)

        XCTAssertTrue(FileManager.default.fileExists(atPath: marker(dir, quiet).path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker(dir, reviewed).path),
                       "turning the gate off for one product must leave every other one reviewed")
    }

    func testWritingTheSameModeRepeatedlyIsStable() async throws {
        let (client, dir) = client()
        let project = "/tmp/bulava-test-project"

        for _ in 0..<3 { try await client.setReviewGate(enabled: false, projectPath: project) }
        XCTAssertTrue(FileManager.default.fileExists(atPath: marker(dir, project).path))

        for _ in 0..<3 { try await client.setReviewGate(enabled: true, projectPath: project) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker(dir, project).path))
    }

    // MARK: - What the mode means

    func testOnlyClaudeAndCodexReviewsWork() {
        XCTAssertTrue(ChatEngineMode.claudeAndCodex.reviewsWork)
        XCTAssertFalse(ChatEngineMode.claude.reviewsWork,
                       "Claude-only means no gate — if this flips, unreviewed work starts claiming review")
    }

    func testSettingsWithoutTheFieldDefaultToReviewed() throws {
        let json = Data(#"{"stateDirPath":"/tmp","pollSeconds":4}"#.utf8)
        let settings = try JSONDecoder().decode(AppSettings.self, from: json)
        XCTAssertEqual(settings.chatMode, .claudeAndCodex)
    }

    func testAFreshInstallIsReviewed() {
        XCTAssertEqual(AppSettings.fallback.chatMode, .claudeAndCodex)
    }
}
