import Foundation

nonisolated struct RunStrategy: Sendable, Equatable {

    var claudeEffort: String

    var codexEffort: String

    var isolated: Bool

    var claudeModel: String = ""

    var codexModel: String = ""

    var reportLanguage: String = "Ukrainian"

    var workBranch: String = ""

    var reportWriter: String = "codex"

    // MARK: Deciding

    static func decide(for task: BacklogTask, projectIsBusy: Bool) -> RunStrategy {
        let claude: String
        switch true {
        case task.planSteps.count >= 5:             claude = "ultracode"
        case task.planSteps.count > 1:              claude = "xhigh"
        case task.type == .research || task.runMode == .audit: claude = "medium"
        case task.surfaceVisual:                    claude = "high"
        default:                                    claude = "high"
        }

        let codex = (task.type == .research || task.runMode == .audit) ? "medium" : "high"
        return RunStrategy(claudeEffort: claude, codexEffort: codex, isolated: projectIsBusy)
    }

    static func safeModelID(_ raw: String) -> String {
        let allowed = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-")
        return String(raw.trimmingCharacters(in: .whitespacesAndNewlines).filter { allowed.contains($0) })
    }

    static let standing = RunStrategy(claudeEffort: "high", codexEffort: "high", isolated: false)

    func speaking(_ language: String) -> RunStrategy {
        var out = self
        if !language.isEmpty { out.reportLanguage = language }
        return out
    }

    func written(by writer: String) -> RunStrategy {
        var out = self
        if !writer.isEmpty { out.reportWriter = writer }
        return out
    }

    func onBranch(_ branch: String?) -> RunStrategy {
        var out = self
        out.workBranch = branch ?? ""
        return out
    }

    // MARK: The director overriding it

    /// The catalogue is passed in because the model has the last word on depth, and the per-task
    /// depth above was decided before anyone knew which model would run it. Haiku 4.5 has no
    /// reasoning levels at all and gets no `--effort`; Opus 4.6 does not take `xhigh` and gets the
    /// deepest level it does take. Without a catalogue nothing is taken away — which is what a
    /// machine that has never run the CLI gets.
    func overridden(by settings: AppSettings,
                    claudeModels: ClaudeModelCatalog = .empty) -> RunStrategy {
        var out = self
        if settings.claudeEffort != .auto { out.claudeEffort = settings.claudeEffort.flagValue }
        if settings.codexEffort != .auto { out.codexEffort = settings.codexEffort.flagValue }
        out.claudeModel = settings.claudeModel.flagValue
        out.codexModel = Self.safeModelID(settings.codexModel)
        out.claudeEffort = claudeModels.supportedEffort(out.claudeEffort, for: settings.claudeModel)
        return out
    }
}
