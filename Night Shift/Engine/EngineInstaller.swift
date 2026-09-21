import Foundation

/// Installing the app is the whole installation.
///
/// The engine travels inside the app bundle and is copied out to a stable place on first use,
/// then installs itself: it writes Claude Code's hooks (backing up what was there) and puts the
/// terminal commands on PATH. Two reasons it is copied rather than run in place — the hooks are
/// written as absolute paths, and a path inside the bundle changes with every update; and the
/// engine writes state next to itself, which has no business living inside a signed bundle.
nonisolated enum EngineInstaller {

    /// One installation at a time, across processes.
    ///
    /// `mkdir` either creates the directory or fails; there is no window between asking and having
    /// it. The engine claims its composer the same way (`delivery_claim` in supervisor-lib.sh), and
    /// this is that pattern in Swift — a Swift-side flag would only serialise one app, and the
    /// engine can also be installed from a second process or a terminal.
    struct Claim {
        private let fd: Int32

        /// Nil when somebody else is installing right now.
        ///
        /// The lock is the kernel's, not a directory this code reasons about. Two earlier versions
        /// of this tried to run mutual exclusion out of a directory and a pid file, and both were
        /// wrong in the same way: deciding a lock is abandoned and then removing it are separate
        /// steps, so two installers can both decide, both remove, and both create their own. There
        /// is no arrangement of pid files that fixes that, because the flaw is the gap between
        /// looking and acting.
        ///
        /// `flock` closes the gap. The file is created once and never unlinked — nothing to race
        /// over — and the lock lives on the open file, so it is released when the process exits
        /// however it exits, including being killed. A second `open` of the same file in the same
        /// process is denied too, so a launch-time install and a button press collide here rather
        /// than in the engine's directory.
        static func take(for target: URL) -> Claim? {
            let path = target.path + ".install-claim"
            // On a Mac that has never run Bulava this directory does not exist yet, and creating
            // the lock inside it would fail for that reason alone — which is how the first release
            // of this came to tell every new user that another installation was already running.
            try? FileManager.default.createDirectory(
                at: URL(fileURLWithPath: path).deletingLastPathComponent(),
                withIntermediateDirectories: true)

            let fd = open(path, O_CREAT | O_RDWR | O_CLOEXEC, 0o644)
            guard fd >= 0 else { return nil }
            guard flock(fd, LOCK_EX | LOCK_NB) == 0 else { close(fd); return nil }

            // 1.6.1 and 1.6.2 kept their lock in a DIRECTORY, at a path of their own. Opening a
            // directory as a file fails, and that failure would read as contention — so this lock
            // lives somewhere else entirely rather than trying to migrate the old one out of the
            // way, which two installers could have done to each other at the same moment. What is
            // left is litter, and only whoever holds the lock sweeps it.
            try? FileManager.default.removeItem(atPath: target.path + ".install-lock")
            return Claim(fd: fd)
        }

        func release() {
            flock(fd, LOCK_UN)
            close(fd)
        }
    }

    struct Outcome: Sendable {
        var ok: Bool
        var log: String
        var installedAt: URL?
    }

    /// Copies the bundled engine over the installed one and runs its installer.
    ///
    /// Never touches a development checkout: on the machine where the engine is being written,
    /// the working copy is the truth and replacing it would silently discard someone's work.
    static func install() async -> Outcome {
        guard let bundled = OrchestratorHome.bundled else {
            return Outcome(ok: false,
                           log: String(localized: "This build carries no engine — nothing to install."),
                           installedAt: nil)
        }
        return await install(from: bundled, to: OrchestratorHome.installed)
    }

    /// The same installation against directories named outright, so that the rule below — a failed
    /// install must not leave a version stamp behind — can be proved by running it on a fixture
    /// rather than by reading the source and trusting the order of the lines.
    static func install(from bundled: URL, to target: URL) async -> Outcome {
        let fm = FileManager.default
        // A writer from an install whose app is gone. Foundation spawns children with every
        // descriptor closed, so an rsync started by a previous launch does not hold the lock and
        // the kernel hands it straight to this one — while that rsync is still writing into the
        // very directory this install is about to copy over.
        if writerStillRunning(in: target) {
            return Outcome(ok: false,
                           log: String(localized: "Another installation is already running."),
                           installedAt: nil)
        }
        guard let claim = Claim.take(for: target) else {
            return Outcome(ok: false,
                           log: String(localized: "Another installation is already running."),
                           installedAt: nil)
        }
        defer { claim.release() }
        // Asked again now that the lock is held. Before it, an install could still be starting a
        // copy this one had already looked for and not found; after it, no install can start one.
        guard !writerStillRunning(in: target) else {
            return Outcome(ok: false,
                           log: String(localized: "Another installation is already running."),
                           installedAt: nil)
        }

        do {
            try fm.createDirectory(at: target.deletingLastPathComponent(),
                                   withIntermediateDirectories: true)
        } catch {
            return Outcome(ok: false, log: error.localizedDescription, installedAt: nil)
        }

        // The stamp goes first, before a single file is touched. It used to be cleared after the
        // copy, which left one case standing: reinstalling the version already there, with rsync
        // failing partway. The number on disk was then the current one, over a tree half replaced.
        let stamp = ".engine-version"
        let stampURL = target.appendingPathComponent(stamp)
        do {
            try fm.removeItem(at: stampURL)
        } catch CocoaError.fileNoSuchFile {
            // Nothing installed here yet, or nothing that ever said what it was.
        } catch {
            return Outcome(ok: false, log: String(localized:
                "The engine's version file could not be replaced, so nothing was copied."),
                           installedAt: nil)
        }

        // Copied through rsync rather than replaced wholesale: the engine's own directory may
        // hold a run's state, and deleting it out from under a live run would end that run.
        //
        // Two directories are held back from `--delete`, and neither is the engine's. The memory
        // store belongs to whoever runs it. `supervisor/lessons` is the same thing one version
        // older: before the store was split out, the director's `_global.md` and `projects/*.md`
        // sat in the checkout itself, and this engine ships no such directory — so without the
        // exclusion, updating the app would delete their writing as a side effect of copying.
        // `install.sh` runs straight after this and moves anything found there into the store.
        //
        // It used to travel with everything else, which meant a copy that landed and an installer
        // that then failed left the new version number sitting on a half-installed engine: hooks
        // never written, terminal commands never linked — and `installedIsStale` comparing that
        // number against the app's, finding them equal, and reporting the machine ready. The one
        // state that must never be reachable is "broken and calls itself finished". Writing the
        // stamp last makes a failure look exactly like what it is — still stale — so the next
        // launch tries again instead of walking into it.
        let copy = await Shell.run(
            "/usr/bin/rsync -a --delete --exclude 'supervisor/memory' --exclude 'supervisor/lessons' --exclude \"$3\" \"$1/\" \"$2/\" 2>&1",
            args: [bundled.path, target.path, stamp], timeout: 120)
        guard copy.exitCode == 0 else {
            return Outcome(ok: false, log: copy.stdout + copy.stderr, installedAt: nil)
        }
        let installer = target.appendingPathComponent("install.sh")
        guard fm.fileExists(atPath: installer.path) else {
            return Outcome(ok: false,
                           log: String(localized: "The engine was copied but carries no installer."),
                           installedAt: target)
        }
        let run = await Shell.run("cd \"$1\" && /bin/bash ./install.sh 2>&1",
                                  args: [target.path], timeout: 300)
        guard run.exitCode == 0 else {
            return Outcome(ok: false, log: (run.stdout + run.stderr).trimmedTail, installedAt: target)
        }
        // Everything worked. Only now does this copy get to call itself the version it came from —
        // and if that cannot be written down, the install is not finished, whatever else succeeded:
        // an engine nobody can identify is one the app will keep replacing at every launch.
        if let version = try? String(contentsOf: bundled.appendingPathComponent(stamp),
                                     encoding: .utf8) {
            do {
                try version.write(to: stampURL, atomically: true, encoding: .utf8)
            } catch {
                return Outcome(ok: false, log: String(localized:
                    "The engine was installed, but its version could not be written down."),
                               installedAt: target)
            }
        }
        return Outcome(ok: true, log: (run.stdout + run.stderr).trimmedTail, installedAt: target)
    }

    /// An rsync of this engine that outlived the app that started it.
    static func writerStillRunning(in target: URL) -> Bool {
        EngineBusy.processExists("rsync.*\(target.path)")
    }

    /// What the readiness screen needs to say about the engine, in one value.
    enum State: Sendable, Equatable {
        case development(URL)     // this machine builds the engine; nothing to install
        case ready(URL)           // installed and current
        case stale(URL)           // installed, but from an older app than this one
        case notInstalled         // the app carries one and can install it
        case unavailable          // no engine anywhere, and none bundled either
    }

    static func state() -> State {
        if let dev = OrchestratorHome.development { return .development(dev) }
        if OrchestratorHome.installedIsStale { return .stale(OrchestratorHome.installed) }
        if let home = OrchestratorHome.detect() { return .ready(home) }
        return OrchestratorHome.bundled == nil ? .unavailable : .notInstalled
    }
}
