import XCTest
import IOKit.pwr_mgt
@testable import Bulava

/// The Mac stays up while work goes on by itself, and is let go when it would only be waiting.
nonisolated final class KeepAwakeTests: XCTestCase {

    func testOnlyWorkThatGoesOnByItselfKeepsTheMacUp() {
        let awake: [WorkerPhase] = [.starting, .working, .reviewing, .pausedForLimit, .offline]
        for phase in awake {
            XCTAssertTrue(PowerKeeper.keepsAwake(phase: phase, waitingFor: nil), "\(phase) goes on by itself")
        }
        for phase in [WorkerPhase.done, .blocked, .stalled, .idle] {
            XCTAssertFalse(PowerKeeper.keepsAwake(phase: phase, waitingFor: nil), "\(phase) is not work in progress")
        }
        XCTAssertTrue(PowerKeeper.keepsAwake(phase: .awaitingDecision, waitingFor: .codexWindow),
                      "a Codex window reopens by itself")
        XCTAssertFalse(PowerKeeper.keepsAwake(phase: .awaitingDecision, waitingFor: .director),
                       "a question nobody answers overnight must not keep the Mac up")
    }

    /// Counted against what the process already holds. The tests run inside the app, and an
    /// `AppModel` another test made keeps its own keeper — holding, when the runs it reads look like
    /// work — for as long as it lives; counted from zero, this passed alone and failed in the suite.
    /// Nothing else runs on the main actor between these lines, so the difference is this keeper's.
    @MainActor
    func testTheAssertionIsReallyHeldAndReallyLetGo() throws {
        let keeper = PowerKeeper()
        let before = Self.bulavaAssertions()
        keeper.hold(true)
        XCTAssertTrue(keeper.holding)
        XCTAssertEqual(Self.bulavaAssertions(), before + 1, "macOS lists the assertion for this process")
        keeper.hold(true)
        XCTAssertEqual(Self.bulavaAssertions(), before + 1, "holding twice is still one assertion")
        keeper.hold(false)
        XCTAssertFalse(keeper.holding)
        XCTAssertEqual(Self.bulavaAssertions(), before, "and it is gone once let go")
    }

    func testItIsOnByDefaultIncludingForSettingsWrittenBeforeIt() throws {
        XCTAssertTrue(AppSettings.fallback.keepAwakeWhileWorking)
        var old = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(AppSettings.fallback)) as? [String: Any])
        old.removeValue(forKey: "keepAwakeWhileWorking")
        let decoded = try JSONDecoder().decode(AppSettings.self, from: JSONSerialization.data(withJSONObject: old))
        XCTAssertTrue(decoded.keepAwakeWhileWorking)
    }

    // MARK: - What macOS says this process holds

    private static func assertionsOfThisProcess() -> [[String: Any]] {
        var raw: Unmanaged<CFDictionary>?
        guard IOPMCopyAssertionsByProcess(&raw) == kIOReturnSuccess,
              let all = raw?.takeRetainedValue() as? [NSNumber: [[String: Any]]] else { return [] }
        return all[NSNumber(value: getpid())] ?? []
    }

    private static func bulavaAssertions() -> Int {
        assertionsOfThisProcess().filter {
            ($0[kIOPMAssertionTypeKey] as? String) == (kIOPMAssertPreventUserIdleSystemSleep as String)
                && ($0[kIOPMAssertionNameKey] as? String) == String(localized: "Bulava is working")
        }.count
    }
}
