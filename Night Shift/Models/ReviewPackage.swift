import Foundation

nonisolated struct DiffFile: Identifiable, Sendable {
    var path: String
    var added: Int
    var removed: Int
    var id: String { path }
    var filename: String { (path as NSString).lastPathComponent }
}

nonisolated struct ReviewPackage: Sendable {
    var projectPath: String
    var projectName: String
    var branch: String?
    var baseRef: String?
    var baseBranch: String?
    var mergeTarget: String?
    var headSHA: String?
    var mismatch: String?
    var changedFiles: [DiffFile]
    var insertions: Int
    var deletions: Int
    var commits: [String]
    var diffText: String
    var truncatedDiff: Bool
    var evidence: Evidence?
    var auditFile: String?
    var auditExcerpt: String?
    var decisionsExcerpt: String?
    var blockedExcerpt: String?
    var reviewDebtExcerpt: String?

    var reviewState: String?
    var reviewVerdict: String?
    var disposition: String?
    var findings: [String]

    var scopeViolationCount: Int = 0
    var loadedAt: Date

    var reportManifest: ReportManifest? = nil
    var reportDirectory: URL? = nil

    var hasScopeViolation: Bool { disposition == "scope_violation" || scopeViolationCount > 0 }

    nonisolated static func empty(projectPath: String) -> ReviewPackage {
        ReviewPackage(projectPath: projectPath,
                      projectName: (projectPath as NSString).lastPathComponent,
                      branch: nil, baseRef: nil, baseBranch: nil, mergeTarget: nil, headSHA: nil, mismatch: nil,
                      changedFiles: [], insertions: 0, deletions: 0, commits: [],
                      diffText: "", truncatedDiff: false, evidence: nil,
                      auditFile: nil, auditExcerpt: nil, decisionsExcerpt: nil,
                      blockedExcerpt: nil, reviewDebtExcerpt: nil,
                      reviewState: nil, reviewVerdict: nil, disposition: nil, findings: [],
                      loadedAt: Date())
    }

    var hasChanges: Bool { !changedFiles.isEmpty || !diffText.isEmpty }
}

nonisolated enum MergeResult: Sendable {
    case merged
    case dirty
    case conflict
    case noBranch
    case sameBranch
    case notReached
    case failed(String)

    var isSuccess: Bool { if case .merged = self { return true } else { return false } }
    var message: String {
        switch self {
        case .merged: "Merged into the target branch"
        case .dirty: "The target branch has uncommitted changes; commit or stash first"
        case .conflict: "Merge hit conflicts; resolve in the repo, then merge manually"
        case .noBranch: "No branch to merge"
        case .sameBranch: "No separate target branch to merge into (the run reused its own branch); open a PR or pick a target manually"
        case .notReached: "Merge ran but the reviewed commit isn't on the target; nothing was marked merged"
        case .failed(let m): m
        }
    }
}

// MARK: - Acceptance gate (Phase 2 pillar 3 — coordinator refactor)

nonisolated enum ReviewClassKind: Sendable { case visual, code, informational }

nonisolated struct AcceptanceSnapshot: Sendable {
    var reviewClass: ReviewClassKind
    var hasScopeViolation: Bool
    var disposition: String?
    var evidencePresent: Bool
    var evidenceOverallPass: Bool
    var evidenceCleanGreen: Bool
    var evidenceBoundToHead: Bool
    var frameValid: Bool
    var headStable: Bool
}

nonisolated enum AcceptanceGate {
    static func evaluate(_ s: AcceptanceSnapshot) -> String? {
        if !s.headStable { return "Стан проєкту змінився після перевірки — відкрий Review і перевір ще раз." }
        if s.hasScopeViolation { return "Є зміни поза межами задачі — перевір їх у Review, перш ніж приймати." }
        if s.reviewClass == .informational { return nil }
        guard s.disposition == "passed" else { return "Рев'ю ще не підтвердило цю роботу — приймати не можна." }
        guard s.evidencePresent, s.evidenceBoundToHead else { return "Немає перевірки збірки й тестів для цієї версії — запусти Verify." }
        guard s.evidenceOverallPass, s.evidenceCleanGreen else { return "Збірка або тести не пройшли чисто — поверни задачу на доопрацювання." }
        if s.reviewClass == .visual, !s.frameValid { return "Немає доказу «до/після» — потрібен кадр, щоб прийняти візуальну зміну." }
        return nil
    }
}
