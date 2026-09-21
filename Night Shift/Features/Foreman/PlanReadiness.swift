import Foundation

nonisolated struct ResourceFacts: Sendable, Equatable, Identifiable {
    var name: String
    var path: String

    var willBeChanged: Bool
    var exists: Bool
    var readable: Bool

    var writable: Bool
    var isGitRepo: Bool

    var hasVerification: Bool
    var hasUncommittedChanges: Bool

    var isBusy: Bool = false

    var missingCapabilities: [String] = []

    var needsExternal: [String] = []

    var writeSet: [String] = []

    var id: String { path }
}

nonisolated struct ReadinessGap: Sendable, Equatable, Identifiable {
    enum Kind: String, Sendable {
        case folderMissing
        case folderUnreadable
        case readOnlyResource
        case noVerification
        case dirtyTree
        case notARepo
        case nowhereToWrite
        case resourceBusy
        case missingTool
        case needsExternal
    }

    var kind: Kind
    var resource: String

    var what: String

    var plan: String

    var blocking: Bool

    var id: String { "\(kind.rawValue)|\(resource)" }
}

nonisolated struct TaskHold: Codable, Equatable, Sendable, Identifiable {
    var kind: String
    var resource: String
    var path: String
    var what: String
    var plan: String

    var id: String { "\(kind)|\(path)" }
    var sentence: String { "\(what) — \(plan)" }
}

nonisolated enum PlanReadiness {

    static func holds(_ gaps: [ReadinessGap], resources: [ResourceFacts]) -> [TaskHold] {
        let pathByName = Dictionary(resources.map { ($0.name, $0.path) }, uniquingKeysWith: { a, _ in a })
        return gaps.filter(\.blocking).map {
            TaskHold(kind: $0.kind.rawValue, resource: $0.resource,
                     path: pathByName[$0.resource] ?? "", what: $0.what, plan: $0.plan)
        }
    }

    static func shorten(_ text: String, limit: Int = 90) -> String {
        let flat = text.replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard flat.count > limit else { return flat }
        let cut = String(flat.prefix(limit))
        if let space = cut.lastIndex(of: " "), cut.distance(from: cut.startIndex, to: space) > limit / 2 {
            return String(cut[cut.startIndex..<space]) + "…"
        }
        return cut + "…"
    }

    static func directorSettledTheTree(_ message: String) -> Bool {
        let text = message.lowercased()
        let stems = ["коміт", "комміт", "commit", "мердж", "merge", "гілк", "ветк", "branch",
                     "stash", "застеш", "main", "master"]
        return stems.contains { text.contains($0) }
    }

    static func gaps(_ resources: [ResourceFacts]) -> [ReadinessGap] {
        var out: [ReadinessGap] = []

        let anyWritable = resources.contains { $0.writable && $0.exists && $0.readable }

        for r in resources {
            if !r.exists {
                out.append(ReadinessGap(
                    kind: .folderMissing, resource: r.name,
                    what: String(format: String(localized: "the folder “%@” is not at its saved path"), r.name),
                    plan: String(localized: "I will not start — fix the project path and I will pick it up"),
                    blocking: true))
                continue
            }
            if !r.readable {
                out.append(ReadinessGap(
                    kind: .folderUnreadable, resource: r.name,
                    what: String(format: String(localized: "I cannot read the folder “%@” — that is a system permission only you can grant"), r.name),
                    plan: String(localized: "I will not start — give Bulava access to the folder and I will pick it up"),
                    blocking: true))
                continue
            }

            if r.willBeChanged && !r.writable {
                out.append(anyWritable
                    ? ReadinessGap(
                        kind: .readOnlyResource, resource: r.name,
                        what: String(format: String(localized: "“%@” is connected read-only, and the work changes it"), r.name),
                        plan: String(format: String(localized: "I will do the rest and describe the needed changes for “%@” in writing"), r.name),
                        blocking: false)
                    : ReadinessGap(
                        kind: .nowhereToWrite, resource: r.name,
                        what: String(format: String(localized: "all of the work lands in “%@”, and it is read-only — there is nowhere to write"), r.name),
                        plan: String(localized: "I will not start — grant write access or tell me which resource to work in"),
                        blocking: true))
            }
            if r.willBeChanged && !r.hasVerification {
                out.append(ReadinessGap(
                    kind: .noVerification, resource: r.name,
                    what: String(format: String(localized: "“%@” has nothing to verify the result with — no tests, no build"), r.name),
                    plan: String(localized: "I will verify by running it and show before/after, but there will be no proof from tests"),
                    blocking: false))
            }
            if r.willBeChanged && r.hasUncommittedChanges {
                out.append(ReadinessGap(
                    kind: .dirtyTree, resource: r.name,
                    what: String(format: String(localized: "“%@” has uncommitted changes in it"), r.name),
                    plan: String(localized: "I will start from the current state and leave your changes alone"),
                    blocking: false))
            }

            for missing in r.missingCapabilities {
                out.append(ReadinessGap(
                    kind: .missingTool, resource: r.name,
                    what: missing,
                    plan: String(localized: "I will not start until this exists — it is a one-time action on your side"),
                    blocking: true))
            }

            if !r.needsExternal.isEmpty {
                out.append(ReadinessGap(
                    kind: .needsExternal, resource: r.name,
                    what: String(format: String(localized: "“%@” needs things this machine does not have: %@"), r.name,
                          r.needsExternal.map { shorten($0) }.joined(separator: "; ")),
                    plan: String(localized: "I will do the rest and leave that part unproven — tell me if you grant access"),
                    blocking: false))
            }
            if r.isBusy {
                out.append(ReadinessGap(
                    kind: .resourceBusy, resource: r.name,
                    what: String(format: String(localized: "another job is already running in “%@”"), r.name),
                    plan: String(localized: "I will queue and start when it frees up"),
                    blocking: false))
            }
            if r.willBeChanged && !r.isGitRepo {
                out.append(ReadinessGap(
                    kind: .notARepo, resource: r.name,
                    what: String(format: String(localized: "“%@” is not under git, so there is no one-move undo"), r.name),
                    plan: String(localized: "I will start a history so the changes can be read and rolled back"),
                    blocking: false))
            }
        }

        return out.sorted { ($0.blocking ? 0 : 1) < ($1.blocking ? 0 : 1) }
    }

    static func confirmationNote(_ gaps: [ReadinessGap]) -> String {
        guard !gaps.isEmpty else { return "" }
        var lines: [String] = []
        let blocking = gaps.filter(\.blocking)
        let assumed = gaps.filter { !$0.blocking }

        if !blocking.isEmpty {
            lines.append(blocking.count == 1
                         ? String(localized: "One thing stops the work before it starts:")
                         : String(localized: "These stop the work before it starts:"))
            for g in blocking {
                lines.append("  • \(g.what)")
                lines.append("    \(g.plan)")
            }
        }
        if !assumed.isEmpty {
            if !blocking.isEmpty { lines.append("") }
            lines.append(assumed.count == 1
                         ? String(localized: "One thing to settle so the night does not stall:")
                         : String(localized: "A few things to settle so the night does not stall:"))
            for g in assumed { lines.append("  • \(g.what) → \(g.plan)") }
            lines.append("")
            lines.append(String(localized: "If that is right — press Yes. If not, tell me how, and I will redo the plan."))
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - Making the plan match what will actually happen

    nonisolated struct MovedStep: Sendable, Equatable {
        var title: String
        var from: String
        var to: String
    }

    nonisolated struct Host: Sendable, Equatable {
        var id: UUID?
        var path: String
        var name: String
    }

    static func rehostReadOnlySteps(_ drafts: [SubtaskDraft],
                                    readOnlyPaths: Set<String>,
                                    fallbackHost: Host? = nil) -> (drafts: [SubtaskDraft], moved: [MovedStep]) {
        guard !readOnlyPaths.isEmpty else { return (drafts, []) }

        let needsMoving = drafts.contains { d in
            guard let p = d.projectPath else { return false }
            return readOnlyPaths.contains(p) && !d.readsOnly
        }
        guard needsMoving else { return (drafts, []) }

        let inPlan = drafts.first { d in
            guard let p = d.projectPath else { return false }
            return !readOnlyPaths.contains(p)
        }
        let host: Host? = inPlan.flatMap { d in
            d.projectPath.map { Host(id: d.projectID, path: $0, name: d.projectName) }
        } ?? fallbackHost
        guard let host, !readOnlyPaths.contains(host.path) else { return (drafts, []) }
        let hostPath = host.path

        var out: [SubtaskDraft] = []
        var moved: [MovedStep] = []
        for var d in drafts {
            guard let path = d.projectPath, readOnlyPaths.contains(path), !d.readsOnly else {
                out.append(d); continue
            }
            let from = d.projectName
            moved.append(MovedStep(title: d.title, from: from, to: host.name))
            d.detail = """
            «\(from)» підключено ТІЛЬКО НА ЧИТАННЯ — не змінюй у ньому жодного файлу.
            Замість зміни здай ОПИС потрібних змін (які файли, що саме, чому) у \(host.name),
            щоб команда, яка володіє «\(from)», могла це застосувати.

            """ + d.detail
            d.title = "Описати зміни для «\(from)»: \(d.title)"
            d.projectID = host.id
            d.projectPath = hostPath
            d.projectName = host.name
            d.acceptance += ["опис змін для «\(from)» лежить у \(host.name), і в «\(from)» нічого не змінено"]
            out.append(d)
        }
        return (out, moved)
    }

    static func blockingReason(_ gaps: [ReadinessGap]) -> String {
        let blocking = gaps.filter(\.blocking)
        guard !blocking.isEmpty else { return "" }
        return blocking.map { "\($0.what) — \($0.plan)" }.joined(separator: " · ")
    }

    static func acceptedContract(_ gaps: [ReadinessGap]) -> String {
        let assumed = gaps.filter { !$0.blocking }
        guard !assumed.isEmpty else { return "" }
        var lines = [String(localized: "AGREED CONTRACT (the user confirmed this — act exactly so):")]
        for g in assumed {
            lines.append("• \(g.what) → \(g.plan)")
        }
        lines.append(String(localized: "Do not ask about this again and do not pretend you did not know."))
        return lines.joined(separator: "\n")
    }

    static func movedNote(_ moved: [MovedStep]) -> String {
        guard !moved.isEmpty else { return "" }
        var lines = [moved.count == 1
                     ? String(localized: "I moved one step so the plan can actually run:")
                     : String(localized: "I moved a few steps so the plan can actually run:")]
        for m in moved {
            lines.append("  • " + String(format: String(localized: "“%@” is read-only, so I will do “%@” as a written description of the needed changes in %@"),
                                          m.from, m.title, m.to))
        }
        return lines.joined(separator: "\n")
    }
}
