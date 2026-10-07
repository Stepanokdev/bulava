import Foundation

/// The director's uncommitted work in a folder a run is about to start in, as the engine reports it
/// (`night-shift dirty-state`).
///
/// A start used to commit all of it silently — `git add -A`, as `night-shift`, into the branch the
/// director was on. Now the engine stops with exit 77 and the app asks: leave the changes where they
/// are, commit them under the director's own name, or let the director sort them out their own way
/// and carry on once the folder is clean. This is what the question is asked about, and its digest
/// is what the answer is checked against: a commit covers the files that were on the screen.
nonisolated struct DirtyTree: Sendable, Equatable, Decodable {
    nonisolated struct Entry: Sendable, Equatable, Decodable, Identifiable {
        let xy: String
        let path: String
        var id: String { xy + path }

        nonisolated enum Kind: Sendable { case modified, added, deleted, renamed, untracked, conflicted }

        /// Porcelain `XY` read the way a person reads a file list: what happened to it, whichever
        /// half (staged or not) it happened in.
        var kind: Kind {
            let chars = Array(xy)
            let x = chars.first ?? " ", y = chars.count > 1 ? chars[1] : " "
            if xy == "??" { return .untracked }
            if x == "U" || y == "U" || xy == "AA" || xy == "DD" { return .conflicted }
            if x == "R" || x == "C" { return .renamed }
            if x == "D" || y == "D" { return .deleted }
            if x == "A" { return .added }
            return .modified
        }

        /// Staged, at least in part — the split a commit made by the app will not keep.
        var isStaged: Bool {
            guard let x = xy.first else { return false }
            return x != " " && x != "?"
        }
    }

    let dirty: Bool
    let unborn: Bool
    let head: String
    let branch: String
    let digest: String
    let author: String?
    let keepPossible: Bool
    let total: Int
    let files: [Entry]

    nonisolated enum CodingKeys: String, CodingKey {
        case dirty, unborn, head, branch, digest, author, total, files
        case keepPossible = "keep_possible"
    }

    static func parse(_ text: String) -> DirtyTree? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let line = trimmed.split(whereSeparator: \.isNewline).last,
              let data = String(line).data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(DirtyTree.self, from: data)
    }

    /// Nothing is left for the question to be about — the director committed, stashed or dropped it.
    var isSettled: Bool { !dirty && !unborn }

    var hasStagedSplit: Bool { files.contains(where: \.isStaged) && files.contains { !$0.isStaged } }

    /// The subject a commit made from the app starts with. The director edits it; this is only
    /// something better than an empty field.
    var suggestedMessage: String {
        if unborn { return "Initial commit" }
        let names = files.prefix(3).map { ($0.path as NSString).lastPathComponent }
        guard !names.isEmpty else { return "Work in progress" }
        let rest = total - names.count
        return "WIP: " + names.joined(separator: ", ") + (rest > 0 ? " +\(rest)" : "")
    }
}

/// What the director answered, in the form the engine reads (`SUPERVISOR_DIRTY*`).
nonisolated enum DirtyTreeChoice: Sendable, Equatable {
    /// Start, and leave the changes exactly where they are — the engine keeps a snapshot to measure
    /// the run against and to restore from.
    case keep
    /// Commit everything that was listed, as the director, with this message.
    case commit(message: String, digest: String)

    var env: [String: String] {
        switch self {
        case .keep:
            return ["SUPERVISOR_DIRTY": "keep"]
        case .commit(let message, let digest):
            var env = ["SUPERVISOR_DIRTY": "commit", "SUPERVISOR_DIRTY_DIGEST": digest]
            let text = message.trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty { env["SUPERVISOR_COMMIT_MESSAGE"] = text }
            return env
        }
    }
}
