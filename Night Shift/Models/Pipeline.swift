import Foundation

// MARK: - Text the engine writes in both languages

/// A sentence the ENGINE wrote — a module's name, a validation message — in Ukrainian and English.
///
/// These do not go through the string catalogue: they come from `pipeline-tool.py`, the one place
/// that knows what a pipeline is, and the app only chooses which of the two to show.
nonisolated struct PipelineText: Codable, Sendable, Equatable, Hashable {
    var uk: String
    var en: String

    init(uk: String, en: String) { self.uk = uk; self.en = en }

    init(from decoder: Decoder) throws {
        if let single = try? decoder.singleValueContainer(), let s = try? single.decode(String.self) {
            uk = s; en = s; return
        }
        let c = try decoder.container(keyedBy: CodingKeys.self)
        uk = (try? c.decode(String.self, forKey: .uk)) ?? ""
        en = (try? c.decode(String.self, forKey: .en)) ?? uk
        if uk.isEmpty { uk = en }
    }

    /// The one shown now: Ukrainian when the app speaks it, English otherwise.
    var local: String { PipelineText.prefersUkrainian ? uk : en }

    static var prefersUkrainian: Bool { LanguageBundle.currentCode.hasPrefix("uk") }
}

// MARK: - A JSON value, for parameters whose shape belongs to the module

nonisolated enum JSONValue: Codable, Sendable, Equatable, Hashable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case array([JSONValue])
    case object([String: JSONValue])
    case null

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let b = try? c.decode(Bool.self) { self = .bool(b) }
        else if let n = try? c.decode(Double.self) { self = .number(n) }
        else if let s = try? c.decode(String.self) { self = .string(s) }
        else if let a = try? c.decode([JSONValue].self) { self = .array(a) }
        else if let o = try? c.decode([String: JSONValue].self) { self = .object(o) }
        else { throw DecodingError.dataCorruptedError(in: c, debugDescription: "not JSON") }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .string(let s): try c.encode(s)
        case .number(let n):
            if n.rounded() == n, abs(n) < 1e15 { try c.encode(Int(n)) } else { try c.encode(n) }
        case .bool(let b): try c.encode(b)
        case .array(let a): try c.encode(a)
        case .object(let o): try c.encode(o)
        case .null: try c.encodeNil()
        }
    }

    var string: String? {
        switch self {
        case .string(let s): s
        case .number(let n): n.rounded() == n ? String(Int(n)) : String(n)
        case .bool(let b): b ? "true" : "false"
        default: nil
        }
    }
    var bool: Bool? {
        switch self {
        case .bool(let b): b
        case .string(let s): s == "true" ? true : (s == "false" ? false : nil)
        default: nil
        }
    }
    var int: Int? {
        switch self {
        case .number(let n): Int(n)
        case .string(let s): Int(s)
        default: nil
        }
    }
}

// MARK: - The description (bulava.pipeline/1)

nonisolated struct PipelineLoop: Codable, Sendable, Equatable, Hashable {
    var max: Int
}

nonisolated struct PipelineEdge: Codable, Sendable, Equatable, Hashable, Identifiable {
    var from: String
    var to: String
    var loop: PipelineLoop?

    var id: String { from + ">" + to }
    var fromNode: String { PipelineEdge.split(from).node }
    var fromPort: String { PipelineEdge.split(from).port }
    var toNode: String { PipelineEdge.split(to).node }
    var toPort: String { PipelineEdge.split(to).port }

    static func split(_ end: String) -> (node: String, port: String) {
        guard let dot = end.lastIndex(of: ".") else { return (end, "") }
        return (String(end[..<dot]), String(end[end.index(after: dot)...]))
    }
}

nonisolated struct PipelineNode: Codable, Sendable, Equatable, Hashable, Identifiable {
    var id: String
    var module: String
    var title: String?
    var params: [String: JSONValue]?
    var prompt: String?
    var x: Double?
    var y: Double?
    /// Keys this build does not know, written back exactly as they came.
    var extra: [String: JSONValue] = [:]

    init(id: String, module: String, title: String? = nil, params: [String: JSONValue]? = nil,
         prompt: String? = nil, x: Double? = nil, y: Double? = nil) {
        self.id = id; self.module = module; self.title = title; self.params = params
        self.prompt = prompt; self.x = x; self.y = y
    }

    private enum Known: String, CaseIterable { case id, module, title, params, prompt, x, y }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: AnyKey.self)
        id = try c.decode(String.self, forKey: AnyKey("id"))
        module = try c.decode(String.self, forKey: AnyKey("module"))
        title = try c.decodeIfPresent(String.self, forKey: AnyKey("title"))
        params = try? c.decodeIfPresent([String: JSONValue].self, forKey: AnyKey("params"))
        prompt = try c.decodeIfPresent(String.self, forKey: AnyKey("prompt"))
        x = try? c.decodeIfPresent(Double.self, forKey: AnyKey("x"))
        y = try? c.decodeIfPresent(Double.self, forKey: AnyKey("y"))
        extra = AnyKey.unknown(in: c, known: Set(Known.allCases.map(\.rawValue)))
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: AnyKey.self)
        for (k, v) in extra { try c.encode(v, forKey: AnyKey(k)) }
        try c.encode(id, forKey: AnyKey("id"))
        try c.encode(module, forKey: AnyKey("module"))
        try c.encodeIfPresent(title, forKey: AnyKey("title"))
        if let params, !params.isEmpty { try c.encode(params, forKey: AnyKey("params")) }
        if let prompt, !prompt.isEmpty { try c.encode(prompt, forKey: AnyKey("prompt")) }
        try c.encodeIfPresent(x, forKey: AnyKey("x"))
        try c.encodeIfPresent(y, forKey: AnyKey("y"))
    }

    /// The module's key without namespace and version: `bulava/gate.review@1` → `gate.review`.
    var key: String {
        let afterSlash = module.split(separator: "/", maxSplits: 1).last.map(String.init) ?? module
        return afterSlash.split(separator: "@").first.map(String.init) ?? afterSlash
    }

    func param(_ k: String) -> JSONValue? { params?[k] }
}

/// A coding key for any string, so a type can keep the keys it does not model.
nonisolated struct AnyKey: CodingKey, Hashable {
    var stringValue: String
    var intValue: Int? { nil }
    init(_ s: String) { stringValue = s }
    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { return nil }

    static func unknown(in c: KeyedDecodingContainer<AnyKey>, known: Set<String>) -> [String: JSONValue] {
        var out: [String: JSONValue] = [:]
        for k in c.allKeys where !known.contains(k.stringValue) {
            if let v = try? c.decode(JSONValue.self, forKey: k) { out[k.stringValue] = v }
        }
        return out
    }
}

nonisolated struct PipelineOrigin: Codable, Sendable, Equatable, Hashable {
    var kind: String
    var of: String?
    var ofRevision: Int?
    var repo: String?
    var path: String?
    var ref: String?
    var sha: String?
}

/// One pipeline as `pipeline-tool.py show` returns it: prompts inline, positions merged in.
///
/// Keys this build does not model are carried through untouched (`extra`), so a save from the app
/// never drops what a newer engine or another editor put into the file.
nonisolated struct PipelineDocument: Codable, Sendable, Equatable {
    var schema: String = "bulava.pipeline/1"
    var id: String
    var name: String
    var description: String = ""
    var version: String?
    var revision: Int = 1
    var builtin: Bool?
    var executes: String?
    var hidden: Bool?
    var armed: Bool?
    var origin: PipelineOrigin?
    var nodes: [PipelineNode] = []
    var edges: [PipelineEdge] = []
    var i18n: [String: [String: String]]?
    var extra: [String: JSONValue] = [:]

    init(id: String, name: String, description: String = "", nodes: [PipelineNode] = [], edges: [PipelineEdge] = []) {
        self.id = id; self.name = name; self.description = description; self.nodes = nodes; self.edges = edges
    }

    private enum Known: String, CaseIterable {
        case schema, id, name, description, version, revision, builtin, executes, hidden, armed, origin, nodes, edges, i18n
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: AnyKey.self)
        func opt<T: Decodable>(_ t: T.Type, _ k: String) -> T? { try? c.decodeIfPresent(t, forKey: AnyKey(k)) }
        schema = opt(String.self, "schema") ?? "bulava.pipeline/1"
        id = try c.decode(String.self, forKey: AnyKey("id"))
        name = opt(String.self, "name") ?? id
        description = opt(String.self, "description") ?? ""
        version = opt(String.self, "version")
        revision = opt(Int.self, "revision") ?? 1
        builtin = opt(Bool.self, "builtin")
        executes = opt(String.self, "executes")
        hidden = opt(Bool.self, "hidden")
        armed = opt(Bool.self, "armed")
        origin = opt(PipelineOrigin.self, "origin")
        nodes = try c.decodeIfPresent([PipelineNode].self, forKey: AnyKey("nodes")) ?? []
        edges = try c.decodeIfPresent([PipelineEdge].self, forKey: AnyKey("edges")) ?? []
        i18n = opt([String: [String: String]].self, "i18n")
        extra = AnyKey.unknown(in: c, known: Set(Known.allCases.map(\.rawValue)))
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: AnyKey.self)
        for (k, v) in extra { try c.encode(v, forKey: AnyKey(k)) }
        try c.encode(schema, forKey: AnyKey("schema"))
        try c.encode(id, forKey: AnyKey("id"))
        try c.encode(name, forKey: AnyKey("name"))
        try c.encode(description, forKey: AnyKey("description"))
        try c.encodeIfPresent(version, forKey: AnyKey("version"))
        try c.encode(revision, forKey: AnyKey("revision"))
        try c.encodeIfPresent(builtin, forKey: AnyKey("builtin"))
        try c.encodeIfPresent(executes, forKey: AnyKey("executes"))
        try c.encodeIfPresent(hidden, forKey: AnyKey("hidden"))
        try c.encodeIfPresent(armed, forKey: AnyKey("armed"))
        try c.encodeIfPresent(origin, forKey: AnyKey("origin"))
        try c.encode(nodes, forKey: AnyKey("nodes"))
        try c.encode(edges, forKey: AnyKey("edges"))
        try c.encodeIfPresent(i18n, forKey: AnyKey("i18n"))
    }

    var isBuiltin: Bool { builtin == true }
    var isImported: Bool { origin?.kind == "github" || origin?.kind == "file" }

    var localizedDescription: String {
        if !PipelineText.prefersUkrainian, let en = i18n?["en"]?["description"], !en.isEmpty { return en }
        return description
    }

    func node(_ id: String) -> PipelineNode? { nodes.first { $0.id == id } }
}

// MARK: - The palette (`pipeline-tool.py registry`)

nonisolated struct PipelinePortSpec: Codable, Sendable, Equatable, Hashable {
    var id: String
    var type: String?
    var types: [String]?
    var req: Bool?
    var multi: Bool?
    var label: PipelineText?

    var accepted: [String] { types ?? (type.map { [$0] } ?? []) }
}

nonisolated struct PipelineParamSpec: Codable, Sendable, Equatable, Hashable {
    var k: String
    var label: PipelineText
    var type: String
    var `default`: JSONValue?
    var options: [String]?
    /// What each option is called on screen.
    var ol: [String: PipelineText]?

    func optionLabel(_ value: String) -> String { ol?[value]?.local ?? value }
}

nonisolated struct PipelineModuleSpec: Codable, Sendable, Equatable, Hashable {
    var t: PipelineText
    var cat: String
    var phase: String
    var v: String
    var exec: Bool
    var d: PipelineText
    var inPorts: [PipelinePortSpec]
    var outPorts: [PipelinePortSpec]
    var p: [PipelineParamSpec]?
    var g: String?
    var prompt: Bool?
    var code: Bool?
    var report: Bool?
    var effect: Bool?
    var unattended: Bool?

    enum CodingKeys: String, CodingKey {
        case t, cat, phase, v, exec, d, p, g, prompt, code, report, effect, unattended
        case inPorts = "in", outPorts = "out"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        t = try c.decode(PipelineText.self, forKey: .t)
        cat = try c.decode(String.self, forKey: .cat)
        phase = try c.decode(String.self, forKey: .phase)
        v = try c.decode(String.self, forKey: .v)
        exec = (try? c.decode(Bool.self, forKey: .exec)) ?? false
        d = (try? c.decode(PipelineText.self, forKey: .d)) ?? PipelineText(uk: "", en: "")
        inPorts = (try? c.decode([PipelinePortSpec].self, forKey: .inPorts)) ?? []
        outPorts = (try? c.decode([PipelinePortSpec].self, forKey: .outPorts)) ?? []
        p = try? c.decode([PipelineParamSpec].self, forKey: .p)
        g = try? c.decode(String.self, forKey: .g)
        prompt = try? c.decode(Bool.self, forKey: .prompt)
        code = try? c.decode(Bool.self, forKey: .code)
        report = try? c.decode(Bool.self, forKey: .report)
        effect = try? c.decode(Bool.self, forKey: .effect)
        unattended = try? c.decode(Bool.self, forKey: .unattended)
    }
}

nonisolated struct PipelineRegistry: Codable, Sendable, Equatable {
    var schema: String
    var modules: [String: PipelineModuleSpec]
    var types: [String: PipelineText]
    var reviewCeiling: Int
    var reviewDefault: Int

    enum CodingKeys: String, CodingKey {
        case schema, modules, types
        case reviewCeiling = "review_ceiling", reviewDefault = "review_default"
    }

    func spec(_ node: PipelineNode) -> PipelineModuleSpec? { modules[node.key] }

    /// The palette in the order a person reads it, never alphabetical: triggers first, results last.
    static let categoryOrder = ["trigger", "prep", "agent", "skill", "gate", "flow", "out", "later"]

    func ordered(category: String) -> [(key: String, spec: PipelineModuleSpec)] {
        modules.filter { $0.value.cat == category }
            .sorted { lhs, rhs in
                if lhs.value.exec != rhs.value.exec { return lhs.value.exec }
                return lhs.key < rhs.key
            }
            .map { ($0.key, $0.value) }
    }

    static func compatible(_ outType: String, _ inTypes: [String]) -> Bool {
        !outType.isEmpty && !inTypes.isEmpty && (inTypes.contains("any") || outType == "any" || inTypes.contains(outType))
    }

    func typeName(_ t: String) -> String { types[t]?.local ?? t }
}

// MARK: - What the validator said (`pipeline-tool.py validate|show`)

nonisolated struct PipelineIssue: Codable, Sendable, Equatable, Hashable, Identifiable {
    var level: String
    var code: String
    var msg: PipelineText
    var node: String?
    var edge: Int?

    var id: String { "\(code)|\(node ?? "")|\(edge.map(String.init) ?? "")|\(msg.en)" }
    var isError: Bool { level == "error" }
}

nonisolated struct PipelineGuarantee: Codable, Sendable, Equatable, Hashable, Identifiable {
    var k: String
    var t: PipelineText
    var tone: String
    var id: String { k + t.en }
}

nonisolated struct PipelineValidation: Codable, Sendable, Equatable {
    var ok: Bool?
    var issues: [PipelineIssue] = []
    var guarantees: [PipelineGuarantee] = []
    var needs: [String] = []
    var unverified: Bool?

    var errors: [PipelineIssue] { issues.filter(\.isError) }
    var warnings: [PipelineIssue] { issues.filter { !$0.isError } }
    var runnable: Bool { errors.isEmpty }
}

// MARK: - The library (`pipeline-tool.py list`)

nonisolated struct PipelineSummary: Codable, Sendable, Equatable, Identifiable, Hashable {
    var id: String
    var kind: String
    var name: String?
    var description: String?
    var revision: Int?
    var version: String?
    var origin: PipelineOrigin?
    var builtin: Bool?
    var armed: Bool?
    var nodes: Int?
    var steps: [String?]?
    var errors: Int?
    var warnings: Int?
    var guarantees: [PipelineGuarantee]?
    var needs: [String]?
    var executes: String?
    var updated: Double?
    var broken: String?
    var hidden: Bool?
    var i18n: [String: [String: String]]?

    var isBuiltin: Bool { kind == "builtin" }
    var isImported: Bool { origin?.kind == "github" || origin?.kind == "file" }
    var localizedDescription: String? {
        if !PipelineText.prefersUkrainian, let en = i18n?["en"]?["description"], !en.isEmpty { return en }
        return description
    }
    var displayName: String { (name?.isEmpty == false ? name : nil) ?? id }
    var runnable: Bool { broken == nil && (errors ?? 0) == 0 }
}

// MARK: - Graph helpers shared by the editor, the canvas and the run view

extension PipelineDocument {

    /// Nodes in the order they run, with how deep each sits — the same walk the engine compiles.
    nonisolated func topologicalOrder() -> (order: [String], level: [String: Int]) {
        var indegree: [String: Int] = [:]
        var forward: [String: [String]] = [:]
        for n in nodes { indegree[n.id] = 0; forward[n.id] = [] }
        for e in edges where e.loop == nil {
            guard indegree[e.toNode] != nil, forward[e.fromNode] != nil else { continue }
            forward[e.fromNode, default: []].append(e.toNode)
            indegree[e.toNode, default: 0] += 1
        }
        var level: [String: Int] = [:]
        var queue = nodes.map(\.id).filter { indegree[$0] == 0 }
        queue.forEach { level[$0] = 0 }
        var order: [String] = []
        var i = 0
        while i < queue.count {
            let u = queue[i]; i += 1
            order.append(u)
            for v in forward[u] ?? [] {
                level[v] = max(level[v] ?? 0, (level[u] ?? 0) + 1)
                indegree[v, default: 0] -= 1
                if indegree[v] == 0 { queue.append(v) }
            }
        }
        for n in nodes where !order.contains(n.id) { order.append(n.id) }
        return (order, level)
    }

    /// Rows for a vertical drawing: every node of one depth side by side.
    nonisolated func rows() -> [[String]] {
        let t = topologicalOrder()
        var byLevel: [Int: [String]] = [:]
        for id in t.order { byLevel[t.level[id] ?? 0, default: []].append(id) }
        return byLevel.keys.sorted().compactMap { byLevel[$0] }
    }

    nonisolated func downstream(of id: String) -> Set<String> {
        var forward: [String: [String]] = [:]
        for e in edges where e.loop == nil { forward[e.fromNode, default: []].append(e.toNode) }
        var seen = Set<String>(); var stack = forward[id] ?? []
        while let x = stack.popLast() { if seen.insert(x).inserted { stack += forward[x] ?? [] } }
        return seen
    }

    nonisolated func upstream(of id: String) -> Set<String> {
        var back: [String: [String]] = [:]
        for e in edges where e.loop == nil { back[e.toNode, default: []].append(e.fromNode) }
        var seen = Set<String>(); var stack = back[id] ?? []
        while let x = stack.popLast() { if seen.insert(x).inserted { stack += back[x] ?? [] } }
        return seen
    }
}
