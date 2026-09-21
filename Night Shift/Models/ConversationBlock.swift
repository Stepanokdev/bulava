import Foundation

// MARK: - Artifact

nonisolated struct ArtifactRef: Codable, Equatable, Sendable, Identifiable {
    enum Kind: String, Codable, Sendable {
        case image, video, archive, document, code, log, other

        static func of(_ name: String) -> Kind {
            switch (name as NSString).pathExtension.lowercased() {
            case "png", "jpg", "jpeg", "gif", "heic", "webp": .image
            case "mp4", "mov", "m4v":                         .video
            case "zip", "tar", "gz", "tgz":                   .archive
            case "pdf", "md", "txt", "html", "rtf", "doc", "docx": .document
            case "swift", "kt", "ts", "js", "py", "go", "sh", "json", "yml", "yaml", "patch", "diff": .code
            case "log":                                       .log
            default:                                          .other
            }
        }

        init(from decoder: Decoder) throws {
            let raw = try decoder.singleValueContainer().decode(String.self)
            self = Kind(rawValue: raw) ?? .other
        }
    }

    var runID: String

    var relativePath: String
    var displayName: String
    var byteSize: Int?
    var kind: Kind

    var id: String { runID + "/" + relativePath }

    init(runID: String, relativePath: String, displayName: String? = nil,
         byteSize: Int? = nil, kind: Kind? = nil) {
        self.runID = runID
        self.relativePath = relativePath
        let name = displayName ?? (relativePath as NSString).lastPathComponent
        self.displayName = name
        self.byteSize = byteSize
        self.kind = kind ?? Kind.of(name)
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        runID = (try? c.decode(String.self, forKey: .runID)) ?? ""
        relativePath = (try? c.decode(String.self, forKey: .relativePath)) ?? ""
        displayName = (try? c.decode(String.self, forKey: .displayName))
            ?? (relativePath as NSString).lastPathComponent
        byteSize = try? c.decodeIfPresent(Int.self, forKey: .byteSize)
        kind = (try? c.decode(Kind.self, forKey: .kind)) ?? Kind.of(displayName)
    }

    func resolve(base: URL) -> URL? {
        guard !relativePath.isEmpty, !relativePath.hasPrefix("/") else { return nil }
        let parts = relativePath.split(separator: "/", omittingEmptySubsequences: false)
        guard !parts.contains("..") else { return nil }

        guard !runID.contains("/"), runID != "..", !runID.hasPrefix(".") else { return nil }

        let root = runID.isEmpty ? base : base.appendingPathComponent(runID)
        let candidate = root.appendingPathComponent(relativePath)
        guard FileManager.default.fileExists(atPath: candidate.path) else { return nil }

        let resolved = candidate.resolvingSymlinksInPath().standardizedFileURL
        let runFence = root.resolvingSymlinksInPath().standardizedFileURL
        let rootFence = base.resolvingSymlinksInPath().standardizedFileURL
        func contains(_ fence: URL, _ path: URL) -> Bool {
            var prefix = fence.path
            if !prefix.hasSuffix("/") { prefix += "/" }
            return path.path.hasPrefix(prefix)
        }
        guard contains(runFence, resolved), contains(rootFence, resolved) else { return nil }
        return resolved
    }
}

// MARK: - Activity

nonisolated struct BlockActivity: Codable, Equatable, Sendable {
    enum Status: String, Codable, Sendable {
        case running, done, failed

        init(from decoder: Decoder) throws {
            let raw = try decoder.singleValueContainer().decode(String.self)
            self = Status(rawValue: raw) ?? .done
        }
    }

    var toolCallID: String

    var verbKey: String

    var object: String?
    var status: Status

    var detail: String?

    init(toolCallID: String, verbKey: String, object: String? = nil,
         status: Status = .running, detail: String? = nil) {
        self.toolCallID = toolCallID
        self.verbKey = verbKey
        self.object = object
        self.status = status
        self.detail = detail
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        toolCallID = (try? c.decode(String.self, forKey: .toolCallID)) ?? ""
        verbKey = (try? c.decode(String.self, forKey: .verbKey)) ?? "working"
        object = try? c.decodeIfPresent(String.self, forKey: .object)
        status = (try? c.decode(Status.self, forKey: .status)) ?? .done
        detail = try? c.decodeIfPresent(String.self, forKey: .detail)
    }
}

// MARK: - Block

nonisolated struct ConversationBlock: Identifiable, Codable, Equatable, Sendable {
    enum Kind: String, Codable, Sendable {

        case markdown

        case activity

        /// What another agent said, in its own words. `text` is its answer; `activity.object`
        /// carries which agent, and `activity.detail` the question it was asked.
        case consult

        case file

        case gallery

        case error

        case unknown

        init(from decoder: Decoder) throws {
            let raw = try decoder.singleValueContainer().decode(String.self)
            self = Kind(rawValue: raw) ?? .unknown
        }
    }

    var id: String
    var kind: Kind

    var text: String
    var activity: BlockActivity?
    var artifacts: [ArtifactRef]

    init(id: String, kind: Kind, text: String = "",
         activity: BlockActivity? = nil, artifacts: [ArtifactRef] = []) {
        self.id = id
        self.kind = kind
        self.text = text
        self.activity = activity
        self.artifacts = artifacts
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = (try? c.decode(String.self, forKey: .id)) ?? UUID().uuidString
        kind = (try? c.decode(Kind.self, forKey: .kind)) ?? .unknown
        text = (try? c.decode(String.self, forKey: .text)) ?? ""
        activity = try? c.decodeIfPresent(BlockActivity.self, forKey: .activity)
        artifacts = (try? c.decode([ArtifactRef].self, forKey: .artifacts)) ?? []
    }

    // MARK: Convenience

    static func markdown(id: String, _ text: String) -> ConversationBlock {
        ConversationBlock(id: id, kind: .markdown, text: text)
    }

    static func activity(_ a: BlockActivity) -> ConversationBlock {
        ConversationBlock(id: a.toolCallID, kind: .activity, activity: a)
    }

    static func file(id: String, _ ref: ArtifactRef) -> ConversationBlock {
        ConversationBlock(id: id, kind: .file, artifacts: [ref])
    }

    static func gallery(id: String, _ refs: [ArtifactRef], caption: String = "") -> ConversationBlock {
        ConversationBlock(id: id, kind: .gallery, text: caption, artifacts: refs)
    }

    static func error(id: String, _ text: String) -> ConversationBlock {
        ConversationBlock(id: id, kind: .error, text: text)
    }

    static func consult(id: String, agent: String, ask: String, answer: String,
                        status: BlockActivity.Status) -> ConversationBlock {
        ConversationBlock(id: id, kind: .consult, text: answer,
                          activity: BlockActivity(toolCallID: id, verbKey: "asks %@",
                                                  object: agent, status: status,
                                                  detail: ask.isEmpty ? nil : ask))
    }

    var isRenderable: Bool {
        switch kind {
        case .markdown, .error: !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .activity:         activity != nil
        // Renderable the moment the question is asked: the card shows "Asking Codex…" and fills
        // in when the answer lands, so a two-minute review is not two minutes of nothing.
        case .consult:          activity != nil
        case .file, .gallery:   !artifacts.isEmpty
        case .unknown:          true
        }
    }
}

// MARK: - Upsert

nonisolated extension Array where Element == ConversationBlock {

    mutating func upsert(_ block: ConversationBlock) {
        if let i = firstIndex(where: { $0.id == block.id }) {
            self[i] = block
        } else {
            append(block)
        }
    }

    var renderable: [ConversationBlock] { filter(\.isRenderable) }
}
