import SwiftUI

struct TaskCard: View {
    @Environment(AppModel.self) private var model
    let task: BacklogTask

    @State private var evidence: Evidence?
    @State private var manifest: ReportManifest?

    @State private var disposition: String?

    @State private var whyStopped: String?

    @State private var stepsExpanded = false

    private var instance: SupervisorInstance? { model.liveInstance(for: task) }
    private var state: WorkState { model.workState(of: task) }
    private var milestones: [WorkMilestone] {
        WorkProgress.milestones(task: task, instance: instance, evidence: evidence,
                                disposition: disposition, hasReport: manifest != nil)
    }
    private var now: NowLine? {
        WorkProgress.nowLine(task: task, instance: instance,
                             activity: task.projectPath.flatMap { model.workerActivity[$0] })
    }
    private var actions: [ResultAction] { TaskPresentation.cardActions(for: task, model: model) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Card {
                VStack(alignment: .leading, spacing: 0) {
                    header
                    if let whyStopped { why(whyStopped) }
                    if state != .planned { steps }
                    if let now { nowStrip(now) }
                    if !task.planSteps.isEmpty { coverage }
                    actionRow
                }
            }
            ExplainRow(target: .task(task, manifest: manifest))
        }
        .padding(.leading, 25)
        .task(id: task.id) { await loadArtifacts() }

        .task(id: task.state) { await loadArtifacts() }
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Eyebrow(eyebrowKey, color: Palette.accentEmphasis)
                Text(task.title)
                    .cardTitleStyle()
                    .foregroundStyle(Palette.text)
                    .fixedSize(horizontal: false, vertical: true)
                subtitleLine
            }
            Spacer(minLength: 8)
            statePill
        }
        .padding(.horizontal, 15)
        .padding(.top, 14)
        .padding(.bottom, 12)
    }

    private var eyebrowKey: LocalizedStringKey {

        if task.isNote, state == .planned { return "Bulava noticed" }
        return switch state {
        case .running, .paused: "Working on it"
        case .needsAnswer:      "Waiting on you"
        case .stopped:          "It stopped"
        case .reportReady:      "Finished"
        case .partial:          "Partly done"
        case .failed:           "Stopped"
        case .planned:          "Planned"
        case .done:             "Done"
        }
    }

    @ViewBuilder private var subtitleLine: some View {
        if state == .running, let since = WorkProgress.startedAt(task: task, instance: instance) {
            HStack(spacing: 5) {
                Text("Working for").font(Typo.caption).foregroundStyle(Palette.textFaint)
                ElapsedLabel(since: since)
            }
        } else if let text = TaskPresentation.subtitle(for: task, model: model), !text.isEmpty {
            Text(text)
                .font(Typo.caption)
                .foregroundStyle(Palette.textFaint)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var statePill: some View {
        StatePill(text: LocalizedStringKey(state.labelKey),
                  systemImage: state.symbol,
                  tint: tint, wash: wash)
    }

    private var tint: Color {
        switch state {
        case .running:      Palette.green
        case .paused:       Palette.orange
        case .needsAnswer:  Palette.orange
        case .stopped:      Palette.orange
        case .reportReady:  Palette.green
        case .partial:      Palette.orange
        case .failed:       Palette.red
        case .planned:      Palette.textTertiary
        case .done:         Palette.green
        }
    }

    private var wash: Color {
        switch state {
        case .running, .reportReady, .done: Palette.greenSoft
        case .paused, .needsAnswer,
             .stopped, .partial:            Palette.orangeSoft
        case .failed:                       Palette.redSoft
        case .planned:                      Palette.panelMuted
        }
    }

    // MARK: - Why it stopped

    @ViewBuilder private func why(_ text: String) -> some View {
        VStack(spacing: 0) {
            Hairline()
            HStack(alignment: .top, spacing: 9) {
                Image(systemName: state == .failed ? "exclamationmark.triangle" : "quote.opening")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Palette.textFaint)
                    .padding(.top, 2)
                Text(text.count > 700 ? String(text.prefix(700)) + "…" : text)
                    .font(Typo.caption)
                    .foregroundStyle(Palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 15)
            .padding(.vertical, 11)
        }
    }

    // MARK: - Milestones

    private var steps: some View {
        VStack(spacing: 0) {
            Hairline()
            VStack(alignment: .leading, spacing: 0) {
                if collapseSteps, let current = currentMilestone {
                    Button {
                        withAnimation(Motion.expand) { stepsExpanded = true }
                    } label: {
                        HStack(spacing: 8) {
                            MilestoneRow(milestone: current)
                            Text(String(format: String(localized: "step %lld of %lld"),
                                        (milestones.firstIndex(of: current) ?? 0) + 1, milestones.count))
                                .font(Typo.meta)
                                .monospacedDigit()
                                .foregroundStyle(Palette.textFaint)
                                .fixedSize()
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(Text("Show every step"))
                } else {
                    ForEach(milestones) { milestone in
                        MilestoneRow(milestone: milestone)
                    }
                }
            }
            .padding(.horizontal, 15)
            .padding(.vertical, 8)
        }
    }

    private var collapseSteps: Bool {
        !stepsExpanded && (state == .running || state == .paused) && currentMilestone != nil
    }

    private var currentMilestone: WorkMilestone? {
        milestones.first { $0.mark == .current }
            ?? milestones.last { $0.mark == .done }
    }

    // MARK: - Now

    private func nowStrip(_ line: NowLine) -> some View {
        VStack(spacing: 0) {
            Hairline()
            HStack(alignment: .top, spacing: 9) {
                Text("Now")
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(Palette.accentEmphasis)
                    .fixedSize()
                VStack(alignment: .leading, spacing: 2) {
                    Text(line.sentence)
                        .font(Typo.control)
                        .foregroundStyle(Palette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)

                    if let until = line.until {
                        CountdownLabel(until: until)
                    } else if let detail = line.detail, !detail.isEmpty {
                        Text(detail)
                            .font(Typo.caption)
                            .foregroundStyle(Palette.textFaint)
                            .lineLimit(3)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 15)
            .padding(.vertical, 10)
            .background(Palette.accentSoft)
        }
    }

    // MARK: - Coverage

    private var coverage: some View {
        VStack(spacing: 0) {
            Hairline()
            DisclosureGroup {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(Array(task.planSteps.enumerated()), id: \.offset) { i, step in
                        HStack(alignment: .top, spacing: 8) {
                            Text("\(i + 1)")
                                .font(Typo.panelMeta)
                                .monospacedDigit()
                                .foregroundStyle(Palette.textFaint)
                                .frame(width: 12, alignment: .trailing)
                            Text(step)
                                .font(Typo.step)
                                .foregroundStyle(Palette.textTertiary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                .padding(.top, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
            } label: {
                Text("What this covers · \(task.planSteps.count) steps")
                    .font(Typo.meta)
                    .foregroundStyle(Palette.textFaint)
            }
            .padding(.horizontal, 15)
            .padding(.vertical, 9)
        }
    }

    // MARK: - Actions

    private var actionRow: some View {
        VStack(spacing: 0) {
            Hairline()
            HStack(spacing: 7) {
                Button { model.openTaskDetail(task) } label: {
                    Text("Details")
                }
                .buttonStyle(.bulava(.quiet))

                CloseWorkButton(target: .task(task), running: state == .running || state == .paused)

                Spacer(minLength: 0)

                ForEach(actions) { action in
                    Button { action.perform(model) } label: {
                        Label { Text(action.titleKey) } icon: { Image(systemName: action.symbol) }
                            .labelStyle(.titleAndIcon)
                    }
                    .buttonStyle(.bulava(emphasis(action)))
                    .disabled(action.disabledReason != nil)
                    .help(action.disabledReason.map { Text($0) } ?? Text(action.titleKey))

                    .accessibilityIdentifier("task-action-\(action.id)")
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 9)
        }
    }

    private func emphasis(_ action: ResultAction) -> ButtonRole2 {
        switch action.emphasis {
        case .primary: .primary
        case .secondary: .secondary
        case .quiet: .quiet
        case .danger: .danger
        }
    }

    // MARK: - Artifacts

    private func loadArtifacts() async {
        manifest = await model.reportManifest(for: task)
        evidence = model.verifiedEvidence[task.id]

        guard task.dispatchedAt != nil, !task.state.isActive || task.state == .blocked else {
            disposition = nil; whyStopped = nil; return
        }
        let review = await model.loadReview(for: task)
        disposition = review?.disposition
        whyStopped = Self.reasonToShow(review: review, instance: instance, task: task)
    }

    static func reasonToShow(review: ReviewPackage?, instance: SupervisorInstance?,
                             task: BacklogTask) -> String? {
        func clean(_ s: String?) -> String? {
            var t = s?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

            for prefix in ["worker blocker finding:", "worker finding:", "blocker finding:",
                           "worker needs_scope finding:", "finding:"] where
                t.lowercased().hasPrefix(prefix) {
                t = String(t.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
                break
            }
            return t.isEmpty ? nil : t
        }
        if let review, review.disposition == "needs-user" || review.disposition == "scope_violation",
           let finding = clean(review.findings.first) {
            return finding
        }
        return clean(instance?.outcomeSummary) ?? clean(review?.findings.first)
    }
}

// MARK: - Milestone row

private struct MilestoneRow: View {
    @Environment(\.motionEnabled) private var motionEnabled
    let milestone: WorkMilestone
    @State private var spin = false

    var body: some View {
        HStack(spacing: 8) {
            glyph
                .frame(width: 15)
            Text(LocalizedStringKey(milestone.titleKey))
                .font(Typo.step)
                .foregroundStyle(labelColor)
            Spacer(minLength: 0)
        }
        .frame(minHeight: 27)
    }

    @ViewBuilder private var glyph: some View {
        switch milestone.mark {
        case .done:
            Image(systemName: "checkmark")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(Palette.green)
        case .current:

            Circle()
                .trim(from: 0, to: 0.28)
                .stroke(Palette.accentEmphasis, style: StrokeStyle(lineWidth: 1.6, lineCap: .round))
                .frame(width: 10, height: 10)
                .rotationEffect(.degrees(spin ? 360 : 0))
                .onAppear {
                    guard motionEnabled else { return }
                    withAnimation(.linear(duration: 1.6).repeatForever(autoreverses: false)) {
                        spin = true
                    }
                }
        case .waiting:
            Circle()
                .strokeBorder(Palette.lineStrong, lineWidth: 1.2)
                .frame(width: 9, height: 9)
        case .skipped:
            Image(systemName: "minus")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(Palette.textFaint)
        case .failed:
            Image(systemName: "xmark")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(Palette.red)
        }
    }

    private var labelColor: Color {
        switch milestone.mark {
        case .done:    Palette.textSecondary
        case .current: Palette.text
        case .waiting: Palette.textFaint
        case .skipped: Palette.textFaint
        case .failed:  Palette.red
        }
    }
}
