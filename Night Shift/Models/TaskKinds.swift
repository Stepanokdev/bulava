import SwiftUI

nonisolated enum TaskType: String, Codable, CaseIterable, Sendable {
    case feature, bug, design, research, content, refactor, chore, idea

    var label: String { rawValue.capitalized }
    var icon: String {
        switch self {
        case .feature: "wand.and.stars"
        case .bug: "ladybug"
        case .design: "paintbrush.pointed"
        case .research: "magnifyingglass"
        case .content: "text.alignleft"
        case .refactor: "arrow.triangle.2.circlepath"
        case .chore: "wrench.and.screwdriver"
        case .idea: "lightbulb"
        }
    }
    var tint: Color {
        switch self {
        case .feature: Palette.accent
        case .bug: Palette.red
        case .design: Palette.orange
        case .research: Palette.blue
        case .content: Palette.green
        case .refactor: Palette.accentEmphasis
        case .chore: Palette.textTertiary
        case .idea: Palette.orange
        }
    }
}

nonisolated enum Priority: Int, Codable, CaseIterable, Sendable, Comparable {
    case p0 = 0, p1, p2, p3
    static func < (a: Priority, b: Priority) -> Bool { a.rawValue < b.rawValue }
    var label: String { "P\(rawValue)" }
    var tint: Color {
        switch self {
        case .p0: Palette.red
        case .p1: Palette.orange
        case .p2: Palette.blue
        case .p3: Palette.textTertiary
        }
    }
}

nonisolated enum TaskState: String, Codable, CaseIterable, Sendable {
    case needsClarification
    case ready
    case researching
    case planning
    case executing
    case verifying
    case finalizing
    case blocked
    case review
    case approved
    case merged
    case failed

    case closed

    var label: String {
        switch self {
        case .needsClarification: "Needs clarification"
        case .ready: "Ready"
        case .researching: "Researching"
        case .planning: "Planning"
        case .executing: "Executing"
        case .verifying: "Verifying"
        case .finalizing: "Finalizing"
        case .blocked: "Blocked"
        case .review: "Waiting for review"
        case .approved: "Approved"
        case .merged: "Merged"
        case .failed: "Failed"
        case .closed: "Closed"
        }
    }

    var short: String {
        switch self {
        case .needsClarification: "Clarify"
        case .ready: "Ready"
        case .researching: "Research"
        case .planning: "Planning"
        case .executing: "Executing"
        case .verifying: "Verifying"
        case .finalizing: "Finalizing"
        case .blocked: "Blocked"
        case .review: "Review"
        case .approved: "Approved"
        case .merged: "Merged"
        case .failed: "Failed"
        case .closed: "Closed"
        }
    }

    var tint: Color {
        switch self {
        case .needsClarification: Palette.orange
        case .ready: Palette.textTertiary
        case .researching, .planning: Palette.blue
        case .executing: Palette.accent
        case .verifying: Palette.green
        case .finalizing: Palette.accentEmphasis
        case .blocked, .failed: Palette.red
        case .review: Palette.accentEmphasis
        case .approved: Palette.green
        case .merged: Palette.green
        case .closed: Palette.textTertiary
        }
    }

    var column: BoardColumn {
        switch self {
        case .needsClarification: .clarify
        case .ready: .ready
        case .researching, .planning, .executing, .verifying, .finalizing: .inProgress
        case .blocked: .blocked
        case .review: .review
        case .approved, .merged, .closed: .done
        case .failed: .blocked
        }
    }

    var isActive: Bool {
        switch self {
        case .researching, .planning, .executing, .verifying, .finalizing: true
        default: false
        }
    }
}

nonisolated enum TaskBucket: String, CaseIterable, Sendable {
    case backlog, inProgress, needsAttention, review, done

    init(_ s: TaskState) {
        switch s {
        case .ready: self = .backlog
        case .researching, .planning, .executing, .verifying, .finalizing: self = .inProgress
        case .blocked, .needsClarification, .failed: self = .needsAttention
        case .review: self = .review
        case .approved, .merged, .closed: self = .done
        }
    }
    var label: String {
        switch self {
        case .backlog: "Backlog"; case .inProgress: "In progress"; case .needsAttention: "Needs you"
        case .review: "Review"; case .done: "Done"
        }
    }
    var icon: String {
        switch self {
        case .backlog: "tray"; case .inProgress: "bolt.fill"; case .needsAttention: "exclamationmark.circle"
        case .review: "checkmark.circle"; case .done: "checkmark"
        }
    }
    var tint: Color {
        switch self {
        case .backlog: Palette.textTertiary; case .inProgress: Palette.blue; case .needsAttention: Palette.orange
        case .review: Palette.accentEmphasis; case .done: Palette.green
        }
    }
}

nonisolated enum BoardColumn: String, CaseIterable, Identifiable {
    case clarify, ready, inProgress, blocked, review, done
    var id: String { rawValue }
    var title: String {
        switch self {
        case .clarify: "Needs clarification"
        case .ready: "Ready"
        case .inProgress: "In progress"
        case .blocked: "Blocked"
        case .review: "Review"
        case .done: "Done"
        }
    }
    var tint: Color {
        switch self {
        case .clarify: Palette.orange
        case .ready: Palette.textTertiary
        case .inProgress: Palette.accent
        case .blocked: Palette.red
        case .review: Palette.accentEmphasis
        case .done: Palette.green
        }
    }
}
