import XCTest
@testable import Bulava

/// The built-in "Claude + a Codex team" is chosen by name in the composer, so its name follows the
/// app's language; a pipeline somebody named keeps the name they gave it, whatever its copy carries.
/// Read from the real `pipeline-tool.py list` of this checkout, the way the picker gets it.
nonisolated final class PipelineNamesTests: XCTestCase {

    nonisolated(unsafe) private var savedLanguage: AppLanguage = .system
    nonisolated(unsafe) private var state: URL!

    override func setUpWithError() throws {
        savedLanguage = AppLanguage(rawValue: LanguageBundle.currentCode) ?? .system
        state = FileManager.default.temporaryDirectory.appendingPathComponent("names-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: state, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        LanguageBundle.adopt(savedLanguage)
        try? FileManager.default.removeItem(at: state)
    }

    private func library() throws -> [PipelineSummary] {
        let tool = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("engine/bin/pipeline-tool.py")
        try XCTSkipUnless(FileManager.default.fileExists(atPath: tool.path), "no checkout beside the tests")
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        p.arguments = [tool.path, "list"]
        p.environment = ["PYTHONDONTWRITEBYTECODE": "1", "HOME": state.path, "SUPERVISOR_STATE_DIR": state.path]
        let out = Pipe(); p.standardOutput = out
        try p.run(); p.waitUntilExit()
        struct Listing: Decodable { var pipelines: [PipelineSummary] }
        return try JSONDecoder().decode(Listing.self, from: out.fileHandleForReading.readDataToEndOfFile()).pipelines
    }

    func testTheTeamPipelineIsBuiltInAndNamedInTheAppsLanguage() throws {
        let team = try XCTUnwrap(try library().first { $0.id == "review-team" }, "the engine does not list review-team")
        XCTAssertTrue(team.isBuiltin)
        XCTAssertTrue(team.runnable)
        XCTAssertTrue((team.guarantees ?? []).contains { $0.k == "team" }, "the picker should say a team reviews")

        LanguageBundle.adopt(.uk)
        XCTAssertEqual(team.displayName, "Claude + команда Codex")
        LanguageBundle.adopt(.en)
        XCTAssertEqual(team.displayName, "Claude + a Codex team")
        XCTAssertTrue(team.localizedDescription?.hasPrefix("Same as Claude + Codex") == true)
    }

    func testTheDefaultIsStillClaudeAndCodex() throws {
        let all = try library()
        XCTAssertEqual(ChatEngineMode.claudeAndCodex.messagePipeline, "adaptive-peer")
        LanguageBundle.adopt(.en)
        XCTAssertEqual(all.first { $0.id == "adaptive-peer" }?.displayName, "Claude + Codex")
    }

    /// The editor's title reads the description itself, not the library row.
    func testTheEditorTitleFollowsTheLanguageForABuiltInOnly() throws {
        let tool = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("engine/supervisor/pipelines/manifests/review-team/pipeline.json")
        try XCTSkipUnless(FileManager.default.fileExists(atPath: tool.path), "no checkout beside the tests")
        let doc = try JSONDecoder().decode(PipelineDocument.self, from: Data(contentsOf: tool))
        LanguageBundle.adopt(.en)
        XCTAssertEqual(doc.displayName, "Claude + a Codex team")
        LanguageBundle.adopt(.uk)
        XCTAssertEqual(doc.displayName, "Claude + команда Codex")
        var copy = doc
        copy.builtin = nil
        copy.name = "Моя команда"
        LanguageBundle.adopt(.en)
        XCTAssertEqual(copy.displayName, "Моя команда")
    }

    func testACopyKeepsTheNameItWasGiven() {
        var copy = PipelineSummary(id: "my-team", kind: "user", name: "Моя команда")
        copy.i18n = ["en": ["name": "Claude + a Codex team"]]
        LanguageBundle.adopt(.en)
        XCTAssertEqual(copy.displayName, "Моя команда")
    }
}
