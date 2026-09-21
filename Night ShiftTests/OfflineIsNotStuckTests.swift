import XCTest
@testable import Bulava

nonisolated final class OfflineIsNotStuckTests: XCTestCase {

    private func silentWorker(offline: Bool, stalled: Bool = false) -> SupervisorInstance {
        var inst = SupervisorInstance(slug: "demo-0000", projectPath: "/tmp/demo", session: "x",
                                      watchdogAlive: true, hasPlan: false, hasResearch: false)

        inst.lastActivity = Date().addingTimeInterval(-4 * 3600)
        inst.stalled = stalled
        inst.offline = offline
        inst.offlineSince = offline ? Date().addingTimeInterval(-4 * 3600) : nil
        return inst
    }

    // MARK: - Not stuck

    func testAnOutageIsNotAStuckWorker() {
        XCTAssertFalse(silentWorker(offline: true).looksStuck,
                       "an outage must not raise the stuck alarm — there is nothing to act on")
    }

    func testTheSameSilenceWithNetworkIsStuck() {
        XCTAssertTrue(silentWorker(offline: false).looksStuck,
                      "silence with a working connection is still a stuck worker")
    }

    func testAnOutageBeatsAStaleStallMarker() {
        let inst = silentWorker(offline: true, stalled: true)
        XCTAssertFalse(inst.looksStuck)
        XCTAssertEqual(inst.phase, .offline,
                       "offline must outrank stalled: only one of them is a problem")
    }

    // MARK: - What it says

    @MainActor func testTheReasonNamesTheNetworkRatherThanSilence() {
        let model = AppModel()
        var inst = silentWorker(offline: true)
        inst.offlineSince = nil

        XCTAssertEqual(model.stuckReason(inst),
                       String(localized: "No network. It carries on by itself when the connection returns."))
    }

    @MainActor func testAnOutageAndAHangDoNotReadTheSame() {
        let model = AppModel()
        XCTAssertNotEqual(model.stuckReason(silentWorker(offline: true)),
                          model.stuckReason(silentWorker(offline: false)))
    }

    @MainActor func testThePhaseReadsAsWaitingNotAsFailure() {
        XCTAssertEqual(WorkerPhase.offline.humanLabel, String(localized: "Waiting for the network"))
    }

    // MARK: - Defaults

    func testARunWithoutTheMarkerIsOnline() {
        let inst = SupervisorInstance(slug: "demo-0000", projectPath: "/tmp/demo", session: "x",
                                      watchdogAlive: true, hasPlan: false, hasResearch: false)
        XCTAssertFalse(inst.offline)
        XCTAssertNil(inst.offlineSince)
    }
}
