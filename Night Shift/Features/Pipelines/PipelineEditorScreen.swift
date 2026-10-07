import SwiftUI

/// One pipeline, open: the canvas on the left, and on the right what the selected step does, what
/// the validator says, and the chat that changes it.
struct PipelineEditorScreen: View {
    @Environment(AppModel.self) private var model
    @Environment(\.undoManager) private var undoManager
    let pipelineID: String
    @State private var state: PipelineEditorState
    @State private var tab: Tab = .step
    @State private var naming: NamingRequest?
    @State private var sharing = false
    @State private var confirmDelete = false
    @State private var arming = false

    enum Tab: Hashable { case step, checks, chat }

    init(pipelineID: String) {
        self.pipelineID = pipelineID
        _state = State(initialValue: PipelineEditorState(id: pipelineID))
    }

    private var summary: PipelineSummary? { model.pipelineSummary(pipelineID) }

    var body: some View {
        VStack(spacing: 0) {
            header
            Hairline()
            if let banner = bannerContent { banner }
            if state.loadFailed {
                VStack(spacing: 10) {
                    Text("This pipeline could not be read.").font(Typo.rowLabel).foregroundStyle(Palette.text)
                    Button("Back to pipelines") { model.openPipelines() }.buttonStyle(.bulava(.secondary))
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if state.doc == nil {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                HStack(spacing: 0) {
                    PipelineCanvas(state: state, registry: model.pipelineRegistry)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    Rectangle().fill(Palette.line).frame(width: 1)
                    inspector
                        .frame(width: 330)
                        .background(Palette.chrome)
                }
            }
        }
        .background(Palette.content)
        .task {
            if model.pendingPipelineRequests[pipelineID] != nil { tab = .chat }
            state.undoManager = undoManager
            await state.load(model)
        }
        .onChange(of: undoManager) { _, new in state.undoManager = new }
        .onDisappear {
            undoManager?.removeAllActions(withTarget: state)
            Task { await state.flush() }
        }
        .sheet(item: $naming) { request in
            PipelineNameSheet(request: request) { name, _ in
                naming = nil
                Task {
                    if case .success(let id) = await model.duplicatePipeline(pipelineID, name: name) { model.openPipeline(id) }
                }
            } cancel: { naming = nil }
        }
        .sheet(isPresented: $sharing) {
            if let summary { PipelineExportSheet(summary: summary) { sharing = false } }
        }
        .confirmationDialog(Text("Delete “\(state.doc?.name ?? pipelineID)”?"), isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                Task { if await model.deletePipeline(pipelineID) { model.openPipelines() } }
            }
            Button("Keep", role: .cancel) {}
        } message: {
            Text("Chats and automations that used it go back to the default. A run already under way finishes on its own copy.")
        }
        .onChange(of: state.selection) { _, new in if new != nil, tab != .chat { tab = .step } }
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .center, spacing: 10) {
            Button { model.openPipelines() } label: { Image(systemName: "chevron.left") }
                .buttonStyle(.icon(size: 26, glyph: 12))
                .help(Text("All pipelines"))
            VStack(alignment: .leading, spacing: 2) {
                if state.readOnly {
                    Text(verbatim: state.doc?.name ?? pipelineID)
                        .font(Typo.toolbarTitle).foregroundStyle(Palette.text)
                } else {
                    TextField("Name", text: Binding(get: { state.doc?.name ?? "" },
                                                    set: { v in state.edit(coalescing: "name") { $0.name = v } }))
                        .textFieldStyle(.plain)
                        .font(Typo.toolbarTitle)
                        .foregroundStyle(Palette.text)
                        .frame(maxWidth: 360)
                }
                Text(verbatim: statusLine)
                    .font(Typo.panelMeta)
                    .foregroundStyle(statusTint)
            }
            Spacer(minLength: 8)
            if state.readOnly {
                Button { naming = .duplicate(summary ?? PipelineSummary(id: pipelineID, kind: "builtin", name: state.doc?.name)) } label: {
                    Label("Duplicate to change it", systemImage: "plus.square.on.square")
                }
                .buttonStyle(.bulava(.primary))
            } else {
                // ⌘Z and ⇧⌘Z come through Edit in the menu bar, to the same undo manager.
                Button { if let undoManager { undoManager.undo() } else { state.undo() } } label: { Image(systemName: "arrow.uturn.backward") }
                    .buttonStyle(.icon(size: 28, glyph: 12))
                    .disabled(!state.canUndo)
                    .help(Text("Undo (⌘Z)"))
                Button { if let undoManager { undoManager.redo() } else { state.redo() } } label: { Image(systemName: "arrow.uturn.forward") }
                    .buttonStyle(.icon(size: 28, glyph: 12))
                    .disabled(!state.canRedo)
                    .help(Text("Redo (⇧⌘Z)"))
            }
            Menu {
                if model.pipelineID(forChat: nil) != pipelineID {
                    Button("Use for new chats") {
                        model.settings.defaultPipelineID = pipelineID == model.builtinChatPipeline ? nil : pipelineID
                    }
                }
                if !state.readOnly {
                    Button("Make a copy…") { naming = .duplicate(summary ?? PipelineSummary(id: pipelineID, kind: "user", name: state.doc?.name)) }
                    Button("Share…") { Task { await state.flush(); sharing = true } }
                    Divider()
                    Button("Delete pipeline…", role: .destructive) { confirmDelete = true }
                }
            } label: {
                Image(systemName: "ellipsis")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
        }
        .padding(.horizontal, 14)
        .frame(height: 56)
    }

    private var statusLine: String {
        if state.readOnly { return String(localized: "Built in · read only") }
        switch state.saveState {
        case .clean: return String(localized: "Revision \(state.doc?.revision ?? 0)")
        case .pending, .saving: return String(localized: "Saving…")
        case .saved: return String(localized: "Saved · revision \(state.doc?.revision ?? 0)")
        case .stale: return String(localized: "Changed elsewhere")
        case .failed(let why): return String(localized: "Not saved: \(why)")
        }
    }

    private var statusTint: Color {
        switch state.saveState {
        case .stale, .failed: Palette.red
        default: Palette.textFaint
        }
    }

    // MARK: Banners

    private var bannerContent: AnyView? {
        if case .stale = state.saveState {
            return AnyView(banner(tint: Palette.orange, wash: Palette.orangeSoft,
                                  text: String(localized: "Somebody else changed this pipeline while it was open: the chat or another window. Your last change is not saved.")) {
                Button("Take theirs") { Task { await state.reload() } }.buttonStyle(.bulava(.secondary))
                Button("Keep mine") { Task { await state.overwrite() } }.buttonStyle(.bulava(.primary))
            })
        }
        if let doc = state.doc, doc.armed == false {
            let source = [doc.origin?.repo, doc.origin?.path].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: "/")
            let sha = (doc.origin?.sha).map { " @" + $0.prefix(10) } ?? ""
            return AnyView(banner(tint: Palette.blue, wash: Palette.blueSoft,
                                  text: source.isEmpty
                                    ? String(localized: "Switched off. Read its steps and prompts; messages can go through it once you switch it on.")
                                    : String(localized: "Imported from \(source)\(sha) and switched off. Read its steps and prompts; messages can go through it once you switch it on.")) {
                Button("Switch it on") {
                    arming = true
                    Task {
                        await state.flush()
                        if await model.armPipeline(pipelineID) { await state.reload() }
                        arming = false
                    }
                }
                .buttonStyle(.bulava(.primary))
                .disabled(arming || !state.validation.runnable)
            })
        }
        return nil
    }

    private func banner<Actions: View>(tint: Color, wash: Color, text: String, @ViewBuilder actions: () -> Actions) -> some View {
        HStack(spacing: 10) {
            Text(verbatim: text).font(Typo.caption).foregroundStyle(tint)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            actions()
        }
        .padding(.horizontal, 14).padding(.vertical, 8)
        .background(wash)
    }

    // MARK: Inspector

    private var inspector: some View {
        VStack(spacing: 0) {
            Picker("", selection: $tab) {
                Text("Step").tag(Tab.step)
                Text(checksTitle).tag(Tab.checks)
                Text("Chat").tag(Tab.chat)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(10)
            Hairline()
            switch tab {
            case .step:
                ScrollView { StepInspector(state: state).padding(13) }
            case .checks:
                ScrollView { ChecksInspector(state: state).padding(13) }
            case .chat:
                PipelineChatPanel(state: state)
            }
        }
    }

    private var checksTitle: String {
        let n = state.validation.errors.count
        return n > 0 ? String(localized: "Checks · \(n)") : String(localized: "Checks")
    }
}

// MARK: - The selected step

private struct StepInspector: View {
    @Environment(AppModel.self) private var model
    @Bindable var state: PipelineEditorState
    @State private var defaultPrompt: [String: String] = [:]

    var body: some View {
        if let doc = state.doc {
            if let id = state.selection, let node = doc.node(id) {
                nodeForm(node, doc: doc)
            } else if let eid = state.selectedEdge, let edge = doc.edges.first(where: { $0.id == eid }) {
                edgeForm(edge, doc: doc)
            } else {
                pipelineForm(doc)
            }
        }
    }

    // A whole pipeline: what it is called and what it is for.
    private func pipelineForm(_ doc: PipelineDocument) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Eyebrow("About this pipeline")
            if state.readOnly {
                Text(verbatim: doc.localizedDescription)
                    .font(Typo.body)
                    .foregroundStyle(Palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                field("Description") {
                    TextEditor(text: Binding(get: { doc.description },
                                             set: { v in state.edit(coalescing: "description") { $0.description = v } }))
                        .font(Typo.body)
                        .frame(minHeight: 80)
                        .scrollContentBackground(.hidden)
                        .padding(6)
                        .background(RoundedRectangle(cornerRadius: Metrics.radiusControl, style: .continuous).fill(Palette.field))
                }
            }
            Text(state.readOnly
                 ? "Select a step to see what it does and the prompt it uses. To change anything, duplicate the pipeline."
                 : "Select a step on the canvas to change it, or drag from an output dot to an input dot to connect two steps.")
                .font(Typo.caption).foregroundStyle(Palette.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
            GuaranteeList(guarantees: state.validation.guarantees)
        }
    }

    private func nodeForm(_ node: PipelineNode, doc: PipelineDocument) -> some View {
        let spec = model.pipelineRegistry?.modules[node.key]
        return VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Image(systemName: PipelineGlyphs.category(spec?.cat ?? ""))
                        .foregroundStyle(Palette.textSecondary)
                    Text(verbatim: spec?.t.local ?? node.key).font(Typo.panelRow).foregroundStyle(Palette.text)
                }
                if let d = spec?.d.local, !d.isEmpty {
                    Text(verbatim: d).font(Typo.caption).foregroundStyle(Palette.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            field("Name") {
                TextField(spec?.t.local ?? "", text: Binding(get: { node.title ?? "" },
                                                             set: { v in state.edit(coalescing: "title:" + node.id) { $0.setTitle(v, of: node.id) } }))
                    .textFieldStyle(.roundedBorder)
                    .disabled(state.readOnly)
            }

            ForEach(spec?.p ?? [], id: \.k) { param in
                paramControl(param, node: node)
            }

            ForEach(state.issues(for: node.id)) { issue in
                Label { Text(verbatim: issue.msg.local).fixedSize(horizontal: false, vertical: true) } icon: {
                    Image(systemName: issue.isError ? "xmark.octagon" : "exclamationmark.triangle")
                }
                .font(Typo.caption)
                .foregroundStyle(issue.isError ? Palette.red : Palette.orange)
            }

            if spec?.prompt == true { promptEditor(node) }

            connections(node, doc: doc)

            if !state.readOnly {
                Button(role: .destructive) { state.edit { $0.removeNode(node.id) } } label: {
                    Label("Remove this step", systemImage: "trash")
                }
                .buttonStyle(.bulava(.danger))
            }
        }
    }

    @ViewBuilder private func paramControl(_ param: PipelineParamSpec, node: PipelineNode) -> some View {
        let current = node.param(param.k) ?? param.default
        switch param.type {
        case "bool":
            Toggle(isOn: Binding(get: { current?.bool ?? false },
                                 set: { v in setParam(param.k, .bool(v), node) })) {
                Text(verbatim: param.label.local).font(Typo.caption)
            }
            .toggleStyle(.switch)
            .controlSize(.small)
            .disabled(state.readOnly)
        case "select":
            field(LocalizedStringKey(param.label.local)) {
                Picker("", selection: Binding(get: { current?.string ?? param.options?.first ?? "" },
                                              set: { v in setParam(param.k, .string(v), node) })) {
                    ForEach(param.options ?? [], id: \.self) { o in Text(verbatim: param.optionLabel(o)).tag(o) }
                }
                .labelsHidden()
                .disabled(state.readOnly)
            }
        default:
            field(LocalizedStringKey(param.label.local)) {
                TextField("", text: Binding(get: { current?.string ?? "" },
                                            set: { v in setParam(param.k, .string(v), node, typing: true) }))
                    .textFieldStyle(.roundedBorder)
                    .disabled(state.readOnly)
            }
        }
    }

    private func setParam(_ k: String, _ v: JSONValue, _ node: PipelineNode, typing: Bool = false) {
        state.edit(coalescing: typing ? "param:\(node.id).\(k)" : nil) { d in
            guard let i = d.nodes.firstIndex(where: { $0.id == node.id }) else { return }
            var p = d.nodes[i].params ?? [:]
            p[k] = v
            d.nodes[i].params = p
        }
    }

    @ViewBuilder private func promptEditor(_ node: PipelineNode) -> some View {
        let own = node.prompt ?? ""
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Eyebrow("Prompt")
                Spacer()
                if own.isEmpty, !state.readOnly {
                    Button("Write my own") {
                        Task {
                            let base = await prompt(for: node)
                            state.edit { d in
                                if let i = d.nodes.firstIndex(where: { $0.id == node.id }) {
                                    d.nodes[i].prompt = base.isEmpty ? " " : base
                                }
                            }
                        }
                    }
                    .buttonStyle(.plain).font(Typo.caption).foregroundStyle(Palette.accent)
                } else if !own.isEmpty, !state.readOnly {
                    Button("Use the built-in one") {
                        state.edit { d in
                            if let i = d.nodes.firstIndex(where: { $0.id == node.id }) { d.nodes[i].prompt = nil }
                        }
                    }
                    .buttonStyle(.plain).font(Typo.caption).foregroundStyle(Palette.accent)
                }
            }
            if own.isEmpty {
                Text("Uses the built-in prompt.")
                    .font(Typo.caption).foregroundStyle(Palette.textTertiary)
                if let text = defaultPrompt[node.key], !text.isEmpty {
                    ScrollView {
                        Text(verbatim: text)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(Palette.textSecondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                    }
                    .frame(height: 160)
                    .padding(6)
                    .background(RoundedRectangle(cornerRadius: Metrics.radiusControl, style: .continuous).fill(Palette.panelMuted))
                }
            } else {
                TextEditor(text: Binding(get: { node.prompt ?? "" },
                                         set: { v in state.edit(coalescing: "prompt:" + node.id) { d in
                                             if let i = d.nodes.firstIndex(where: { $0.id == node.id }) { d.nodes[i].prompt = v }
                                         } }))
                    .font(.system(size: 11.5, design: .monospaced))
                    .frame(minHeight: 200)
                    .scrollContentBackground(.hidden)
                    .padding(6)
                    .background(RoundedRectangle(cornerRadius: Metrics.radiusControl, style: .continuous).fill(Palette.field))
                    .overlay(RoundedRectangle(cornerRadius: Metrics.radiusControl, style: .continuous).strokeBorder(Palette.line, lineWidth: 1))
                    .disabled(state.readOnly)
                Text(node.key.hasPrefix("prep.") && node.key != "prep.compose"
                     ? "This text replaces the built-in prompt for this step. {{TASK}}, {{CONTEXT}} and the other names in double braces are filled in when it runs."
                     : "Your text is added to what the engine always sends; the parts that keep a run safe stay in place.")
                    .font(Typo.meta).foregroundStyle(Palette.textFaint)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .task(id: node.key) { _ = await prompt(for: node) }
    }

    private func prompt(for node: PipelineNode) async -> String {
        if let cached = defaultPrompt[node.key] { return cached }
        let text = await model.client.defaultPipelinePrompt(module: node.key)
        defaultPrompt[node.key] = text
        return text
    }

    private func connections(_ node: PipelineNode, doc: PipelineDocument) -> some View {
        let touching = doc.edges.filter { $0.fromNode == node.id || $0.toNode == node.id }
        return VStack(alignment: .leading, spacing: 6) {
            Eyebrow("Connections")
            if touching.isEmpty {
                Text("Not connected yet.").font(Typo.caption).foregroundStyle(Palette.textTertiary)
            }
            ForEach(touching) { edge in
                edgeRow(edge, doc: doc)
            }
        }
    }

    private func edgeRow(_ edge: PipelineEdge, doc: PipelineDocument) -> some View {
        let reg = model.pipelineRegistry
        let a = doc.node(edge.fromNode).map { RunNodeNaming.title($0, in: doc, registry: reg) } ?? edge.fromNode
        let b = doc.node(edge.toNode).map { RunNodeNaming.title($0, in: doc, registry: reg) } ?? edge.toNode
        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: edge.loop != nil ? "arrow.uturn.backward" : "arrow.right")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(edge.loop != nil ? Palette.orange : Palette.textFaint)
                Text(verbatim: "\(a) → \(b)").font(Typo.caption).foregroundStyle(Palette.textSecondary).lineLimit(1)
                Spacer(minLength: 4)
                if !state.readOnly {
                    Button { state.edit { $0.edges.removeAll { $0.id == edge.id } } } label: { Image(systemName: "xmark") }
                        .buttonStyle(.icon(size: 20, glyph: 9))
                        .help(Text("Disconnect"))
                }
            }
            if let loop = edge.loop {
                loopStepper(edge, loop: loop)
            }
        }
    }

    private func loopStepper(_ edge: PipelineEdge, loop: PipelineLoop) -> some View {
        let ceiling = model.pipelineRegistry?.reviewCeiling ?? 12
        return Stepper(value: Binding(get: { loop.max },
                                      set: { v in state.edit { d in
                                          if let i = d.edges.firstIndex(where: { $0.id == edge.id }) { d.edges[i].loop?.max = v }
                                      } }),
                       in: 1...ceiling) {
            Text(String(localized: "Rounds back to the worker, at most: \(loop.max)")).font(Typo.caption).foregroundStyle(Palette.textSecondary)
        }
        .controlSize(.small)
        .disabled(state.readOnly)
        .padding(.leading, 15)
    }

    private func edgeForm(_ edge: PipelineEdge, doc: PipelineDocument) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Eyebrow("Connection")
            edgeRow(edge, doc: doc)
            Text(edge.loop != nil
                 ? "When the check fails, the work goes back to the worker with the findings — at most this many times, then it waits for you."
                 : "What the step on the left produces goes into the step on the right.")
                .font(Typo.caption).foregroundStyle(Palette.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func field<Content: View>(_ label: LocalizedStringKey, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(label).font(Typo.meta).foregroundStyle(Palette.textTertiary)
            content()
        }
    }
}

// MARK: - What the validator says

private struct ChecksInspector: View {
    @Bindable var state: PipelineEditorState

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if state.validation.issues.isEmpty {
                Label("Nothing to fix. It can run.", systemImage: "checkmark.circle")
                    .font(Typo.caption).foregroundStyle(Palette.green)
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    Eyebrow("To fix before it can run")
                    ForEach(state.validation.errors) { issueRow($0) }
                    if state.validation.errors.isEmpty {
                        Text("Nothing blocks it.").font(Typo.caption).foregroundStyle(Palette.green)
                    }
                }
                if !state.validation.warnings.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Eyebrow("Worth a look")
                        ForEach(state.validation.warnings) { issueRow($0) }
                    }
                }
            }
            GuaranteeList(guarantees: state.validation.guarantees)
            if !state.validation.needs.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Eyebrow("Needs")
                    Text(verbatim: state.validation.needs.map { $0 == "codex" ? "Codex" : $0 }.joined(separator: ", "))
                        .font(Typo.caption).foregroundStyle(Palette.textSecondary)
                }
            }
        }
    }

    private func issueRow(_ issue: PipelineIssue) -> some View {
        Button {
            if let n = issue.node { state.selection = n }
        } label: {
            HStack(alignment: .top, spacing: 6) {
                Image(systemName: issue.isError ? "xmark.octagon" : "exclamationmark.triangle")
                    .foregroundStyle(issue.isError ? Palette.red : Palette.orange)
                Text(verbatim: issue.msg.local)
                    .foregroundStyle(Palette.text)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            .font(Typo.caption)
            .padding(6)
        }
        .buttonStyle(.row())
        .disabled(issue.node == nil)
    }
}

private struct GuaranteeList: View {
    let guarantees: [PipelineGuarantee]

    var body: some View {
        if !guarantees.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Eyebrow("What it guarantees")
                ForEach(guarantees) { g in
                    Label { Text(verbatim: g.t.local) } icon: {
                        Image(systemName: g.tone == "ok" ? "checkmark.shield" : "exclamationmark.shield")
                    }
                    .font(Typo.caption)
                    .foregroundStyle(g.tone == "ok" ? Palette.green : Palette.orange)
                }
            }
        }
    }
}
