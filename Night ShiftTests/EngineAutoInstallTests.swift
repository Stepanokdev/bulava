import XCTest
@testable import Bulava

/// The engine travels inside the app, and updating the app used to leave a red wall whose only
/// instruction was to press a button that copies a file out of the application you had just
/// installed. A tester on 1.6 asked the obvious question — why is that not automatic — and he was
/// right. What these pin is the two reasons it was a question, because neither has gone away:
/// replacing the engine under a running worker breaks it, and an install that fails halfway used
/// to call itself finished.
nonisolated final class EngineAutoInstallTests: XCTestCase {

    private func instance(_ name: String = "proj") -> SupervisorInstance {
        SupervisorInstance(slug: name, projectPath: "/tmp/\(name)", session: "night-\(name)",
                           watchdogAlive: false, hasPlan: false, hasResearch: false)
    }

    // MARK: - What counts as busy

    func testAnIdleMachineIsIdle() {
        XCTAssertNil(EngineBusy.reason(instances: [], on: .quiet),
                     "with nothing running there is nothing to wait for")
    }

    func testAWorkingRunStopsTheInstall() {
        var inst = instance(); inst.workerStatus = "busy"
        let reason = EngineBusy.reason(instances: [inst], on: .quiet)
        XCTAssertNotNil(reason, "swapping the scripts under a working turn is how a night dies")
        XCTAssertTrue(reason!.contains("proj"), "the person should be told which run: \(reason ?? "")")
    }

    func testAReviewStopsIt() {
        var inst = instance(); inst.reviewActive = true
        XCTAssertNotNil(EngineBusy.reason(instances: [inst], on: .quiet))
    }

    func testAnUndeliveredMessageStopsIt() {
        var inst = instance(); inst.queuedWork = true
        XCTAssertNotNil(EngineBusy.reason(instances: [inst], on: .quiet),
                        "a message already accepted is work in flight, even with the pane idle")
    }

    /// The one the launch-time shortcut gets wrong. The engine is started with nohup and disowned
    /// so that closing Bulava does not interrupt a preparation — which means a fresh launch says
    /// nothing at all about whether work is running.
    func testASupervisedRunStopsItEvenWithAnIdlePane() {
        var inst = instance()
        inst.watchdogAlive = true
        inst.workerStatus = "idle"
        XCTAssertNotNil(EngineBusy.reason(instances: [inst], on: .quiet),
                        "a live watchdog means a run that outlived the app")
    }

    func testTheReasonNamesTheWorkNotTheMechanism() {
        var inst = instance("Ledger"); inst.workerStatus = "busy"
        let reason = EngineBusy.reason(instances: [inst], on: .quiet) ?? ""
        XCTAssertFalse(reason.contains("rsync"), "the reader did not ask about rsync: \(reason)")
        XCTAssertFalse(reason.isEmpty)
    }

    // MARK: - A half-done install must not look finished

    /// The stamp is how the app decides whether the installed engine matches this build. Copying
    /// it with everything else meant a copy that landed, followed by an installer that failed,
    /// left the new number sitting on an engine whose hooks were never written — and the app
    /// compared the numbers, found them equal, and called the machine ready.
    func testAnEngineWithNoStampReadsAsStaleRatherThanReady() throws {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("engine-stamp-\(UUID().uuidString)")
        let engine = tmp.appendingPathComponent("engine")
        try FileManager.default.createDirectory(at: engine.appendingPathComponent("bin"),
                                                withIntermediateDirectories: true)
        try "#!/bin/bash\n".write(to: engine.appendingPathComponent("bin/verify.sh"),
                                  atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: tmp) }

        XCTAssertNil(OrchestratorHome.version(of: engine),
                     "an engine mid-install carries no version, and that is the point")

        try "202609139999\n".write(to: engine.appendingPathComponent(".engine-version"),
                                   atomically: true, encoding: .utf8)
        XCTAssertEqual(OrchestratorHome.version(of: engine), "202609139999",
                       "and once the install has finished, it says which build it is")
    }

    /// The installer writes the stamp on the last line, after the installer script has returned 0.
    /// Reading the source is the only way to assert an ordering that a unit test cannot observe
    /// without a real bundle to install from.
    func testTheInstallerWritesTheStampAfterRunningTheInstaller() throws {
        let src = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Night Shift/Engine/EngineInstaller.swift")
        let text = try String(contentsOf: src, encoding: .utf8)
        let copy = try XCTUnwrap(text.range(of: "rsync"))
        let runsInstaller = try XCTUnwrap(text.range(of: "./install.sh"))
        let writesStamp = try XCTUnwrap(text.range(of: "version.write(to: stampURL"))
        XCTAssertTrue(copy.lowerBound < runsInstaller.lowerBound)
        XCTAssertTrue(runsInstaller.lowerBound < writesStamp.lowerBound,
                      "the stamp must be written after install.sh succeeds, never before")
        XCTAssertTrue(text.contains("--exclude \\\"$3\\\""),
                      "the copy must hold the stamp back rather than bring it along")
    }

    // MARK: - The real probe has to actually see the machine

    /// Injecting a probe buys the tests determinism and buys the code a new way to be wrong: a
    /// `.machine` probe that quietly stopped observing would pass every test above. So the
    /// observation itself is made to answer both ways, about a process this test owns — it must
    /// say no before the process exists and yes while it is alive.
    func testTheMachineProbeSeesAProcessAppearAndGo() throws {
        let needle = "bulava-probe-\(UUID().uuidString)"
        XCTAssertFalse(EngineBusy.processExists(needle),
                       "nothing by this name has ever run on this Mac")

        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        // The trailing `:` matters — a shell execs its last command and loses its own argv with it,
        // which would take the needle out of the command line this probe reads.
        p.arguments = ["-c", "sleep 5; : \(needle)"]
        try p.run()
        defer { p.terminate() }

        var seen = false
        for _ in 0..<50 where !seen {            // pgrep sees it once the fork has landed
            seen = EngineBusy.processExists(needle)
            if !seen { Thread.sleep(forTimeInterval: 0.05) }
        }
        XCTAssertTrue(seen, "the probe looked at the machine and failed to find a running process")

        p.terminate(); p.waitUntilExit()
        var gone = false
        for _ in 0..<50 where !gone {
            gone = !EngineBusy.processExists(needle)
            if !gone { Thread.sleep(forTimeInterval: 0.05) }
        }
        XCTAssertTrue(gone, "and it must stop reporting a process that has exited")
    }

    /// `.quiet` exists for the tests. Production must still be the one that asks the machine.
    func testTheDefaultProbeIsTheMachine() throws {
        let src = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Night Shift/Engine/EngineBusy.swift")
        let text = try String(contentsOf: src, encoding: .utf8)
        XCTAssertTrue(text.contains("on probe: Probe = .machine"),
                      "a caller that passes nothing must get the real machine, not the quiet stub")
        XCTAssertTrue(text.contains("static let machine = Probe(strayProcess: { EngineBusy.strayProcess() }"),
                      "and .machine must be wired to the live observation")
    }

    // MARK: - …proved by running it

    /// A "bundled engine" the size of the claim: an installer that decides whether it works, and
    /// a version stamp that must only survive success.
    private func fixtureEngine(installerExits code: Int, version: String) throws -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("engine-fixture-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("bin"),
                                                withIntermediateDirectories: true)
        try "#!/bin/bash\nexit \(code)\n".write(to: dir.appendingPathComponent("install.sh"),
                                                 atomically: true, encoding: .utf8)
        try "#!/bin/bash\n".write(to: dir.appendingPathComponent("bin/verify.sh"),
                                  atomically: true, encoding: .utf8)
        try "\(version)\n".write(to: dir.appendingPathComponent(".engine-version"),
                                  atomically: true, encoding: .utf8)
        return dir
    }

    /// The defect the tester walked into, run rather than read: the copy lands, the installer then
    /// fails, and the machine must not come out of it holding the new version number. Restore the
    /// old order — stamp copied along with everything else — and this is the assertion that fails.
    func testAFailedInstallLeavesNoVersionBehind() async throws {
        let bundled = try fixtureEngine(installerExits: 1, version: "202609139999")
        let target = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("engine-target-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        let oldStamp = target.appendingPathComponent(".engine-version")
        try "202501010001\n".write(to: oldStamp, atomically: true, encoding: .utf8)
        // Aged deliberately. Every build number is the same twelve digits, so rsync's size check
        // can never tell two stamps apart and the decision falls entirely to the timestamp — a
        // fixture written a moment ago would be skipped as unchanged, and this test would then be
        // demonstrating rsync's granularity instead of the rule it is here to hold.
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -86_400)],
                                              ofItemAtPath: oldStamp.path)
        defer {
            try? FileManager.default.removeItem(at: bundled)
            try? FileManager.default.removeItem(at: target)
        }

        let outcome = await EngineInstaller.install(from: bundled, to: target)
        XCTAssertFalse(outcome.ok, "an installer that exited 1 did not install anything")
        XCTAssertNil(OrchestratorHome.version(of: target),
                     "a half-installed engine that reports a version is read as ready and never retried")
    }

    func testASuccessfulInstallTakesTheVersionItCameFrom() async throws {
        let bundled = try fixtureEngine(installerExits: 0, version: "202609139999")
        let target = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("engine-target-\(UUID().uuidString)")
        defer {
            try? FileManager.default.removeItem(at: bundled)
            try? FileManager.default.removeItem(at: target)
        }

        let outcome = await EngineInstaller.install(from: bundled, to: target)
        XCTAssertTrue(outcome.ok, "log: \(outcome.log)")
        XCTAssertEqual(OrchestratorHome.version(of: target), "202609139999",
                       "and only then does the installed copy claim the build it came from")
    }

    // MARK: - Two installs, one directory

    private func scratch() -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("engine-claim-\(UUID().uuidString)")
    }

    /// Installing at launch means the app can now start one while a person presses the button, or
    /// while a second process does the same thing. Both write to one directory with rsync.
    func testOnlyOneInstallCanHoldTheDirectory() throws {
        let target = scratch()
        let first = try XCTUnwrap(EngineInstaller.Claim.take(for: target))
        XCTAssertNil(EngineInstaller.Claim.take(for: target),
                     "a second installer must not copy into a directory being copied into")
        first.release()
        let third = try XCTUnwrap(EngineInstaller.Claim.take(for: target),
                                  "and the claim must be available again once it is let go")
        third.release()
    }

    /// A copy interrupted partway leaves a tree that looks engine-shaped from a distance. The app
    /// installs by itself now, so "quit during the copy" is a state a user can reach — and the
    /// terminal symlink used to accept such a tree as a working engine.
    func testAHalfCopiedTreeIsNotAnEngine() throws {
        let root = scratch()
        try FileManager.default.createDirectory(at: root.appendingPathComponent("supervisor"),
                                                withIntermediateDirectories: true)
        try "# standards\n".write(to: root.appendingPathComponent("supervisor/STANDARDS.md"),
                                  atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: root) }

        XCTAssertFalse(OrchestratorHome.isEngine(at: root),
                       "without the scripts the app calls, this is the wreckage of a copy")

        try FileManager.default.createDirectory(at: root.appendingPathComponent("bin"),
                                                withIntermediateDirectories: true)
        try "#!/bin/bash\n".write(to: root.appendingPathComponent("bin/verify.sh"),
                                  atomically: true, encoding: .utf8)
        XCTAssertTrue(OrchestratorHome.isEngine(at: root))
    }

    // MARK: - What a fresh machine looks like

    /// The case the whole change exists for: somebody installs Bulava for the first time. There is
    /// no ~/Library/Application Support/Bulava yet, so the claim was being made inside a directory
    /// that did not exist — and a first launch was told that another installation was already
    /// running. Nothing else in this file caught it, because every fixture above sits in a
    /// temporary directory that already exists.
    func testTheFirstInstallOnAMachineThatHasNeverHadOne() async throws {
        let bundled = try fixtureEngine(installerExits: 0, version: "202609139999")
        let home = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("fresh-mac-\(UUID().uuidString)")
        let target = home.appendingPathComponent("Application Support/Bulava/engine")
        defer {
            try? FileManager.default.removeItem(at: bundled)
            try? FileManager.default.removeItem(at: home)
        }

        let outcome = await EngineInstaller.install(from: bundled, to: target)
        XCTAssertTrue(outcome.ok, "a first install must not fail: \(outcome.log)")
        XCTAssertEqual(OrchestratorHome.version(of: target), "202609139999")
    }

    /// A reinstall of the SAME version that fails while copying used to leave the old stamp in
    /// place — and the old stamp is the current version, so the app read a half-replaced tree as
    /// ready. The stamp goes before anything is written, not after the copy has worked.
    func testACopyThatFailsLeavesNoVersionEither() async throws {
        let missing = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("no-such-engine-\(UUID().uuidString)")
        let target = scratch()
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        try "202609139999\n".write(to: target.appendingPathComponent(".engine-version"),
                                   atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: target) }

        let outcome = await EngineInstaller.install(from: missing, to: target)
        XCTAssertFalse(outcome.ok, "there was nothing to copy from")
        XCTAssertNil(OrchestratorHome.version(of: target),
                     "a tree that may be half-replaced must not still claim the current version")
    }

    /// The property that replaces every pid file and staleness rule this went through: the lock
    /// belongs to the kernel, so a holder that dies — quit, crashed, killed — releases it on the
    /// way out, and nothing has to decide whether a lock is abandoned.
    func testALockDiesWithTheProcessHoldingIt() throws {
        let python = "/usr/bin/python3"
        try XCTSkipUnless(FileManager.default.isExecutableFile(atPath: python),
                          "needs python3 to hold the lock from outside this process")
        let target = scratch()
        let path = target.path + ".install-claim"
        defer { try? FileManager.default.removeItem(at: URL(fileURLWithPath: path)) }

        let holder = Process()
        holder.executableURL = URL(fileURLWithPath: python)
        holder.arguments = ["-c", """
import fcntl, sys, time
f = open(sys.argv[1], 'w')
fcntl.flock(f, fcntl.LOCK_EX)
print('held', flush=True)
time.sleep(30)
""", path]
        let out = Pipe(); holder.standardOutput = out
        try holder.run()
        defer { if holder.isRunning { holder.terminate() } }
        _ = out.fileHandleForReading.availableData   // blocks until the child says it holds it

        XCTAssertNil(EngineInstaller.Claim.take(for: target),
                     "another process is copying into this directory right now")

        holder.terminate(); holder.waitUntilExit()
        var free: EngineInstaller.Claim?
        for _ in 0..<50 where free == nil {
            free = EngineInstaller.Claim.take(for: target)
            if free == nil { Thread.sleep(forTimeInterval: 0.05) }
        }
        XCTAssertNotNil(free, "the kernel releases a lock when its holder dies; nothing else has to")
        free?.release()
    }

    /// Releasing gives up the lock without deleting the file it lives in. Removing it is what the
    /// two earlier attempts did, and it is what made them racy: a file that is never unlinked has
    /// nothing to race over.
    func testReleasingLeavesTheLockFileAlone() throws {
        let target = scratch()
        let path = target.path + ".install-claim"
        defer { try? FileManager.default.removeItem(at: URL(fileURLWithPath: path)) }

        let claim = try XCTUnwrap(EngineInstaller.Claim.take(for: target))
        claim.release()
        XCTAssertTrue(FileManager.default.fileExists(atPath: path))
        let again = try XCTUnwrap(EngineInstaller.Claim.take(for: target),
                                  "and the file being there is not itself a lock")
        again.release()
    }

    /// Same process, two claims. `flock` denies the second open as readily as it denies another
    /// process, which is what makes the launch-time install and the button collide here.
    func testTwoClaimsInOneProcessCollideToo() throws {
        let target = scratch()
        defer { try? FileManager.default.removeItem(at: URL(fileURLWithPath: target.path + ".install-claim")) }
        let first = try XCTUnwrap(EngineInstaller.Claim.take(for: target))
        XCTAssertNil(EngineInstaller.Claim.take(for: target))
        first.release()
    }

    /// Upgrading from the two releases that kept their lock in a directory. One left behind by an
    /// install that died would make every open() here fail — and this is the code that decides
    /// whether a person can install anything at all, so the failure would be permanent.
    func testALockDirectoryLeftByAnOlderVersionDoesNotBlockForever() throws {
        let target = scratch()
        let legacy = target.path + ".install-lock"
        try FileManager.default.createDirectory(atPath: legacy, withIntermediateDirectories: true)
        try "4242\n".write(to: URL(fileURLWithPath: legacy).appendingPathComponent("pid"),
                           atomically: true, encoding: .utf8)
        defer {
            try? FileManager.default.removeItem(atPath: legacy)
            try? FileManager.default.removeItem(atPath: target.path + ".install-claim")
        }

        let claim = try XCTUnwrap(EngineInstaller.Claim.take(for: target),
                                  "a lock from a version that locked differently is not a lock")
        XCTAssertFalse(FileManager.default.fileExists(atPath: legacy),
                       "and the holder sweeps up what that version left")
        claim.release()
    }

    /// The app can be quit mid-install, and the rsync it started keeps going: Foundation closes
    /// every descriptor in a child, so that rsync does not hold the lock and the next launch is
    /// given it immediately — over a directory still being written into.
    func testAnRsyncThatOutlivedTheAppIsNoticed() async throws {
        let target = scratch()
        defer { try? FileManager.default.removeItem(atPath: target.path + ".install-claim") }
        XCTAssertFalse(EngineInstaller.writerStillRunning(in: target))

        let orphan = Process()
        orphan.executableURL = URL(fileURLWithPath: "/bin/sh")
        orphan.arguments = ["-c", "sleep 5; : rsync -a \(target.path)/"]
        try orphan.run()
        defer { if orphan.isRunning { orphan.terminate() } }

        var seen = false
        for _ in 0..<50 where !seen {
            seen = EngineInstaller.writerStillRunning(in: target)
            if !seen { try await Task.sleep(nanoseconds: 50_000_000) }
        }
        XCTAssertTrue(seen, "a copy into this directory is still in flight")

        let bundled = try fixtureEngine(installerExits: 0, version: "202609139999")
        defer { try? FileManager.default.removeItem(at: bundled) }
        let outcome = await EngineInstaller.install(from: bundled, to: target)
        XCTAssertFalse(outcome.ok, "installing over a copy in progress is how both end up broken")

        orphan.terminate(); orphan.waitUntilExit()
    }

    // MARK: - A wall with no way through it

    /// What the tester actually met. The engine is older than the app, so Bulava starts nothing
    /// until it is replaced — and replacing it was refused, because a run was still supervised.
    /// Stopping that run from the other screen does not help either: `night-shift stop` leaves the
    /// tmux session open on purpose, and an open session holds the engine too. The refusal knew the
    /// run's name the whole time and offered nothing to do with it.
    func testWorkThatBlocksTheEngineIsNamedWellEnoughToStop() {
        var inst = instance("Highline College")
        inst.watchdogAlive = true
        guard let holder = EngineBusy.blocker(instances: [inst], on: .quiet)?.holder else {
            return XCTFail("the refusal named the run and offered nothing to do with it")
        }
        XCTAssertEqual(holder.name, "Highline College")
        XCTAssertEqual(holder.projectPath, "/tmp/Highline College")
        XCTAssertEqual(holder.session, "night-Highline College",
                       "the session has to be named too — stopping the run leaves it open")
    }

    /// Stopping one of two and then discovering the second leaves somebody who pressed "stop and
    /// install" with their work stopped and no engine installed — worse off than before they
    /// touched it. So the button has to know about all of them before it promises anything.
    func testEveryRunHoldingTheEngineIsCounted() {
        var working = instance("Ledger"); working.workerStatus = "busy"
        var supervised = instance("Highline College"); supervised.watchdogAlive = true
        let blocker = EngineBusy.blocker(instances: [working, supervised], on: .quiet)
        XCTAssertEqual(blocker?.holders.count, 2, "one press has to account for both")
        XCTAssertTrue(blocker?.text.contains("Ledger") == true,
                      "and the sentence names the most pressing one")
        XCTAssertEqual(Set((blocker?.holders ?? []).map(\.name)), ["Ledger", "Highline College"])
    }

    /// A run that is merely registered holds nothing: it is finished work whose folder is still
    /// there, and stopping it would be stopping nothing.
    func testAnIdleFinishedRunIsNotAHolder() {
        var done = instance("Ledger")
        done.workerStatus = "idle"
        XCTAssertNil(EngineBusy.blocker(instances: [done], on: .quiet))
    }

    /// …but only when there is a run to stop. A process that outlived its own run, or a session
    /// with no instance behind it, is something to be told about, not something to offer to end.
    func testAProcessWithNoRunBehindItIsNotOfferedAsSomethingToStop() {
        let stray = EngineBusy.Probe(strayProcess: { "message-pump.sh" }, workerSession: { false })
        let blocker = EngineBusy.blocker(instances: [], on: stray)
        XCTAssertNotNil(blocker, "it still holds the engine")
        XCTAssertNil(blocker?.holder, "there is no run left to stop")

        let session = EngineBusy.Probe(strayProcess: { nil }, workerSession: { true })
        XCTAssertNil(EngineBusy.blocker(instances: [], on: session)?.holder)
    }

    /// Stopping is not the same as gone: the watchdog is killed outright, but the pump and the
    /// pipeline notice on their own next poll. Installing inside that gap is refused for a process
    /// already on its way out — and the person is told a stranger's process is in the way, having
    /// done exactly what was asked.
    func testItWaitsForTheLastProcessesToFinishDying() async {
        let polls = Counter()
        let held = await EngineBusy.waitUntilFree(
            check: {
                polls.bump() < 4 ? EngineBusy.Blocker(text: "a message-pump.sh is still going") : nil
            },
            wait: { }, attempts: 40)
        XCTAssertNil(held, "it came free on the fourth look and the install should have gone ahead")
        XCTAssertEqual(polls.value, 4)
    }

    /// A counter the injected closures can share without being on an actor.
    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var n = 0
        func bump() -> Int { lock.lock(); defer { lock.unlock() }; n += 1; return n }
        var value: Int { lock.lock(); defer { lock.unlock() }; return n }
    }

    func testWaitingGivesUpAndSaysWhatIsStillHoldingIt() async {
        let held = await EngineBusy.waitUntilFree(
            check: { EngineBusy.Blocker(text: "“Ledger” is working") },
            wait: { }, attempts: 3)
        XCTAssertEqual(held?.text, "“Ledger” is working",
                       "after waiting it has to name what is there, not install over it")
    }

    /// A stop that did not take must never be followed by an install.
    func testAFailedStopIsReportedInTermsOfTheWork() {
        let refused = AppModel.engineHolderProblem(.stopRefused("no such instance"),
                                                   name: "Highline College")
        XCTAssertTrue(refused.contains("Highline College"))
        XCTAssertTrue(refused.contains("no such instance"))
        XCTAssertTrue(AppModel.engineHolderProblem(.sessionRemains, name: "Ledger").contains("Ledger"))
    }
}
