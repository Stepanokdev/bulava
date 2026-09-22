import SwiftUI
import Observation

/// Where explanations are kept.
///
/// A file of its own, and not an entry in the conversation. An explanation is something read
/// beside a result, not something the worker said — putting it in the feed as a `.foreman` entry
/// would credit Bulava with words it never wrote, and an older build, which decodes an unknown
/// `ConversationEntry.Kind` as `.foreman`, would do exactly that.
///
/// Keyed by the record and the depth, so a turn and the night task beside it are independent, two
/// turns can be explained at once, and the short explanation and the walk-through both survive.
@MainActor
@Observable
final class ExplanationStore {

    private(set) var byKey: [String: Explanation] = [:]

    private let file: JSONFile<[String: Explanation]>

    /// Enough for months of use. Past this the oldest go: these are cached answers, not records,
    /// and an unbounded file that nothing ever prunes is a slow leak in a long-lived app.
    nonisolated static let capacity = 300

    init(fileURL: URL = AppSupport.file("explanations.json")) {
        file = JSONFile<[String: Explanation]>(url: fileURL)
        byKey = Self.pruned(file.load() ?? [:])
    }

    nonisolated static func key(_ anchor: ExplainAnchor, _ depth: ExplainDepth) -> String {
        anchor.key + "#" + depth.rawValue
    }

    func explanation(_ anchor: ExplainAnchor, _ depth: ExplainDepth) -> Explanation? {
        byKey[Self.key(anchor, depth)]
    }

    func put(_ explanation: Explanation, for anchor: ExplainAnchor, depth: ExplainDepth) {
        byKey[Self.key(anchor, depth)] = explanation
        byKey = Self.pruned(byKey)
        file.save(byKey)
    }

    /// The newest `capacity` explanations, by the time they were written.
    nonisolated static func pruned(_ all: [String: Explanation],
                                   capacity: Int = capacity) -> [String: Explanation] {
        guard all.count > capacity else { return all }
        // Sorted by key as well as date so a tie is broken the same way every time — otherwise
        // which of two same-second explanations survives depends on dictionary order.
        let keep = all.sorted { a, b in
            a.value.at == b.value.at ? a.key < b.key : a.value.at > b.value.at
        }.prefix(capacity)
        return Dictionary(uniqueKeysWithValues: keep.map { ($0.key, $0.value) })
    }
}
