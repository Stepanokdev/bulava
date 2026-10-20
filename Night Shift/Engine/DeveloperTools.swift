import Foundation

/// Whether git and python3 are really on this Mac, or only Apple's stand-ins for them.
///
/// `/usr/bin/git` and `/usr/bin/python3` are on every Mac. Until Apple's command line tools are
/// installed they are stand-ins: running one asks macOS to install the tools — a dialog — and exits
/// with "No developer tools were found". `command -v` finds them all the same, so the readiness
/// screen called both available while the engine's installer died on python3 with Apple's words as
/// its reason (a 1.13 user's report, 2026-10-11).
///
/// Answered from the disk and never by running the tool: on exactly the Mac this is about, running
/// it IS the dialog — and readiness is checked every twenty minutes.
nonisolated enum DeveloperTools {

    /// Bulava's tools that macOS ships only as a stand-in in /usr/bin. Not every tool there is one:
    /// macOS 15 ships a real jq, and reading it as a stand-in would block work on every Mac
    /// without Xcode.
    static let standIns: Set<String> = ["git", "python3"]

    /// What `xcode-select -p` answered.
    enum Directory: Equatable, Sendable {
        case at(String)
        /// It answered that there is none.
        case absent
        /// It could not be asked: it did not start, or did not finish. Not evidence of anything.
        case unknown
    }

    /// Whether `path` — what `command -v name` printed — is Apple's stand-in. Resolved first: a
    /// /usr/local/bin/git that links to /usr/bin/git is the same stand-in under another name.
    static func isStandIn(_ name: String, at path: String,
                          resolve: (String) -> String = { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path })
        -> Bool {
        guard standIns.contains(name), !path.isEmpty else { return false }
        return resolve(path) == "/usr/bin/" + name
    }

    /// True only when it is proven that `name`, found at `path`, cannot run until macOS installs
    /// Apple's command line tools.
    ///
    /// A stand-in runs the real tool out of the developer directory — the command line tools or
    /// Xcode — and asks for the install when that directory has none. So the question is whether
    /// the directory carries it: `xcode-select -p` repeats a DEVELOPER_DIR whether or not it
    /// exists, and a selection can outlive the tools it named. A probe that could not be asked
    /// proves nothing, and nothing is claimed — a false «missing» here stops every run on a Mac
    /// that works.
    static func needsCommandLineTools(_ name: String, at path: String, developerDirectory: Directory,
                                      isExecutable: (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) },
                                      resolve: (String) -> String = { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path })
        -> Bool {
        guard isStandIn(name, at: path, resolve: resolve) else { return false }
        switch developerDirectory {
        case .at(let dir): return !isExecutable((dir as NSString).appendingPathComponent("usr/bin/" + name))
        case .absent:      return true
        case .unknown:     return false
        }
    }

    /// The same question about this Mac. xcode-select is asked only for a stand-in.
    static func needsCommandLineTools(_ name: String, at path: String) async -> Bool {
        guard isStandIn(name, at: path) else { return false }
        return needsCommandLineTools(name, at: path, developerDirectory: await developerDirectory())
    }

    /// …about `name` as the engine will meet it: first on the PATH Bulava runs things with.
    static func needsCommandLineTools(_ name: String) async -> Bool {
        let found = await Shell.run("command -v \"$1\" 2>/dev/null || true", args: [name], timeout: 10)
        return await needsCommandLineTools(name, at: found.stdout.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// `xcode-select -p`, in the environment the tools themselves run in. It only reads a setting;
    /// it never offers to install anything.
    static func developerDirectory() async -> Directory {
        let result = await Shell.run("/usr/bin/xcode-select -p 2>/dev/null", timeout: 10)
        guard result.launched, result.endedBy == .exited else { return .unknown }
        let dir = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        return result.exitCode == 0 && !dir.isEmpty ? .at(dir) : .absent
    }
}
