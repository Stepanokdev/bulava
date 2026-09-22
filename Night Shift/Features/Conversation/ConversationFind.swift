import SwiftUI
import MarkdownUI

// MARK: - A place the phrase can be shown in

/// One occurrence of the phrase, somewhere the reader can be taken to and shown it.
///
/// Every result is an occurrence — his own message, the agent's prose, a code block. Only a card
/// assembled out of several pieces at once (a question, a folded consultation whose header carries
/// the question and whose body carries the answer) is `.whole`, because there is no single run of
/// text to mark inside it.
nonisolated struct FindPlace: Identifiable, Equatable, Sendable {

    enum Mark: Equatable, Sendable {
        /// One occurrence in a run of text the app can mark character by character. The number is
        /// which occurrence of the phrase in that text this is.
        case range(occurrence: Int)

        /// A card made of several pieces: the card itself is marked.
        case whole
    }

    var entryID: UUID

    /// The block inside the entry, when the entry draws blocks rather than its own text.
    var blockID: String?
    var mark: Mark

    /// How many times the phrase appears in this place. One, except for a `.whole` card.
    var mentions: Int

    /// This place is folded away by default, so arriving at it has to open it.
    var opensBlock: Bool

    /// The occurrence is inside rendered Markdown, where the leaf that holds it — a paragraph, a
    /// heading, a code block — puts down its own anchor.
    var inProse: Bool = false

    /// Stable across a rebuild, which is what keeps the reader on the same result while an answer
    /// is still streaming in below them.
    var id: String {
        let where_ = ConversationFind.anchor(entry: entryID, block: blockID)
        switch mark {
        case .range(let occurrence): return "\(where_)#\(occurrence)"
        case .whole:                 return where_
        }
    }

    /// The whole message or card. A jump goes here first, so that it lands somewhere real even
    /// when the finer anchor below turns out not to be in the hierarchy.
    var blockScrollID: String { ConversationFind.anchor(entry: entryID, block: blockID) }

    /// The paragraph the phrase is actually in, when it is in prose. Scrolled to after
    /// `blockScrollID`, which refines a jump into a three-page answer down to the right line.
    var scrollID: String {
        guard inProse, case .range(let occurrence) = mark else { return blockScrollID }
        return ConversationFind.proseAnchor(entry: entryID, block: blockID, occurrence: occurrence)
    }
}

// MARK: - The index

nonisolated enum ConversationFind {

    /// The id both the view and the scroll use, so a jump lands on the thing that was found.
    static func anchor(entry: UUID, block: String?) -> String {
        guard let block else { return "find.entry.\(entry.uuidString)" }
        return "find.block.\(entry.uuidString).\(block)"
    }

    /// The anchor a single occurrence inside rendered Markdown puts down, laid by the paragraph
    /// that holds it.
    static func proseAnchor(entry: UUID, block: String?, occurrence: Int) -> String {
        "\(anchor(entry: entry, block: block))@\(occurrence)"
    }

    /// Every occurrence of `query` in `text`, left to right and never overlapping.
    ///
    /// Case-insensitive but diacritic-SENSITIVE: `привет` finds `ПРИВЕТ`, and `е` does not find
    /// `ё`. In a product spoken in Russian and Ukrainian those are different letters, and folding
    /// them together would quietly answer a different question than the one asked.
    static func ranges(in text: String, query: String) -> [Range<String.Index>] {
        guard !query.isEmpty, !text.isEmpty else { return [] }
        var out: [Range<String.Index>] = []
        var from = text.startIndex
        while from < text.endIndex,
              let found = text.range(of: query, options: [.caseInsensitive],
                                     range: from..<text.endIndex) {
            out.append(found)
            from = found.upperBound > found.lowerBound
                ? found.upperBound
                : text.index(after: found.lowerBound)
        }
        return out
    }

    static func mentions(in text: String, query: String) -> Int {
        ranges(in: text, query: query).count
    }

    /// What a piece of Markdown actually PUTS ON SCREEN, with the syntax taken out.
    ///
    /// Searching the source instead was wrong in both directions: `**фраза**` was never found
    /// because of the asterisks between the letters, and `http` matched link destinations the
    /// reader cannot see and could never be shown. This runs the same parser that draws the
    /// prose, so the index and the page agree on what the words are.
    ///
    /// Memoised because it is asked for every block of the thread on every keystroke, and again
    /// on every chunk of a streaming answer.
    static func displayedText(ofMarkdown markdown: String) -> String {
        if let cached = ProsePlainText.shared.value(for: markdown) { return cached }
        let rendered = MarkdownContent(markdown).renderPlainText()
        ProsePlainText.shared.store(rendered, for: markdown)
        return rendered
    }

    /// Where the phrase appears in the thread, in the order it is read.
    ///
    /// This mirrors the drawing rule in `EntryViews` exactly: an entry with renderable blocks
    /// draws the blocks and NOT its own text. `ConversationStore.updateBlocks` writes the same
    /// prose into both, so searching both would count every answer twice and the counter would be
    /// wrong in a way nobody could explain.
    static func places(in entries: [ConversationEntry], query: String) -> [FindPlace] {
        guard !query.isEmpty else { return [] }
        var out: [FindPlace] = []

        for entry in entries {
            switch entry.kind {

            // A question card is assembled out of the decision it carries, not out of `blocks`.
            case .question:
                let count = mentions(in: questionText(entry), query: query)
                if count > 0 {
                    out.append(FindPlace(entryID: entry.id, blockID: nil, mark: .whole,
                                         mentions: count, opensBlock: false))
                }

            case .user, .foreman, .codex:
                let blocks = entry.blocks.renderable
                if !blocks.isEmpty {
                    for block in blocks {
                        out += places(for: block, in: entry.id, query: query)
                    }
                } else if entry.kind == .user {
                    // His own message is an ordinary `Text` the app builds, so every occurrence
                    // can be marked where it stands.
                    for occurrence in ranges(in: entry.text, query: query).indices {
                        out.append(FindPlace(entryID: entry.id, blockID: nil,
                                             mark: .range(occurrence: occurrence),
                                             mentions: 1, opensBlock: false))
                    }
                } else {
                    out += prosePlaces(entryID: entry.id, blockID: nil,
                                       markdown: entry.text, query: query)
                }

            // `visibleEntries(inChat:)` never hands these over — they are not on screen.
            case .task, .report, .decision, .event:
                continue
            }
        }
        return out
    }

    /// What a question card actually puts on screen.
    static func questionText(_ entry: ConversationEntry) -> String {
        var parts = [entry.decision?.headline ?? entry.text]
        if let situation = entry.decision?.situation, !situation.isEmpty { parts.append(situation) }
        parts += (entry.decision?.items ?? []).map(\.question)
        return parts.joined(separator: "\n")
    }

    /// What a consult card holds: the answer it folds away, and the question it was asked, which
    /// is on its header even while it is folded.
    static func consultText(answer: String, ask: String?) -> String {
        [displayedText(ofMarkdown: answer), ask ?? ""]
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
    }

    /// One result per occurrence in what the Markdown puts on screen. The paragraph that holds
    /// each one marks the phrase itself and lays down its own anchor; see `MarkdownProse`.
    private static func prosePlaces(entryID: UUID, blockID: String?,
                                    markdown: String, query: String) -> [FindPlace] {
        let shown = displayedText(ofMarkdown: markdown)
        return ranges(in: shown, query: query).indices.map { occurrence in
            FindPlace(entryID: entryID, blockID: blockID,
                      mark: .range(occurrence: occurrence),
                      mentions: 1, opensBlock: false, inProse: true)
        }
    }

    private static func places(for block: ConversationBlock, in entryID: UUID,
                               query: String) -> [FindPlace] {
        func whole(_ text: String, opens: Bool) -> [FindPlace] {
            let count = mentions(in: text, query: query)
            guard count > 0 else { return [] }
            return [FindPlace(entryID: entryID, blockID: block.id, mark: .whole,
                              mentions: count, opensBlock: opens)]
        }
        func exact(_ text: String, opens: Bool) -> [FindPlace] {
            ranges(in: text, query: query).indices.map { occurrence in
                FindPlace(entryID: entryID, blockID: block.id,
                          mark: .range(occurrence: occurrence), mentions: 1, opensBlock: opens)
            }
        }

        switch block.kind {
        case .markdown:
            return prosePlaces(entryID: entryID, blockID: block.id,
                               markdown: block.text, query: query)
        case .consult:
            return whole(consultText(answer: block.text, ask: block.activity?.detail),
                         opens: true)
        case .error:
            return exact(block.text, opens: false)
        case .unknown:
            return exact(block.text, opens: true)
        // Step lines, files and galleries are the engine's record of what it did, not what was
        // said. Searching them would fill the counter with results nobody was looking for.
        case .activity, .file, .gallery:
            return []
        }
    }
}

// MARK: - What the Markdown puts on screen, remembered

/// A small memo of Markdown source → the words it draws.
///
/// Running cmark over the whole thread on every keystroke, and again on every chunk of a
/// streaming answer, is the one thing in this feature that could be felt. Answers do not change
/// once they are finished, so the same source is asked for over and over and the answer is always
/// the same.
nonisolated private final class ProsePlainText: @unchecked Sendable {
    static let shared = ProsePlainText()

    /// Enough for a long thread; past that the oldest half goes, which is cheaper than tracking
    /// use order for something that costs a millisecond to recompute.
    private static let capacity = 600

    private let lock = NSLock()
    private var memo: [String: String] = [:]
    private var order: [String] = []

    func value(for source: String) -> String? {
        lock.lock(); defer { lock.unlock() }
        return memo[source]
    }

    func store(_ rendered: String, for source: String) {
        lock.lock(); defer { lock.unlock() }
        if memo.updateValue(rendered, forKey: source) == nil {
            order.append(source)
            if order.count > Self.capacity {
                for key in order.prefix(Self.capacity / 2) { memo[key] = nil }
                order.removeFirst(Self.capacity / 2)
            }
        }
    }
}

// MARK: - The session

/// What the reader is doing with Find right now: the phrase, what it found, and where they are
/// among the results.
nonisolated struct FindSession: Equatable, Sendable {

    var query = ""
    private(set) var places: [FindPlace] = []

    /// Held by identity rather than by index, so a chunk of streamed answer adding two results
    /// below does not silently move the reader onto a different one.
    private(set) var activeID: String?

    var isEmpty: Bool { places.isEmpty }

    /// How many times the phrase appears, which is more than `places.count` when a markdown block
    /// holds it more than once.
    var mentions: Int { places.reduce(0) { $0 + $1.mentions } }

    var activeIndex: Int? {
        guard let activeID else { return nil }
        return places.firstIndex { $0.id == activeID }
    }

    var active: FindPlace? { activeIndex.map { places[$0] } }

    /// Rebuild against the thread as it stands now, leaving the reader where they are whenever
    /// the result they are on is still there.
    mutating func refresh(_ found: [FindPlace]) {
        places = found
        if let activeID, found.contains(where: { $0.id == activeID }) { return }
        activeID = found.first?.id
    }

    /// Next or previous, wrapping at both ends the way every browser does — without the wrap,
    /// ⌘G at the last result looks broken.
    @discardableResult
    mutating func step(_ delta: Int) -> FindPlace? {
        guard !places.isEmpty else { return nil }
        let from = activeIndex ?? (delta >= 0 ? -1 : 0)
        let count = places.count
        let next = ((from + delta) % count + count) % count
        activeID = places[next].id
        return places[next]
    }

    mutating func clear() {
        query = ""
        places = []
        activeID = nil
    }
}

// MARK: - What each piece of the thread needs to know

/// Passed down the thread so every drawn piece can mark the phrase inside itself.
///
/// Through the environment rather than through initialisers: the prose is five view types deep,
/// and threading a parameter through all of them would touch far more of the conversation than
/// this feature is about.
nonisolated struct FindMark: Equatable, Sendable {
    var query = ""
    var activeEntryID: UUID?
    var activeBlockID: String?
    var activeOccurrence: Int?

    var searching: Bool { !query.isEmpty }

    /// Is this the piece the reader is standing on?
    func isActive(entry: UUID, block: String? = nil) -> Bool {
        searching && activeEntryID == entry && activeBlockID == block
    }

    /// How a whole-marked piece should be drawn: untouched, holding the phrase, or the one the
    /// reader was taken to.
    func state(entry: UUID, block: String? = nil, text: String) -> FindHighlight.State {
        guard searching, ConversationFind.mentions(in: text, query: query) > 0 else { return .none }
        return isActive(entry: entry, block: block) ? .active : .matched
    }

    /// The text, with the phrase marked in it where there is one to mark. Plain otherwise, and
    /// without paying for an attributed copy when nobody is searching.
    func text(_ string: String, entry: UUID, block: String? = nil) -> Text {
        if let marked = marked(string, entry: entry, block: block) { return Text(marked) }
        return Text(string)
    }

    /// The text with the phrase marked in it, or nil when there is nothing in it to mark and the
    /// caller should keep drawing plain text.
    func marked(_ text: String, entry: UUID, block: String? = nil) -> AttributedString? {
        guard searching else { return nil }
        let found = ConversationFind.ranges(in: text, query: query)
        guard !found.isEmpty else { return nil }

        let activeHere = isActive(entry: entry, block: block) ? activeOccurrence : nil
        var out = AttributedString()
        var cursor = text.startIndex
        for (index, range) in found.enumerated() {
            out += AttributedString(text[cursor..<range.lowerBound])
            var piece = AttributedString(text[range])
            if index == activeHere {
                piece.backgroundColor = Palette.accent
                piece.foregroundColor = Palette.onAccent
            } else {
                piece.backgroundColor = Palette.accentSoft
            }
            out += piece
            cursor = range.upperBound
        }
        out += AttributedString(text[cursor...])
        return out
    }

    /// What a piece of rendered Markdown needs in order to mark the phrase inside itself, or nil
    /// when nothing is being searched for.
    ///
    /// The whole prose's displayed words come along, because a paragraph on its own cannot tell
    /// WHICH occurrence in the answer it is holding, and that is what decides whether it draws
    /// the one the reader is standing on.
    func prose(entry: UUID, block: String? = nil, markdown: String) -> ProseFind? {
        guard searching else { return nil }
        let shown = ConversationFind.displayedText(ofMarkdown: markdown)
        guard ConversationFind.mentions(in: shown, query: query) > 0 else { return nil }
        return ProseFind(query: query,
                         displayed: shown,
                         entryID: entry,
                         blockID: block,
                         activeOccurrence: isActive(entry: entry, block: block)
                            ? activeOccurrence : nil)
    }
}

/// Where Find stands inside one piece of rendered Markdown.
nonisolated struct ProseFind: Equatable, Sendable {
    var query: String

    /// Every word this prose puts on screen, syntax already taken out — the same string the
    /// index counted, so the numbering agrees.
    var displayed: String
    var entryID: UUID
    var blockID: String?

    /// Which occurrence in `displayed` the reader was taken to, or nil when the one they are on
    /// is somewhere else in the thread.
    var activeOccurrence: Int?

    /// How many occurrences come before this leaf, so a paragraph knows which of the answer's
    /// results it is holding.
    ///
    /// Returns nil when the leaf cannot be placed: two paragraphs word for word the same, with
    /// a different number of results before each, cannot tell which of them this one is. It then
    /// marks its own matches without claiming any of them is the active one — a quieter answer
    /// than pointing at the wrong line.
    func occurrencesBefore(leaf: String) -> Int? {
        guard !leaf.isEmpty else { return nil }
        var counts: Set<Int> = []
        var from = displayed.startIndex
        while from < displayed.endIndex,
              let at = displayed.range(of: leaf, range: from..<displayed.endIndex) {
            counts.insert(ConversationFind.mentions(in: String(displayed[..<at.lowerBound]),
                                                    query: query))
            if counts.count > 1 { return nil }
            from = at.upperBound > at.lowerBound ? at.upperBound
                                                 : displayed.index(after: at.lowerBound)
        }
        return counts.first
    }
}

private struct FindMarkKey: EnvironmentKey {
    static let defaultValue = FindMark()
}

extension EnvironmentValues {
    var findMark: FindMark {
        get { self[FindMarkKey.self] }
        set { self[FindMarkKey.self] = newValue }
    }
}

// MARK: - A card Find may open

/// A card folded by default, which Find may open and the reader may fold again.
///
/// Find opening a card is a loan, not a decision: the reader's own `expanded` is never written
/// to, so closing the search leaves every card exactly as they had it. But while Find is holding
/// one open the reader must still be able to shut it, and the card cannot reach into the search
/// to do that — so it records that it overruled the loan, and forgets that the next time Find
/// comes back to this card. Without the second half, a card Find had opened answered every press
/// of its own Hide button by staying open.
nonisolated struct FoldedByDefault: Equatable, Sendable {
    private var expanded = false
    private var overruledFind = false

    init() {}

    func showing(findOpened: Bool) -> Bool { expanded || (findOpened && !overruledFind) }

    mutating func toggle(findOpened: Bool) {
        let wasShowing = showing(findOpened: findOpened)
        expanded = !wasShowing
        overruledFind = wasShowing && findOpened
    }

    /// Find has arrived here; whatever the reader did on an earlier visit is spent.
    mutating func findArrived() { overruledFind = false }
}

// MARK: - Marking a whole piece

/// The outline around a CARD that holds the phrase and has no single run of text to mark inside
/// it — a question, a folded consultation whose header carries one half and whose body the other.
///
/// An outline, not a fill. A filled card reads as "this card is the answer", and when the card is
/// a page long that is exactly the complaint this feature earned the first time: the phrase was
/// found and then had to be looked for by eye all over again. Ordinary prose does not come here
/// at all any more — `MarkdownProse` marks the phrase itself, where it stands.
struct FindHighlight: ViewModifier {
    enum State { case none, matched, active }

    let state: State

    /// Drawn OUTSIDE the card's own frame, with a negative inset, so that typing into the find
    /// field marks the thread without relaying it. A highlight that adds padding pushes every
    /// answer below it down on each keystroke.
    func body(content: Content) -> some View {
        content
            .background {
                if state != .none {
                    RoundedRectangle(cornerRadius: Metrics.radiusPanel, style: .continuous)
                        .strokeBorder(state == .active ? Palette.accent
                                                       : Palette.accent.opacity(0.28),
                                      lineWidth: state == .active ? 1.5 : 1)
                        .padding(-5)
                }
            }
    }
}

extension View {

    func findHighlight(_ state: FindHighlight.State) -> some View {
        modifier(FindHighlight(state: state))
    }

    /// The anchor a find jump scrolls to. Applied to the very thing that was found, so the reader
    /// lands on the paragraph rather than on the top of a three-page answer.
    func findAnchor(entry: UUID, block: String? = nil) -> some View {
        id(ConversationFind.anchor(entry: entry, block: block))
    }
}
