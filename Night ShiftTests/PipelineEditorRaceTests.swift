import XCTest
@testable import Bulava

/// Two ways an edit used to be lost in the pipeline editor: a change made while the previous one
/// was still being written, and a chat proposal applied over a change made after it was proposed.
/// Both run against the engine's own tool, writing into a scratch state folder.
nonisolated final class PipelineEditorRaceTests: XCTestCase {

    /// The app model as the editor's backend, with one write that can be held back on purpose.
    @MainActor
    final class HeldBackend: PipelineEditorBackend {
        let inner: AppModel
        var holdNextSave = false
        /// Every write is refused, the way a full disk or a broken folder refuses it.
        var refuseSaves = false
        private(set) var held = false
        private var gate: CheckedContinuation<Void, Never>?
        private(set) var saves = 0

        init(_ inner: AppModel) { self.inner = inner }

        func release() { held = false; gate?.resume(); gate = nil }

        func editorLoad(_ id: String) async -> PipelineDetail? { await inner.editorLoad(id) }
        func editorValidate(_ doc: PipelineDocument) async -> PipelineValidation? { await inner.editorValidate(doc) }
        func editorPreviewPatch(_ id: String, operations: Data) async -> Result<PipelinePatchPreview, PipelineToolError> {
            await inner.editorPreviewPatch(id, operations: operations)
        }
        func editorSave(_ doc: PipelineDocument, expectRevision: Int?) async -> PipelineWriteResult {
            saves += 1
            if refuseSaves { return .refused("disk is full") }
            if holdNextSave {
                holdNextSave = false
                held = true
                await withCheckedContinuation { gate = $0 }
            }
            return await inner.editorSave(doc, expectRevision: expectRevision)
        }
    }

    private var scratch: URL!
    private var previousState: String?
    private var previousApp: String?

    override func setUp() {
        super.setUp()
        previousState = ProcessInfo.processInfo.environment["SUPERVISOR_STATE_DIR"]
        previousApp = ProcessInfo.processInfo.environment["BULAVA_STATE_DIR"]
    }

    @MainActor
    private func model() async throws -> AppModel {
        scratch = FileManager.default.temporaryDirectory.appendingPathComponent("bulava-editor-race-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: scratch.appendingPathComponent("app"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: scratch.appendingPathComponent("state"), withIntermediateDirectories: true)
        setenv("BULAVA_STATE_DIR", scratch.appendingPathComponent("app").path, 1)
        setenv("SUPERVISOR_STATE_DIR", scratch.appendingPathComponent("state").path, 1)
        let m = AppModel()
        await m.loadPipelineLibrary()
        XCTAssertNotNil(m.pipelineRegistry, "the engine's pipeline tool answers")
        return m
    }

    override func tearDown() {
        if let scratch { try? FileManager.default.removeItem(at: scratch) }
        // Back to what the rest of the suite runs with.
        if let previousState { setenv("SUPERVISOR_STATE_DIR", previousState, 1) } else { unsetenv("SUPERVISOR_STATE_DIR") }
        if let previousApp { setenv("BULAVA_STATE_DIR", previousApp, 1) } else { unsetenv("BULAVA_STATE_DIR") }
        super.tearDown()
    }

    @MainActor
    private func waitUntil(_ what: String, _ condition: () -> Bool) async {
        for _ in 0..<400 where !condition() { try? await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(condition(), what)
    }

    @MainActor
    private func title(_ doc: PipelineDocument?, _ node: String) -> String? { doc?.node(node)?.title }

    // MARK: A change made while the one before it is being written

    @MainActor
    func testAChangeMadeWhileTheLastOneIsBeingWrittenIsWrittenToo() async throws {
        let m = try await model()
        guard case .success(let id) = await m.duplicatePipeline("plain", name: "Race") else { return XCTFail("no copy") }
        let backend = HeldBackend(m)
        let state = PipelineEditorState(id: id)
        state.saveDelay = .zero
        await state.load(backend)
        XCTAssertNotNil(state.doc)

        // A: its write is held on the way.
        backend.holdNextSave = true
        state.edit { $0.setTitle("A", of: "report") }
        await waitUntil("write A started and is held") { backend.held }

        // B: made while A is still being written.
        state.edit { $0.setTitle("B", of: "merge") }
        XCTAssertTrue(state.hasUnsaved)

        backend.release()
        await state.flush()
        XCTAssertFalse(state.hasUnsaved, "nothing he changed is left unwritten")
        if case .saved = state.saveState {} else { XCTFail("ends saved, not \(state.saveState)") }
        XCTAssertGreaterThanOrEqual(backend.saves, 2, "B went in a write of its own, after A")

        // Opened again from disk: both changes are there.
        let reopened = PipelineEditorState(id: id)
        await reopened.load(m)
        XCTAssertEqual(title(reopened.doc, "report"), "A")
        XCTAssertEqual(title(reopened.doc, "merge"), "B")
    }

    @MainActor
    func testFlushWaitsForTheWriteUnderWay() async throws {
        let m = try await model()
        guard case .success(let id) = await m.duplicatePipeline("plain", name: "Flush") else { return XCTFail("no copy") }
        let backend = HeldBackend(m)
        let state = PipelineEditorState(id: id)
        state.saveDelay = .zero
        await state.load(backend)

        backend.holdNextSave = true
        state.edit { $0.setTitle("Held", of: "report") }
        await waitUntil("the write is held") { backend.held }

        var flushed = false
        let flushing = Task { @MainActor in await state.flush(); flushed = true }
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertFalse(flushed, "flush does not return while a write is still on its way")
        backend.release()
        await flushing.value
        XCTAssertTrue(flushed)
        let reopened = PipelineEditorState(id: id)
        await reopened.load(m)
        XCTAssertEqual(title(reopened.doc, "report"), "Held")
    }

    // MARK: A proposal applied after he changed the pipeline himself

    @MainActor
    func testApplyingAnOlderProposalKeepsWhatHeChangedSince() async throws {
        let m = try await model()
        guard case .success(let id) = await m.duplicatePipeline("plain", name: "Chat race") else { return XCTFail("no copy") }
        let registry = try XCTUnwrap(m.pipelineRegistry)
        let state = PipelineEditorState(id: id)
        state.saveDelay = .zero
        await state.load(m)
        let loopIndex = try XCTUnwrap(state.doc?.edges.firstIndex { $0.loop != nil })
        XCTAssertEqual(state.doc?.edges[loopIndex].loop?.max, 3)

        // Claude proposes: two rounds at most.
        let answer = #"{"say":"Two rounds.","patch":[{"op":"replace","path":"/edges/\#(loopIndex)/loop/max","value":2}]}"#
        let session = PipelineChatSession { _ in answer }
        await session.send("two rounds at most", state: state, registry: registry)
        let first = try XCTUnwrap(session.lines.last { $0.state == .open })

        // He renames a step by hand before applying.
        state.edit { $0.setTitle("Renamed by hand", of: "report") }

        let outcome = await session.apply(first.id, state: state, registry: registry)
        XCTAssertEqual(outcome, .reproposed, "the old proposal is not applied over his change")
        XCTAssertEqual(title(state.doc, "report"), "Renamed by hand")
        XCTAssertEqual(state.doc?.edges[loopIndex].loop?.max, 3, "nothing applied yet: he sees it again first")
        XCTAssertEqual(session.lines.first { $0.id == first.id }?.state, .superseded)

        let again = try XCTUnwrap(session.lines.last { $0.state == .open }, "the same change, shown again on top of his")
        XCTAssertNotEqual(again.id, first.id)
        XCTAssertTrue(again.changes.contains { $0.contains("2") }, "it still says what it changes: \(again.changes)")
        let applied = await session.apply(again.id, state: state, registry: registry)
        XCTAssertEqual(applied, .applied)
        XCTAssertEqual(title(state.doc, "report"), "Renamed by hand")
        XCTAssertEqual(state.doc?.edges[loopIndex].loop?.max, 2)

        await state.flush()
        let reopened = PipelineEditorState(id: id)
        await reopened.load(m)
        XCTAssertEqual(title(reopened.doc, "report"), "Renamed by hand", "his rename survives on disk")
        XCTAssertEqual(reopened.doc?.edges[loopIndex].loop?.max, 2, "and so does the change he accepted")
    }

    @MainActor
    func testAProposalForAnUnchangedPipelineAppliesAtOnce() async throws {
        let m = try await model()
        guard case .success(let id) = await m.duplicatePipeline("plain", name: "Chat plain") else { return XCTFail("no copy") }
        let registry = try XCTUnwrap(m.pipelineRegistry)
        let state = PipelineEditorState(id: id)
        state.saveDelay = .zero
        await state.load(m)
        let loopIndex = try XCTUnwrap(state.doc?.edges.firstIndex { $0.loop != nil })
        let session = PipelineChatSession { _ in
            #"{"say":"One round.","patch":[{"op":"replace","path":"/edges/\#(loopIndex)/loop/max","value":1}]}"#
        }
        await session.send("one round", state: state, registry: registry)
        let line = try XCTUnwrap(session.lines.last { $0.state == .open })
        let applied = await session.apply(line.id, state: state, registry: registry)
        XCTAssertEqual(applied, .applied)
        XCTAssertEqual(state.doc?.edges[loopIndex].loop?.max, 1)
    }

    @MainActor
    func testWhenTheShapeChangedClaudeIsAskedAgain() async throws {
        let m = try await model()
        guard case .success(let id) = await m.duplicatePipeline("plain", name: "Chat shape") else { return XCTFail("no copy") }
        let registry = try XCTUnwrap(m.pipelineRegistry)
        let state = PipelineEditorState(id: id)
        state.saveDelay = .zero
        await state.load(m)
        var asked = 0
        let session = PipelineChatSession { _ in
            asked += 1
            return #"{"say":"Renamed.","patch":[{"op":"replace","path":"/nodes/0/title","value":"Start"}]}"#
        }
        await session.send("rename the first step", state: state, registry: registry)
        let first = try XCTUnwrap(session.lines.last { $0.state == .open })
        // He takes a step out: the operations' indexes no longer point where they did.
        state.edit { $0.removeNode("merge") }
        let outcome = await session.apply(first.id, state: state, registry: registry)
        XCTAssertEqual(outcome, .reproposed)
        XCTAssertEqual(asked, 2, "an index-based change is not replayed over a different shape")
        XCTAssertNil(state.doc?.node("merge"), "his removal stands")
    }

    // MARK: A proposal while his last edit could not be written

    @MainActor
    func testNothingIsProposedWhileHisEditIsNotSaved() async throws {
        let m = try await model()
        guard case .success(let id) = await m.duplicatePipeline("plain", name: "Refused new") else { return XCTFail("no copy") }
        let registry = try XCTUnwrap(m.pipelineRegistry)
        let backend = HeldBackend(m)
        let state = PipelineEditorState(id: id)
        state.saveDelay = .zero
        await state.load(backend)
        let loopIndex = try XCTUnwrap(state.doc?.edges.firstIndex { $0.loop != nil })
        let original = title(state.doc, "report")

        backend.refuseSaves = true
        state.edit { $0.setTitle("Unsaved by hand", of: "report") }
        await state.flush()
        if case .failed = state.saveState {} else { XCTFail("the refused write shows: \(state.saveState)") }

        var asked = 0
        let session = PipelineChatSession { _ in
            asked += 1
            return #"{"say":"Two rounds.","patch":[{"op":"replace","path":"/edges/\#(loopIndex)/loop/max","value":2}]}"#
        }
        await session.send("two rounds at most", state: state, registry: registry)
        XCTAssertEqual(asked, 0, "nothing is worked out on a version he has already changed")
        XCTAssertNil(session.lines.first { $0.state == .open }, "and nothing is offered to apply")
        XCTAssertEqual(session.lines.last?.role, .note, "he is told why")
        XCTAssertEqual(title(state.doc, "report"), "Unsaved by hand", "his edit is still in the editor")
        XCTAssertTrue(state.hasUnsaved)

        let onDisk = PipelineEditorState(id: id)
        await onDisk.load(m)
        XCTAssertEqual(title(onDisk.doc, "report"), original, "the refused edit never reached the disk")

        // Once writing works again, the same request goes through and keeps his edit.
        backend.refuseSaves = false
        await session.send("two rounds at most", state: state, registry: registry)
        XCTAssertEqual(asked, 1)
        let line = try XCTUnwrap(session.lines.last { $0.state == .open })
        let applied = await session.apply(line.id, state: state, registry: registry)
        XCTAssertEqual(applied, .applied)
        await state.flush()
        let reopened = PipelineEditorState(id: id)
        await reopened.load(m)
        XCTAssertEqual(title(reopened.doc, "report"), "Unsaved by hand")
        XCTAssertEqual(reopened.doc?.edges[loopIndex].loop?.max, 2)
    }

    @MainActor
    func testAnOlderProposalIsNotReworkedWhileHisEditIsNotSaved() async throws {
        let m = try await model()
        guard case .success(let id) = await m.duplicatePipeline("plain", name: "Refused older") else { return XCTFail("no copy") }
        let registry = try XCTUnwrap(m.pipelineRegistry)
        let backend = HeldBackend(m)
        let state = PipelineEditorState(id: id)
        state.saveDelay = .zero
        await state.load(backend)
        let loopIndex = try XCTUnwrap(state.doc?.edges.firstIndex { $0.loop != nil })
        let original = title(state.doc, "report")

        var asked = 0
        let session = PipelineChatSession { _ in
            asked += 1
            return #"{"say":"Two rounds.","patch":[{"op":"replace","path":"/edges/\#(loopIndex)/loop/max","value":2}]}"#
        }
        await session.send("two rounds at most", state: state, registry: registry)
        let proposal = try XCTUnwrap(session.lines.last { $0.state == .open })

        // He edits by hand, and that write is refused.
        backend.refuseSaves = true
        state.edit { $0.setTitle("Unsaved by hand", of: "report") }
        for _ in 0..<2 {
            let outcome = await session.apply(proposal.id, state: state, registry: registry)
            XCTAssertEqual(outcome, .failed, "an older proposal is not applied, and not reworked either")
            XCTAssertEqual(title(state.doc, "report"), "Unsaved by hand", "his edit stays")
            XCTAssertEqual(state.doc?.edges[loopIndex].loop?.max, 3, "the proposal did not land")
            XCTAssertEqual(session.lines.first { $0.id == proposal.id }?.state, .open, "it waits until he can save")
        }
        XCTAssertEqual(asked, 1, "Claude was not asked again over an unsaved version")
        let onDisk = PipelineEditorState(id: id)
        await onDisk.load(m)
        XCTAssertEqual(title(onDisk.doc, "report"), original)
        XCTAssertEqual(onDisk.doc?.edges[loopIndex].loop?.max, 3)

        // Writing works again: the edit goes to disk, the change is reworked on top and shown again.
        backend.refuseSaves = false
        let outcome = await session.apply(proposal.id, state: state, registry: registry)
        XCTAssertEqual(outcome, .reproposed)
        let again = try XCTUnwrap(session.lines.last { $0.state == .open })
        let applied = await session.apply(again.id, state: state, registry: registry)
        XCTAssertEqual(applied, .applied)
        await state.flush()
        let reopened = PipelineEditorState(id: id)
        await reopened.load(m)
        XCTAssertEqual(title(reopened.doc, "report"), "Unsaved by hand")
        XCTAssertEqual(reopened.doc?.edges[loopIndex].loop?.max, 2)
    }
}
