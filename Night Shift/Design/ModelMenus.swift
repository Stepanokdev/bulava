import SwiftUI

/// The Claude model menu, in both places that offer one.
///
/// Settings and the composer ask the same question, and the answer has grown: families that follow
/// the newest release, and the specific versions the CLI still runs. Two copies of that menu would
/// drift apart the first time the catalogue gained a section, so there is one.
struct ClaudeModelMenu: View {

    @Environment(AppModel.self) private var model

    /// Settings rows sit on a grid and share one width; the composer sizes itself to the choice.
    var width: CGFloat?

    @ViewBuilder var body: some View {
        if let width {
            menu.frame(width: width)
        } else {
            menu.fixedSize()
        }
    }

    private var menu: some View {
        Picker("", selection: Binding(get: { model.settings.claudeModel },
                                      set: { model.chooseClaudeModel($0) })) {
            // Automatic is a choice like any other, and it can say what it does: the CLI's own
            // settings name the model that answers when Bulava passes no `--model`, and the
            // catalogue names the service's default behind that.
            Text(verbatim: familyLabel(.auto))
                .tag(ClaudeModelChoice.auto)

            // The families first, because following the newest model is the right default and the
            // one most people should stay on. Each says what it resolves to today, which is the
            // question "Opus" could never answer on its own.
            Section("Newest of each") {
                ForEach(ClaudeModelChoice.families) { choice in
                    Text(verbatim: familyLabel(choice)).tag(choice)
                }
            }

            if !model.claudeModels.models.isEmpty {
                Section("A fixed version") {
                    ForEach(model.claudeModels.models) { candidate in
                        Text(verbatim: candidate.name)
                            .tag(ClaudeModelChoice(rawValue: candidate.id))
                    }
                }
            }

            // A version pinned on a machine whose catalogue has since moved on is still what the
            // app is sending, and has to be shown as the current value — otherwise the menu reads
            // "Automatic" while the runs say otherwise.
            if model.settings.claudeModel.isPinnedVersion,
               model.claudeModels.model(id: model.settings.claudeModel.rawValue) == nil {
                Text(verbatim: model.settings.claudeModel.rawValue)
                    .tag(model.settings.claudeModel)
            }
        }
        .labelsHidden()
        .pickerStyle(.menu)
        .accessibilityIdentifier("claude.model")
    }

    /// "Opus" on a machine with no catalogue; "Opus · Opus 5" on one that has read it. The same
    /// for "Automatic", which resolves to whatever the CLI would answer with on its own.
    private func familyLabel(_ choice: ClaudeModelChoice) -> String {
        let name = String(localized: choice.label)
        guard let version = model.claudeModels.versionName(for: choice) else { return name }
        return "\(name) · \(version)"
    }
}
