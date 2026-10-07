import Foundation

/// The files that made a start's checkpoint too big, as the engine wrote them down
/// (`night-shift heavy-state`, after a start stopped with exit 79).
///
/// A four-gigabyte screen recording lying untracked in a folder used to stop every start there with
/// a red paragraph about megabytes. The engine now names the files, biggest first, and the answer —
/// leave them out of checkpoints — is applied by the engine to this same list, never to paths the
/// app hands over.
nonisolated struct HeavyFiles: Sendable, Equatable, Decodable {
    nonisolated struct File: Sendable, Equatable, Decodable, Identifiable {
        /// Relative to the project folder.
        let path: String
        let size: Int64
        /// Already in git. An ignore rule cannot take it out of a checkpoint, and the engine does not
        /// untrack anybody's file.
        let tracked: Bool
        /// The `.gitignore` line for it. Nil for a tracked file, and for a name git cannot hold on one
        /// line — neither can be left out by a rule.
        let rule: String?
        var id: String { path }

        var name: String { (path as NSString).lastPathComponent }
        /// The folder inside the project, or empty when the file lies at its top.
        var folder: String {
            let dir = (path as NSString).deletingLastPathComponent
            return dir == "." ? "" : dir
        }
        var canLeaveOut: Bool { !tracked && rule != nil }
    }

    let totalBytes: Int64
    let limitBytes: Int64
    let fileLimitBytes: Int64
    /// What the checkpoint would weigh with every file that can be left out left out.
    let remainingBytes: Int64
    /// Whether that is within both limits — false when tracked files alone are too heavy.
    let fitsAfter: Bool
    let files: [File]

    nonisolated enum CodingKeys: String, CodingKey {
        case files
        case totalBytes = "total_bytes"
        case limitBytes = "limit_bytes"
        case fileLimitBytes = "file_limit_bytes"
        case remainingBytes = "remaining_bytes"
        case fitsAfter = "fits_after"
    }

    static func parse(_ text: String) -> HeavyFiles? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let line = trimmed.split(whereSeparator: \.isNewline).last,
              let data = String(line).data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(HeavyFiles.self, from: data)
    }

    var leavable: [File] { files.filter(\.canLeaveOut) }
    var tracked: [File] { files.filter(\.tracked) }
    /// There is something the buttons can do.
    var canLeaveOut: Bool { !leavable.isEmpty }
}

/// Where «leave them out» is written.
nonisolated enum HeavyFilesRule: String, Sendable {
    /// The engine's own record and `.git/info/exclude` — nothing changes in the project.
    case local
    /// The project's `.gitignore`, because the director asked for exactly that.
    case gitignore
}
