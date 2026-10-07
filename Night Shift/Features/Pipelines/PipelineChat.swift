import SwiftUI

/// One line of the conversation about a pipeline.
nonisolated struct PipelineChatLine: Identifiable, Equatable, Sendable {
    enum Role: Equatable, Sendable { case you, bulava, note }
    var id = UUID()
    var role: Role
    var text: String
    /// What the change would do, when this answer proposed one.
    var changes: [String] = []
    var newProblems: [String] = []
    var state: ProposalState = .none

    enum ProposalState: Equatable, Sendable { case none, open, applied, discarded, superseded }
}

// MARK: - What is asked of Claude, and what comes back

/// The request the chat sends and the reading of its answer. Claude never writes the file: it
/// answers with RFC 6902 operations, the engine tries them on a copy, and only what he accepts
/// reaches the description — through the same save as an edit by hand.
nonisolated enum PipelineChatPrompt {

    static func build(registry: PipelineRegistry, doc: PipelineDocument, validation: PipelineValidation,
                      history: [PipelineChatLine], request: String) -> String {
        let palette = registry.modules
            .filter { $0.value.exec }
            .sorted { $0.key < $1.key }
            .map { key, m -> [String: Any] in
                var o: [String: Any] = [
                    "key": key, "title": m.t.en, "category": m.cat, "does": m.d.en,
                    "in": m.inPorts.map { "\($0.id):\($0.accepted.joined(separator: "|"))" },
                    "out": m.outPorts.map { "\($0.id):\($0.type ?? "any")" },
                ]
                if let p = m.p, !p.isEmpty {
                    o["params"] = p.map { spec -> String in
                        var s = "\(spec.k) (\(spec.type)"
                        if let opts = spec.options { s += ": " + opts.joined(separator: "|") }
                        return s + ")"
                    }
                }
                if m.prompt == true { o["prompt"] = "editable" }
                return o
            }
        var current = doc
        // Names in other languages are presentation; a rename drops them by itself.
        current.i18n = nil
        for i in current.nodes.indices {
            if let p = current.nodes[i].prompt, p.count > 600 {
                current.nodes[i].prompt = String(p.prefix(600)) + " …[truncated; keep it unless asked to change it]"
            }
        }
        let docJSON = (try? JSONEncoder().encode(current)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        let paletteJSON = (try? JSONSerialization.data(withJSONObject: palette, options: [.sortedKeys]))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
        let problems = validation.issues.map { "- [\($0.level)] \($0.code) \($0.node ?? ""): \($0.msg.en)" }.joined(separator: "\n")
        let earlier = history.suffix(8).compactMap { line -> String? in
            switch line.role {
            case .you: "USER: " + line.text
            case .bulava: "YOU: " + line.text
            case .note: nil
            }
        }.joined(separator: "\n")

        return """
        You edit a Bulava pipeline for the user. A pipeline is a graph of steps (nodes) wired by
        typed ports: what a message goes through before a coding agent gets it, who does the work,
        what checks the result. Answer with ONE JSON object and nothing else — no prose around it,
        no code fences:

        {"say": "<one to three sentences, in the language of the user's request: what you changed and why, or one question if the request is unclear>",
         "patch": [<RFC 6902 operations against the CURRENT description below>]}

        Rules for the patch:
        - The first operation is {"op":"test","path":"/revision","value":\(doc.revision)}.
        - Use only modules from PALETTE. A node is {"id","module","title","params"?,"prompt"?,"x","y"};
          module is "bulava/<key>@1". Ids: lowercase latin letters, digits and hyphens, unique.
        - An edge is {"from":"<node>.<outPort>","to":"<node>.<inPort>"}. The out type must be one the
          in port accepts. Exactly one trigger and one worker (agent.*) per pipeline.
        - Sending work back is an edge from a check's "fail" port to the worker's "feedback" port with
          "loop":{"max":N}, N from 1 to \(registry.reviewCeiling).
        - A prompt is plain text in the node's "prompt". Never put keys, tokens or passwords anywhere.
        - Give new nodes "x","y" near the steps they connect to: about 220 apart left to right,
          120 apart top to bottom.
        - Removing a node: also remove every edge that touches it. Remove array items from the
          highest index down, so earlier indexes stay valid.
        - Change only what the request asks for. If nothing should change, return "patch": [].
        - Write titles of new steps in the language of the request.

        PALETTE:
        \(paletteJSON)

        CURRENT DESCRIPTION (revision \(doc.revision)):
        \(docJSON)

        CURRENT PROBLEMS:
        \(problems.isEmpty ? "none" : problems)

        CONVERSATION SO FAR:
        \(earlier.isEmpty ? "none" : earlier)

        REQUEST:
        \(request)
        """
    }

    struct Answer: Equatable {
        var say: String
        var patch: Data
        var isEmpty: Bool
    }

    /// The JSON object in an answer, wherever it sits; nil when there is none or it has no "say".
    static func parse(_ text: String) -> Answer? {
        var candidates: [Substring] = []
        if let start = text.firstIndex(of: "{"), let end = text.lastIndex(of: "}"), start < end {
            candidates.append(text[start...end])
        }
        for c in candidates {
            guard let data = String(c).data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let say = obj["say"] as? String else { continue }
            let ops = (obj["patch"] as? [[String: Any]]) ?? []
            let meaningful = ops.filter { ($0["op"] as? String) != "test" }
            let patch = (try? JSONSerialization.data(withJSONObject: ops)) ?? Data("[]".utf8)
            return Answer(say: say, patch: patch, isEmpty: meaningful.isEmpty)
        }
        return nil
    }
}

// MARK: - What a change does, in words

nonisolated enum PipelineDiff {

    static func describe(from old: PipelineDocument, to new: PipelineDocument, registry: PipelineRegistry?) -> [String] {
        var lines: [String] = []
        func name(_ n: PipelineNode, _ d: PipelineDocument) -> String { RunNodeNaming.title(n, in: d, registry: registry) }
        if old.name != new.name { lines.append(String(localized: "Renamed to “\(new.name)”")) }
        if old.description != new.description { lines.append(String(localized: "New description")) }
        let oldIDs = Set(old.nodes.map(\.id)), newIDs = Set(new.nodes.map(\.id))
        for n in new.nodes where !oldIDs.contains(n.id) {
            lines.append(String(localized: "Added step “\(name(n, new))”"))
        }
        for n in old.nodes where !newIDs.contains(n.id) {
            lines.append(String(localized: "Removed step “\(name(n, old))”"))
        }
        for n in new.nodes {
            guard let before = old.node(n.id) else { continue }
            var what: [String] = []
            if before.module != n.module { what.append(String(localized: "the kind of step")) }
            if (before.title ?? "") != (n.title ?? "") { what.append(String(localized: "the name")) }
            if (before.params ?? [:]) != (n.params ?? [:]) { what.append(String(localized: "the settings")) }
            if (before.prompt ?? "") != (n.prompt ?? "") { what.append(String(localized: "the prompt")) }
            if !what.isEmpty {
                lines.append(String(localized: "Changed step “\(name(n, new))”: \(what.joined(separator: ", "))"))
            }
        }
        let oldEdges = Dictionary(old.edges.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let newEdges = Dictionary(new.edges.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        func label(_ e: PipelineEdge, _ d: PipelineDocument) -> String {
            let a = d.node(e.fromNode).map { name($0, d) } ?? e.fromNode
            let b = d.node(e.toNode).map { name($0, d) } ?? e.toNode
            return "\(a) → \(b)"
        }
        for (id, e) in newEdges.sorted(by: { $0.key < $1.key }) where oldEdges[id] == nil {
            lines.append(e.loop != nil
                         ? String(localized: "Sends back: \(label(e, new)) · rounds at most: \(e.loop?.max ?? 0)")
                         : String(localized: "New connection: \(label(e, new))"))
        }
        for (id, e) in oldEdges.sorted(by: { $0.key < $1.key }) where newEdges[id] == nil {
            lines.append(String(localized: "Connection removed: \(label(e, old))"))
        }
        for (id, e) in newEdges.sorted(by: { $0.key < $1.key }) {
            if let before = oldEdges[id], before.loop?.max != e.loop?.max, let m = e.loop?.max {
                lines.append(String(localized: "Rounds back to the worker, at most: \(m) (was \(before.loop?.max ?? 0))"))
            }
        }
        return lines
    }
}

// MARK: - The conversation, apart from how it is drawn

/// One pipeline's conversation: what was said, and the changes proposed and not yet decided.
///
/// A proposal remembers the description it was made against. Applying it to a pipeline he has
/// changed since would quietly undo his change, so it is not applied: his changes are written
/// first, the same change is worked out again on top of them and shown again — or, when the
/// pipeline's shape moved under it, Claude is asked again.
@MainActor
@Observable
final class PipelineChatSession {

    struct Proposal {
        var preview: PipelinePatchPreview
        var operations: Data
        var basis: PipelineDocument
        var request: String
        var say: String
    }

    enum ApplyOutcome: Equatable {
        case applied
        /// The pipeline had changed; a fresh proposal is in the conversation, waiting for him.
        case reproposed
        /// A built-in cannot change; the description to make a copy of comes back.
        case needsCopy
        case failed
    }

    private(set) var lines: [PipelineChatLine] = []
    private(set) var thinking = false
    @ObservationIgnored private(set) var proposals: [UUID: Proposal] = [:]
    @ObservationIgnored private let ask: @MainActor (String) async -> String?

    init(ask: @escaping @MainActor (String) async -> String?) { self.ask = ask }

    func proposal(_ id: UUID) -> Proposal? { proposals[id] }

    private func append(_ line: PipelineChatLine) { lines.append(line) }

    func note(_ text: String) { append(PipelineChatLine(role: .note, text: text)) }

    func mark(_ id: UUID, _ s: PipelineChatLine.ProposalState) {
        guard let i = lines.firstIndex(where: { $0.id == id }) else { return }
        lines[i].state = s
        if s != .open { proposals[id] = nil }
    }

    /// He asked for something: his words, then what Claude proposes for the pipeline as it is now.
    func send(_ request: String, state: PipelineEditorState, registry: PipelineRegistry) async {
        let request = request.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !request.isEmpty, !thinking else { return }
        append(PipelineChatLine(role: .you, text: request))
        await propose(request, state: state, registry: registry, history: Array(lines.dropLast()))
    }

    private func propose(_ request: String, state: PipelineEditorState, registry: PipelineRegistry,
                         history: [PipelineChatLine]) async {
        thinking = true
        defer { thinking = false }
        guard await persisted(state) else { return }
        guard let doc = state.doc, let backend = state.backend else { return }
        for line in lines where line.state == .open { mark(line.id, .discarded) }

        var prompt = PipelineChatPrompt.build(registry: registry, doc: doc, validation: state.validation,
                                              history: history, request: request)
        for attempt in 0..<2 {
            guard let raw = await ask(prompt) else {
                append(PipelineChatLine(role: .note, text: String(localized: "Claude did not answer. Check that it is signed in, then try again.")))
                return
            }
            guard let answer = PipelineChatPrompt.parse(raw) else {
                append(PipelineChatLine(role: .bulava, text: raw.trimmingCharacters(in: .whitespacesAndNewlines)))
                return
            }
            if answer.isEmpty {
                append(PipelineChatLine(role: .bulava, text: answer.say))
                return
            }
            let operations = PipelinePatchOps.pinned(answer.patch, toRevision: doc.revision) ?? answer.patch
            switch await backend.editorPreviewPatch(state.id, operations: operations) {
            case .success(let preview):
                offer(preview, operations: operations, basis: doc, request: request, say: answer.say, registry: registry)
                return
            case .failure(let error):
                guard attempt == 0 else {
                    append(PipelineChatLine(role: .note, text: String(localized: "The change Claude proposed does not fit this pipeline: \(error.text)")))
                    return
                }
                prompt += "\n\nYOUR PREVIOUS ANSWER COULD NOT BE APPLIED: \(error.text)\nReturn a corrected JSON object."
            }
        }
    }

    private func offer(_ preview: PipelinePatchPreview, operations: Data, basis: PipelineDocument,
                       request: String, say: String, registry: PipelineRegistry) {
        var preview = preview
        preview.document.dropTitleOverrides(changedFrom: basis)
        let changes = PipelineDiff.describe(from: basis, to: preview.document, registry: registry)
        var line = PipelineChatLine(role: .bulava, text: say, changes: changes,
                                    newProblems: preview.newErrors.map(\.msg.local), state: .open)
        if changes.isEmpty { line.state = .none }
        proposals[line.id] = Proposal(preview: preview, operations: operations, basis: basis, request: request, say: say)
        append(line)
    }

    /// Writes what he changed and says whether everything is on disk.
    ///
    /// A change is proposed against the description on disk, and the description in the editor is
    /// what a proposal is checked against when it is applied. If his last edit could not be
    /// written, the two differ: a proposal made now would be worked out on the old description and
    /// then applied over his edit. So nothing is proposed until it is written, and he is told why.
    private func persisted(_ state: PipelineEditorState) async -> Bool {
        await state.flush()
        guard state.hasUnsaved else { return true }
        switch state.saveState {
        case .stale:
            append(PipelineChatLine(role: .note, text: String(localized: "This pipeline was changed elsewhere. Reload it or keep your version first, then ask again.")))
        case .failed(let why):
            append(PipelineChatLine(role: .note, text: String(localized: "Your last change is not saved (\(why)), so nothing is proposed: a proposal would be worked out on the old version and undo it. It stays in the editor; ask again once it is saved.")))
        default:
            append(PipelineChatLine(role: .note, text: String(localized: "Your last change is not saved yet, so nothing is proposed. Ask again in a moment.")))
        }
        return false
    }

    /// Applies a proposal — only to the pipeline it was made for.
    func apply(_ id: UUID, state: PipelineEditorState, registry: PipelineRegistry) async -> ApplyOutcome {
        guard let p = proposals[id] else { return .failed }
        if state.readOnly { return .needsCopy }
        guard let current = state.doc else { return .failed }
        if current.sameContent(as: p.basis) {
            state.replace(with: p.preview.document)
            mark(id, .applied)
            return .applied
        }

        // He changed the pipeline after this was proposed. His changes go to disk first; then the
        // same change is worked out on top of them and shown again before anything is applied.
        // Until they are on disk nothing is worked out at all, and this proposal stays as it was.
        thinking = true
        let saved = await persisted(state)
        thinking = false
        guard saved, let now = state.doc, let backend = state.backend else { return .failed }
        mark(id, .superseded)
        if now.sameShape(as: p.basis), let operations = PipelinePatchOps.pinned(p.operations, toRevision: now.revision),
           case .success(let preview) = await backend.editorPreviewPatch(state.id, operations: operations) {
            append(PipelineChatLine(role: .note, text: String(localized: "The pipeline changed while this proposal waited. Here is the same change on top of your edits: check it and apply again.")))
            offer(preview, operations: operations, basis: now, request: p.request, say: p.say, registry: registry)
            return .reproposed
        }
        append(PipelineChatLine(role: .note, text: String(localized: "The proposal no longer fits the pipeline as you changed it. Asking again.")))
        await propose(p.request, state: state, registry: registry, history: lines)
        return .reproposed
    }
}

/// Changes Claude proposed, held as RFC 6902 operations.
nonisolated enum PipelinePatchOps {

    /// The same operations, made to apply only to `revision`: the first operation tests it.
    static func pinned(_ operations: Data, toRevision revision: Int) -> Data? {
        guard var ops = (try? JSONSerialization.jsonObject(with: operations)) as? [[String: Any]] else { return nil }
        let test: [String: Any] = ["op": "test", "path": "/revision", "value": revision]
        if let first = ops.first, first["op"] as? String == "test", first["path"] as? String == "/revision" {
            ops[0] = test
        } else {
            ops.insert(test, at: 0)
        }
        return try? JSONSerialization.data(withJSONObject: ops)
    }
}

extension PipelineDocument {

    /// The same description, whatever revision number each copy carries.
    func sameContent(as other: PipelineDocument) -> Bool {
        var a = self, b = other
        a.revision = 0
        b.revision = 0
        return a == b
    }

    /// The same steps and connections in the same order — what index-based operations point at.
    func sameShape(as other: PipelineDocument) -> Bool {
        nodes.map(\.id) == other.nodes.map(\.id) && edges.map(\.id) == other.edges.map(\.id)
    }
}

// MARK: - The panel

struct PipelineChatPanel: View {
    @Environment(AppModel.self) private var model
    @Bindable var state: PipelineEditorState
    @State private var draft = ""
    @FocusState private var focused: Bool

    private var session: PipelineChatSession { model.pipelineChatSession(state.id) }
    private var lines: [PipelineChatLine] { session.lines }

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        if lines.isEmpty { intro }
                        ForEach(lines) { line in
                            lineView(line).id(line.id)
                        }
                        if session.thinking {
                            HStack(spacing: 8) {
                                ProgressView().controlSize(.small)
                                Text("Working out the change…").font(Typo.caption).foregroundStyle(Palette.textTertiary)
                            }
                            .id("thinking")
                        }
                    }
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .onChange(of: lines.count) { _, _ in
                    withAnimation(Motion.standard) { proxy.scrollTo(lines.last?.id, anchor: .bottom) }
                }
            }
            Hairline()
            composer
        }
        .task(id: state.id) {
            if let pending = model.pendingPipelineRequests.removeValue(forKey: state.id), !pending.isEmpty {
                draft = pending
                await send()
            }
        }
    }

    private var intro: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Describe what you want, and Bulava changes the pipeline.")
                .font(Typo.panelRow).foregroundStyle(Palette.text)
            Text(state.readOnly
                 ? "This one is built in, so a change you accept becomes a new pipeline of yours."
                 : "You see every change before it is made, and Undo takes it back.")
                .font(Typo.caption).foregroundStyle(Palette.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 4) {
                example("Make Codex review the research report, two rounds at most")
                example("Require the minimalist-ui skill before the work is accepted")
                example("Skip the independent positions; I want it fast")
            }
            .padding(.top, 4)
        }
    }

    private func example(_ key: String.LocalizationValue) -> some View {
        let text = String(localized: key)
        return Button { draft = text; focused = true } label: {
            Text(verbatim: text)
                .font(Typo.caption)
                .foregroundStyle(Palette.accent)
                .multilineTextAlignment(.leading)
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder private func lineView(_ line: PipelineChatLine) -> some View {
        switch line.role {
        case .you:
            Text(verbatim: line.text)
                .font(Typo.body)
                .foregroundStyle(Palette.text)
                .padding(.horizontal, 10).padding(.vertical, 7)
                .background(RoundedRectangle(cornerRadius: Metrics.radiusChip, style: .continuous).fill(Palette.panelMuted))
                .frame(maxWidth: .infinity, alignment: .trailing)
                .textSelection(.enabled)
        case .note:
            Text(verbatim: line.text)
                .font(Typo.caption)
                .foregroundStyle(Palette.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        case .bulava:
            VStack(alignment: .leading, spacing: 8) {
                Text(verbatim: line.text)
                    .font(Typo.body)
                    .foregroundStyle(Palette.text)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                if !line.changes.isEmpty {
                    VStack(alignment: .leading, spacing: 3) {
                        ForEach(Array(line.changes.enumerated()), id: \.offset) { _, c in
                            Text(verbatim: "· " + c).font(Typo.caption).foregroundStyle(Palette.textSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        ForEach(Array(line.newProblems.enumerated()), id: \.offset) { _, p in
                            Label { Text(verbatim: p) } icon: { Image(systemName: "exclamationmark.triangle") }
                                .font(Typo.caption).foregroundStyle(Palette.orange)
                        }
                    }
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: Metrics.radiusChip, style: .continuous).fill(Palette.panelMuted))
                    proposalButtons(line)
                }
            }
        }
    }

    @ViewBuilder private func proposalButtons(_ line: PipelineChatLine) -> some View {
        switch line.state {
        case .open:
            HStack(spacing: 6) {
                Button(state.readOnly ? "Apply as a new pipeline" : "Apply") { Task { await apply(line) } }
                    .buttonStyle(.bulava(.primary))
                    .disabled(session.thinking)
                Button("Discard") { session.mark(line.id, .discarded) }
                    .buttonStyle(.bulava(.quiet))
            }
        case .applied:
            Text("Applied").font(Typo.panelMeta).foregroundStyle(Palette.green)
        case .discarded:
            Text("Discarded").font(Typo.panelMeta).foregroundStyle(Palette.textFaint)
        case .superseded:
            Text("Replaced by the proposal below").font(Typo.panelMeta).foregroundStyle(Palette.textFaint)
        case .none:
            EmptyView()
        }
    }

    private var composer: some View {
        HStack(alignment: .bottom, spacing: 6) {
            TextField("What should change?", text: $draft, axis: .vertical)
                .textFieldStyle(.plain)
                .font(Typo.body)
                .lineLimit(1...6)
                .focused($focused)
                .onSubmit { Task { await send() } }
                .padding(.horizontal, 10).padding(.vertical, 8)
                .background(RoundedRectangle(cornerRadius: Metrics.radiusControl, style: .continuous).fill(Palette.field))
                .overlay(RoundedRectangle(cornerRadius: Metrics.radiusControl, style: .continuous).strokeBorder(Palette.line, lineWidth: 1))
            Button { Task { await send() } } label: { Image(systemName: "arrow.up") }
                .buttonStyle(.icon(size: 30, glyph: 12))
                .disabled(session.thinking || draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .help(Text("Send"))
        }
        .padding(10)
    }

    // MARK: Talking

    private func send() async {
        let request = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !request.isEmpty, !session.thinking, let registry = model.pipelineRegistry else { return }
        draft = ""
        await session.send(request, state: state, registry: registry)
    }

    private func apply(_ line: PipelineChatLine) async {
        guard let registry = model.pipelineRegistry else { return }
        let session = self.session
        guard await session.apply(line.id, state: state, registry: registry) == .needsCopy,
              let preview = session.proposal(line.id)?.preview else { return }
        // A built-in stays as it is: the change becomes a pipeline of his own.
        let name = String(localized: "\(state.doc?.name ?? state.id) — copy")
        switch await model.duplicatePipeline(state.id, name: name) {
        case .success(let newID):
            guard let copy = await model.pipelineDetail(newID) else { return }
            var next = preview.document
            next.id = newID
            next.name = copy.document.name
            next.builtin = nil
            next.executes = nil
            next.origin = copy.document.origin
            next.revision = copy.document.revision
            if case .saved = await model.savePipeline(next, expectRevision: copy.document.revision) {
                session.mark(line.id, .applied)
                model.pipelineChatSessions[newID] = session
                model.openPipeline(newID)
            }
        case .failure(let e):
            session.note(e.text)
        }
    }
}
