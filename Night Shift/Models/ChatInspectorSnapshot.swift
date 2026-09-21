import Foundation

nonisolated struct ChatInspectorProject: Sendable, Equatable {
    var id: UUID?
    var name: String
    var path: String
    var access: ResourceAccess
    var isPrimary: Bool
}

nonisolated enum ChatFileChangeKind: String, Sendable, Equatable {
    case added
    case modified
    case deleted
    case renamed
    case copied
    case untracked
    case conflicted
    case typeChanged
    case unknown

    var labelKey: String {
        switch self {
        case .added:       "Added"
        case .modified:    "Modified"
        case .deleted:     "Deleted"
        case .renamed:     "Renamed"
        case .copied:      "Copied"
        case .untracked:   "Untracked"
        case .conflicted:  "Conflict"
        case .typeChanged: "Type changed"
        case .unknown:     "Changed"
        }
    }
}

nonisolated struct ChatFileChange: Identifiable, Sendable, Equatable {
    var path: String
    var previousPath: String?
    var kind: ChatFileChangeKind
    var staged: Bool
    var added: Int?
    var removed: Int?

    var id: String { path }
    var filename: String { (path as NSString).lastPathComponent }
}

nonisolated struct ChatProjectInspection: Identifiable, Sendable, Equatable {
    var project: ChatInspectorProject
    var isGitRepository: Bool
    var branch: String?
    var changes: [ChatFileChange]

    var id: String { project.path }
}

nonisolated struct ChatInspectorSnapshot: Sendable {
    var projects: [ChatProjectInspection]
    var evidence: Evidence?
    var loadedAt: Date

    static let empty = ChatInspectorSnapshot(projects: [], evidence: nil, loadedAt: .distantPast)

    var changedProjects: [ChatProjectInspection] { projects.filter { !$0.changes.isEmpty } }
    var changeCount: Int { projects.reduce(0) { $0 + $1.changes.count } }
}
