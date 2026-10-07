import Foundation
import CryptoKit

/// The choices a report asks the director to make, as its agent wrote them in `decisions.json`
/// beside the report.
///
/// The questions are the agent's; the controls are Bulava's own. Nothing in the report's page can
/// tick a box, open the confirmation or send an answer: the page is shown, and the decisions are
/// drawn natively next to it from this file — on the Mac (`DecisionPanel`) and on the phone.
nonisolated struct DecisionSet: Codable, Equatable, Sendable {

    struct Item: Codable, Equatable, Sendable, Identifiable {
        var id: String
        var title: String
        var detail: String?
        var options: [String]
        /// The agent's own advice: a hint on the controls, never a default answer.
        var recommended: String?
        /// Whether a comment field is offered.
        var comment: Bool
    }

    var title: String
    var items: [Item]
    /// The file's content, hashed: a changed file is a different set of questions, and an answer
    /// given to the old one is not taken for an answer to the new one.
    var revision: String

    static let fileName = "decisions.json"
    static let maxItems = 40

    /// The set beside a report, if it has one and it is sound.
    static func load(besides report: URL) -> DecisionSet? {
        guard let data = try? Data(contentsOf: report.deletingLastPathComponent().appendingPathComponent(fileName)) else {
            return nil
        }
        if case .success(let set) = parse(data) { return set }
        return nil
    }

    /// Read and checked: what is wrong is said in words the agent can act on.
    static func parse(_ data: Data) -> Result<DecisionSet, DecisionRefusal> {
        guard let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return .failure(DecisionRefusal(message: "decisions.json is not a JSON object"))
        }
        let title = (obj["title"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard let raw = obj["items"] as? [[String: Any]], !raw.isEmpty else {
            return .failure(DecisionRefusal(message: "decisions.json needs a non-empty \"items\" array"))
        }
        guard raw.count <= maxItems else {
            return .failure(DecisionRefusal(message: "decisions.json has more than \(maxItems) items"))
        }
        var items: [Item] = []
        var seen = Set<String>()
        for (index, entry) in raw.enumerated() {
            let where_ = "item \(index + 1)"
            guard let id = entry["id"] as? String, id.range(of: #"^[A-Za-z0-9_-]{1,40}$"#, options: .regularExpression) != nil else {
                return .failure(DecisionRefusal(message: "\(where_): \"id\" must be 1–40 letters, digits, - or _"))
            }
            guard seen.insert(id).inserted else {
                return .failure(DecisionRefusal(message: "\(where_): the id \"\(id)\" is used twice"))
            }
            let itemTitle = (entry["title"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !itemTitle.isEmpty, itemTitle.count <= 300 else {
                return .failure(DecisionRefusal(message: "\(where_): \"title\" must be 1–300 characters"))
            }
            let given = entry["options"] as? [String]
            let options = (given ?? defaultOptions).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            guard (2...6).contains(options.count), options.allSatisfy({ !$0.isEmpty && $0.count <= 60 }),
                  Set(options).count == options.count else {
                return .failure(DecisionRefusal(message: "\(where_): \"options\" must be 2–6 different labels of up to 60 characters"))
            }
            var recommended = (entry["recommended"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            // The default options are shown in his language; the agent may name one in English.
            if given == nil, let named = recommended,
               let index = englishDefaults.firstIndex(where: { $0.caseInsensitiveCompare(named) == .orderedSame }) {
                recommended = options[index]
            }
            if let recommended, !recommended.isEmpty, !options.contains(recommended) {
                return .failure(DecisionRefusal(message: "\(where_): \"recommended\" must be one of its options"))
            }
            let detail = (entry["detail"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            items.append(Item(id: id, title: itemTitle, detail: detail.flatMap { $0.isEmpty ? nil : String($0.prefix(2000)) },
                              options: options, recommended: recommended?.isEmpty == false ? recommended : nil,
                              comment: entry["comment"] as? Bool ?? true))
        }
        let revision = SHA256.hash(data: data).prefix(12).map { String(format: "%02x", $0) }.joined()
        return .success(DecisionSet(title: title.isEmpty ? String(localized: "Decisions") : String(title.prefix(200)),
                                    items: items, revision: revision))
    }

    static var defaultOptions: [String] {
        [String(localized: "Take it"), String(localized: "Later"), String(localized: "No")]
    }
    static let englishDefaults = ["Take it", "Later", "No"]
}

/// Why a set of decisions, or an answer to it, was not taken.
nonisolated struct DecisionRefusal: Error, Equatable, Sendable {
    enum Code: String, Sendable { case invalid, stale, conflict, gone }
    var code: Code = .invalid
    var message: String
}

/// What the director chose, item by item, and what he wrote.
nonisolated struct DecisionAnswers: Codable, Equatable, Sendable {
    var choices: [String: String] = [:]
    var comments: [String: String] = [:]
    var general: String = ""

    var isEmpty: Bool {
        choices.isEmpty && comments.values.allSatisfy { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            && general.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Only what the set asks about, only its own options, and text of a sane length.
    func checked(against set: DecisionSet) -> Result<DecisionAnswers, DecisionRefusal> {
        var out = DecisionAnswers()
        for (id, choice) in choices where !choice.isEmpty {
            guard let item = set.items.first(where: { $0.id == id }), item.options.contains(choice) else {
                return .failure(DecisionRefusal(message: String(localized: "An answer names a choice this report does not offer.")))
            }
            out.choices[id] = choice
        }
        for (id, comment) in comments {
            let text = comment.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            guard set.items.contains(where: { $0.id == id }), text.count <= 2000 else {
                return .failure(DecisionRefusal(message: String(localized: "A comment is too long, or belongs to nothing in this report.")))
            }
            out.comments[id] = text
        }
        let general = general.trimmingCharacters(in: .whitespacesAndNewlines)
        guard general.count <= 4000 else {
            return .failure(DecisionRefusal(message: String(localized: "A comment is too long, or belongs to nothing in this report.")))
        }
        out.general = general
        return .success(out)
    }

    /// What of an earlier answer still fits these questions: a choice of an item that is gone, or
    /// of an option it no longer offers, is left out rather than shown as chosen.
    func fitted(to set: DecisionSet) -> DecisionAnswers {
        var out = DecisionAnswers(general: general)
        for item in set.items {
            if let choice = choices[item.id], item.options.contains(choice) { out.choices[item.id] = choice }
            if let comment = comments[item.id], !comment.isEmpty { out.comments[item.id] = comment }
        }
        return out
    }
}

/// One answer that was sent: what it answered, what it built on, and when.
nonisolated struct DecisionSubmission: Codable, Equatable, Sendable, Identifiable {
    var id: UUID
    var revision: String
    /// The submission this one corrects, as the sender saw it. A different one in between means
    /// another device answered meanwhile.
    var basedOn: UUID?
    var answers: DecisionAnswers
    var sentAt: Date
    /// "mac", or the phone's device id.
    var device: String
}
