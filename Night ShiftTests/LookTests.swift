import XCTest
import Darwin
@testable import Bulava

nonisolated final class LookStreamTests: XCTestCase {

    private func stream(_ lines: [String]) -> SupervisorClient.LookStream {
        SupervisorClient.LookStream(ndjson: lines.joined(separator: "\n"))
    }

    func testTheFinalResultIsTheAnswer() {
        let s = stream([
            #"{"type":"system","subtype":"init","tools":["Read"]}"#,
            #"{"type":"assistant","message":{"content":[{"type":"text","text":"Looking."}]}}"#,
            #"{"type":"result","subtype":"success","result":"Two files changed, both on the server."}"#,
        ])
        XCTAssertEqual(s.answer, "Two files changed, both on the server.")
        XCTAssertNil(s.error)
    }

    func testWorkingIsKeptWhenTheRunNeverFinished() {
        let s = stream([
            #"{"type":"assistant","message":{"content":[{"type":"text","text":"Read handlers.go."}]}}"#,
            #"{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Grep"}]}}"#,
            #"{"type":"assistant","message":{"content":[{"type":"text","text":"The store is a mirror."}]}}"#,
        ])
        XCTAssertNil(s.answer)
        XCTAssertEqual(s.partial, "Read handlers.go.\n\nThe store is a mirror.")
    }

    func testARefusalIsNotPresentedAsAnAnswer() {
        let s = stream([#"{"type":"result","subtype":"error","is_error":true,"result":"Credit balance too low"}"#])
        XCTAssertNil(s.answer)
        XCTAssertEqual(s.error, "Credit balance too low")
    }

    func testGarbageLinesAreIgnoredRatherThanBreakingTheParse() {
        let s = stream([
            "not json at all",
            "",
            #"{"type":"result","subtype":"success","result":"fine"}"#,
        ])
        XCTAssertEqual(s.answer, "fine")
    }
}

// MARK: - Silence, not slowness

nonisolated final class ShellIdleWatchdogTests: XCTestCase {

    @MainActor func testAChattyCommandOutlivesItsIdleBudget() async {
        let r = await Shell.run("for i in 1 2 3 4 5 6; do echo tick; sleep 0.5; done",
                                timeout: 30, idle: 1.5)
        XCTAssertEqual(r.endedBy, .exited, "a command that was still talking got cut off")
        XCTAssertEqual(r.exitCode, 0)
        XCTAssertEqual(r.stdout.split(separator: "\n").count, 6)
    }

    @MainActor func testASilentCommandIsCutAtTheIdleBudget() async {
        let started = Date()
        let r = await Shell.run("sleep 30", timeout: 30, idle: 1)
        XCTAssertEqual(r.endedBy, .wentQuiet(idle: 1))
        XCTAssertLessThan(Date().timeIntervalSince(started), 10, "the idle watchdog did not fire")
    }

    @MainActor func testTheCeilingStillStopsARunaway() async {
        let r = await Shell.run("while true; do echo spin; sleep 0.2; done", timeout: 2, idle: 30)
        XCTAssertEqual(r.endedBy, .hitCeiling(after: 2))
    }

    @MainActor func testAnIsolatedTimeoutReapsTheWholeProcessTree() async throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("bulava-process-tree-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let leaderFile = folder.appendingPathComponent("leader.pid")
        let childFile = folder.appendingPathComponent("child.pid")

        let result = await Shell.run(
            """
            printf %s $$ > "$1"
            (trap '' TERM; sleep 30) &
            printf %s $! > "$2"
            wait
            """,
            args: [leaderFile.path, childFile.path],
            timeout: 1,
            isolatingProcessTree: true)

        XCTAssertEqual(result.endedBy, .hitCeiling(after: 1))
        let pids = [leaderFile, childFile].compactMap { url -> Int32? in
            guard let raw = try? String(contentsOf: url, encoding: .utf8) else { return nil }
            return Int32(raw.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        XCTAssertEqual(pids.count, 2, "the fixture did not launch its nested process")
        for _ in 0..<40 where pids.contains(where: { Darwin.kill($0, 0) == 0 }) {
            try? await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertTrue(pids.allSatisfy { Darwin.kill($0, 0) != 0 },
                      "an isolated command left a descendant alive after its timeout")
    }
}

// MARK: - What the night can reach

nonisolated final class WorkerEnvironmentTests: XCTestCase {

    private let sample = """
    Checking MCP server health…

    claude.ai Slack: https://mcp.slack.com/mcp - ! Needs authentication
    stepanok-deploy: node /Users/x/MCP/stepanok-deploy/src/index.js - ✔ Connected
    xcodebuildmcp: node xcodebuildmcp - ✘ Failed to connect — -32000: Connection closed
    imagegen: node /Users/x/MCP/imagegen/dist/index.js - ✔ Connected
    """

    func testTheThreeStatesAreKeptApart() {
        let servers = WorkerEnvironment.parseServers(sample)
        XCTAssertEqual(servers.count, 4, "the health header must not become a server")
        XCTAssertEqual(servers.first { $0.name == "stepanok-deploy" }?.status, "connected")
        XCTAssertEqual(servers.first { $0.name == "claude.ai Slack" }?.status, "needs_auth")
        XCTAssertEqual(servers.first { $0.name == "xcodebuildmcp" }?.status, "failed")
    }

    func testTheBriefNamesWhatIsUsableAndWhatNeedsHim() {
        var env = WorkerEnvironment()
        env.servers = WorkerEnvironment.parseServers(sample)
        env.tools = ["git", "docker"]
        let brief = env.brief
        XCTAssertTrue(brief.contains("stepanok-deploy"), "a connected server must be named as available")
        XCTAssertTrue(brief.contains("needs sign-in"), "a server he could fix in a minute must say so")
        XCTAssertTrue(brief.contains("git, docker"))

        XCTAssertTrue(brief.contains("NIGHT RUN"))
    }

    func testAnEmptyEnvironmentSaysNothingRatherThanLying() {
        XCTAssertEqual(WorkerEnvironment().brief, "")
        XCTAssertTrue(WorkerEnvironment.parseServers("Checking MCP server health…\n\n").isEmpty)
    }

    func testMCPHealthChecksAreThrottledEvenWhenThePreviousOneFailed() {
        let now = Date(timeIntervalSinceReferenceDate: 10_000)
        XCTAssertFalse(SupervisorClient.workerEnvironmentNeedsRefresh(
            checkedAt: now.addingTimeInterval(-3_599), lastAttempt: nil, now: now))
        XCTAssertTrue(SupervisorClient.workerEnvironmentNeedsRefresh(
            checkedAt: now.addingTimeInterval(-3_600), lastAttempt: nil, now: now))
        XCTAssertFalse(SupervisorClient.workerEnvironmentNeedsRefresh(
            checkedAt: nil, lastAttempt: now.addingTimeInterval(-30), now: now),
            "a failed probe must not be retried by every ordinary UI refresh")
    }
}
