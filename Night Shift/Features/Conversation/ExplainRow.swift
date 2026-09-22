import SwiftUI

/// "Explain what happened", wherever a result lands.
///
/// One affordance, three places — a turn in a conversation, a night task's card, the report card
/// under it — because a result explained one way in one place and another way in another is two
/// features that happen to share a name. The call sites differ only in what they are anchored to.
struct ExplainRow: View {
    @Environment(AppModel.self) private var model

    enum Target {
        case turn(ConversationEntry)
        /// The manifest comes from the card, which has already loaded it.
        case task(BacklogTask, manifest: ReportManifest?)
    }

    let target: Target

    /// Set on the cards, whose own rows are separated by hairlines.
    var showsDivider = false

    @State private var expanded = true

    private var state: ExplainState {
        switch target {
        case .turn(let entry):              model.explainState(turn: entry)
        case .task(let task, let manifest): model.explainState(task: task, manifest: manifest)
        }
    }

    private var profile: String { model.settings.learningProfileForPrompt }

    var body: some View {
        let state = state
        if state.available || state.hasAnything {
            VStack(alignment: .leading, spacing: 0) {
                if showsDivider { Hairline() }
                content(state)
                    .padding(.horizontal, showsDivider ? 15 : 0)
                    .padding(.vertical, showsDivider ? 11 : 0)
            }
            .animation(Motion.standard, value: state.hasAnything)
            .animation(Motion.standard, value: state.isRunning)
        }
    }

    @ViewBuilder private func content(_ state: ExplainState) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            // Normally the short one; the walk-through stands in for it if the short one has
            // aged out of the cache, so an explanation already paid for is never invisible.
            if let head = state.brief ?? state.stepByStep {
                panel(head, state: state)
            } else {
                openingRow(state)
            }
        }
        .frame(maxWidth: MarkdownProse.proseWidth, alignment: .leading)
    }

    // MARK: - Nothing yet

    /// The first press. One button, never a choice between two: which register the explanation is
    /// written in follows from the profile, and a reader cannot be asked to pick between
    /// consequences they have not seen yet.
    @ViewBuilder private func openingRow(_ state: ExplainState) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 8) {
                Button { press(.brief) } label: {
                    Label {
                        Text(state.briefRunning ? openingBusyTitle : openingTitle)
                    } icon: {
                        if state.briefRunning {
                            ProgressView().controlSize(.small)
                        } else {
                            Image(systemName: "graduationcap")
                        }
                    }
                    .labelStyle(.titleAndIcon)
                }
                .buttonStyle(.bulava(.quiet))
                .disabled(!state.available || state.briefRunning)
                .help(Text(openingHelp))
                .accessibilityIdentifier("explain.start")

                Spacer(minLength: 0)
            }
            // Which register the answer comes in, said on the action itself rather than left to
            // be discovered. Free text will not go into a sentence — "for a designer, I read code
            // but do not write it" has no grammar — so it is named on its own line instead of
            // built into the button's label.
            if profile.isEmpty {
                Text("In plain words.")
                    .font(Typo.meta)
                    .foregroundStyle(Palette.textFaint)
            } else {
                Text(String(format: String(localized: "Through what you already know: %@"), profile))
                    .font(Typo.meta)
                    .foregroundStyle(Palette.textFaint)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let failure = state.failure {
                failureLine(failure)
            }
        }
    }

    private var openingTitle: LocalizedStringKey { "Explain what happened" }

    private var openingBusyTitle: LocalizedStringKey { "Working out what happened…" }

    private var openingHelp: LocalizedStringKey {
        profile.isEmpty
            ? "A short read-only explanation of this result, in plain words. It changes nothing and does not interrupt the work."
            : "A short read-only explanation of this result, written through the background you set in Settings. It changes nothing and does not interrupt the work."
    }

    // MARK: - The explanation

    @ViewBuilder private func panel(_ head: Explanation, state: ExplainState) -> some View {
        PanelCard {
            VStack(alignment: .leading, spacing: 0) {
                header(head, state: state)
                Hairline()
                VStack(alignment: .leading, spacing: 10) {
                    if let brief = state.brief { prose(brief.text) }

                    if let steps = state.stepByStep {
                        if state.brief != nil {
                            Hairline()
                            Eyebrow("Step by step")
                        }
                        prose(steps.text)
                    }

                    if state.stale { staleLine() }
                    if let failure = state.failure { failureLine(failure) }

                    if state.available { actions(state) }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 11)
            }
        }
        .transition(.opacity)
    }

    /// Who the explanation was written for, said out loud and stored with it — so it stays true
    /// after the profile in Settings is edited.
    @ViewBuilder private func header(_ head: Explanation, state: ExplainState) -> some View {
        Button { withAnimation(Motion.expand) { expanded.toggle() } } label: {
            HStack(spacing: 7) {
                Image(systemName: "graduationcap")
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(Palette.accentEmphasis)
                Eyebrow("Explained", color: Palette.accentEmphasis)
                if !head.profile.isEmpty {
                    Text(verbatim: "·")
                        .font(Typo.meta)
                        .foregroundStyle(Palette.textFaint)
                    Text(String(format: String(localized: "for %@"), head.profile))
                        .font(Typo.meta)
                        .foregroundStyle(Palette.textFaint)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                Spacer(minLength: 6)
                if state.isRunning { ProgressView().controlSize(.small) }
                Text(Fmt.clock(head.at))
                    .font(Typo.meta)
                    .foregroundStyle(Palette.textFaint)
                Image(systemName: expanded ? "chevron.up" : "chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(Palette.textFaint)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(Text(expanded ? "Hide the explanation" : "Show the explanation"))
        .accessibilityIdentifier("explain.disclose")
    }

    @ViewBuilder private func prose(_ text: String) -> some View {
        if expanded {
            MarkdownProse(text: text,
                          fileRoots: model.fileRoots(forProductID: productID, chatID: chatID),
                          openWeb: { model.webPreview = $0 })
        }
    }

    @ViewBuilder private func actions(_ state: ExplainState) -> some View {
        if expanded {
            HStack(spacing: 7) {
                if state.stepByStep == nil {
                    Button { press(.stepByStep) } label: {
                        Label {
                            Text(state.stepByStepRunning ? "Going through it…" : "Go through it step by step")
                        } icon: {
                            Image(systemName: "list.number")
                        }
                        .labelStyle(.titleAndIcon)
                    }
                    .buttonStyle(.bulava(.quiet))
                    .disabled(!state.available || state.stepByStepRunning)
                    .accessibilityIdentifier("explain.deeper")
                }

                Button { press(.brief) } label: {
                    Label {
                        Text(state.briefRunning ? "Explaining again…" : "Explain again")
                    } icon: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .labelStyle(.titleAndIcon)
                }
                .buttonStyle(.bulava(.quiet))
                .disabled(!state.available || state.briefRunning)
                .help(Text("Ask again — after editing your background in Settings, or when this result has moved on."))
                .accessibilityIdentifier("explain.again")

                Spacer(minLength: 0)
            }
        }
    }

    // MARK: - Notices

    @ViewBuilder private func staleLine() -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: "clock.arrow.circlepath")
                .font(.system(size: 10))
            Text("This result has changed since the explanation was written.")
                .fixedSize(horizontal: false, vertical: true)
        }
        .font(Typo.meta)
        .foregroundStyle(Palette.orange)
    }

    @ViewBuilder private func failureLine(_ failure: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: "exclamationmark.circle")
                .font(.system(size: 10))
            Text(verbatim: failure)
                .fixedSize(horizontal: false, vertical: true)
        }
        .font(Typo.meta)
        .foregroundStyle(Palette.red)
    }

    // MARK: - Wiring

    private func press(_ depth: ExplainDepth) {
        switch target {
        case .turn(let entry):
            model.explain(turn: entry, depth: depth)
        case .task(let task, let manifest):
            model.explain(task: task, manifest: manifest, depth: depth)
        }
    }

    private var productID: UUID? {
        switch target {
        case .turn(let entry): entry.productID
        case .task(let task, _): model.productID(for: task)
        }
    }

    private var chatID: UUID? {
        switch target {
        case .turn(let entry): entry.chatID
        case .task: nil
        }
    }
}
