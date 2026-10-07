import XCTest
import SwiftUI
@testable import Bulava

/// A project's own MCP servers are asked about in Bulava, not discovered by a start that times out.
///
/// Claude Code stops to ask which `.mcp.json` servers to enable before its session starts, so the
/// run-id handshake never came and the start was rolled back as a hooks problem. The engine now
/// reports the question (exit 78, `mcp-state`); these hold the app to reading it the same way.
nonisolated final class McpQuestionTests: XCTestCase {

    override func setUp() {
        super.setUp()
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("bulava-mcp-state-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        setenv("BULAVA_STATE_DIR", dir.path, 1)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: dir)
            unsetenv("BULAVA_STATE_DIR")
        }
    }

    private func repoWithMcp() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("bulava-mcp-\(UUID().uuidString)").resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        try #"{"mcpServers":{"oex-platform-index":{"command":"true"},"paragon":{"command":"true"}}}"#
            .write(to: dir.appendingPathComponent(".mcp.json"), atomically: true, encoding: .utf8)
        return dir
    }

    @MainActor
    func testTheEngineNamesTheServersClaudeWouldAskAbout() async throws {
        let dir = try repoWithMcp()
        let pending = await AppModel().client.pendingMcpServers(projectPath: dir.path)
        XCTAssertEqual(pending, ["oex-platform-index", "paragon"])
    }

    @MainActor
    func testAProjectWithoutMcpAsksNothing() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("bulava-nomcp-\(UUID().uuidString)").resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        let pending = await AppModel().client.pendingMcpServers(projectPath: dir.path)
        XCTAssertEqual(pending, [])
    }

    func testTheListReadsAsAPhrase() {
        XCTAssertEqual(AppModel.mcpServerList(["a", "b"]), "a, b")
        XCTAssertTrue(AppModel.mcpServerList(["a", "b", "c", "d", "e", "f"]).hasPrefix("a, b, c, d "))
        XCTAssertEqual(AppModel.mcpServerList([]), "")
    }

    @MainActor
    func testNoAnswerWithoutAQuestion() {
        let model = AppModel()
        let chatID = UUID(), entryID = UUID()
        model.answerMcp(enable: true, entryID: entryID, in: chatID)
        XCTAssertNil(model.mcpBlocked[chatID])
        model.mcpBlocked[chatID] = .init(entryID: UUID(), folder: "/x", servers: ["a"])
        model.answerMcp(enable: true, entryID: entryID, in: chatID)
        XCTAssertNotNil(model.mcpBlocked[chatID], "an answer for another message does not clear this one")
    }

    @MainActor
    func testTheRowRenders() throws {
        let model = AppModel()
        let block = AppModel.McpBlock(entryID: UUID(), folder: "/Users/me/edx-load-tests",
                                      servers: ["oex-platform-index", "paragon"])
        let view = McpRow(block: block, entryID: block.entryID, chatID: UUID())
            .environment(model)
            .frame(width: 640)
            .padding(12)
            .background(Palette.content)
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        let image = try XCTUnwrap(renderer.nsImage)
        XCTAssertGreaterThan(image.size.height, 40)
        if let out = ProcessInfo.processInfo.environment["BULAVA_RENDER_DIR"],
           let tiff = image.tiffRepresentation,
           let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
            try png.write(to: URL(fileURLWithPath: out).appendingPathComponent("mcp-row.png"))
        }
    }
}
