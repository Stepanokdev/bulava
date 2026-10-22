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
    }
}
