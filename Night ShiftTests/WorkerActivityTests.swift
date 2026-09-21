import XCTest
@testable import Bulava

nonisolated final class WorkerActivityTests: XCTestCase {

    func testTheTranscriptDirectoryIsDerivedFromThePath() {
        XCTAssertEqual(WorkerActivity.transcriptDirName(for: "/Users/i/Developer/Clients/pocket-ledger"),
                       "-Users-i-Developer-Clients-pocket-ledger")
        XCTAssertEqual(WorkerActivity.transcriptDirName(for: "/Users/i/Developer/MyProjects/Night Shift"),
                       "-Users-i-Developer-MyProjects-Night-Shift")
        XCTAssertEqual(WorkerActivity.transcriptDirName(for: "/Users/i/Dev/.nightshift-worktrees/x-1A2B"),
                       "-Users-i-Dev--nightshift-worktrees-x-1A2B")
    }

    private func toolLine(_ name: String, _ input: [String: Any]) -> String {
        let obj: [String: Any] = ["type": "assistant",
                                  "message": ["content": [["type": "tool_use", "name": name, "input": input]]]]
        return String(data: try! JSONSerialization.data(withJSONObject: obj), encoding: .utf8)!
    }

    func testTheNEWESTToolCallIsWhatItIsDoing() {
        let tail = [toolLine("Read", ["file_path": "/a/b/SearchScreen.kt"]),
                    toolLine("Bash", ["command": "cd /a/b && ./gradlew assembleDebug"])].joined(separator: "\n")
        let line = WorkerActivity.line(fromTranscriptTail: tail, at: Date())
        XCTAssertEqual(line?.key, "runs %@")
        XCTAssertEqual(line?.object, "./gradlew assembleDebug")
    }

    func testATruncatedFirstLineIsSkipped() {
        let tail = "ent\":[{\"type\":\"text\"}]}}\n" + toolLine("Read", ["file_path": "/a/Info.plist"])
        XCTAssertEqual(WorkerActivity.line(fromTranscriptTail: tail, at: Date())?.object, "Info.plist")
    }

    func testAFileIsNamedByItsBasename() {
        let line = WorkerActivity.line(fromTranscriptTail: toolLine("Edit", ["file_path": "/very/long/path/App.kt"]),
                                       at: Date())
        XCTAssertEqual(line?.key, "edits %@")
        XCTAssertEqual(line?.object, "App.kt")
    }

    func testAnUnknownToolIsJustWorking() {
        let line = WorkerActivity.line(fromTranscriptTail: toolLine("SomeFutureTool", ["x": 1]), at: Date())
        XCTAssertEqual(line?.key, "working")
        XCTAssertNil(line?.object)
    }

    func testNothingToShowWhenThereIsNoToolCall() {
        let text = #"{"type":"assistant","message":{"content":[{"type":"text","text":"Thinking about it"}]}}"#
        XCTAssertNil(WorkerActivity.line(fromTranscriptTail: text, at: Date()))
    }

    func testTheCommandIsShownAsAPersonWouldGlanceAtIt() {
        XCTAssertEqual(WorkerActivity.shorten(command: "cd /Users/i/p && git checkout main"),
                       "git checkout main")
        XCTAssertEqual(WorkerActivity.shorten(command: "echo one\necho two"), "echo one echo two")
        let long = WorkerActivity.shorten(command: String(repeating: "x", count: 200))
        XCTAssertEqual(long.count, 61)
        XCTAssertTrue(long.hasSuffix("…"))
    }

    @MainActor
    func testAStaleTranscriptIsNotReportedAsNow() {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("bulava-activity-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        XCTAssertNil(WorkerActivity.current(projectPath: dir.appendingPathComponent("nope").path))
    }
}

nonisolated final class NowLineTests: XCTestCase {

    func testTheLiveLineReplacesTheGenericOne() {
        var task = BacklogTask(title: "t", projectPath: "/tmp/p", type: .feature, priority: .p2, state: .executing)
        task.dispatchedAt = Date()
        let inst = SupervisorInstance(slug: "s", projectPath: "/tmp/p", session: "x", watchdogAlive: true,
                                      hasPlan: false, hasResearch: false)
        let generic = WorkProgress.nowLine(task: task, instance: inst)
        XCTAssertEqual(generic?.key, "Claude is working.")

        let live = WorkProgress.nowLine(task: task, instance: inst,
                                        activity: .init(key: "reads %@", object: "SearchScreen.kt", at: Date()))
        XCTAssertEqual(live?.key, "reads %@")
        XCTAssertEqual(live?.object, "SearchScreen.kt")
        XCTAssertTrue(live!.sentence.contains("SearchScreen.kt"),
                      "the placeholder is filled, not printed")
        XCTAssertFalse(live!.sentence.contains("%@"))
    }

    func testAWaitingQuestionStillWins() {
        var task = BacklogTask(title: "t", projectPath: "/tmp/p", type: .feature, priority: .p2, state: .executing)
        task.dispatchedAt = Date()
        var inst = SupervisorInstance(slug: "s", projectPath: "/tmp/p", session: "x", watchdogAlive: true,
                                      hasPlan: false, hasResearch: false)
        inst.pendingQuestion = PendingUserQuestion(
            questions: [.init(question: "Який акаунт брати?", header: nil, options: [], multiSelect: false)],
            askedAt: Date())
        let line = WorkProgress.nowLine(task: task, instance: inst,
                                        activity: .init(key: "reads %@", object: "A.kt", at: Date()))
        XCTAssertEqual(line?.key, "A worker is waiting on your answer.")
    }
}

nonisolated final class MCPActivityTests: XCTestCase {

    private func tool(_ name: String) -> String {
        let obj: [String: Any] = ["message": ["content": [["type": "tool_use", "name": name, "input": [:]]]]]
        return String(data: try! JSONSerialization.data(withJSONObject: obj), encoding: .utf8)!
    }

    func testTheSimulatorIsNamedAsWhatItIs() {
        let line = WorkerActivity.line(fromTranscriptTail: tool("mcp__appium-mcp__appium_swipe"), at: Date())
        XCTAssertEqual(line?.key, "drives the app on a device")
        XCTAssertNil(line?.object)
    }

    func testAnUnknownServerIsNamedNotInterpreted() {
        let line = WorkerActivity.line(fromTranscriptTail: tool("mcp__memex__search_memory"), at: Date())
        XCTAssertEqual(line?.key, "works with %@")
        XCTAssertEqual(line?.object, "memex")
    }
}
