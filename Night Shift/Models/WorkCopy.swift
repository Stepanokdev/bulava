import Foundation

/// A separate checkout of one of his repositories that a run works in instead of his folder.
///
/// A git linked worktree on a branch of its own, in a folder Bulava owns
/// (`~/Library/Developer/Bulava/copies`), never inside any repository: the engine matches a
/// folder to its run by the longest path prefix, so a copy nested in another project's tree could
/// come out unsupervised. His folder, his branch and his uncommitted work are never touched while
/// the copy is in use; only an explicit merge moves his branch, and only forward.
nonisolated struct WorkCopy: Identifiable, Codable, Equatable, Sendable {
    nonisolated enum State: String, Codable, Sendable {
        /// Being created. A copy left in this state was interrupted and is cleaned up.
        case preparing
        /// A run or a chat works in it.
        case active
        /// The work is done and waits for him: merge it or throw it away.
        case waiting
        case merged
        case discarded
        /// The folder is gone and its branch dealt with. Kept as history.
        case removed
    }

    nonisolated enum Owner: Codable, Equatable, Sendable {
        case run(UUID)
        case chat(UUID)
        /// A card started while its project was busy.
        case task(UUID)
    }

    var id: UUID
    /// The folder the work happens in — the copy's counterpart of `sourcePath`.
    var path: String
    /// The top of the copy's checkout. Equal to `path` unless his folder is a subfolder of a repo.
    var checkoutRoot: String
    /// His folder.
    var sourcePath: String
    /// The top of his repository.
    var sourceRoot: String
    var projectID: UUID
    /// The copy's own branch.
    var branch: String
    /// The branch it started from, and where a merge goes.
    var baseRef: String
    var baseSHA: String
    var owner: Owner
    var state: State
    var createdAt: Date
    var removedAt: Date?
    /// Ignored files copied in from his folder (`.worktreeinclude`). Copies, so disposable.
    var copiedFiles: [String]
    var mergedSHA: String?
    var note: String?

    init(id: UUID = UUID(), path: String, checkoutRoot: String, sourcePath: String,
         sourceRoot: String, projectID: UUID, branch: String, baseRef: String, baseSHA: String,
         owner: Owner, state: State = .preparing, createdAt: Date = Date(),
         copiedFiles: [String] = []) {
        self.id = id
        self.path = path
        self.checkoutRoot = checkoutRoot
        self.sourcePath = sourcePath
        self.sourceRoot = sourceRoot
        self.projectID = projectID
        self.branch = branch
        self.baseRef = baseRef
        self.baseSHA = baseSHA
        self.owner = owner
        self.state = state
        self.createdAt = createdAt
        self.copiedFiles = copiedFiles
    }

    /// Something may still work in it.
    var isLive: Bool { state == .preparing || state == .active || state == .waiting }

    /// Not finished with on disk: anything but removed. A merged or discarded copy whose removal
    /// did not complete is still the sweep's business.
    var needsReconciling: Bool { state != .removed }

    var name: String { (checkoutRoot as NSString).lastPathComponent }
}

/// What is in a copy right now, read off git.
nonisolated struct WorkCopyStatus: Equatable, Sendable {
    /// Commits on the copy's branch that its base does not have.
    var commitsAhead: Int
    /// Tracked and untracked changes not committed yet.
    var uncommitted: [String]
    /// Ignored files that are neither build output nor copied in — someone's work that a removal
    /// would delete. Their presence keeps the copy.
    var keepsakes: [String]
    var exists: Bool
    /// git answered every question. When it did not, nothing about the copy may be concluded —
    /// least of all that it is empty.
    var inspected: Bool = true

    var hasWork: Bool { commitsAhead > 0 || !uncommitted.isEmpty }

    static let missing = WorkCopyStatus(commitsAhead: 0, uncommitted: [], keepsakes: [], exists: false,
                                        inspected: false)
}
