import Foundation

nonisolated enum CriterionStatus: String, Sendable {
    case pass, fail, inconclusive, skipped, unknown
    init(raw: String) { self = CriterionStatus(rawValue: raw) ?? .unknown }
}

nonisolated struct EvidenceCriterion: Sendable, Identifiable {
    var criterion: String
    var command: String
    var exitCode: Int
    var artifact: String
    var status: CriterionStatus
    var note: String
    var id: String { criterion + command }
}

nonisolated struct Evidence: Sendable {
    var projectDir: String
    var sessionID: String
    var baseSHA: String
    var headSHA: String
    var treeDigest: String
    var stacks: [String]
    var criteria: [EvidenceCriterion]
    var overallStatus: CriterionStatus

    private struct Raw: Decodable {
        struct Crit: Decodable {
            var criterion: String
            var command: String
            var exit_code: Int
            var artifact: String
            var status: String
            var note: String
        }
        var project_dir: String?
        var session_id: String?
        var base_sha: String?
        var head_sha: String?
        var work_tree_digest: String?
        var stacks: [String]?
        var criteria: [Crit]?
        var overall_status: String?
    }

    static func decode(from data: Data) -> Evidence? {
        guard let raw = try? JSONDecoder().decode(Raw.self, from: data) else { return nil }
        return Evidence(
            projectDir: raw.project_dir ?? "",
            sessionID: raw.session_id ?? "",
            baseSHA: raw.base_sha ?? "",
            headSHA: raw.head_sha ?? "",
            treeDigest: raw.work_tree_digest ?? "",
            stacks: raw.stacks ?? [],
            criteria: (raw.criteria ?? []).map {
                EvidenceCriterion(criterion: $0.criterion, command: $0.command,
                                  exitCode: $0.exit_code, artifact: $0.artifact,
                                  status: CriterionStatus(raw: $0.status), note: $0.note)
            },
            overallStatus: CriterionStatus(raw: raw.overall_status ?? "unknown"))
    }

    var passed: Int { criteria.filter { $0.status == .pass }.count }
    var failed: Int { criteria.filter { $0.status == .fail }.count }
}
