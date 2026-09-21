import Foundation

// MARK: - Access

nonisolated enum ResourceAccess: String, Codable, Sendable, CaseIterable {

    case workspace

    case source

    var isReadOnly: Bool { self == .source }
}

// MARK: - Resource

nonisolated enum ResourceKind: String, Codable, Sendable, CaseIterable {
    case repository
    case folder
    case website
    case integration

    var symbol: String {
        switch self {
        case .repository:  "chevron.left.forwardslash.chevron.right"
        case .folder:      "folder"
        case .website:     "globe"
        case .integration: "arrow.up.forward.app"
        }
    }

    var labelKey: String {
        switch self {
        case .repository:  "Code"
        case .folder:      "Folder"
        case .website:     "Website"
        case .integration: "Integration"
        }
    }
}

nonisolated struct ProductResource: Identifiable, Codable, Equatable, Sendable {
    var id: UUID
    var name: String
    var kind: ResourceKind
    var access: ResourceAccess

    var projectID: UUID?

    var urlString: String?

    var note: String

    init(id: UUID = UUID(),
         name: String,
         kind: ResourceKind = .repository,
         access: ResourceAccess = .workspace,
         projectID: UUID? = nil,
         urlString: String? = nil,
         note: String = "") {
        self.id = id
        self.name = name
        self.kind = kind
        self.access = access
        self.projectID = projectID
        self.urlString = urlString
        self.note = note
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = (try? c.decode(UUID.self, forKey: .id)) ?? UUID()
        name = (try? c.decode(String.self, forKey: .name)) ?? ""
        kind = (try? c.decode(ResourceKind.self, forKey: .kind)) ?? .repository
        access = (try? c.decode(ResourceAccess.self, forKey: .access)) ?? .workspace
        projectID = try? c.decodeIfPresent(UUID.self, forKey: .projectID)
        urlString = try? c.decodeIfPresent(String.self, forKey: .urlString)
        note = (try? c.decode(String.self, forKey: .note)) ?? ""
    }

    var isRunnable: Bool { projectID != nil }
}

// MARK: - Decision

/// A decision an older version of Bulava recorded about a product and fed back into prompts.
///
/// Nothing produces these any more and nothing reads them into a run. The type survives for one
/// reason: whatever is already stored on a director's disk is their writing, and a build that
/// silently dropped the field would erase it on the next save. See `Product.legacyDecisions`.
nonisolated struct ProductDecision: Identifiable, Codable, Equatable, Sendable {
    var id: UUID
    var at: Date
    var text: String

    var taskID: UUID?

    init(id: UUID = UUID(), at: Date = Date(), text: String, taskID: UUID? = nil) {
        self.id = id
        self.at = at
        self.text = text
        self.taskID = taskID
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = (try? c.decode(UUID.self, forKey: .id)) ?? UUID()
        at = (try? c.decode(Date.self, forKey: .at)) ?? Date()
        text = (try? c.decode(String.self, forKey: .text)) ?? ""
        taskID = try? c.decodeIfPresent(UUID.self, forKey: .taskID)
    }
}

// MARK: - Product

nonisolated struct Product: Identifiable, Codable, Equatable, Sendable {
    var id: UUID
    var name: String

    var summary: String
    var resources: [ProductResource]
    var pinned: Bool
    var addedAt: Date

    var lastOpenedAt: Date?

    var lastWorkedAt: Date?

    // MARK: Description

    /// What the director typed about this product, in the add or rename sheet. Explicit input,
    /// shown where it was entered, changed only by them — not something the app concluded.
    var brief: String

    /// Decisions recorded by a version of Bulava that kept its own memory of the director's
    /// choices. Read by nothing: it is decoded and re-encoded so that saving a product does not
    /// destroy what is on disk, and that is its whole remaining job.
    ///
    /// Deliberately not named `decisions`: the old name invited exactly the thing that was
    /// removed, which was quietly appending these to a prompt.
    var legacyDecisions: [ProductDecision]

    // MARK: Face

    var iconPath: String?

    var iconScanned: Bool

    init(id: UUID = UUID(),
         name: String,
         summary: String = "",
         resources: [ProductResource] = [],
         pinned: Bool = false,
         addedAt: Date = Date(),
         lastOpenedAt: Date? = nil,
         lastWorkedAt: Date? = nil,
         brief: String = "",
         legacyDecisions: [ProductDecision] = [],
         iconPath: String? = nil,
         iconScanned: Bool = false) {
        self.id = id
        self.name = name
        self.summary = summary
        self.resources = resources
        self.pinned = pinned
        self.addedAt = addedAt
        self.lastOpenedAt = lastOpenedAt
        self.lastWorkedAt = lastWorkedAt
        self.brief = brief
        self.legacyDecisions = legacyDecisions
        self.iconPath = iconPath
        self.iconScanned = iconScanned
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = (try? c.decode(String.self, forKey: .name)) ?? ""
        summary = (try? c.decode(String.self, forKey: .summary)) ?? ""
        resources = (try? c.decode([ProductResource].self, forKey: .resources)) ?? []
        pinned = (try? c.decode(Bool.self, forKey: .pinned)) ?? false
        addedAt = (try? c.decode(Date.self, forKey: .addedAt)) ?? Date()
        lastOpenedAt = try? c.decodeIfPresent(Date.self, forKey: .lastOpenedAt)

        lastWorkedAt = (try? c.decodeIfPresent(Date.self, forKey: .lastWorkedAt)) ?? lastOpenedAt
        brief = (try? c.decode(String.self, forKey: .brief)) ?? ""
        legacyDecisions = (try? c.decode([ProductDecision].self, forKey: .legacyDecisions)) ?? []
        iconPath = try? c.decodeIfPresent(String.self, forKey: .iconPath)
        iconScanned = (try? c.decode(Bool.self, forKey: .iconScanned)) ?? false
    }

    /// Spelled out rather than synthesized, because `legacyDecisions` has to keep reading and
    /// writing the key it was stored under. A synthesized set would rename it to `legacyDecisions`
    /// on disk and orphan every decision already saved.
    enum CodingKeys: String, CodingKey {
        case id, name, summary, resources, pinned, addedAt, lastOpenedAt, lastWorkedAt
        case brief
        case legacyDecisions = "decisions"
        case iconPath, iconScanned
    }

    // MARK: Derived

    var initials: String {
        let words = name.split(separator: " ").filter { !$0.isEmpty }
        if words.count >= 2 {
            return words.prefix(2).compactMap { $0.first }.map(String.init).joined().uppercased()
        }
        return String(name.prefix(1)).uppercased()
    }

    var writableProjectIDs: [UUID] {
        resources.filter { $0.access == .workspace }.compactMap(\.projectID)
    }

    var sourceProjectIDs: [UUID] {
        resources.filter { $0.access == .source }.compactMap(\.projectID)
    }

    var allProjectIDs: [UUID] { resources.compactMap(\.projectID) }

    var defaultProjectID: UUID? {
        resources.first { $0.access == .workspace && $0.kind == .repository }?.projectID
            ?? writableProjectIDs.first
    }

    func access(forProjectID id: UUID) -> ResourceAccess? {
        resources.first { $0.projectID == id }?.access
    }
}

// MARK: - Sheet intent

nonisolated enum ProductSheetMode: Identifiable, Equatable, Sendable {
    case newProduct
    case addResource(productID: UUID)

    var id: String {
        switch self {
        case .newProduct: "new"
        case .addResource(let id): "resource-\(id.uuidString)"
        }
    }

    var targetProductID: UUID? {
        switch self {
        case .newProduct: nil
        case .addResource(let id): id
        }
    }
}
