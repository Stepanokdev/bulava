import XCTest
@testable import Bulava

/// The pipeline editor judges with this build's rules, not with whatever engine copy is installed.
///
/// 20 Oct: after the update to 1.15 the installed engine stayed at an older build, because it is
/// replaced only when nothing is working, and the editor asked THAT copy. «Повний цикл», a role
/// pipeline 1.15 runs, was shown with eight errors: "more than one edge enters input context".
nonisolated final class PipelineToolFollowsTheAppTests: XCTestCase {

    nonisolated(unsafe) private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("tool-\(UUID().uuidString)")
        for name in ["dev", "bundled", "installed"] {
            let bin = root.appendingPathComponent("\(name)/bin")
            try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
            try Data().write(to: bin.appendingPathComponent("pipeline-tool.py"))
        }
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    private func home(_ name: String) -> URL { root.appendingPathComponent(name) }
    private func tool(_ name: String) -> String { home(name).appendingPathComponent("bin/pipeline-tool.py").path }

    func testTheAppsOwnCopyIsAskedBeforeTheInstalledOne() {
        XCTAssertEqual(SupervisorClient.pipelineTool(development: nil, bundled: home("bundled"), installed: home("installed")),
                       tool("bundled"))
    }

    func testBulavaDevAsksTheCheckout() {
        XCTAssertEqual(SupervisorClient.pipelineTool(development: home("dev"), bundled: home("bundled"), installed: home("installed")),
                       tool("dev"))
    }

    func testWithoutACopyInTheAppTheInstalledOneAnswers() {
        XCTAssertEqual(SupervisorClient.pipelineTool(development: nil, bundled: nil, installed: home("installed")),
                       tool("installed"))
        XCTAssertNil(SupervisorClient.pipelineTool(development: nil, bundled: home("missing"), installed: nil))
    }

    /// The case itself, with the real tool: the engine this tree ships accepts a role pipeline in
    /// which two roles feed one input — the shape the older engine refused.
    func testThisEngineAcceptsTwoRolesIntoOneInput() throws {
        let engine = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("engine/bin/pipeline-tool.py")
        try XCTSkipUnless(FileManager.default.fileExists(atPath: engine.path), "no checkout beside the tests")
        let doc: [String: Any] = [
            "schema": "bulava.pipeline/1", "id": "fan-in", "name": "Fan in",
            "nodes": [
                ["id": "chat", "module": "bulava/trigger.chat@1"],
                ["id": "context", "module": "bulava/prep.context@1"],
                ["id": "position", "module": "bulava/prep.position@1", "params": ["engine": "codex"]],
                ["id": "position-2", "module": "bulava/prep.position@1", "params": ["engine": "claude"]],
                ["id": "position-3", "module": "bulava/prep.position@1", "params": ["engine": "claude"]],
                ["id": "align", "module": "bulava/prep.align@1"],
                ["id": "compose", "module": "bulava/prep.compose@1"],
                ["id": "claude", "module": "bulava/agent.claude@1"],
            ],
            "edges": [
                ["from": "chat.task", "to": "context.task"],
                ["from": "context.context", "to": "position.context"],
                ["from": "context.context", "to": "position-2.context"],
                ["from": "position.position", "to": "position-3.context"],
                ["from": "position-2.position", "to": "position-3.context"],
                ["from": "position-3.position", "to": "align.positions"],
                ["from": "align.checks", "to": "compose.in"],
                ["from": "compose.brief", "to": "claude.brief"],
            ],
        ]
        let file = root.appendingPathComponent("fan-in.json")
        try JSONSerialization.data(withJSONObject: doc).write(to: file)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        p.arguments = [engine.path, "validate", file.path]
        p.environment = ["PYTHONDONTWRITEBYTECODE": "1", "HOME": root.path]
        let out = Pipe(); p.standardOutput = out
        try p.run(); p.waitUntilExit()
        let line = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            .split(separator: "\n").last { $0.first == "{" }.map(String.init) ?? ""
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any], line)
        let issues = (json["issues"] as? [[String: Any]]) ?? []
        let fanIn = issues.filter { ((($0["msg"] as? [String: Any])?["uk"] as? String) ?? "").contains("більше одного зв") }
        XCTAssertTrue(fanIn.isEmpty, "two roles into one input refused: \(fanIn)")
    }
}
