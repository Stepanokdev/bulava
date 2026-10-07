import SwiftUI

/// One run: how it went, when, why it started, its own words — and the one or two things he can
/// do about it from here.
struct AutomationRunRow: View {
    @Environment(AppModel.self) private var model
    let run: AutomationRun
    var showsAutomationName = false

    @State private var showingChanges = false
    @State private var confirmingDiscard = false
    @State private var working = false
    @State private var problem: String?

    private var automation: Automation? { model.automations.automation(id: run.automationID) }
    private var copy: WorkCopy? { run.workspaceID.flatMap { model.automations.copy(id: $0) } }
    private var phase: DirectChatPhase? { run.chatID.map { model.directPhase(for: $0) } }
    private var look: AutomationPresentation.Look { AutomationPresentation.look(run, phase: phase) }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .firstTextBaseline, spacing: 9) {
                StatePill(text: LocalizedStringKey(look.word), systemImage: look.symbol,
                          tint: look.tint, wash: look.wash)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        if showsAutomationName, let automation {
                            Text(verbatim: automation.name)
                                .font(Typo.rowLabel)
                                .foregroundStyle(Palette.text)
                                .lineLimit(1)
                        }
                        Text(verbatim: Fmt.stamp(run.startedAt ?? run.createdAt))
                            .font(Typo.caption)
                            .monospacedDigit()
                            .foregroundStyle(Palette.textTertiary)
                        Text(verbatim: "· " + AutomationPresentation.reasonWord(run.reason))
                            .font(Typo.caption)
                            .foregroundStyle(Palette.textFaint)
                            .lineLimit(1)
                    }
                    if let gist = AutomationPresentation.gist(run) {
                        Text(verbatim: gist)
                            .font(Typo.body)
                            .foregroundStyle(Palette.textSecondary)
                            .lineLimit(3)
                            .fixedSize(horizontal: false, vertical: true)
                            .textSelection(.enabled)
                    }
                }
                Spacer(minLength: 6)
                if working { ProgressView().controlSize(.small) }
            }
            actions
            if let problem {
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 10))
                    Text(verbatim: problem).fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                    Button { self.problem = nil } label: { Image(systemName: "xmark") }
                        .buttonStyle(.icon(size: 16, glyph: 8))
                        .help(Text("Dismiss"))
                        .accessibilityLabel(Text("Dismiss"))
                }
                .font(Typo.caption)
                .foregroundStyle(Palette.orange)
                .transition(.opacity)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .animation(Motion.standard, value: problem)
        .sheet(isPresented: $showingChanges) {
            if let copy { CopyChangesSheet(copy: copy, run: run) }
        }
        .confirmationDialog(Text("Throw these changes away?"), isPresented: $confirmingDiscard,
                            titleVisibility: .visible) {
            Button("Discard changes", role: .destructive) { discard() }
            Button("Keep", role: .cancel) {}
        } message: {
            Text("The changes and their branch are deleted. Your folder is not touched.")
        }
    }

    @ViewBuilder private var actions: some View {
        let buttons = available
        if !buttons.isEmpty {
            WrappingHStack(horizontalSpacing: 6, verticalSpacing: 6) {
                ForEach(buttons, id: \.self) { action in
                    button(for: action)
                }
            }
            .disabled(working)
        }
    }

    private enum Action: Hashable {
        case start, skip, open, stop, changes, showCopy, merge, discard, report, writingReport, evidence
    }

    private var writingReport: Bool {
        run.chatID.map { model.generatingChatReportIDs.contains($0) } ?? false
    }

    private var available: [Action] {
        switch run.state {
        case .awaitingApproval, .awaitingAway: return [.start, .skip]
        case .preparing: return []
        case .running: return [.open, .stop]
        case .skipped: return []
        case .failed: return run.chatID == nil ? [] : [.open]
        case .finished:
            // A written report, the one being written, or — for runs from before reports were
            // asked for — what was left, called by its name rather than "report".
            let report: [Action] = model.reportPage(for: run) != nil ? [.report]
                : writingReport ? [.writingReport]
                : model.evidenceOnlyFolder(for: run) != nil ? [.evidence] : []
            if run.result == .changes, run.handoff == .waiting, copy?.isLive == true {
                if model.runIsWorking(run) != nil { return [.open] }
                return [.changes, .merge] + report + [.showCopy, .open, .discard]
            }
            if run.result == .needsYou { return [.open, .stop] }
            return report + (run.chatID == nil ? [] : [.open])
        }
    }

    @ViewBuilder private func button(for action: Action) -> some View {
        switch action {
        case .start:
            Button("Start now") {
                if run.state == .awaitingApproval { model.approveRun(run.id) }
                else {
                    model.automations.updateRun(run.id) { $0.state = .preparing }
                    Task { await model.prepareAndStart(run.id) }
                }
            }
            .buttonStyle(.bulava(.primary))
        case .skip:
            Button("Skip") { model.skipRun(run.id) }.buttonStyle(.bulava(.quiet))
        case .open:
            Button(phase?.wantsAttention == true ? "Answer" : "Open conversation") { model.openRunChat(run) }
                .buttonStyle(.bulava(phase?.wantsAttention == true ? .primary : .secondary))
        case .stop:
            Button("Stop") { model.stopRun(run.id) }.buttonStyle(.bulava(.quiet))
        case .changes:
            Button("Review changes") { showingChanges = true }.buttonStyle(.bulava(.secondary))
        case .showCopy:
            Button("Show in Finder") { if let copy { model.openCopy(copy.id) } }.buttonStyle(.bulava(.quiet))
        case .merge:
            Button(String(format: String(localized: "Merge into %@"), copy?.baseRef ?? "")) { merge() }
                .buttonStyle(.bulava(.primary))
        case .discard:
            Button("Discard changes") { confirmingDiscard = true }.buttonStyle(.bulava(.danger))
        case .report:
            Button("Open report") { model.openReport(of: run) }
                .buttonStyle(.bulava(run.result == .report ? .primary : .secondary))
        case .writingReport:
            HStack(spacing: 6) {
                ProgressView().controlSize(.mini)
                Text("Writing the report…")
                    .font(Typo.caption)
                    .foregroundStyle(Palette.textTertiary)
            }
        case .evidence:
            Button("Evidence only, no written report") { model.openEvidence(of: run) }
                .buttonStyle(.bulava(.quiet))
                .help(Text("This run left screenshots or a recording but did not write down what it did or how it was checked."))
        }
    }

    private func merge() {
        working = true
        Task {
            let result = await model.mergeRun(run.id)
            working = false
            problem = result
            if result == nil, let copy, model.automations.copy(id: copy.id)?.integrating != nil {
                model.toast = ToastMessage(text: String(localized: "It could not be merged by itself, so the chat is merging it."), kind: .info)
            } else if result == nil, let copy {
                model.toast = ToastMessage(text: String(format: String(localized: "Merged into %@"), copy.baseRef), kind: .info)
            }
        }
    }

    private func discard() {
        working = true
        Task {
            problem = await model.discardRun(run.id)
            working = false
        }
    }
}

// MARK: - The changes a copy holds

struct CopyChangesSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let copy: WorkCopy
    var run: AutomationRun?

    @State private var diff: String?
    @State private var status: WorkCopyStatus?

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Changes in the copy")
                        .cardTitleStyle()
                        .foregroundStyle(Palette.text)
                    Text(verbatim: String(format: String(localized: "Branch %@, started from %@ (%@)"),
                                          copy.branch, copy.baseRef, String(copy.baseSHA.prefix(8))))
                        .font(Typo.caption)
                        .foregroundStyle(Palette.textTertiary)
                        .textSelection(.enabled)
                }
                Spacer(minLength: 8)
                if let status, status.inspected {
                    Text(verbatim: Fmt.count("%lld changed files", changedFiles))
                        .font(Typo.caption)
                        .foregroundStyle(Palette.textSecondary)
                }
                Button("Done") { dismiss() }
                    .buttonStyle(.bulava(.secondary))
                    .keyboardShortcut(.cancelAction)
            }
            .padding(16)
            Hairline()
            Group {
                if let diff {
                    if diff.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        Text("Nothing has changed in the copy.")
                            .font(Typo.body)
                            .foregroundStyle(Palette.textTertiary)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        DiffView(text: diff, maxLines: 4_000)
                            .padding(12)
                    }
                } else {
                    ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .frame(width: 820, height: 620)
        .background(Palette.content)
        .task {
            status = await model.copyStatus(copy.id)
            diff = await model.copyDiff(copy.id)
        }
    }

    private var changedFiles: Int {
        guard let diff else { return 0 }
        return diff.split(separator: "\n").filter { $0.hasPrefix("diff --git ") }.count
    }
}
