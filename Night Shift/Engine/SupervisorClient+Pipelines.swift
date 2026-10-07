import Foundation

/// A description as the library holds it, with what the engine's validator said about it.
nonisolated struct PipelineDetail: Sendable, Equatable {
    var kind: String
    var document: PipelineDocument
    var validation: PipelineValidation

    var isBuiltin: Bool { kind == "builtin" }
}

/// What a write to the library came back with. `stale` is its own case because the answer to it is
/// different: somebody else (the chat, another window) changed the description since it was read.
nonisolated enum PipelineWriteResult: Sendable, Equatable {
    case saved(revision: Int, validation: PipelineValidation)
    case stale(revision: Int)
    case refused(String)

    var revision: Int? {
        if case .saved(let r, _) = self { return r }
        return nil
    }
}

/// A proposed change, tried on a copy: what the description would be, and whether it would still run.
nonisolated struct PipelinePatchPreview: Sendable, Equatable {
    var document: PipelineDocument
    var validation: PipelineValidation
    var newErrors: [PipelineIssue]
    var baseRevision: Int
}

extension SupervisorClient {

    fileprivate var pipelineTool: String? {
        guard let home = OrchestratorHome.detect()?.path else { return nil }
        let path = "\(home)/bin/pipeline-tool.py"
        return FileManager.default.fileExists(atPath: path) ? path : nil
    }

    /// The tool reads stdin only when told to; everything bigger than an argument goes through a file,
    /// because `Shell.run` has no stdin and a description can be long.
    fileprivate func runTool(_ argv: [String], input: Data? = nil, timeout: TimeInterval = 30) async -> (code: Int32, json: Data?, text: String) {
        guard let tool = pipelineTool else { return (-1, nil, "engine not found") }
        var args = [tool] + argv
        var temp: URL?
        if let input {
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("bulava-pipeline-\(UUID().uuidString).json")
            do { try input.write(to: url, options: .atomic) } catch { return (-1, nil, error.localizedDescription) }
            temp = url
            args += ["--in", url.path]
        }
        defer { if let temp { try? FileManager.default.removeItem(at: temp) } }
        let placeholders = (1...args.count).map { "\"$\($0)\"" }.joined(separator: " ")
        let r = await Shell.run("/usr/bin/python3 \(placeholders)", args: args, timeout: timeout)
        let line = r.stdout.split(separator: "\n").last { $0.first == "{" }
        return (r.launched ? r.exitCode : -1, line.flatMap { String($0).data(using: .utf8) },
                r.stderr.trimmedTail.isEmpty ? r.stdout.trimmedTail : r.stderr.trimmedTail)
    }

    fileprivate static func object(_ data: Data?) -> [String: Any]? {
        data.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
    }

    private static func decode<T: Decodable>(_ type: T.Type, _ value: Any?) -> T? {
        decodeValue(type, value)
    }

    func pipelineRegistry() async -> PipelineRegistry? {
        let r = await runTool(["registry"])
        return r.json.flatMap { try? JSONDecoder().decode(PipelineRegistry.self, from: $0) }
    }

    func pipelineLibrary() async -> [PipelineSummary]? {
        let r = await runTool(["list"])
        guard r.code == 0, let root = Self.object(r.json) else { return nil }
        return Self.decode([PipelineSummary].self, root["pipelines"])
    }

    func pipelineDetail(id: String) async -> PipelineDetail? {
        let r = await runTool(["show", id])
        guard r.code == 0, let root = Self.object(r.json),
              let doc = Self.decode(PipelineDocument.self, root["pipeline"]) else { return nil }
        let validation = Self.decode(PipelineValidation.self, root["validation"]) ?? PipelineValidation()
        return PipelineDetail(kind: (root["kind"] as? String) ?? "user", document: doc, validation: validation)
    }

    /// `draft` relaxes only "this module cannot run yet": an editor shows a half-built pipeline
    /// with its real problems instead of drowning them in that one.
    func validatePipeline(_ doc: PipelineDocument, draft: Bool = true) async -> PipelineValidation? {
        guard let data = try? JSONEncoder().encode(doc) else { return nil }
        guard let tool = pipelineTool else { return nil }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("bulava-pipeline-\(UUID().uuidString).json")
        guard (try? data.write(to: url, options: .atomic)) != nil else { return nil }
        defer { try? FileManager.default.removeItem(at: url) }
        let argv = draft ? [tool, "validate", "--draft", url.path] : [tool, "validate", url.path]
        let r = await Shell.run("/usr/bin/python3 \"$1\" \"$2\" \"$3\"\(draft ? " \"$4\"" : "")", args: argv, timeout: 20)
        guard let line = r.stdout.split(separator: "\n").last(where: { $0.first == "{" }),
              let d = String(line).data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(PipelineValidation.self, from: d)
    }

    func savePipeline(_ doc: PipelineDocument, expectRevision: Int?) async -> PipelineWriteResult {
        guard let data = try? JSONEncoder().encode(doc) else { return .refused("encode") }
        var argv = ["save", doc.id]
        if let expectRevision { argv += ["--expect-revision", String(expectRevision)] }
        let r = await runTool(argv, input: data)
        let root = Self.object(r.json)
        if r.code == 6 { return .stale(revision: (root?["revision"] as? Int) ?? 0) }
        guard r.code == 0, let root else { return .refused((root?["error"] as? String) ?? r.text) }
        return .saved(revision: (root["revision"] as? Int) ?? doc.revision,
                      validation: Self.decode(PipelineValidation.self, root["validation"]) ?? PipelineValidation())
    }

    /// RFC 6902 operations, as the chat writes them. The engine applies them under its lock and
    /// refuses a change that would break a pipeline that ran.
    func previewPipelinePatch(id: String, operations: Data) async -> Result<PipelinePatchPreview, PipelineToolError> {
        let r = await runTool(["patch", id, "--dry-run"], input: operations)
        guard let root = Self.object(r.json) else { return .failure(.message(r.text)) }
        guard let doc = Self.decode(PipelineDocument.self, root["pipeline"]) else {
            return .failure(r.code == 6 ? .stale : .message((root["error"] as? String) ?? r.text))
        }
        return .success(PipelinePatchPreview(
            document: doc,
            validation: Self.decode(PipelineValidation.self, root["validation"]) ?? PipelineValidation(),
            newErrors: Self.decode([PipelineIssue].self, root["new_errors"]) ?? [],
            baseRevision: (root["revision"] as? Int) ?? 1))
    }

    func applyPipelinePatch(id: String, operations: Data) async -> PipelineWriteResult {
        let r = await runTool(["patch", id], input: operations)
        let root = Self.object(r.json)
        if r.code == 6 { return .stale(revision: (root?["revision"] as? Int) ?? 0) }
        guard r.code == 0, let root else { return .refused((root?["error"] as? String) ?? r.text) }
        return .saved(revision: (root["revision"] as? Int) ?? 0,
                      validation: Self.decode(PipelineValidation.self, root["validation"]) ?? PipelineValidation())
    }

    func duplicatePipeline(_ source: String, as newID: String, name: String) async -> Result<String, PipelineToolError> {
        let r = await runTool(["duplicate", source, newID, "--name", name])
        guard r.code == 0, let root = Self.object(r.json), let id = root["id"] as? String else {
            return .failure(.message((Self.object(r.json)?["error"] as? String) ?? r.text))
        }
        return .success(id)
    }

    /// Moves the package aside rather than erasing it: a run that already started keeps its own
    /// snapshot, and a deletion by mistake can be undone from the trash folder.
    func deletePipeline(_ id: String) async -> Bool {
        await runTool(["delete", id]).code == 0
    }

    func defaultPipelinePrompt(module key: String) async -> String {
        let r = await runTool(["default-prompt", key])
        return (Self.object(r.json)?["prompt"] as? String) ?? ""
    }

    // MARK: - The run journal

    /// The events of the run a chat is showing: `run-events.jsonl` next to the run, plus its
    /// previous generation when the engine has just rotated it. Only the tail is read; a run's own
    /// lines are all near the end because the file is append-only.
    func runEvents(projectPath: String, runID: String?) -> [RunEvent] {
        guard let base = paths.artifactBase(runID: runID, projectPath: projectPath) else { return [] }
        var out: [RunEvent] = []
        for name in ["run-events.jsonl.1", "run-events.jsonl"] {
            let url = base.appendingPathComponent(name)
            guard let text = Self.tail(of: url, bytes: 1_048_576) else { continue }
            out += RunEvent.parse(lines: text.split(separator: "\n"))
        }
        return out
    }

    /// Size and modification time of the journal — enough to know nothing new was written.
    func runEventsStamp(projectPath: String, runID: String?) -> String {
        guard let base = paths.artifactBase(runID: runID, projectPath: projectPath) else { return "" }
        let fm = FileManager.default
        return ["run-events.jsonl.1", "run-events.jsonl"].map { name in
            let attrs = try? fm.attributesOfItem(atPath: base.appendingPathComponent(name).path)
            let size = (attrs?[.size] as? NSNumber)?.int64Value ?? -1
            let date = (attrs?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
            return "\(size)@\(date)"
        }.joined(separator: "|") + "#" + base.path
    }

    /// The description a run was compiled from — its own copy, so an edit saved after it started
    /// does not redraw a run that is following the old one.
    func runPipelineDocument(snapshot: String?, pipeline: String?) async -> PipelineDocument? {
        if let snapshot, !snapshot.isEmpty {
            let url = URL(fileURLWithPath: snapshot).appendingPathComponent("pipeline/pipeline.json")
            if let data = try? Data(contentsOf: url), let doc = try? JSONDecoder().decode(PipelineDocument.self, from: data) {
                return doc
            }
        }
        guard let pipeline, !pipeline.isEmpty else { return nil }
        return await pipelineDetail(id: pipeline)?.document
    }

    nonisolated static func tail(of url: URL, bytes: Int) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        let start = size > UInt64(bytes) ? size - UInt64(bytes) : 0
        try? handle.seek(toOffset: start)
        guard let data = try? handle.readToEnd() else { return nil }
        var text = String(decoding: data, as: UTF8.self)
        // A cut in the middle of a line leaves a fragment that is not an event.
        if start > 0, let nl = text.firstIndex(of: "\n") { text = String(text[text.index(after: nl)...]) }
        return text
    }
}

nonisolated enum PipelineToolError: Error, Sendable, Equatable {
    case stale
    case message(String)

    var text: String {
        switch self {
        case .stale: String(localized: "Someone changed this pipeline in the meantime.")
        case .message(let m): m
        }
    }
}

// MARK: - Sharing (`pipeline-share.sh`, `pipeline-tool.py export|arm`)

/// What a download turned out to be, before anything is added: the description, what the audit
/// said about it, and where exactly it came from.
nonisolated struct PipelineImportPreview: Sendable, Equatable {
    var quarantine: String
    var verdict: String
    var document: PipelineDocument
    var validation: PipelineValidation
    var skills: [String]
    var files: [String]
    var ignored: [String]
    var findings: [String]
    var reviewVerdict: String
    var reviewNotes: String
    var repo: String?
    var path: String?
    var ref: String?
    var sha: String?

    var rejected: Bool { verdict == "REJECT" }
}

nonisolated enum PipelineImportFailure: Error, Sendable, Equatable {
    case badAddress
    case download(String)
    case notFound
    case several([String])
    case rejected
    case other(String)
}

extension SupervisorClient {

    private var shareScript: String? {
        guard let home = OrchestratorHome.detect()?.path else { return nil }
        let path = "\(home)/bin/pipeline-share.sh"
        return FileManager.default.fileExists(atPath: path) ? path : nil
    }

    private func runShare(_ argv: [String], timeout: TimeInterval) async -> (code: Int32, root: [String: Any]?, text: String) {
        guard let script = shareScript else { return (-1, nil, "engine not found") }
        let args = [script] + argv
        let placeholders = (2...args.count).map { "\"$\($0)\"" }.joined(separator: " ")
        let r = await Shell.run("bash \"$1\" \(placeholders)", args: args, timeout: timeout)
        let line = r.stdout.split(separator: "\n").last { $0.first == "{" }
        let root = line.flatMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] }
        return (r.launched ? r.exitCode : -1, root, (root?["error"] as? String) ?? r.stderr.trimmedTail)
    }

    func fetchPipelineForImport(_ source: String, path: String?) async -> Result<PipelineImportPreview, PipelineImportFailure> {
        var argv = ["fetch", source]
        if let path, !path.isEmpty { argv += ["--path", path] }
        // A clone and, when Codex is here, its reading of every prompt.
        let r = await runShare(argv, timeout: 420)
        switch r.code {
        case 0: break
        case 2: return .failure(.badAddress)
        case 3: return .failure(.notFound)
        case 9: return .failure(.several((r.root?["candidates"] as? [String]) ?? []))
        case 1: return .failure(.download(r.text))
        default: return .failure(.other(r.text))
        }
        guard let root = r.root, let q = root["quarantine"] as? String,
              let doc = Self.decodeValue(PipelineDocument.self, root["pipeline"]) else {
            return .failure(.other(r.text))
        }
        let audit = root["audit"] as? [String: Any]
        let findings = ((audit?["findings"] as? [[String: Any]]) ?? []).compactMap { $0["detail"] as? String }
        let review = root["review"] as? [String: Any]
        let origin = root["origin"] as? [String: Any]
        return .success(PipelineImportPreview(
            quarantine: q,
            verdict: (root["verdict"] as? String) ?? "REJECT",
            document: doc,
            validation: Self.decodeValue(PipelineValidation.self, root["validation"]) ?? PipelineValidation(),
            skills: (root["skills"] as? [String]) ?? [],
            files: (root["files"] as? [String]) ?? [],
            ignored: (root["ignored"] as? [String]) ?? [],
            findings: findings,
            reviewVerdict: (review?["verdict"] as? String) ?? "SKIP",
            reviewNotes: (review?["notes"] as? String) ?? "",
            repo: origin?["repo"] as? String,
            path: origin?["path"] as? String,
            ref: origin?["ref"] as? String,
            sha: origin?["sha"] as? String))
    }

    func installImportedPipeline(_ preview: PipelineImportPreview, as id: String) async -> Result<String, PipelineImportFailure> {
        let r = await runShare(["install", preview.quarantine, id], timeout: 30)
        switch r.code {
        case 0: return .success(id)
        case 8: return .failure(.rejected)
        default: return .failure(.other(r.text))
        }
    }

    func discardImport(_ preview: PipelineImportPreview) async {
        _ = await runShare(["discard", preview.quarantine], timeout: 15)
    }

    /// He has read an imported pipeline and lets messages run on it.
    func armPipeline(id: String) async -> Bool {
        await runTool(["arm", id]).code == 0
    }

    func exportPipeline(id: String, to folder: URL) async -> Result<URL, PipelineToolError> {
        let r = await runTool(["export", id, "--out", folder.path])
        guard r.code == 0, let root = Self.object(r.json), let dir = root["dir"] as? String else {
            if r.code == 8 { return .failure(.message(String(localized: "It carries something that looks like an access key. Take it out of the prompt first: everyone binds their own keys."))) }
            return .failure(.message((Self.object(r.json)?["error"] as? String) ?? r.text))
        }
        return .success(URL(fileURLWithPath: dir))
    }

    func publishPipeline(folder: URL, repository: String, isPrivate: Bool) async -> Result<URL, PipelineToolError> {
        var argv = ["publish", folder.path, repository]
        if isPrivate { argv.append("--private") }
        let r = await runShare(argv, timeout: 120)
        guard r.code == 0, let s = r.root?["url"] as? String, let url = URL(string: s) else {
            return .failure(.message(r.text))
        }
        return .success(url)
    }

    nonisolated static func decodeValue<T: Decodable>(_ type: T.Type, _ value: Any?) -> T? {
        guard let value, JSONSerialization.isValidJSONObject(value),
              let data = try? JSONSerialization.data(withJSONObject: value) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }
}
