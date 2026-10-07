import XCTest
@testable import Bulava

/// A run whose watchdog died with its session, while it still owed work, is seen for what it is.
///
/// A chat parked on Codex's usage window, owing its review, lost its tmux session and its watchdog a
/// few minutes before Codex came back. The screen went on saying "Waiting for Codex · back around
/// 11:26 PM" at 11:28 and after: the pause was read before anything asked whether anyone was left
/// to lift it. Bulava now brings such a run back (`reviveDeadRuns`), and says so while it does.
nonisolated final class RevivalTests: XCTestCase {

    private var state: URL!
    private let project = "/tmp/mapache-test"

    override func setUp() async throws {
        state = FileManager.default.temporaryDirectory.appendingPathComponent("bulava-revival-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: state, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: state)
    }

    /// A run parked on Codex, owing its review, started an hour ago; `watchdog` a live pid or none.
    private func parkedRun(watchdog: Int32? = nil, extra: [String: String] = [:]) async throws -> SupervisorInstance? {
        let slug = Slug.forPath(project)
        let dir = state.appendingPathComponent("instances/\(slug)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let resume = Int(Date().addingTimeInterval(-120).timeIntervalSince1970)
        var files = [
            "project": project, "session": "night-\(slug)", "run-id": "49319D5B", "started-at": "",
            "paused-for-limit.json": #"{"provider":"codex","resume_after":\#(resume),"reason":"reviewer unreachable","run_id":"49319D5B"}"#,
            "review-pending": #"{"reason":"the reviewer could not be reached"}"#,
            "watchdog.pid": watchdog.map { "\($0)" } ?? "99999",
        ]
        files.merge(extra) { _, new in new }
        for (name, text) in files {
            try text.write(to: dir.appendingPathComponent(name), atomically: true, encoding: .utf8)
        }
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-3600)],
                                              ofItemAtPath: dir.appendingPathComponent("started-at").path)
        return await SupervisorClient(paths: SupervisorPaths(stateDir: state)).snapshot().instances.first
    }

    func testAParkedRunWithNoWatchdogIsBeingBroughtBackNotWaitingForCodex() async throws {
        let parked = try await parkedRun()
        let run = try XCTUnwrap(parked)
        XCTAssertTrue(run.owesWork, "it owes a review and is parked on a window")
        XCTAssertFalse(run.watchdogAlive)
        XCTAssertTrue(run.needsRevival)
        let phase = DirectChatPhase.resolve(instance: run, bindingHasOutcome: false)
        XCTAssertEqual(phase, .reviving, "nobody is left to notice Codex come back")
        XCTAssertTrue(phase.isActive)
        XCTAssertEqual(DirectChatPhase.resolve(instance: run, bindingHasOutcome: false, revivalGaveUp: true),
                       .revivalFailed, "and says so once it could not be brought back")
        XCTAssertTrue(DirectChatPhase.revivalFailed.wantsAttention)
    }

    func testAStoppedOrFinishedRunIsLeftAlone() async throws {
        let stoppedRun = try await parkedRun(extra: ["director-stopped": ""])
        let stopped = try XCTUnwrap(stoppedRun)
        XCTAssertFalse(stopped.needsRevival, "the director stopped it")
        try? FileManager.default.removeItem(at: state.appendingPathComponent("instances"))
        let doneRun = try await parkedRun(extra: ["done": "succeeded"])
        let done = try XCTUnwrap(doneRun)
        XCTAssertFalse(done.needsRevival, "it wrote its result")
    }

    func testAWatchedRunStillWaitsAndAPastReturnIsNotPromised() async throws {
        // A watchdog that is alive: this test's own process stands in for it by pid; the command
        // check reads the process and finds no watchdog, so a live-looking one is written here.
        let parked = try await parkedRun()
        let run = try XCTUnwrap(parked)
        var watched = run
        watched.watchdogAlive = true
        let phase = DirectChatPhase.resolve(instance: watched, bindingHasOutcome: false)
        guard case .waitingForCodex(let until) = phase else { return XCTFail("expected waiting for Codex, got \(phase)") }
        XCTAssertNotNil(until)
        XCTAssertFalse(phase.label.contains(Fmt.stamp(until!)), "a time already gone by is not promised")
        XCTAssertEqual(phase.label, String(localized: "Codex is back — picking the work up"))
        let later = DirectChatPhase.waitingForCodex(Date().addingTimeInterval(3600))
        XCTAssertTrue(later.label.contains(Fmt.stamp(Date().addingTimeInterval(3600))), "a time ahead still is")
    }

    func testARunThatOwesNothingIsNotRevived() async throws {
        let slug = Slug.forPath(project)
        let dir = state.appendingPathComponent("instances/\(slug)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for (name, text) in ["project": project, "session": "night-\(slug)", "run-id": "r", "started-at": ""] {
            try text.write(to: dir.appendingPathComponent(name), atomically: true, encoding: .utf8)
        }
        let snapshot = await SupervisorClient(paths: SupervisorPaths(stateDir: state)).snapshot()
        let run = try XCTUnwrap(snapshot.instances.first)
        XCTAssertFalse(run.owesWork)
        XCTAssertFalse(run.needsRevival, "a dead run that owes nothing is left for the next message to start afresh")
    }
}
