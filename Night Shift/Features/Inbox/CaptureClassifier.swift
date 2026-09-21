import Foundation

nonisolated enum CaptureClassifier {
    static func suggestProject(for text: String, in projects: [Project]) -> UUID? {
        let lower = text.lowercased()

        return projects
            .filter { !$0.name.isEmpty && lower.contains($0.name.lowercased()) }
            .max { $0.name.count < $1.name.count }?
            .id
    }

    static func suggestType(for text: String) -> TaskType? {
        let lower = text.lowercased()
        let table: [(TaskType, [String])] = [
            (.bug, ["bug", "crash", "fix", "broken", "не работает", "падает", "баг", "виправ"]),
            (.design, ["design", "spacing", "layout", "ui", "дизайн", "отступ", "выравн", "макет"]),
            (.research, ["research", "investigate", "compare", "explore", "ресерч", "исследов", "розвід"]),
            (.content, ["seo", "article", "blog", "copy", "статьи", "контент", "текст"]),
            (.refactor, ["refactor", "cleanup", "rewrite", "рефактор"]),
            (.chore, ["update", "bump", "config", "chore", "обнови"]),
            (.idea, ["idea", "maybe", "what if", "идея", "может", "а что если"]),
            (.feature, ["add", "implement", "feature", "support", "добавь", "сделай", "зроби", "додай"]),
        ]
        for (type, keywords) in table where keywords.contains(where: { lower.contains($0) }) {
            return type
        }
        return nil
    }

    static func suggestPriority(for text: String) -> Priority {
        let lower = text.lowercased()
        if ["urgent", "asap", "critical", "срочно", "критично", "p0"].contains(where: { lower.contains($0) }) { return .p0 }
        if ["important", "soon", "важно", "p1"].contains(where: { lower.contains($0) }) { return .p1 }
        return .p2
    }

    static func title(from text: String) -> String {
        let firstLine = text.split(separator: "\n").first.map(String.init) ?? text
        let trimmed = firstLine.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.count > 90 ? String(trimmed.prefix(90)) + "…" : trimmed
    }
}
