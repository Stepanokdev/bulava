import Foundation

extension AppModel {

    // MARK: - Which pipeline a message goes through

    /// The built-in pipeline every chat used before pipelines could be chosen.
    var builtinChatPipeline: String { settings.chatMode.messagePipeline }

    /// What a chat's next message goes through: its own choice, else the default for new chats,
    /// else the built-in one for the chat mode.
    func pipelineID(forChat chatID: UUID?) -> String {
        if let chatID, let own = conversations.chat(id: chatID)?.pipelineID, !own.isEmpty { return own }
        if let chosen = settings.defaultPipelineID, !chosen.isEmpty { return chosen }
        return builtinChatPipeline
    }

    /// The name handed to the engine as `--pipeline` for this chat's next message — the one place
    /// the send reads it from.
    func relayPipeline(forChat chatID: UUID?) -> String {
        SupervisorClient.safePipelineName(pipelineID(forChat: chatID))
    }

    /// Change it for one chat — or, with no chat yet, for the next new one.
    ///
    /// A chat's choice is kept as it was made, a built-in one included: "nothing chosen" means
    /// "as new chats", and when new chats default to one of his own pipelines, storing the built-in
    /// as nothing would put that chat straight back on his.
    func choosePipeline(_ id: String, forChat chatID: UUID?) {
        if let chatID, conversations.chat(id: chatID) != nil {
            conversations.setPipeline(id, for: chatID)
        } else {
            settings.defaultPipelineID = id == builtinChatPipeline ? nil : id
        }
    }

    /// The conversation about one pipeline, made the first time its chat is opened.
    func pipelineChatSession(_ id: String) -> PipelineChatSession {
        if let existing = pipelineChatSessions[id] { return existing }
        let client = self.client
        let session = PipelineChatSession { prompt in await client.askClaude(prompt: prompt, timeout: 240) }
        pipelineChatSessions[id] = session
        return session
    }

    func pipelineSummary(_ id: String) -> PipelineSummary? {
        pipelineLibrary.first { $0.id == id }
    }

    /// The name a pipeline goes by on screen; the id when the library has not been read yet.
    func pipelineName(_ id: String) -> String {
        pipelineSummary(id)?.displayName ?? id
    }

    // MARK: - The library

    func loadPipelineLibrary() async {
        if let list = await client.pipelineLibrary() {
            pipelineLibrary = list.filter { $0.hidden != true }
        }
        if pipelineRegistry == nil { pipelineRegistry = await client.pipelineRegistry() }
    }

    func pipelineDetail(_ id: String) async -> PipelineDetail? {
        await client.pipelineDetail(id: id)
    }

    /// A free id for a copy: the source's, then `-2`, `-3`… — never one that exists.
    func freePipelineID(basedOn base: String) -> String {
        let taken = Set(pipelineLibrary.map(\.id))
        let stem = Self.pipelineSlug(base)
        if !taken.contains(stem) { return stem }
        var n = 2
        while taken.contains("\(stem)-\(n)") { n += 1 }
        return "\(stem)-\(n)"
    }

    nonisolated static func pipelineSlug(_ text: String) -> String {
        let latin = text.applyingTransform(.toLatin, reverse: false)?
            .applyingTransform(.stripDiacritics, reverse: false) ?? text
        var out = ""
        for ch in latin.lowercased() {
            if ch.isASCII, ch.isLetter || ch.isNumber { out.append(ch) }
            else if !out.hasSuffix("-") { out.append("-") }
        }
        let trimmed = out.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        let clipped = String(trimmed.prefix(48)).trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return clipped.isEmpty ? "pipeline" : clipped
    }

    func duplicatePipeline(_ source: String, name: String) async -> Result<String, PipelineToolError> {
        let id = freePipelineID(basedOn: name)
        let result = await client.duplicatePipeline(source, as: id, name: name)
        await loadPipelineLibrary()
        return result
    }

    /// A new, empty pipeline: just the chat trigger, so the canvas has somewhere to start from.
    func createPipeline(name: String) async -> Result<String, PipelineToolError> {
        let id = freePipelineID(basedOn: name)
        var doc = PipelineDocument(id: id, name: name, nodes: [
            PipelineNode(id: "chat", module: "bulava/trigger.chat@1", x: 24, y: 40),
        ])
        doc.revision = 0
        switch await client.savePipeline(doc, expectRevision: 0) {
        case .saved:
            await loadPipelineLibrary()
            return .success(id)
        case .stale:
            return .failure(.stale)
        case .refused(let why):
            return .failure(.message(why))
        }
    }

    func deletePipeline(_ id: String) async -> Bool {
        let ok = await client.deletePipeline(id)
        if ok {
            if settings.defaultPipelineID == id { settings.defaultPipelineID = nil }
            for chat in conversations.chats where chat.pipelineID == id {
                conversations.setPipeline(nil, for: chat.id)
            }
            for automation in automations.automations where automation.pipelineID == id {
                automations.update(automation.id) { $0.pipelineID = nil }
            }
        }
        await loadPipelineLibrary()
        return ok
    }

    func savePipeline(_ doc: PipelineDocument, expectRevision: Int?) async -> PipelineWriteResult {
        let result = await client.savePipeline(doc, expectRevision: expectRevision)
        if case .saved = result { await loadPipelineLibrary() }
        return result
    }

    // MARK: - A chat's run, as it happens

    /// Reads the journal again for one chat and works out its latest run.
    func refreshChatRun(chatID: UUID) async {
        guard let chat = conversations.chat(id: chatID), let binding = chat.session,
              !binding.projectPath.isEmpty else {
            if chatRuns[chatID] != nil { chatRuns[chatID] = nil }
            return
        }
        let stamp = await client.runEventsStamp(projectPath: binding.projectPath, runID: binding.activeRunID)
        let ids = conversations.entries(inChat: chatID).filter { $0.kind == .user }.map(\.id.uuidString)
        let key = stamp + "#" + (ids.last ?? "")
        guard chatRunStamps[chatID] != key else { return }

        let events = await client.runEvents(projectPath: binding.projectPath, runID: binding.activeRunID)
        guard let messageID = RunReducer.latestMessage(in: events, among: ids) else {
            chatRunStamps[chatID] = key
            if chatRuns[chatID] != nil { chatRuns[chatID] = nil }
            return
        }
        let mine = events.filter { $0.messageID == messageID }
        let start = mine.last { $0.stage == "pipeline" && $0.state == "running" }
        let snapshot = start?.snapshot
        let pipeline = start?.pipeline ?? mine.first?.pipeline
        let docKey = snapshot ?? ("builtin:" + (pipeline ?? ""))
        var document = runDocuments[docKey]
        if document == nil {
            document = await client.runPipelineDocument(snapshot: snapshot, pipeline: pipeline)
            if let document { runDocuments[docKey] = document }
        }
        let graph = RunReducer.reduce(events: events, messageID: messageID, document: document)
        let next = ChatRun(graph: graph, document: document)
        chatRunStamps[chatID] = key
        if chatRuns[chatID] != next { chatRuns[chatID] = next }
    }

    /// Keeps one chat's run fresh while a view showing it is on screen: every second while
    /// something is happening, every few seconds otherwise. The loop ends with the view.
    func watchChatRun(chatID: UUID?) async {
        guard let chatID else { return }
        while !Task.isCancelled {
            await refreshChatRun(chatID: chatID)
            let busy = (chatRuns[chatID]?.graph.isLive ?? false) || directPhase(for: chatID).isActive
            try? await Task.sleep(for: .seconds(busy ? 1 : 4))
        }
    }
}

// MARK: - Sharing

extension AppModel {

    func fetchPipelineForImport(_ source: String, path: String?) async -> Result<PipelineImportPreview, PipelineImportFailure> {
        await client.fetchPipelineForImport(source, path: path)
    }

    func installImportedPipeline(_ preview: PipelineImportPreview) async -> Result<String, PipelineImportFailure> {
        let id = freePipelineID(basedOn: preview.document.id.isEmpty ? preview.document.name : preview.document.id)
        let result = await client.installImportedPipeline(preview, as: id)
        await loadPipelineLibrary()
        return result
    }

    func discardImport(_ preview: PipelineImportPreview) async {
        await client.discardImport(preview)
    }

    func armPipeline(_ id: String) async -> Bool {
        let ok = await client.armPipeline(id: id)
        await loadPipelineLibrary()
        return ok
    }

    func exportPipeline(_ id: String, to folder: URL) async -> Result<URL, PipelineToolError> {
        await client.exportPipeline(id: id, to: folder)
    }

    /// Exported into a folder of its own first, so what goes to GitHub is exactly what an export
    /// would have written — no key, no home path — and nothing else of his.
    func publishPipeline(_ id: String, repository: String, isPrivate: Bool) async -> Result<URL, PipelineToolError> {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("bulava-publish-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: base) }
        switch await client.exportPipeline(id: id, to: base) {
        case .failure(let e): return .failure(e)
        case .success(let dir): return await client.publishPipeline(folder: dir, repository: repository, isPrivate: isPrivate)
        }
    }
}

// MARK: - The editor's reads and writes

extension AppModel: PipelineEditorBackend {

    func editorLoad(_ id: String) async -> PipelineDetail? {
        if pipelineRegistry == nil { await loadPipelineLibrary() }
        return await pipelineDetail(id)
    }

    func editorSave(_ doc: PipelineDocument, expectRevision: Int?) async -> PipelineWriteResult {
        await savePipeline(doc, expectRevision: expectRevision)
    }

    func editorValidate(_ doc: PipelineDocument) async -> PipelineValidation? {
        await client.validatePipeline(doc, draft: true)
    }

    func editorPreviewPatch(_ id: String, operations: Data) async -> Result<PipelinePatchPreview, PipelineToolError> {
        await client.previewPipelinePatch(id: id, operations: operations)
    }
}
