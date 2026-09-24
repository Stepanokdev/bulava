import XCTest
@testable import Bulava

/// What the paid readiness probes remember between launches, and when they ask again.
///
/// Three hundred and eleven «reply with the single word: ok» sessions in one week, all answered
/// «ok», came from a verdict that lived in the process and died with it — and from one probe's
/// failure throwing away the other's answer, so an evening of Codex being out bought a Claude turn
/// every twenty minutes. Dates in, decisions out; no shell, no CLI.
nonisolated final class ProbeMemoryTests: XCTestCase {

    private func ready(_ id: String) -> PreflightCheck {
        PreflightCheck(id: id, titleKey: "\(id) answers", detailKey: "came back", status: .ready, evidence: "ok")
    }

    func testAFreshVerdictIsRepeatedNotAskedAgain() {
        var m = ProbeMemory()
        let t0 = Date()
        m.recordReady(ready("claude-auth"), now: t0)
        let later = t0.addingTimeInterval(20 * 60)
        guard case .remembered(let v) = m.answer(for: "claude-auth", probe: false, now: later) else {
            return XCTFail("a twenty-minute-old verdict should be repeated")
        }
        XCTAssertEqual(v.check.status, .ready)
        XCTAssertEqual(v.check.titleKey, "claude-auth answers")
        XCTAssertEqual(v.check.evidence, "ok")
    }

    func testAVerdictOlderThanADayIsAskedAgain() {
        var m = ProbeMemory()
        let t0 = Date()
        m.recordReady(ready("claude-auth"), now: t0)
        XCTAssertEqual(m.answer(for: "claude-auth", probe: false,
                                now: t0.addingTimeInterval(PreflightRunner.paidProbeTTL + 1)), .ask)
    }

    func testSomeoneWaitingAlwaysGetsAFreshAnswer() {
        var m = ProbeMemory()
        m.recordReady(ready("codex-auth"), now: Date())
        XCTAssertEqual(m.answer(for: "codex-auth", probe: true, now: Date()), .ask)
    }

    /// The amplifier: Codex failing used to clear the shared clock, and the next free refresh
    /// re-bought Claude's answer too.
    func testOneProbeFailingLeavesTheOthersVerdictAlone() {
        var m = ProbeMemory()
        let t0 = Date()
        m.recordReady(ready("claude-auth"), now: t0)
        m.recordReady(ready("codex-auth"), now: t0)
        m.recordFailure(id: "codex-auth", now: t0.addingTimeInterval(60))
        guard case .remembered = m.answer(for: "claude-auth", probe: false, now: t0.addingTimeInterval(120)) else {
            return XCTFail("Claude's verdict must survive Codex's failure")
        }
        XCTAssertNil(m.provenAt(ids: PreflightRunner.paidProbeIDs),
                     "with one probe unproven the shared clock says nothing is proven")
    }

    func testAFailedProbeIsNotAskedAgainForAnHourThenIs() {
        var m = ProbeMemory()
        let t0 = Date()
        m.recordFailure(id: "codex-auth", now: t0)
        guard case .holdOff(let until) = m.answer(for: "codex-auth", probe: false, now: t0.addingTimeInterval(20 * 60)) else {
            return XCTFail("twenty minutes after a failure the free refresh must not ask again")
        }
        XCTAssertEqual(until, t0.addingTimeInterval(ProbeMemory.failureBackoff))
        XCTAssertEqual(m.answer(for: "codex-auth", probe: false,
                                now: t0.addingTimeInterval(ProbeMemory.failureBackoff + 1)), .ask)
        // A person waiting is not held off.
        XCTAssertEqual(m.answer(for: "codex-auth", probe: true, now: t0.addingTimeInterval(60)), .ask)
    }

    func testTheSharedClockIsTheOldestVerdict() {
        var m = ProbeMemory()
        let t0 = Date()
        m.recordReady(ready("claude-auth"), now: t0)
        m.recordReady(ready("codex-auth"), now: t0.addingTimeInterval(3600))
        XCTAssertEqual(m.provenAt(ids: PreflightRunner.paidProbeIDs), t0)
        XCTAssertNil(ProbeMemory().provenAt(ids: PreflightRunner.paidProbeIDs))
    }

    func testMemorySurvivesARoundTripThroughDefaults() {
        let suite = "ProbeMemoryTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        var m = ProbeMemory()
        let t0 = Date(timeIntervalSince1970: 1_790_000_000)
        m.recordReady(ready("claude-auth"), now: t0)
        m.recordFailure(id: "codex-auth", now: t0)
        m.save(to: defaults)
        let back = ProbeMemory.load(from: defaults)
        XCTAssertEqual(back, m)
        guard case .remembered = back.answer(for: "claude-auth", probe: false, now: t0.addingTimeInterval(60)) else {
            return XCTFail("a relaunch must repeat the remembered verdict instead of paying for it")
        }
    }

    func testAnEmptyOrCorruptStoreIsAnEmptyMemory() {
        let suite = "ProbeMemoryTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        XCTAssertEqual(ProbeMemory.load(from: defaults), ProbeMemory())
        defaults.set(Data("not json".utf8), forKey: ProbeMemory.defaultsKey)
        XCTAssertEqual(ProbeMemory.load(from: defaults), ProbeMemory())
    }

    /// The launch path's contract, pinned: with a remembered pair the free depth is not due, and
    /// the test host is recognised as such.
    func testTheFreeDepthWithARememberedPairIsNotDue() {
        var m = ProbeMemory()
        let t0 = Date()
        m.recordReady(ready("claude-auth"), now: t0)
        m.recordReady(ready("codex-auth"), now: t0)
        XCTAssertFalse(PreflightRunner.paidProbesAreDue(provenAt: m.provenAt(ids: PreflightRunner.paidProbeIDs),
                                                        now: t0.addingTimeInterval(60), depth: .free))
        XCTAssertTrue(PreflightRunner.isTestHost, "these tests run in the test host")
    }
}
