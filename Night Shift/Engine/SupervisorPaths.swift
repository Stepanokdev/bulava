import Foundation

nonisolated struct SupervisorPaths: Sendable {
    let stateDir: URL

    init(stateDir: URL) { self.stateDir = stateDir }

    static var `default`: SupervisorPaths {
        if let env = ProcessInfo.processInfo.environment["SUPERVISOR_STATE_DIR"], !env.isEmpty {
            return SupervisorPaths(stateDir: URL(fileURLWithPath: env))
        }
        let home = FileManager.default.homeDirectoryForCurrentUser
        return SupervisorPaths(stateDir: home.appendingPathComponent(".claude/supervisor"))
    }

    var usageJSON: URL       { stateDir.appendingPathComponent("usage.json") }

    var workerEnvJSON: URL   { stateDir.appendingPathComponent("worker-environment.json") }
    var codexUsageJSON: URL  { stateDir.appendingPathComponent("codex-usage.json") }
    var nightModeFlag: URL   { stateDir.appendingPathComponent("night-mode") }
    var supervisorLog: URL   { stateDir.appendingPathComponent("supervisor.log") }
    var watchdogLog: URL     { stateDir.appendingPathComponent("watchdog.log") }
    var codexLog: URL        { stateDir.appendingPathComponent("codex.log") }
    var decisionsJSONL: URL  { stateDir.appendingPathComponent("decisions.jsonl") }

    var instancesDir: URL    { stateDir.appendingPathComponent("instances") }

    func undeliveredDir(slug: String) -> URL {
        stateDir.appendingPathComponent("undelivered").appendingPathComponent(slug)
    }
    var evidenceDir: URL     { stateDir.appendingPathComponent("evidence") }

    func instanceDir(slug: String) -> URL { instancesDir.appendingPathComponent(slug) }

    var runsDir: URL { stateDir.appendingPathComponent("runs") }
    func runDir(runID: String) -> URL { runsDir.appendingPathComponent(runID) }

    func artifactBase(runID: String?, projectPath: String) -> URL? {
        let fm = FileManager.default

        if let runID, !runID.isEmpty {
            let dir = runDir(runID: runID)
            if fm.fileExists(atPath: dir.path) { return dir }
        }

        let inst = instanceDir(slug: Slug.forPath(projectPath))
        guard fm.fileExists(atPath: inst.path) else { return nil }
        let liveID = (try? String(contentsOf: inst.appendingPathComponent("run-id"), encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if let runID, !runID.isEmpty {

            return liveID == runID ? inst : nil
        }

        return inst
    }

    var reportsDir: URL      { stateDir.appendingPathComponent("reports") }
    func reportDir(task8: String) -> URL { reportsDir.appendingPathComponent(task8) }

    var queueDir: URL        { stateDir.appendingPathComponent("queue") }
    var queuePending: URL    { queueDir.appendingPathComponent("pending") }
    var queueDone: URL       { queueDir.appendingPathComponent("done") }
    var queueNeedsUser: URL  { queueDir.appendingPathComponent("needs-user") }
    var queueRunnerPID: URL  { queueDir.appendingPathComponent("runner.pid") }
    var queueStopFlag: URL   { queueDir.appendingPathComponent("stop") }
    var queueCurrent: URL    { queueDir.appendingPathComponent("current") }
    var queueRunnerLog: URL  { queueDir.appendingPathComponent("runner.log") }

    func auditedMarker(sid: String) -> URL { stateDir.appendingPathComponent("audited-\(sid)") }
    func auditState(sid: String) -> URL    { stateDir.appendingPathComponent("audit-state-\(sid)") }
    func roundsFile(sid: String) -> URL    { stateDir.appendingPathComponent("rounds-\(sid)") }
}

enum OrchestratorHome {

    /// Where an installed engine lives. A stable path on purpose: the hooks written into Claude
    /// Code's settings are absolute, and a path inside the app bundle changes with every update.
    nonisolated static var installed: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Bulava/engine")
    }

    /// The copy that shipped inside this build of the app — the source the installer copies from.
    nonisolated static var bundled: URL? {
        guard let url = Bundle.main.url(forResource: "engine", withExtension: nil) else { return nil }
        return FileManager.default.fileExists(atPath: url.appendingPathComponent("install.sh").path)
            ? url : nil
    }

    /// The development checkout, when this machine has one. Kept FIRST so that editing the engine
    /// in the repository still changes what runs — on a machine without it, nothing here matches
    /// and the installed copy answers instead.
    nonisolated static var development: URL? {
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Developer/MyProjects/Night Shift/engine")
        return FileManager.default.fileExists(atPath: url.appendingPathComponent("bin/verify.sh").path)
            ? url : nil
    }

    /// A directory is an engine when it carries the engine's own entry point.
    ///
    /// The terminal symlink used to be trusted on weaker evidence — a `supervisor/STANDARDS.md`
    /// somewhere above it — and a copy interrupted partway through satisfies that while missing
    /// everything the app actually calls. Since the app now installs by itself at launch, an
    /// interrupted copy is a state a user can reach by quitting, and it must read as "not ready"
    /// rather than as an engine.
    nonisolated static func isEngine(at root: URL) -> Bool {
        FileManager.default.fileExists(atPath: root.appendingPathComponent("bin/verify.sh").path)
    }

    nonisolated static func detect() -> URL? {
        let fm = FileManager.default

        if let dev = development { return dev }
        if isEngine(at: installed) { return installed }

        // An engine reached through the terminal command, wherever that points.
        let link = fm.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin/night-shift")
        if let dest = try? fm.destinationOfSymbolicLink(atPath: link.path) {
            let scriptURL = dest.hasPrefix("/")
                ? URL(fileURLWithPath: dest)
                : link.deletingLastPathComponent().appendingPathComponent(dest).standardizedFileURL

            let root = scriptURL.deletingLastPathComponent().deletingLastPathComponent()
            if isEngine(at: root) { return root }
        }
        return nil
    }

    /// The build number the engine at `url` shipped with, or nil for a development checkout that
    /// was never stamped.
    nonisolated static func version(of url: URL) -> String? {
        guard let text = try? String(contentsOf: url.appendingPathComponent(".engine-version"),
                                     encoding: .utf8) else { return nil }
        let v = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return v.isEmpty ? nil : v
    }

    /// True when an engine is installed but came from an older app than this one.
    ///
    /// It matters because the app calls the engine's scripts by name and reads their output: a
    /// copy left behind by a previous version can answer in a shape this build does not expect.
    /// A development checkout is never called stale — it is the one being worked on.
    nonisolated static var installedIsStale: Bool {
        guard development == nil else { return false }
        guard let bundled, let mine = version(of: bundled) else { return false }
        let fm = FileManager.default
        guard fm.fileExists(atPath: installed.appendingPathComponent("bin/verify.sh").path) else {
            return false   // nothing installed yet is a different problem, reported separately
        }
        guard let theirs = version(of: installed) else { return true }
        return (Int(theirs) ?? 0) < (Int(mine) ?? 0)
    }
}
