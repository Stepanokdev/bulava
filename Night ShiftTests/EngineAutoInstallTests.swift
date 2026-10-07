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

        // A stand-in that IS an rsync by name, copying into this directory — which is what the
        // probe now asks, rather than whether some command line mentions the words.
        let bin = scratch()
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let fake = bin.appendingPathComponent("rsync")
        try "#!/bin/sh\nsleep 5\n".write(to: fake, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fake.path)
        defer { try? FileManager.default.removeItem(at: bin) }

        let orphan = Process()
        orphan.executableURL = fake
        orphan.arguments = ["-a", "/tmp/source/", "\(target.path)/"]
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

    /// A process that outlived its run is not somebody's work to stop — it is the engine's own
    /// leftover, and the wall offers to end it. It used to say only that it was there, with no
    /// button, and the one button on the screen repeated the refused install.
    func testALeftoverWithNoRunBehindItIsOfferedToBeEnded() {
        let stray = EngineBusy.Probe(strayProcess: { [EngineBusy.Leftover(pid: 4242, name: "message-pump.sh")] },
                                     workerSession: { [] })
        let blocker = EngineBusy.blocker(instances: [], on: stray)
        XCTAssertNotNil(blocker, "it still holds the engine")
        XCTAssertNil(blocker?.holder, "there is no run left to stop")
        XCTAssertEqual(blocker?.leftovers.map(\.pid), [4242], "but there is a process to end")
        XCTAssertTrue(blocker?.hasLeftovers == true)

        let session = EngineBusy.Probe(strayProcess: { [] }, workerSession: { ["night-gone"] })
        let held = EngineBusy.blocker(instances: [], on: session)
        XCTAssertNil(held?.holder)
        XCTAssertEqual(held?.orphanSessions, ["night-gone"], "and a session to close")
    }

    /// A run that is working is named and asked about; its own watchdog, which runs out of the same
    /// directory, is not listed beside it as a "leftover".
    func testALiveRunIsNotDressedUpAsALeftover() {
        var inst = instance("Ledger"); inst.watchdogAlive = true
        let probe = EngineBusy.Probe(strayProcess: { [EngineBusy.Leftover(pid: 1, name: "watchdog.sh")] },
                                     workerSession: { [] })
        let blocker = EngineBusy.blocker(instances: [inst], on: probe)
        XCTAssertEqual(blocker?.holder?.name, "Ledger")
        XCTAssertTrue(blocker?.leftovers.isEmpty == true)
    }

    // MARK: - Which processes belong to the engine being replaced

    /// The machine this was found on: the installed engine's path has a space in it, the checkout's
    /// too, temporary folders are reached through `/var` and `/private/var`, and a reviewer's prompt
    /// quoted the script's name. Only a daemon running OUT OF the install target holds it.
    func testOnlyDaemonsRunningFromTheTargetHoldIt() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("engine owner \(UUID().uuidString)")
        let target = root.appendingPathComponent("Application Support/Bulava/engine")
        let checkout = root.appendingPathComponent("Night Shift/engine")
        for dir in [target, checkout] {
            try FileManager.default.createDirectory(at: dir.appendingPathComponent("bin"),
                                                    withIntermediateDirectories: true)
        }
        defer { try? FileManager.default.removeItem(at: root) }
        // `/var/folders/…` and `/private/var/folders/…` are one place.
        let viaVar = target.path.replacingOccurrences(of: "/private/var/", with: "/var/")

        let table: [ProcessTable.Entry] = [
            .init(pid: 10, argv: ["/bin/bash", target.path + "/bin/watchdog.sh", "proj-1"]),
            .init(pid: 11, argv: ["/bin/bash", viaVar + "/bin/message-pump.sh", "proj-1"]),
            .init(pid: 12, argv: ["/bin/bash", checkout.path + "/bin/watchdog.sh", "proj-2"]),
            .init(pid: 13, argv: ["/bin/bash", "/private/var/folders/x/T/tmp.AB/engine/bin/watchdog.sh", "project-1"]),
            .init(pid: 14, argv: ["node", "/opt/codex/bin/codex.js", "exec",
                                  "why does \(target.path)/bin/watchdog.sh keep running?"]),
            .init(pid: 15, argv: ["grep", "watchdog.sh"]),
            .init(pid: 16, argv: ["/bin/bash", "-c", "\(target.path)/bin/watchdog.sh x; sleep 1"]),
            .init(pid: 17, argv: ["/bin/bash", target.path + "/bin/pipeline.sh", "proj-1"]),
            .init(pid: 18, argv: ["/bin/bash", target.path + "/bin/night-shift.sh", "status"]),
            .init(pid: 19, argv: ["/bin/bash", "bin/watchdog.sh", "proj-3"]),
        ]
        let cwd: (Int32) -> String? = { $0 == 19 ? target.path : nil }
        let found = EngineProcesses.daemons(of: target, in: table, cwd: cwd)
        XCTAssertEqual(found.map(\.pid), [10, 11, 17, 19],
                       "the target's own daemons, however their path was spelled — and nothing else")
        XCTAssertEqual(found.map(\.name), ["watchdog.sh", "message-pump.sh", "pipeline.sh", "watchdog.sh"])
    }

    /// The install target is a sibling-prefix of nothing: `engine2` is not inside `engine`.
    func testASiblingDirectoryIsNotInsideTheTarget() {
        XCTAssertFalse(ProcessTable.path("/tmp/x/engine2/bin/watchdog.sh", isInside: "/tmp/x/engine"))
        XCTAssertTrue(ProcessTable.path("/tmp/x/engine/bin/watchdog.sh", isInside: "/tmp/x/engine"))
        XCTAssertTrue(ProcessTable.path("/tmp/x/engine", isInside: "/tmp/x/engine/"))
    }

    /// The same for the copy itself: it is rsync, and it writes into the target.
    func testAnRsyncIsAWriterOnlyWhenItCopiesIntoTheTarget() {
        let target = URL(fileURLWithPath: "/Users/someone/Library/Application Support/Bulava/engine")
        let table: [ProcessTable.Entry] = [
            .init(pid: 1, argv: ["/usr/bin/rsync", "-a", "--delete", "/Applications/Bulava.app/Contents/Resources/engine/",
                                 target.path + "/"]),
            .init(pid: 2, argv: ["/usr/bin/rsync", "-a", "/a/", "/b/"]),
            .init(pid: 3, argv: ["claude", "-p", "rsync -a src/ \(target.path)/ keeps failing"]),
        ]
        XCTAssertEqual(EngineProcesses.writers(into: target, in: table), [1])
    }

    /// The kernel's own record of a process, read back exactly — a path with a space in it stays
    /// one argument, which is the whole reason this does not parse `ps`.
    func testTheProcessTableReadsArgumentsExactly() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("engine probe \(UUID().uuidString)/bin")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir.deletingLastPathComponent()) }
        let script = dir.appendingPathComponent("watchdog.sh")
        try "#!/bin/bash\nsleep 5\n".write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)

        let p = Process()
        p.executableURL = script
        p.arguments = ["slug with space"]
        try p.run()
        defer { if p.isRunning { p.terminate() } }

        var argv: [String]?
        for _ in 0..<50 {
            argv = ProcessTable.arguments(of: p.processIdentifier)
            if argv?.contains(script.path) == true { break }
            Thread.sleep(forTimeInterval: 0.05)
        }
        XCTAssertEqual(argv?.last, "slug with space")
        XCTAssertTrue(argv?.contains(script.path) == true, "argv: \(argv ?? [])")

        let engine = dir.deletingLastPathComponent()
        let mine = EngineProcesses.daemons(of: engine, in: ProcessTable.snapshot())
        XCTAssertTrue(mine.contains { $0.pid == p.processIdentifier },
                      "the live probe found the daemon running out of this engine")
        let other = EngineProcesses.daemons(of: engine.appendingPathComponent("elsewhere"),
                                            in: ProcessTable.snapshot())
        XCTAssertFalse(other.contains { $0.pid == p.processIdentifier })
    }

    /// Ending a leftover ends it — and only a process still running out of the engine is touched.
    func testEndingALeftoverEndsItAndNothingElse() async throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("engine end \(UUID().uuidString)/bin")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir.deletingLastPathComponent()) }
        let script = dir.appendingPathComponent("watchdog.sh")
        try "#!/bin/bash\nwhile :; do sleep 1; done\n".write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)

        let leftover = Process(); leftover.executableURL = script; leftover.arguments = ["x"]
        let bystander = Process()
        bystander.executableURL = URL(fileURLWithPath: "/bin/sleep"); bystander.arguments = ["5"]
        try leftover.run(); try bystander.run()
        defer { if leftover.isRunning { leftover.terminate() }; if bystander.isRunning { bystander.terminate() } }
        try await Task.sleep(nanoseconds: 300_000_000)

        let engine = dir.deletingLastPathComponent()
        let alive = await EngineBusy.end([.init(pid: leftover.processIdentifier, name: "watchdog.sh"),
                                          .init(pid: bystander.processIdentifier, name: "watchdog.sh")],
                                         engine: engine, grace: 2)
        XCTAssertTrue(alive.isEmpty)
        leftover.waitUntilExit()
        XCTAssertFalse(leftover.isRunning, "the leftover is gone")
        XCTAssertTrue(bystander.isRunning, "a pid that is not running this engine is never signalled")
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
