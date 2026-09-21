import Foundation

/// What is actually inside a folder somebody just connected — asked of the engine, not decided here.
///
/// A director connected a workspace: fifteen independent checkouts side by side, plus a python venv,
/// Tutor's runtime data and a Chrome profile. Bulava treated it as one project, the engine saw "not
/// a git repository" and made one out of it — 23 108 files staged, 495 MB of objects, the project's
/// secrets in the index, and a start that never returned.
///
/// The first fix put the rule in two places: here, and in the engine's `nested_repos_in`. They
/// disagreed in three ways at once — depth was counted from different things, a damaged store was a
/// repository to one and not the other, and vendored checkouts leaked into the engine's list. Each
/// divergence meant the app showed one thing and the engine did another, which is the worst shape a
/// bug can take: everything looks right until it runs.
///
/// So there is one rule now, and it lives in the engine. This asks `night-shift scan-folder` and
/// reads the answer. The engine is already a hard dependency — nothing runs without it — so this
/// adds no new one.
nonisolated enum WorkspaceScan {

    /// What a folder turned out to be. The engine decides; these are its words.
    enum Kind: String, Sendable {
        /// A working copy with its own history. A project, whatever is nested inside it.
        case repo
        /// Its real content is other people's repositories.
        case container
        /// Files. No git anywhere — and none will be made without the director saying so.
        case plain
        /// A bare or damaged git store. Nothing runs in it, and nothing may be created over it.
        case storage
        /// Part of somebody else's repository. A second git inside the first is two histories in
        /// one tree.
        case inside
        /// The folder could not be seen whole, and an empty result proves nothing.
        case unknown
    }

    struct Findings: Sendable, Equatable {
        var kind: Kind = .unknown
        /// Absolute paths of the repositories found inside — or, for `inside`, the owning one.
        var repositories: [String] = []
        /// Git stores that are not projects, as `(kind, path)` where kind is `bare` or `broken`.
        var storages: [(String, String)] = []
        /// False when the walk ran out of depth, time or patience.
        var complete = true
        /// Why it stopped, in the engine's words. Empty when it did not.
        var incompleteReason = ""

        var isContainer: Bool { kind == .container }

        static func == (a: Findings, b: Findings) -> Bool {
            a.kind == b.kind && a.repositories == b.repositories && a.complete == b.complete
                && a.incompleteReason == b.incompleteReason
                && a.storages.map(\.1) == b.storages.map(\.1)
        }
    }

    // MARK: - Asking the engine

    static func inspect(path: String) async -> Findings {
        guard let home = OrchestratorHome.detect()?.path else {
            // No engine means nothing can run anyway. Saying "ordinary folder" here would be a
            // guess dressed as an answer.
            return Findings(kind: .unknown, complete: false,
                            incompleteReason: String(localized: "The engine is not installed yet."))
        }
        let r = await Shell.run("bash \"$1/bin/night-shift.sh\" scan-folder \"$2\"",
                                args: [home, path], timeout: 120)
        guard r.launched else {
            return Findings(kind: .unknown, complete: false,
                            incompleteReason: String(localized: "Could not look inside the folder."))
        }
        return parse(r.stdout)
    }

    /// The engine's machine format, and nothing clever: a line it did not write is a line this
    /// ignores.
    static func parse(_ text: String) -> Findings {
        var out = Findings()
        for line in text.split(whereSeparator: \.isNewline) {
            let parts = line.split(separator: "\t", omittingEmptySubsequences: false)
            switch parts.first.map(String.init) ?? "" {
            case let head where head.hasPrefix("kind="):
                out.kind = Kind(rawValue: String(head.dropFirst("kind=".count))) ?? .unknown
            case let head where head.hasPrefix("complete="):
                out.complete = head.hasSuffix("=yes")
            case let head where head.hasPrefix("why="):
                out.incompleteReason = String(head.dropFirst("why=".count))
            case "repo":
                if parts.count >= 2 { out.repositories.append(String(parts[1])) }
            case "storage":
                if parts.count >= 3 { out.storages.append((String(parts[1]), String(parts[2]))) }
            default:
                continue
            }
        }
        return out
    }

    // MARK: - What to connect

    /// What connecting this folder should actually produce.
    ///
    /// For an ordinary folder that is the folder itself, exactly as before. For a workspace it is
    /// the repositories inside it — what the director would have connected by hand, one at a time,
    /// if they had known they needed to.
    static func connection(for path: String) async -> FolderConnection {
        let chosen = Slug.canonicalPath(path)
        let findings = await inspect(path: chosen)
        guard findings.kind == .container else {
            return FolderConnection(
                container: nil,
                folders: [ConnectableFolder(name: (chosen as NSString).lastPathComponent, path: chosen)],
                complete: findings.complete,
                kind: findings.kind,
                incompleteReason: findings.incompleteReason)
        }
        return FolderConnection(
            container: chosen,
            folders: findings.repositories.map {
                ConnectableFolder(name: relativeName(of: $0, under: chosen), path: $0)
            },
            complete: findings.complete,
            kind: findings.kind,
            incompleteReason: findings.incompleteReason)
    }

    /// The repositories of a container, named the way a person would name them: by their path
    /// relative to the folder they were found in, so two `frontend-app-home` checkouts under
    /// different parents stay tellable apart.
    static func relativeName(of repository: String, under container: String) -> String {
        let base = container.hasSuffix("/") ? container : container + "/"
        guard repository.hasPrefix(base) else { return (repository as NSString).lastPathComponent }
        let relative = String(repository.dropFirst(base.count))
        return relative.isEmpty ? (repository as NSString).lastPathComponent : relative
    }
}

// MARK: - Connectable folders

nonisolated struct ConnectableFolder: Identifiable, Sendable, Equatable {
    var name: String
    var path: String
    var id: String { path }
}

nonisolated struct FolderConnection: Sendable, Equatable {
    /// The workspace these came out of, or nil when the chosen folder is itself the project.
    var container: String?
    var folders: [ConnectableFolder]
    var complete: Bool
    var kind: WorkspaceScan.Kind = .plain
    var incompleteReason: String = ""

    var isExpansion: Bool { container != nil }
}
