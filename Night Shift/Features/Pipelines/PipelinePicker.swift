import SwiftUI

/// Which pipeline the next message of this chat goes through — next to the models, in the composer.
/// A pill like the models' one, and a panel behind it rather than a system menu, so each pipeline
/// can say what it guarantees before it is chosen.
struct PipelinePicker: View {
    @Environment(AppModel.self) private var model
    let chatID: UUID?
    @State private var open = false
    @State private var hovering = false

    private var current: String { model.pipelineID(forChat: chatID) }

    var body: some View {
        Button { open = true } label: {
            HStack(spacing: 4) {
                Image(systemName: "point.3.connected.trianglepath.dotted")
                    .font(.system(size: 9.5, weight: .medium))
                Text(verbatim: model.pipelineName(current))
                    .lineLimit(1)
            }
            .font(Typo.meta)
            .foregroundStyle(unusable ? Palette.red : Palette.textSecondary)
            .padding(.horizontal, 7)
            .frame(height: 23)
            .background(Capsule(style: .continuous).fill(hovering || open ? Palette.hover : .clear))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .fixedSize()
        .onHover { hovering = $0 }
        .animation(Motion.hover, value: hovering)
        .popover(isPresented: $open, arrowEdge: .bottom) {
            PipelineChoicePanel(selected: current) { id in
                model.choosePipeline(id, forChat: chatID)
                open = false
            } openPipeline: { id in
                open = false
                model.openPipeline(id)
            } openLibrary: {
                open = false
                model.openPipelines()
            }
        }
        .help(Text(unusable ? "This pipeline cannot run as it is. Open it to see why." : "What this chat’s messages go through"))
        .accessibilityLabel(Text("Pipeline"))
        .accessibilityValue(Text(verbatim: model.pipelineName(current)))
        .task { if model.pipelineLibrary.isEmpty { await model.loadPipelineLibrary() } }
    }

    /// The chosen pipeline is gone, broken, or switched off: the next message would be refused.
    private var unusable: Bool {
        guard !model.pipelineLibrary.isEmpty else { return false }
        guard let s = model.pipelineSummary(current) else { return true }
        return !s.runnable || s.armed == false
    }
}

private struct PipelineChoicePanel: View {
    @Environment(AppModel.self) private var model
    let selected: String
    let choose: (String) -> Void
    let openPipeline: (String) -> Void
    let openLibrary: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    group("Built in", model.pipelineLibrary.filter(\.isBuiltin))
                    let own = model.pipelineLibrary.filter { !$0.isBuiltin }
                    if !own.isEmpty { group("Yours", own) }
                }
                .padding(10)
            }
            .frame(maxHeight: 360)
            Hairline()
            HStack(spacing: 6) {
                Button("Open “\(model.pipelineName(selected))”") { openPipeline(selected) }
                    .buttonStyle(.bulava(.quiet))
                Spacer()
                Button("All pipelines") { openLibrary() }
                    .buttonStyle(.bulava(.quiet))
            }
            .padding(8)
        }
        .frame(width: 340)
    }

    private func group(_ title: LocalizedStringKey, _ items: [PipelineSummary]) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Eyebrow(title).padding(.horizontal, 8).padding(.bottom, 2)
            ForEach(items) { row($0) }
        }
    }

    private func row(_ s: PipelineSummary) -> some View {
        let reason = PipelineMenuItems.reason(s)
        let chosen = s.id == selected
        return Button { choose(s.id) } label: {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "checkmark")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Palette.accent)
                    .opacity(chosen ? 1 : 0)
                    .frame(width: 12)
                    .padding(.top, 2)
                VStack(alignment: .leading, spacing: 3) {
                    Text(verbatim: s.displayName)
                        .font(Typo.panelRow)
                        .foregroundStyle(reason == nil ? Palette.text : Palette.textFaint)
                    if let reason {
                        Text(verbatim: reason).font(Typo.meta).foregroundStyle(Palette.orange)
                    } else if let g = s.guarantees, !g.isEmpty {
                        Text(verbatim: g.map(\.t.local).joined(separator: " · "))
                            .font(Typo.meta)
                            .foregroundStyle(Palette.textTertiary)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
        }
        .buttonStyle(.row(selected: chosen))
        .disabled(reason != nil)
    }
}

/// The pipelines a run can go through, built-in first. One that cannot run is listed, not offered.
struct PipelineMenuItems: View {
    @Environment(AppModel.self) private var model
    let selected: String?
    let choose: (String) -> Void

    var body: some View {
        let builtin = model.pipelineLibrary.filter(\.isBuiltin)
        let own = model.pipelineLibrary.filter { !$0.isBuiltin }
        Section("Built in") {
            ForEach(builtin) { item(for: $0) }
        }
        if !own.isEmpty {
            Section("Yours") {
                ForEach(own) { item(for: $0) }
            }
        }
    }

    /// Why a pipeline cannot be chosen now, or nil when it can.
    static func reason(_ s: PipelineSummary) -> String? {
        s.broken != nil ? String(localized: "cannot be read")
            : (s.errors ?? 0) > 0 ? String(localized: "needs fixing")
            : s.armed == false ? String(localized: "switched off") : nil
    }

    @ViewBuilder private func item(for s: PipelineSummary) -> some View {
        let reason = Self.reason(s)
        Button {
            choose(s.id)
        } label: {
            if selected == s.id {
                Label(s.displayName, systemImage: "checkmark")
            } else if let reason {
                Text(verbatim: "\(s.displayName) — \(reason)")
            } else {
                Text(verbatim: s.displayName)
            }
        }
        .disabled(reason != nil)
    }
}

/// The pipeline an automation's runs go through.
struct AutomationPipelineSection: View {
    @Environment(AppModel.self) private var model
    @Binding var pipelineID: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Eyebrow("Pipeline")
            Menu {
                Button {
                    pipelineID = nil
                } label: {
                    if pipelineID == nil { Label(defaultLabel, systemImage: "checkmark") } else { Text(verbatim: defaultLabel) }
                }
                Divider()
                PipelineMenuItems(selected: pipelineID) { pipelineID = $0 }
            } label: {
                Text(verbatim: pipelineID.map { model.pipelineName($0) } ?? defaultLabel)
            }
            .fixedSize()
            Text(note)
                .font(Typo.caption)
                .foregroundStyle(unreviewed ? Palette.orange : Palette.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .task { if model.pipelineLibrary.isEmpty { await model.loadPipelineLibrary() } }
    }

    private var defaultLabel: String {
        String(localized: "As in chats — \(model.pipelineName(model.pipelineID(forChat: nil)))")
    }

    private var unreviewed: Bool {
        let id = pipelineID ?? model.pipelineID(forChat: nil)
        guard let s = model.pipelineSummary(id) else { return false }
        return !(s.guarantees ?? []).contains { $0.k == "review" && $0.tone == "ok" }
    }

    private var note: LocalizedStringKey {
        unreviewed
            ? "Nothing reviews this pipeline’s result, and nobody is watching an automation while it runs."
            : "What each run goes through: who prepares it, who does the work, what checks it."
    }
}
