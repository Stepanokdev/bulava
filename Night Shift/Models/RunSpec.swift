import Foundation

nonisolated struct RunSpec: Codable, Sendable {
    var schema: Int = 1
    let taskID: String
    let mode: String
    let objective: String
    var acceptance: [String]
    var nonGoals: [String]
    var surface: Surface
    var writePaths: [String]
    var capabilities: Capabilities
    var verificationProfile: String
    var budgets: Budgets

    nonisolated struct Surface: Codable, Sendable {
        var userFacingCopy, visual, behavior, ui: Bool?
        enum CodingKeys: String, CodingKey {
            case userFacingCopy = "user_facing_copy"
            case visual, behavior, ui
        }

        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encodeIfPresent(userFacingCopy, forKey: .userFacingCopy)
            try c.encodeIfPresent(visual, forKey: .visual)
            try c.encodeIfPresent(behavior, forKey: .behavior)
            try c.encodeIfPresent(ui, forKey: .ui)
        }
    }

    nonisolated struct Capabilities: Codable, Sendable {
        var network, push, externalFsWrite: Bool?
        enum CodingKeys: String, CodingKey {
            case network, push
            case externalFsWrite = "external_fs_write"
        }
        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encodeIfPresent(network, forKey: .network)
            try c.encodeIfPresent(push, forKey: .push)
            try c.encodeIfPresent(externalFsWrite, forKey: .externalFsWrite)
        }
    }
    nonisolated struct Budgets: Codable, Sendable {
        var builds, devices, uiInteractions, screenshots: Int
        enum CodingKeys: String, CodingKey {
            case builds, devices
            case uiInteractions = "ui_interactions"
            case screenshots
        }
    }

    enum CodingKeys: String, CodingKey {
        case schema
        case taskID = "task_id"
        case mode, objective, acceptance
        case nonGoals = "non_goals"
        case surface
        case writePaths = "write_paths"
        case capabilities
        case verificationProfile = "verification_profile"
        case budgets
    }

    static func infer(from task: BacklogTask, projectPath: String) -> RunSpec {

        let paths = task.writePaths
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        let requested = task.runMode?.rawValue ?? "broad"
        let mode: String = {
            if requested == "broad" { return "broad" }
            if requested == "audit" { return "audit" }
            return paths.isEmpty ? "broad" : requested
        }()

        func known(_ flag: Bool) -> Bool? { flag ? true : nil }
        let surface = Surface(userFacingCopy: known(task.surfaceUserFacingCopy),
                              visual: known(task.surfaceVisual),
                              behavior: known(task.surfaceBehavior),
                              ui: known(task.surfaceVisual))
        return RunSpec(
            taskID: task.reportKey,
            mode: mode,
            objective: task.title,
            acceptance: task.acceptance,
            nonGoals: task.nonGoals,
            surface: surface,
            writePaths: paths,

            capabilities: Capabilities(network: nil, push: nil, externalFsWrite: nil),
            verificationProfile: task.verificationProfile?.rawValue ?? "standard",
            budgets: Budgets(builds: 1, devices: 1, uiInteractions: 15, screenshots: 1))
    }
}
