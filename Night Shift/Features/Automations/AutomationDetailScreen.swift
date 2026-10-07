import AppKit
import SwiftUI

/// One automation: what it does, when it runs next, what it watches and saw last, and every run it
/// made. Quiet runs in a row fold into one line, so a year of "nothing new" is a sentence and the
/// runs that found something stand out.
struct AutomationDetailScreen: View {
    @Environment(AppModel.self) private var model
    let automationID: UUID

    @State private var editing: AutomationEditorRequest?
    @State private var confirmingDelete = false
    @State private var expandedQuiet: Set<UUID> = []
    @State private var headerWidth: CGFloat = 0

    private var automation: Automation? { model.automations.automation(id: automationID) }
    private var runs: [AutomationRun] { model.automations.runs(for: automationID) }

    var body: some View {
        if let automation {
            VStack(spacing: 0) {
                header(automation)
                Hairline()
                ScrollView {
                    VStack(alignment: .leading, spacing: Metrics.sectionGap) {
                        if let reason = automation.pausedReason, !automation.enabled {
                            pausedBanner(reason)
                        }
                        facts(automation)
                        briefCard(automation)
                        history
                    }
                    .frame(maxWidth: Metrics.readingWidth + 80, alignment: .leading)
                    .frame(maxWidth: .infinity)
                    .padding(18)
                }
            }
            .background(Palette.content)
            .sheet(item: $editing) { request in AutomationEditor(request: request).id(request.id) }
            .confirmationDialog(Text("Delete “\(automation.name)”?"), isPresented: $confirmingDelete,
                                titleVisibility: .visible) {
                Button("Delete", role: .destructive) {
                    if let problem = model.deleteAutomation(automationID) {
                        model.toast = ToastMessage(text: problem, kind: .info)
                    }
                }
                Button("Keep", role: .cancel) {}
            } message: {
                Text("It stops running. The conversations of its runs stay in the product's archive.")
            }
            .onAppear { seeFailures() }
        }
    }

    // MARK: Header

    private func header(_ automation: Automation) -> some View {
        // Side by side while there is room; in a narrow column the actions go under the title and
        // wrap, instead of squeezing the name to nothing. One set of views either way, so each
        // keyboard shortcut is there once.
        let stacked = headerWidth > 0 && headerWidth < 600
        let layout = stacked ? AnyLayout(VStackLayout(alignment: .leading, spacing: 10))
                             : AnyLayout(HStackLayout(alignment: .center, spacing: 10))
        return layout {
            HStack(alignment: .center, spacing: 10) {
                Button { model.navigate(to: .automations) } label: { Image(systemName: "chevron.left") }
                    .buttonStyle(.icon(size: 26, glyph: 11))
                    .help(Text("All automations"))
                    .accessibilityLabel(Text("All automations"))
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: automation.name)
                        .screenTitleStyle()
                        .foregroundStyle(Palette.text)
                        .lineLimit(1)
                    Text(verbatim: AutomationPresentation.triggerLine(automation.trigger))
                        .font(Typo.caption)
                        .foregroundStyle(Palette.textTertiary)
                }
            }
            if !stacked { Spacer(minLength: 8) }
            WrappingHStack(horizontalSpacing: 10, verticalSpacing: 8, maximumUnproposedWidth: .infinity) {
                Toggle(isOn: Binding(get: { automation.enabled },
                                     set: { model.setAutomationEnabled(automationID, $0) })) {
                    Text(automation.enabled ? "On" : "Off")
                        .font(Typo.control)
                        .foregroundStyle(Palette.textSecondary)
                }
                .toggleStyle(.switch)
                .controlSize(.small)
                Button { model.runAutomationNow(automationID) } label: { Label("Run now", systemImage: "play.fill") }
                    .buttonStyle(.bulava(.primary))
                    .keyboardShortcut("r", modifiers: [.command, .option])
                Button("Edit") { editing = .edit(automationID) }
                    .buttonStyle(.bulava(.secondary))
                    .keyboardShortcut("e", modifiers: .command)
                Menu {
                    Button("Delete automation…", role: .destructive) { confirmingDelete = true }
                } label: {
                    Image(systemName: "ellipsis")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help(Text("More actions"))
                .accessibilityLabel(Text("More actions"))
            }
            .fixedSize(horizontal: !stacked, vertical: false)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { headerWidth = $0 }
    }

    private func pausedBanner(_ reason: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "pause.circle.fill").foregroundStyle(Palette.orange)
            Text(verbatim: reason)
                .font(Typo.body)
                .foregroundStyle(Palette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            Button("Switch back on") { model.setAutomationEnabled(automationID, true) }
                .buttonStyle(.bulava(.secondary))
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: Metrics.radiusPanel, style: .continuous).fill(Palette.orangeSoft))
    }

    // MARK: Facts

    private func facts(_ automation: Automation) -> some View {
        let project = model.projects.project(id: automation.projectID)
        let product = model.products.product(id: automation.productID)
        return VStack(alignment: .leading, spacing: 9) {
            factRow("folder", Array(NSOrderedSet(array: [product?.name, project?.name].compactMap { $0 }))
                        .compactMap { $0 as? String }.joined(separator: " · "),
                    detail: project?.displayPath)
            let start = automation.baseBranch.flatMap { $0.isEmpty ? nil : $0 } ?? String(localized: "the default branch")
            if automation.checksOnly {
                factRow("checkmark.seal",
                        String(format: String(localized: "Each run checks %@ in a copy of its own and leaves nothing to merge"), start))
            } else {
                factRow("arrow.triangle.branch",
                        String(format: String(localized: "Each run starts from %@ in a copy of its own"), start))
            }
            if automation.confirmFirst {
                factRow("hand.raised", String(localized: "Asks you before each run"))
            }
            let next = model.nextRuns(of: automation)
            if !next.isEmpty {
                factRow("calendar", String(format: String(localized: "Next: %@"),
                                           next.map { Fmt.stamp($0) }.joined(separator: " · ")))
            }
            if let watch = automation.watch {
                watchRow(watch)
            }
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: Metrics.radiusPanel, style: .continuous).fill(Palette.panel))
        .overlay(RoundedRectangle(cornerRadius: Metrics.radiusPanel, style: .continuous).strokeBorder(Palette.line, lineWidth: 1))
    }

    @ViewBuilder private func watchRow(_ watch: WatchState) -> some View {
        if let error = watch.lastError, !error.isEmpty {
            factRow("exclamationmark.triangle", error, tint: Palette.orange)
            if let fix = watch.lastErrorFix, let url = fix.url {
                Button(fix == .openMail ? "Open Mail" : "Open Privacy settings") { NSWorkspace.shared.open(url) }
                    .buttonStyle(.bulava(.secondary))
                    .padding(.leading, 24)
            }
        } else if let checked = watch.lastCheckedAt {
            let line = watch.baselined
                ? String(format: String(localized: "Last looked %@"), Fmt.stamp(checked))
                : String(localized: "Learning what is already there")
            factRow("eye", line)
        } else {
            factRow("eye", String(localized: "Has not looked yet"))
        }
        if !watch.pending.isEmpty {
            factRow("tray.full", Fmt.count("%lld found, gathering before a run", watch.pending.count), tint: Palette.accent)
        }
    }

    private func factRow(_ symbol: String, _ text: String, detail: String? = nil, tint: Color = Palette.textSecondary) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: symbol)
                .font(.system(size: 11))
                .foregroundStyle(Palette.textFaint)
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 1) {
                Text(verbatim: text)
                    .font(Typo.body)
                    .foregroundStyle(tint)
                    .fixedSize(horizontal: false, vertical: true)
                if let detail {
                    Text(verbatim: detail)
                        .font(Typo.caption)
                        .foregroundStyle(Palette.textTertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                        .help(Text(verbatim: detail))
                }
            }
        }
    }

    private func briefCard(_ automation: Automation) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            PanelTitle("What it does") {
                if automation.briefRevision > 1 {
                    Text(verbatim: String(format: String(localized: "version %@"), String(automation.briefRevision)))
                        .font(Typo.meta)
                        .foregroundStyle(Palette.textFaint)
                }
            }
            Text(verbatim: automation.brief)
                .messageStyle()
                .foregroundStyle(Palette.text)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: Metrics.radiusPanel, style: .continuous).fill(Palette.panel))
                .overlay(RoundedRectangle(cornerRadius: Metrics.radiusPanel, style: .continuous).strokeBorder(Palette.line, lineWidth: 1))
        }
    }

    // MARK: History

    /// Runs as they are shown: each one that did or wants something on its own row, and every
    /// stretch of quiet ones — nothing new, skipped — folded into a single line.
    private enum Line: Identifiable {
        case run(AutomationRun)
        case quiet([AutomationRun])
        var id: UUID {
            switch self {
            case .run(let r): r.id
            case .quiet(let rs): rs[0].id
            }
        }
    }

    private var lines: [Line] {
        var out: [Line] = []
        var stretch: [AutomationRun] = []
        func flush() {
            if stretch.count == 1 { out.append(.run(stretch[0])) }
            if stretch.count > 1 { out.append(.quiet(stretch)) }
            stretch = []
        }
        for run in runs {
            if run.isQuiet { stretch.append(run) } else { flush(); out.append(.run(run)) }
        }
        flush()
        return out
    }

    private var history: some View {
        VStack(alignment: .leading, spacing: 6) {
            PanelTitle("Runs") {
                AutomationResultStrip(runs: Array(runs.prefix(30)))
            }
            if runs.isEmpty {
                Text("No runs yet. Run now to see the first one.")
                    .font(Typo.body)
                    .foregroundStyle(Palette.textTertiary)
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: Metrics.radiusPanel, style: .continuous).fill(Palette.panel))
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(lines.enumerated()), id: \.element.id) { index, line in
                        if index > 0 { Hairline() }
                        switch line {
                        case .run(let run):
                            AutomationRunRow(run: run)
                        case .quiet(let stretch):
                            quietLine(stretch)
                        }
                    }
                }
                .background(RoundedRectangle(cornerRadius: Metrics.radiusPanel, style: .continuous).fill(Palette.panel))
                .overlay(RoundedRectangle(cornerRadius: Metrics.radiusPanel, style: .continuous).strokeBorder(Palette.line, lineWidth: 1))
                .animation(Motion.standard, value: runs.map(\.id))
            }
        }
    }

    @ViewBuilder private func quietLine(_ stretch: [AutomationRun]) -> some View {
        let key = stretch[0].id
        let open = expandedQuiet.contains(key)
        VStack(spacing: 0) {
            Button {
                withAnimation(Motion.expand) {
                    if open { expandedQuiet.remove(key) } else { expandedQuiet.insert(key) }
                }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .rotationEffect(.degrees(open ? 90 : 0))
                        .foregroundStyle(Palette.textFaint)
                    Text(verbatim: quietSummary(stretch))
                        .font(Typo.body)
                        .foregroundStyle(Palette.textTertiary)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if open {
                ForEach(stretch) { run in
                    Hairline()
                    AutomationRunRow(run: run)
                        .padding(.leading, 14)
                }
            }
        }
    }

    private func quietSummary(_ stretch: [AutomationRun]) -> String {
        let newest = stretch.first.map { Fmt.dayLabel($0.createdAt) } ?? ""
        let oldest = stretch.last.map { Fmt.dayLabel($0.createdAt) } ?? ""
        let skipped = stretch.filter { $0.state == .skipped }.count
        let quiet = stretch.count - skipped
        var parts: [String] = []
        if quiet > 0 { parts.append(Fmt.count("%lld runs with nothing new", quiet)) }
        if skipped > 0 { parts.append(Fmt.count("%lld skipped", skipped)) }
        return parts.joined(separator: ", ") + " · " + (oldest == newest ? newest : "\(oldest) – \(newest)")
    }

    /// Opening the page is seeing what is on it: a failure listed here is no longer news.
    private func seeFailures() {
        for run in runs where run.state == .failed && !run.seen { model.markRunSeen(run.id) }
    }
}
