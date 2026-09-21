import Foundation

/// Whether anything is using the engine right now — asked of the machine, not of a snapshot.
///
/// Replacing the engine means rsyncing over its directory and rewriting Claude Code's hooks. Do
/// that while a run is in flight and the scripts change underneath a worker mid-turn: the hooks it
/// is about to call are not the ones it started with, and the night ends quietly.
///
/// The tempting shortcut is "the app has just launched, so nothing can be running". It is false.
/// The engine deliberately outlives the app — `dispatch.sh` starts the watchdog and the message
/// pump with `nohup` and disowns them, precisely so that closing Bulava does not interrupt a
/// preparation already under way. So this asks the operating system: are those processes there,
/// are those tmux sessions there, does any instance on disk still have a living watchdog?
nonisolated enum EngineBusy {

    /// What this asks the operating system, in a shape a test can supply instead.
    ///
    /// Not decoration: the machine writing this engine is itself running one, so a test asserting
    /// "an idle machine is idle" against the real probe asserts something about the developer's
    /// afternoon rather than about the code. The decision and the observation are separated so the
    /// first can be checked on its own.
    struct Probe: Sendable {
        var strayProcess: @Sendable () -> String?
        var workerSession: @Sendable () -> Bool

        /// What production uses: the processes and sessions actually on this Mac.
        static let machine = Probe(strayProcess: { EngineBusy.strayProcess() },
                                   workerSession: { EngineBusy.liveWorkerSession() })
        /// A machine with nothing of the engine's running on it.
        static let quiet = Probe(strayProcess: { nil }, workerSession: { false })
    }

    /// The work holding the engine, when it can be named and stopped.
    ///
    /// Without this the refusal was a dead end. A tester met a required wall — the engine is older
    /// than the app, and Bulava starts nothing until it is replaced — and the only button on it
    /// refused, because a run was still supervised. The refusal knew the run's name and the app
    /// already knew how to stop a run; there was nothing between the two, so the screens sent him
    /// back and forth. Naming the holder is what lets the wall offer a way through.
    struct Holder: Equatable, Sendable {
        var name: String
        var projectPath: String
        var session: String
    }

    struct Blocker: Equatable, Sendable {
        /// One short line saying what is using the engine, for whoever just pressed a button.
        var text: String
        /// Every run holding it, not only the one the sentence names. Stopping one of two and then
        /// discovering the second leaves somebody who pressed "stop and install" with work stopped
        /// and no engine installed — worse off than before they touched it.
        ///
        /// Empty when nothing identifiable owns it: a process that outlived its run, a session with
        /// no instance behind it. Offering to "stop" one of those would be offering to stop
        /// something the app cannot see the shape of.
        var holders: [Holder] = []

        var holder: Holder? { holders.first }
    }

    /// Nil when the engine is genuinely idle. Otherwise one short line saying what is using it,
    /// fit to show a person who just pressed a button and deserves to know why nothing happened.
    static func reason(instances: [SupervisorInstance], on probe: Probe = .machine) -> String? {
        blocker(instances: instances, on: probe)?.text
    }

    static func blocker(instances: [SupervisorInstance], on probe: Probe = .machine) -> Blocker? {
        // Everything that would refuse an install, in the order it is reported — so the sentence
        // names the most pressing one and the button knows about all of them.
        let holding = instances.filter {
            $0.workerStatus == "busy" || $0.reviewActive || $0.auditState == "audit_running"
                || $0.queuedWork || $0.preparing || $0.watchdogAlive
        }
        let holders = holding.map {
            Holder(name: $0.projectName, projectPath: $0.projectPath, session: $0.session)
        }
        func held(_ inst: SupervisorInstance, _ format: String) -> Blocker {
            Blocker(text: String(format: format, inst.projectName), holders: holders)
        }
        if let inst = instances.first(where: { $0.workerStatus == "busy" }) {
            return held(inst, String(localized: "“%@” is working"))
        }
        if let inst = instances.first(where: { $0.reviewActive || $0.auditState == "audit_running" }) {
            return held(inst, String(localized: "“%@” is being reviewed"))
        }
        if let inst = instances.first(where: { $0.queuedWork || $0.preparing }) {
            return held(inst, String(localized: "“%@” has a message it has not delivered yet"))
        }
        if let inst = instances.first(where: { $0.watchdogAlive }) {
            return held(inst, String(localized: "“%@” is still being supervised"))
        }
        // Instances are read from disk, so a run whose folder was removed leaves nothing above to
        // find — and its processes can still be alive. This session found one such pump running
        // forty minutes after its run had been torn down. Nothing here can be offered as a button:
        // there is no run left to stop, only a process to be told about.
        if let stray = probe.strayProcess() {
            return Blocker(text: String(format: String(localized: "a %@ from an earlier run is still going"),
                                        stray))
        }
        if probe.workerSession() {
            return Blocker(text: String(localized: "a worker session is still open in tmux"))
        }
        return nil
    }

    /// Waits for the engine to actually come free after the work holding it has been stopped.
    ///
    /// Stopping a run does not end everything at once: the watchdog is killed outright, but the
    /// message pump and the pipeline notice their run has gone on their own next poll, seconds
    /// later. Installing in that gap is refused for a process that is already on its way out — so
    /// the person who just pressed "stop and install" would be told a stranger's process is in the
    /// way, having done exactly what was asked.
    ///
    /// Returns nil once nothing holds it, or whatever still does when the waiting runs out.
    static func waitUntilFree(check: @Sendable () async -> Blocker?,
                              wait: @Sendable () async -> Void,
                              attempts: Int = 40) async -> Blocker? {
        var last: Blocker?
        for attempt in 0..<max(1, attempts) {
            last = await check()
            if last == nil { return nil }
            if attempt + 1 < attempts { await wait() }
        }
        return last
    }

    /// The engine's own long-running programs, by name, wherever they came from.
    private static func strayProcess() -> String? {
        for name in ["watchdog.sh", "message-pump.sh", "pipeline.sh"] where processExists(name) {
            return name
        }
        return nil
    }

    /// Visible to the tests, which prove it answers both yes and no about a process they
    /// start and stop themselves — an injected probe is worth nothing if the real one is blind.
    static func processExists(_ needle: String) -> Bool {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        p.arguments = ["-f", needle]
        let out = Pipe(); p.standardOutput = out; p.standardError = Pipe()
        do { try p.run() } catch { return false }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return !data.isEmpty
    }

    /// A worker lives in a tmux session named after its run. One still open means a Claude is
    /// sitting in it, whether or not anything else can see the run any more.
    private static func liveWorkerSession() -> Bool {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/bash")
        p.arguments = ["-lc", "tmux list-sessions -F '#S' 2>/dev/null | grep -c '^night-' || true"]
        let out = Pipe(); p.standardOutput = out; p.standardError = Pipe()
        do { try p.run() } catch { return false }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        let n = Int(String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? "0") ?? 0
        return n > 0
    }
}
