import Foundation

nonisolated enum ProjectPlacement {

    nonisolated struct Scope: Sendable {

        var writable: [Project]

        var readOnly: [Project]

        var defaultProjectID: UUID?

        init(writable: [Project] = [], readOnly: [Project] = [], defaultProjectID: UUID? = nil) {
            self.writable = writable
            self.readOnly = readOnly
            self.defaultProjectID = defaultProjectID
        }

        var all: [Project] {
            var seen = Set<UUID>()
            return (writable + readOnly).filter { seen.insert($0.id).inserted }
        }

        var isEmpty: Bool { all.isEmpty }
    }

    nonisolated enum Intent: Sendable {

        case change

        case read
    }

    static func resolve(ref: String?, scope: Scope?, global: [Project],
                        intent: Intent = .change) -> Project? {
        guard let scope else { return match(ref: ref, in: global) ?? soleCandidate(global) }

        let hosts = intent == .read ? scope.all : scope.writable

        if let ref, !ref.isEmpty, let hit = match(ref: ref, in: hosts) { return hit }

        if let ref, !ref.isEmpty, match(ref: ref, in: scope.all) != nil { return nil }

        if hosts.count == 1 { return hosts[0] }

        if let id = scope.defaultProjectID, let host = hosts.first(where: { $0.id == id }) {
            return host
        }

        return nil
    }

    static func host(preferring candidate: Project?, scope: Scope?) -> Project? {
        guard let scope else { return candidate }
        if let candidate, scope.all.contains(where: { $0.id == candidate.id }) { return candidate }
        if let id = scope.defaultProjectID, let host = scope.writable.first(where: { $0.id == id }) {
            return host
        }
        return scope.writable.count == 1 ? scope.writable[0] : nil
    }

    private static func match(ref: String, in candidates: [Project]) -> Project? {
        let needle = ref.lowercased()
        let hits = candidates.filter {
            let name = $0.name.lowercased()
            return name.contains(needle) || needle.contains(name)
        }
        return hits.count == 1 ? hits[0] : nil
    }

    private static func match(ref: String?, in candidates: [Project]) -> Project? {
        guard let ref, !ref.isEmpty else { return nil }
        return match(ref: ref, in: candidates)
    }

    private static func soleCandidate(_ all: [Project]) -> Project? {
        all.count == 1 ? all[0] : nil
    }
}
