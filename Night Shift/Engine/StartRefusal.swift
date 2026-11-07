import Foundation

/// The engine's marker lines for a start that stopped on something only the person can clear.
///
/// Neither is a failure: nothing is broken, so nothing is repaired or reported. Both reached us as
/// anonymous error reports from 1.14 (20 Oct), because a start that ended without one of the exit
/// codes the app listens for was taken for a broken one.
nonisolated enum StartRefusal {
    /// Claude Code sat on its sign-in screen, and the start was rolled back.
    static func needsSignIn(_ output: String) -> Bool { says(output, "handshake-blocked=login") }

    /// The folder is a workspace of repositories, a git store or a piece of a repository — the
    /// engine will not make git there, and the start was refused before anything was touched.
    static func notAProject(_ output: String) -> Bool { says(output, "start-refused=folder") }

    /// A command-line tool the engine runs on is not on this Mac — the engine names it in
    /// `start-refused=tool:<name>`. A Mac set up without tmux met «tmux не встановлено» on its first
    /// message, and 1.17 offered to repair it and sent it to us as `chat.start_failed` (5 Nov).
    /// The tool's name, or nil; a name that is not a plain command name is not taken from the line.
    static func missingTool(_ output: String) -> String? {
        let prefix = "start-refused=tool:"
        for line in output.split(whereSeparator: \.isNewline) where line.hasPrefix(prefix) {
            let name = line.dropFirst(prefix.count)
            if !name.isEmpty, name.count <= 40,
               name.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || "-_.+".contains($0)) }) {
                return String(name)
            }
        }
        return nil
    }

    /// The Homebrew formula that installs a tool the engine named, for the tools Bulava's own
    /// readiness screen already installs that way. Nil for any other name: no button guesses.
    static func brewFormula(forTool tool: String) -> String? {
        ["tmux": "tmux", "jq": "jq"][tool]
    }

    /// What the person reads when a start or a send stopped on a missing tool.
    static func missingToolMessage(_ tool: String) -> String {
        String(format: String(localized: "%@ is not installed on this Mac, so this was not sent. Bulava needs it to run a chat."), tool)
    }

    /// Claude Code no longer keeps the conversation a resume asked for — its own clean-up of old
    /// transcripts removed it — so there is nothing to bring back and nothing for a repair to fix.
    /// Reached us as `chat.resume_failed` from 1.16.1 (23 Oct).
    static func conversationGone(_ output: String) -> Bool { says(output, "resume-refused=transcript") }

    /// What stands between a chat and its folder before the engine is even asked: the folder is
    /// gone — moved, renamed, a drive not mounted — or macOS will not let Bulava into it. Nil when
    /// it is there and readable. The engine refused such a start with «Проєкт не знайдено», and
    /// 1.16.3 sent every retry to us as `chat.start_failed` and offered to repair it (30 Oct).
    ///
    /// Told apart by `stat`'s errno, not by `fileExists`: a folder in Documents without access
    /// answers EPERM, and calling that one gone would send the person looking for something that
    /// is right where they left it.
    static func folderProblem(path: String, name: String) -> String? {
        var info = stat()
        if stat(path, &info) == 0 {
            let isDir = (info.st_mode & S_IFMT) == S_IFDIR
            // Search, not read: the engine only needs to `cd` there, and a folder it can enter but
            // not list still takes a message into a running turn.
            if isDir, access(path, X_OK) == 0 { return nil }
            if isDir { return cannotRead(path: path, name: name) }
            return notThere(path: path, name: name)
        }
        return errno == EACCES || errno == EPERM
            ? cannotRead(path: path, name: name)
            : notThere(path: path, name: name)
    }

    private static func notThere(path: String, name: String) -> String {
        String(format: String(localized: "The folder of “%@” is not there (%@). Was it moved or deleted? Update the project's path and start again."), name, path)
    }

    private static func cannotRead(path: String, name: String) -> String {
        String(format: String(localized: "I cannot read the folder of “%@” (%@). Give Bulava access to it in System Settings, or connect another path."), name, path)
    }

    /// The engine's own words, without the marker lines that are meant for the app alone.
    static func withoutMarkers(_ output: String) -> String {
        output.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !isMarker($0) }
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func says(_ output: String, _ marker: String) -> Bool {
        output.split(whereSeparator: \.isNewline).contains { $0 == marker }
    }

    private static func isMarker(_ line: Substring) -> Bool {
        line.hasPrefix("handshake-blocked=") || line.hasPrefix("start-refused=")
            || line.hasPrefix("resume-refused=")
    }
}
