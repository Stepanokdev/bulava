import ServiceManagement
import SwiftUI

/// Every automation, grouped by product, with what is waiting for him on top.
///
/// The row is what people coming from other tools expect to find: a name, when it runs, how its
/// last runs went, a switch and a play button. A year of weekly runs is a strip of dots, not a
/// list — the list is one click further, on the automation's own page.
struct AutomationsScreen: View {
    @Environment(AppModel.self) private var model
    @State private var editing: AutomationEditorRequest?

    private var waiting: [AutomationRun] {
        model.automationRunsWantingHim.sorted { $0.createdAt > $1.createdAt }
    }

    private var groups: [(product: Product, automations: [Automation])] {
        model.products.sorted.compactMap { product in
            let mine = model.automations.automations(for: product.id)
            return mine.isEmpty ? nil : (product, mine)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Hairline()
            if model.automations.automations.isEmpty {
                ScrollView { empty.padding(.vertical, 40) }
            } else {
                list
            }
        }
        .background(Palette.content)
        .sheet(item: $editing) { request in
            AutomationEditor(request: request).id(request.id)
        }
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text("Automations")
                    .screenTitleStyle()
                    .foregroundStyle(Palette.text)
                Spacer(minLength: 8)
                if !model.automations.automations.isEmpty {
                    Button {
                        editing = .new(productID: model.products.lastVisited?.id, template: nil)
                    } label: {
                        Label("New automation", systemImage: "plus")
                    }
                    .buttonStyle(.bulava(.primary))
                    .keyboardShortcut("n", modifiers: [.command, .option])
                }
            }
            AutomationAvailabilityNote()
            // Only his Bulava opens at login; a Dev build registering itself would start beside it.
            if !model.automations.automations.isEmpty, AppChannel.current.ownsLoginItem { OpenAtLoginRow() }
        }
        .padding(.horizontal, 18)
        .padding(.top, 16)
        .padding(.bottom, 12)
    }

    // MARK: List

    private var list: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: Metrics.sectionGap) {
                if !waiting.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        PanelTitle("Waiting for you")
                        VStack(spacing: 0) {
                            ForEach(Array(waiting.enumerated()), id: \.element.id) { index, run in
                                if index > 0 { Hairline() }
                                AutomationRunRow(run: run, showsAutomationName: true)
                            }
                        }
                        .background(RoundedRectangle(cornerRadius: Metrics.radiusPanel, style: .continuous)
                            .fill(Palette.panel))
                        .overlay(RoundedRectangle(cornerRadius: Metrics.radiusPanel, style: .continuous)
                            .strokeBorder(Palette.line, lineWidth: 1))
                    }
                }
                ForEach(groups, id: \.product.id) { group in
                    VStack(alignment: .leading, spacing: 6) {
                        PanelTitle(LocalizedStringKey(group.product.name)) {
                            Button {
                                editing = .new(productID: group.product.id, template: nil)
                            } label: {
                                Image(systemName: "plus")
                            }
                            .buttonStyle(.icon(size: 20, glyph: 10))
                            .help(Text("New automation for this product"))
                        }
                        VStack(spacing: 0) {
                            ForEach(Array(group.automations.enumerated()), id: \.element.id) { index, automation in
                                if index > 0 { Hairline() }
                                AutomationRow(automation: automation)
                            }
                        }
                        .background(RoundedRectangle(cornerRadius: Metrics.radiusPanel, style: .continuous)
                            .fill(Palette.panel))
                        .overlay(RoundedRectangle(cornerRadius: Metrics.radiusPanel, style: .continuous)
                            .strokeBorder(Palette.line, lineWidth: 1))
                    }
                }
            }
            .frame(maxWidth: Metrics.readingWidth + 80, alignment: .leading)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 18)
            .padding(.vertical, 18)
            .animation(Motion.standard, value: waiting.map(\.id))
        }
        .scrollIndicators(.automatic)
    }

    // MARK: Empty

    private var empty: some View {
        VStack(spacing: 26) {
            InviteState(systemImage: "clock.arrow.2.circlepath",
                        title: Text("Nothing runs by itself yet"),
                        message: "Describe a job once. Bulava runs it on a schedule, when something changes, or when something happens on this Mac — each run in its own copy of the folder, so nothing reaches your branch until you merge it.")
            Button {
                editing = .new(productID: model.products.lastVisited?.id, template: nil)
            } label: {
                Label("New automation", systemImage: "plus")
            }
            .buttonStyle(.bulava(.primary))
            VStack(alignment: .leading, spacing: 10) {
                PanelTitle("Or start from a template")
                AutomationTemplateGrid { template in
                    editing = .new(productID: model.products.lastVisited?.id, template: template)
                }
            }
            .frame(maxWidth: 720)
        }
        .padding(.horizontal, 24)
        .frame(maxWidth: .infinity)
    }
}

// MARK: - One automation

struct AutomationRow: View {
    @Environment(AppModel.self) private var model
    let automation: Automation
    @State private var hovering = false

    private var project: Project? { model.projects.project(id: automation.projectID) }

    var body: some View {
        HStack(spacing: 12) {
            Toggle("", isOn: Binding(get: { automation.enabled },
                                     set: { model.setAutomationEnabled(automation.id, $0) }))
                .toggleStyle(.switch)
                .controlSize(.mini)
                .labelsHidden()
                .accessibilityLabel(Text(verbatim: automation.name))
                .help(automation.enabled ? Text("Switch off — the run going now, if any, finishes") : Text("Switch on"))

            Button { model.navigate(to: .automation(automation.id)) } label: {
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(verbatim: automation.name)
                            .font(Typo.rowLabel)
                            .foregroundStyle(automation.enabled ? Palette.text : Palette.textTertiary)
                            .lineLimit(1)
                        Text(verbatim: subtitle)
                            .font(Typo.caption)
                            .foregroundStyle(Palette.textTertiary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 8)
                    VStack(alignment: .trailing, spacing: 4) {
                        AutomationResultStrip(runs: Array(model.automations.runs(for: automation.id).prefix(14)))
                        Text(verbatim: statusLine)
                            .font(Typo.meta)
                            .monospacedDigit()
                            .foregroundStyle(statusTint)
                            .lineLimit(1)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Button { model.runAutomationNow(automation.id) } label: { Image(systemName: "play.fill") }
                .buttonStyle(.icon(size: 26, glyph: 10))
                .help(Text("Run now"))
                .opacity(hovering ? 1 : 0.55)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(hovering ? Palette.hover : .clear)
        .onHover { hovering = $0 }
        .animation(Motion.hover, value: hovering)
    }

    private var subtitle: String {
        var parts = [AutomationPresentation.triggerLine(automation.trigger)]
        if let project { parts.append(project.name) }
        return parts.joined(separator: " · ")
    }

    private var statusLine: String {
        if automation.pausedReason != nil, !automation.enabled {
            return String(localized: "Switched itself off")
        }
        if !automation.enabled { return String(localized: "Off") }
        if let next = model.nextRuns(of: automation, count: 1).first {
            return String(format: String(localized: "Next run %@"), Fmt.stamp(next))
        }
        if let error = automation.watch?.lastError, !error.isEmpty { return String(localized: "Could not check") }
        if let last = model.lastRun(of: automation.id) {
            let look = AutomationPresentation.look(last, phase: last.chatID.map { model.directPhase(for: $0) })
            return "\(look.word) · \(Fmt.stamp(last.finishedAt ?? last.createdAt))"
        }
        if let checked = automation.watch?.lastCheckedAt {
            return String(format: String(localized: "Checked %@"), Fmt.stamp(checked))
        }
        return String(localized: "Not run yet")
    }

    private var statusTint: Color {
        if !automation.enabled && automation.pausedReason != nil { return Palette.orange }
        if automation.watch?.lastError?.isEmpty == false { return Palette.orange }
        return Palette.textTertiary
    }
}

/// The last runs as dots, oldest on the left: a quiet one small and faint, a failure red, changes
/// waiting orange. Enough to tell at a glance whether an automation still earns its place. Round
/// on purpose: two tall bars side by side read as a pause sign.
struct AutomationResultStrip: View {
    @Environment(AppModel.self) private var model
    let runs: [AutomationRun]

    var body: some View {
        HStack(spacing: 4) {
            ForEach(runs.reversed()) { run in
                let look = AutomationPresentation.look(run, phase: run.chatID.map { model.directPhase(for: $0) })
                Circle()
                    .fill(run.isQuiet ? Palette.track : look.tint)
                    .frame(width: run.isQuiet ? 5 : 7, height: run.isQuiet ? 5 : 7)
                    .frame(width: 7, height: 7)
                    .help(Text(verbatim: "\(look.word) · \(Fmt.stamp(run.finishedAt ?? run.createdAt))"))
            }
        }
        .frame(height: 12, alignment: .center)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Recent runs, newest first"))
        .accessibilityValue(Text(verbatim: spoken))
    }

    /// The newest few, newest first, each with its day: what the dots and their tooltips say to
    /// someone who cannot see them.
    private var spoken: String {
        runs.prefix(5).map { run in
            let word = AutomationPresentation.look(run, phase: run.chatID.map { model.directPhase(for: $0) }).word
            return "\(word), \(Fmt.stamp(run.finishedAt ?? run.createdAt))"
        }.joined(separator: "; ")
    }
}

/// What may and may not happen while he is away, said where he decides to rely on it.
struct AutomationAvailabilityNote: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        WrappingHStack(horizontalSpacing: 14, verticalSpacing: 4) {
            note("macbook", String(localized: "Runs on this Mac while Bulava is open"))
            if model.automationDueSoon {
                if model.runningOnBattery {
                    note("battery.25", String(localized: "On battery: if the Mac sleeps, the run starts when it wakes"),
                         tint: Palette.orange)
                } else if model.settings.keepAwakeWhileWorking {
                    note("cup.and.saucer", String(localized: "The Mac stays awake for the next run, lid open"))
                }
            }
            note("arrow.triangle.branch", String(localized: "Each run works in its own copy"))
        }
    }

    private func note(_ symbol: String, _ text: String, tint: Color = Palette.textTertiary) -> some View {
        HStack(spacing: 5) {
            Image(systemName: symbol).font(.system(size: 10))
            Text(verbatim: text)
        }
        .font(Typo.caption)
        .foregroundStyle(tint)
        .fixedSize()
    }
}

/// Starting points, as cards — the ones that work on any repository first, then the ones that need
/// something filled in. Each card says what a run leaves behind and what it needs, before it is
/// chosen rather than after the first night.
struct AutomationTemplateGrid: View {
    let choose: (AutomationTemplate) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            section("For any repository", group: .anyRepository)
            section("Need a little setup", group: .needsSetup)
        }
    }

    private func section(_ title: LocalizedStringKey, group: AutomationTemplate.Group) -> some View {
        let templates = AutomationTemplate.all().filter { $0.group == group }
        let rows = stride(from: 0, to: templates.count, by: 2).map { Array(templates[$0..<min($0 + 2, templates.count)]) }
        return VStack(alignment: .leading, spacing: 8) {
            Eyebrow(title)
            // Cards in a row share its height, so their edges line up; a lazy grid centred each
            // card in its row instead. One column once two would squeeze the text.
            ViewThatFits(in: .horizontal) {
                Grid(horizontalSpacing: 10, verticalSpacing: 10) {
                    ForEach(rows, id: \.first?.id) { row in
                        GridRow(alignment: .top) {
                            ForEach(row) { template in
                                TemplateCard(template: template) { choose(template) }
                            }
                            if row.count == 1 { Color.clear.gridCellUnsizedAxes([.horizontal, .vertical]) }
                        }
                    }
                }
                .frame(minWidth: 460, idealWidth: 460, maxWidth: .infinity)
                VStack(spacing: 10) {
                    ForEach(templates) { template in
                        TemplateCard(template: template) { choose(template) }
                    }
                }
            }
        }
    }

    private struct TemplateCard: View {
        let template: AutomationTemplate
        let action: () -> Void
        @State private var hovering = false

        var body: some View {
            Button(action: action) {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: template.symbol)
                        .font(.system(size: 14, weight: .regular))
                        .foregroundStyle(Palette.accentEmphasis)
                        .frame(width: 28, height: 28)
                        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Palette.accentSoft))
                    VStack(alignment: .leading, spacing: 5) {
                        Text(verbatim: template.name)
                            .font(Typo.rowLabel)
                            .foregroundStyle(Palette.text)
                        Text(verbatim: template.summary)
                            .font(Typo.caption)
                            .foregroundStyle(Palette.textTertiary)
                            .fixedSize(horizontal: false, vertical: true)
                            .multilineTextAlignment(.leading)
                        Label {
                            Text(verbatim: outputWords)
                        } icon: {
                            Image(systemName: outputSymbol)
                        }
                        .font(Typo.meta)
                        .foregroundStyle(Palette.textSecondary)
                        if let needs = template.needs {
                            Label {
                                Text(verbatim: needs).fixedSize(horizontal: false, vertical: true)
                            } icon: {
                                Image(systemName: "info.circle")
                            }
                            .font(Typo.meta)
                            .foregroundStyle(Palette.textTertiary)
                        }
                    }
                    Spacer(minLength: 0)
                }
                .padding(11)
                .frame(maxWidth: .infinity, minHeight: 92, maxHeight: .infinity, alignment: .topLeading)
                .background(RoundedRectangle(cornerRadius: Metrics.radiusPanel, style: .continuous)
                    .fill(hovering ? Palette.panelRaised : Palette.panel))
                .overlay(RoundedRectangle(cornerRadius: Metrics.radiusPanel, style: .continuous)
                    .strokeBorder(hovering ? Palette.lineStrong : Palette.line, lineWidth: 1))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { hovering = $0 }
            .animation(Motion.hover, value: hovering)
            .accessibilityElement(children: .combine)
            .accessibilityHint(Text(verbatim: template.needs ?? outputWords))
        }

        private var outputWords: String {
            switch template.output {
            case .report: String(localized: "Leaves a report, changes nothing")
            case .changes: String(localized: "Proposes changes on its own branch")
            case .reportAndSmallFixes: String(localized: "A report, and a small fix when one is clear")
            }
        }

        private var outputSymbol: String {
            switch template.output {
            case .report: "doc.text"
            case .changes: "arrow.triangle.branch"
            case .reportAndSmallFixes: "doc.badge.gearshape"
            }
        }
    }
}

/// Automations run only while Bulava is open, so the one setting that makes that true after a
/// restart sits where he relies on it.
private struct OpenAtLoginRow: View {
    // Read once when the row appears, off the main thread: the status is a call into a system
    // service, and an initial value here was evaluated on every redraw of the screen.
    @State private var enabled = false
    @State private var problem: String?

    var body: some View {
        HStack(spacing: 8) {
            Toggle("Open Bulava when I log in", isOn: Binding(get: { enabled }, set: { set($0) }))
                .toggleStyle(.checkbox)
                .font(Typo.caption)
                .foregroundStyle(Palette.textSecondary)
            if let problem {
                Text(verbatim: problem)
                    .font(Typo.caption)
                    .foregroundStyle(Palette.orange)
                    .lineLimit(1)
            }
        }
        .task { enabled = await Task.detached { SMAppService.mainApp.status == .enabled }.value }
    }

    private func set(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            problem = nil
        } catch {
            problem = error.localizedDescription
        }
        enabled = SMAppService.mainApp.status == .enabled
    }
}
