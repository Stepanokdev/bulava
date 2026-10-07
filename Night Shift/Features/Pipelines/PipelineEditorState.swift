import SwiftUI

/// Where an editor reads and writes a pipeline. The app's engine in the product; a stand-in in
/// tests, which is how a slow write can be held back on purpose.
@MainActor
protocol PipelineEditorBackend: AnyObject {
    func editorLoad(_ id: String) async -> PipelineDetail?
    func editorSave(_ doc: PipelineDocument, expectRevision: Int?) async -> PipelineWriteResult
    func editorValidate(_ doc: PipelineDocument) async -> PipelineValidation?
    func editorPreviewPatch(_ id: String, operations: Data) async -> Result<PipelinePatchPreview, PipelineToolError>
}

/// One open pipeline: the description being edited, its history for undo, and its save state.
///
/// Every change is saved on its own a moment later, against the revision this editor last saw.
/// If something else wrote the pipeline in between — the chat in another window, a second editor —
/// the save is refused instead of quietly undoing that change, and the editor says so.
///
/// Writes go one at a time. Each change bumps a generation; a write records the generation it
/// carried, and only that one counts as saved. A change made while a write is on its way stays
/// pending, and the next write takes it — the finishing write never declares it saved.
@MainActor
@Observable
final class PipelineEditorState {

    enum SaveState: Equatable {
        case clean
        case pending
        case saving
        case saved(Date)
        case stale(Int)
        case failed(String)
    }

    let id: String
    var kind = "user"
    var doc: PipelineDocument?
    var validation = PipelineValidation()
    var selection: String?
    var selectedEdge: String?
    var saveState: SaveState = .clean
    var loadFailed = false
    private(set) var baseRevision = 0
    private(set) var undoStack: [PipelineDocument] = []
    private(set) var redoStack: [PipelineDocument] = []

    /// Bumped by every change to the description.
    @ObservationIgnored private(set) var editGeneration = 0
    /// The generation the last finished write carried.
    @ObservationIgnored private(set) var savedGeneration = 0
    /// The write under way, so a second one waits for it instead of racing it.
    @ObservationIgnored private var writing: Task<Void, Never>?
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    @ObservationIgnored private var validateTask: Task<Void, Never>?
    @ObservationIgnored private var gestureStart: PipelineDocument?
    @ObservationIgnored private(set) weak var backend: (any PipelineEditorBackend)?
    /// The window's own: Edit → Undo and ⌘Z reach the pipeline through it, as they do everywhere.
    @ObservationIgnored weak var undoManager: UndoManager?
    /// Typing into one field is one step back, not one per letter.
    @ObservationIgnored private var lastBurst: (key: String, at: Date)?
    /// How long a change waits before it is written, so typing is one write, not one per letter.
    @ObservationIgnored var saveDelay: Duration = .milliseconds(700)

    init(id: String) { self.id = id }

    var readOnly: Bool { kind == "builtin" }
    var canUndo: Bool { !undoStack.isEmpty && !readOnly }
    var canRedo: Bool { !redoStack.isEmpty && !readOnly }
    /// Something he changed is not on disk yet.
    var hasUnsaved: Bool { editGeneration != savedGeneration }

    func issues(for node: String) -> [PipelineIssue] { validation.issues.filter { $0.node == node } }

    // MARK: Loading

    func load(_ backend: any PipelineEditorBackend) async {
        self.backend = backend
        guard let detail = await backend.editorLoad(id) else {
            loadFailed = true
            return
        }
        kind = detail.kind
        undoManager?.removeAllActions(withTarget: self)
        doc = detail.document.withAutoLayout()
        baseRevision = detail.document.revision
        validation = detail.validation
        saveState = .clean
        savedGeneration = editGeneration
        undoStack = []
        redoStack = []
    }

    /// Throw the local version away and take what is on disk now.
    func reload() async {
        guard let backend else { return }
        saveTask?.cancel()
        while let running = writing {
            await running.value
            if writing == running { writing = nil }
        }
        await load(backend)
    }

    // MARK: Editing

    func edit(coalescing key: String? = nil, _ change: (inout PipelineDocument) -> Void) {
        guard !readOnly, var next = doc else { return }
        let before = next
        change(&next)
        guard next != before else { return }
        let sameBurst = key != nil && lastBurst?.key == key && Date().timeIntervalSince(lastBurst?.at ?? .distantPast) < 1.5
        if !sameBurst { record(before) }
        lastBurst = key.map { ($0, Date()) }
        doc = next
        changed()
    }

    private func record(_ before: PipelineDocument) {
        undoStack.append(before)
        if undoStack.count > 200 { undoStack.removeFirst() }
        redoStack.removeAll()
        undoManager?.registerUndo(withTarget: self) { $0.undo() }
        undoManager?.setActionName(String(localized: "Change Pipeline"))
    }

    /// A drag moves a box many times a second; it is one step in the history, not a hundred.
    func beginGesture() {
        if gestureStart == nil { gestureStart = doc }
    }

    /// Where a box stood when the drag that is moving it began.
    func gestureOrigin(of id: String) -> CGPoint? {
        guard let n = (gestureStart ?? doc)?.node(id) else { return nil }
        return CGPoint(x: n.x ?? 0, y: n.y ?? 0)
    }

    func editDuringGesture(_ change: (inout PipelineDocument) -> Void) {
        guard !readOnly, var next = doc else { return }
        change(&next)
        doc = next
    }

    func endGesture() {
        defer { gestureStart = nil }
        guard let start = gestureStart, let doc, start != doc else { return }
        lastBurst = nil
        record(start)
        changed()
    }

    /// Called by the undo manager — through Edit → Undo, ⌘Z or the button — and registers the way
    /// back, which the manager files as Redo.
    func undo() {
        guard canUndo, let current = doc, let previous = undoStack.popLast() else { return }
        redoStack.append(current)
        doc = previous
        lastBurst = nil
        changed()
        undoManager?.registerUndo(withTarget: self) { $0.redo() }
    }

    func redo() {
        guard canRedo, let current = doc, let next = redoStack.popLast() else { return }
        undoStack.append(current)
        doc = next
        lastBurst = nil
        changed()
        undoManager?.registerUndo(withTarget: self) { $0.undo() }
    }

    /// The whole description replaced at once — a change the chat proposed and he accepted.
    func replace(with next: PipelineDocument) {
        guard !readOnly, let current = doc else { return }
        var placed = next.withAutoLayout()
        placed.dropTitleOverrides(changedFrom: current)
        placed.revision = current.revision
        guard placed != current else { return }
        lastBurst = nil
        record(current)
        doc = placed
        changed()
    }

    private func changed() {
        editGeneration += 1
        if let s = selection, doc?.node(s) == nil { selection = nil }
        if let e = selectedEdge, doc?.edges.contains(where: { $0.id == e }) != true { selectedEdge = nil }
        scheduleValidate()
        scheduleSave()
    }

    // MARK: Checking and saving

    private func scheduleValidate() {
        validateTask?.cancel()
        validateTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled, let self, let doc = self.doc, let backend = self.backend else { return }
            let generation = self.editGeneration
            if let v = await backend.editorValidate(doc), !Task.isCancelled, generation == self.editGeneration {
                self.validation = v
            }
        }
    }

    private func scheduleSave() {
        guard !readOnly else { return }
        if case .stale = saveState { return }
        if case .saving = saveState {} else { saveState = .pending }
        saveTask?.cancel()
        let delay = saveDelay
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            await self?.saveNow()
        }
    }

    /// Writes everything not yet written, one write at a time. Also what the chat waits for, so it
    /// proposes a change to what is on disk.
    func saveNow() async {
        guard !readOnly else { return }
        // Wait for a write already under way — and for any that starts while waiting. Whoever sees
        // it finished first lets go of it, so nobody waits on a write that is already over.
        while let running = writing {
            await running.value
            if writing == running { writing = nil }
        }
        guard hasUnsaved, let doc, let backend else { return }
        if case .stale = saveState { return }
        saveTask?.cancel()
        let generation = editGeneration
        let expect = baseRevision
        saveState = .saving
        let task = Task { @MainActor [weak self] in
            let result = await backend.editorSave(doc, expectRevision: expect)
            self?.finish(result, generation: generation)
        }
        writing = task
        await task.value
        if writing == task { writing = nil }
        // A change made while that write was on its way is still waiting; write it now.
        if hasUnsaved, case .pending = saveState { await saveNow() }
    }

    private func finish(_ result: PipelineWriteResult, generation: Int) {
        switch result {
        case .saved(let revision, let v):
            baseRevision = revision
            doc?.revision = revision
            savedGeneration = generation
            if generation == editGeneration {
                validation = v
                saveState = .saved(Date())
            } else {
                saveState = .pending
            }
        case .stale(let revision):
            saveState = .stale(revision)
        case .refused(let why):
            saveState = .failed(why)
        }
    }

    /// He chose to keep his version over the one written elsewhere.
    func overwrite() async {
        guard case .stale(let revision) = saveState else { return }
        baseRevision = revision
        saveState = .pending
        await saveNow()
    }

    /// Everything he changed is written, or a reason it could not be is on screen.
    func flush() async {
        saveTask?.cancel()
        if case .failed = saveState { saveState = .pending }
        await saveNow()
    }
}

// MARK: - Where boxes stand

extension PipelineDocument {

    /// Positions for the steps that have none — a description written by hand or by the chat —
    /// laid out by depth, left to right. Steps that have a place keep it.
    func withAutoLayout() -> PipelineDocument {
        guard nodes.contains(where: { $0.x == nil || $0.y == nil }) else { return self }
        var out = self
        let t = topologicalOrder()
        var perLevel: [Int: Int] = [:]
        for id in t.order {
            guard let i = out.nodes.firstIndex(where: { $0.id == id }) else { continue }
            let level = t.level[id] ?? 0
            let slot = perLevel[level, default: 0]
            perLevel[level] = slot + 1
            if out.nodes[i].x == nil || out.nodes[i].y == nil {
                out.nodes[i].x = 24 + Double(level) * PipelineCanvasMetrics.columnStep
                out.nodes[i].y = 24 + Double(slot) * PipelineCanvasMetrics.rowStep
            }
        }
        return out
    }

    /// An id for a new step of this module that no step has yet: `review`, `review-2`…
    func freeNodeID(for key: String) -> String {
        let stem = key.split(separator: ".").last.map(String.init)?.lowercased() ?? "step"
        let clean = stem.filter { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }
        let base = clean.isEmpty ? "step" : clean
        let taken = Set(nodes.map(\.id))
        if !taken.contains(base) { return base }
        var n = 2
        while taken.contains("\(base)-\(n)") { n += 1 }
        return "\(base)-\(n)"
    }

    mutating func removeNode(_ id: String) {
        nodes.removeAll { $0.id == id }
        edges.removeAll { $0.fromNode == id || $0.toNode == id }
        i18n?["en"]?["node." + id] = nil
    }

    /// A step renamed — by hand or by the chat — is called that in every language: the English
    /// name a built-in step came with no longer describes it.
    mutating func dropTitleOverrides(changedFrom old: PipelineDocument) {
        for n in nodes {
            guard let before = old.node(n.id), (before.title ?? "") != (n.title ?? "") else { continue }
            i18n?["en"]?["node." + n.id] = nil
        }
    }

    mutating func setTitle(_ title: String, of id: String) {
        guard let i = nodes.firstIndex(where: { $0.id == id }) else { return }
        nodes[i].title = title
        // His own name for a step is the name in every language from now on.
        i18n?["en"]?["node." + id] = nil
    }
}

nonisolated enum PipelineCanvasMetrics {
    static let nodeWidth: CGFloat = 176
    static let headerHeight: CGFloat = 40
    static let portRow: CGFloat = 20
    static let columnStep: Double = 230
    static let rowStep: Double = 120

    static func height(inputs: Int, outputs: Int) -> CGFloat {
        headerHeight + CGFloat(max(max(inputs, outputs), 1)) * portRow + 8
    }
}
