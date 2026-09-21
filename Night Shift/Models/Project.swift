import SwiftUI

nonisolated enum ProjectKind: String, Codable, CaseIterable, Sendable {
    case iosNative
    case composeMultiplatform
    case webFrontend
    case webLanding
    case backendGo
    case backendPython
    case maps
    case unknown

    var label: String {
        switch self {
        case .iosNative: "iOS / macOS"
        case .composeMultiplatform: "Compose MP"
        case .webFrontend: "Web app"
        case .webLanding: "Landing"
        case .backendGo: "Go backend"
        case .backendPython: "Python backend"
        case .maps: "Maps / Geo"
        case .unknown: "Project"
        }
    }

    var icon: String {
        switch self {
        case .iosNative: "apple.logo"
        case .composeMultiplatform: "square.on.square.dashed"
        case .webFrontend: "globe"
        case .webLanding: "sparkles.rectangle.stack"
        case .backendGo: "server.rack"
        case .backendPython: "chevron.left.forwardslash.chevron.right"
        case .maps: "map"
        case .unknown: "folder"
        }
    }

    var tint: Color {
        switch self {
        case .iosNative: Color(hex: 0x8B65FF)
        case .composeMultiplatform: Color(hex: 0x57C88E)
        case .webFrontend: Color(hex: 0x5AA8F0)
        case .webLanding: Color(hex: 0xE0A23C)
        case .backendGo: Color(hex: 0x37B5C6)
        case .backendPython: Color(hex: 0xF0616B)
        case .maps: Color(hex: 0x9C7BFF)
        case .unknown: Color(hex: 0x6C6F7A)
        }
    }
}

nonisolated enum DeliveryMode: String, Codable, CaseIterable, Sendable {
    case personal, client, prototype, research

    var label: String {
        switch self {
        case .personal: "Personal"
        case .client: "Client"
        case .prototype: "Prototype"
        case .research: "Research"
        }
    }

    var mergesOnApprove: Bool { self != .client && self != .research }
    var tint: Color {
        switch self {
        case .personal: Color(hex: 0x4FC58C)
        case .client: Color(hex: 0xE3A63E)
        case .prototype: Color(hex: 0x8B65FF)
        case .research: Color(hex: 0x5AA8F0)
        }
    }
}

nonisolated struct Project: Identifiable, Codable, Equatable, Hashable {
    var id: UUID
    var name: String
    var path: String
    var kind: ProjectKind
    var delivery: DeliveryMode?
    var stacks: [String]
    var pinned: Bool
    var addedAt: Date
    var notes: String

    var gitRemote: String?
    var defaultBranch: String?
    var buildCommand: String?

    init(id: UUID = UUID(), name: String, path: String, kind: ProjectKind = .unknown,
         delivery: DeliveryMode? = nil,
         stacks: [String] = [], pinned: Bool = false, addedAt: Date = Date(), notes: String = "",
         gitRemote: String? = nil, defaultBranch: String? = nil, buildCommand: String? = nil) {
        self.id = id; self.name = name; self.path = path; self.kind = kind; self.delivery = delivery
        self.stacks = stacks; self.pinned = pinned; self.addedAt = addedAt; self.notes = notes
        self.gitRemote = gitRemote; self.defaultBranch = defaultBranch
        self.buildCommand = buildCommand ?? Self.defaultBuildCommand(for: kind)
    }

    var deliveryMode: DeliveryMode { delivery ?? .personal }

    var slug: String { Slug.forPath(path) }
    var displayPath: String {
        let home = NSHomeDirectory()
        return path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
    }

    static func defaultBuildCommand(for kind: ProjectKind) -> String? {
        switch kind {
        case .iosNative: "xcodebuild build"
        case .composeMultiplatform: "./gradlew build"
        case .webFrontend, .webLanding: "npm run build"
        case .backendGo: "go build ./..."
        case .backendPython: "python3 -m compileall ."
        case .maps: "npm run build"
        case .unknown: nil
        }
    }
}

nonisolated struct ProjectLiveStatus: Equatable, Sendable {
    var supervised: Bool = false
    var phase: WorkerPhase? = nil
    var branch: String? = nil
    var queuedCount: Int = 0
    var needsAttention: Bool = false
    var lastOutcome: QueueOutcome? = nil
    var healthy: Bool = true
}
