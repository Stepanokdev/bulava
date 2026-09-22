import SwiftUI
import MarkdownUI

/// Marking the found phrase inside the agent's prose — the phrase itself, not the answer around it.
///
/// ## Why this exists
///
/// MarkdownUI draws a whole answer as one view and offers no way to colour a range of characters
/// inside it: `InlineNode` and `TextInlineRenderer` are internal, and inline HTML comes out as
/// literal text, so `<mark>` is no help either. The first cut of Find worked around that by
/// outlining the entire message, which found the phrase and then made the reader look for it by
/// eye down sixty lines.
///
/// What the library DOES offer is the seam the theme already uses: a block style is handed the
/// block's own content, and may draw whatever it likes in place of it. So the leaves — a
/// paragraph, a heading, a code block — draw themselves here whenever they hold the phrase, out
/// of `AttributedString`, where a range can be given a background. Everything else in the answer
/// still goes through MarkdownUI untouched, which is what keeps the page identical to the one the
/// reader was looking at a moment ago.
///
/// ## What this deliberately does not do
///
/// A leaf only draws itself when it holds a match AND a search is running. Nothing about ordinary
/// reading changes — same renderer, same layout, same drag-selection across the whole answer.
enum ProseHighlight {

    /// The leaves whose displayed text is one run and can therefore be marked exactly.
    enum Leaf: Equatable {
        case paragraph
        case heading(level: Int)
        case codeBlock

        var font: Font {
            switch self {
            case .paragraph:            ProseStyle.body
            case .heading(let level):   ProseStyle.heading(level)
            case .codeBlock:            ProseStyle.codeBlock
            }
        }

        var colour: Color {
            switch self {
            case .paragraph:  Palette.textSecondary
            case .heading:    Palette.text
            case .codeBlock:  Palette.textSecondary
            }
        }
    }

    /// The displayed text of a leaf, with its inline markup carried over and the phrase marked.
    ///
    /// Returns nil whenever the leaf cannot be drawn faithfully — an inline image, markdown the
    /// inline parser will not take — and the caller then keeps MarkdownUI's own drawing and marks
    /// nothing. A paragraph drawn wrong is worse than a paragraph drawn plain.
    static func attributed(markdown: String, leaf: Leaf) -> AttributedString? {
        if case .codeBlock = leaf { return AttributedString(markdown) }
        // An inline image has no character to hand to `Text`; it would simply vanish.
        guard !markdown.contains("![") else { return nil }

        let source = stripBlockSyntax(markdown, leaf: leaf)
        guard var parsed = try? AttributedString(
            markdown: source,
            options: .init(allowsExtendedAttributes: true,
                           interpretedSyntax: .inlineOnlyPreservingWhitespace,
                           failurePolicy: .returnPartiallyParsedIfPossible))
        else { return nil }

        // The theme's inline styles, applied by hand because they live inside MarkdownUI's own
        // renderer. `ProseStyle` is the single place both this and `Theme.bulava` read them from,
        // so the two cannot drift apart.
        for run in parsed.runs {
            let intent = run.inlinePresentationIntent ?? []
            if intent.contains(.code) {
                parsed[run.range].font = ProseStyle.inlineCode
                parsed[run.range].foregroundColor = Palette.text
                parsed[run.range].backgroundColor = Palette.panelMuted
            } else if intent.contains(.stronglyEmphasized) {
                parsed[run.range].font = leaf.font.weight(.semibold)
                parsed[run.range].foregroundColor = Palette.text
            } else if intent.contains(.emphasized) {
                parsed[run.range].font = leaf.font.italic()
            }
            if run.link != nil { parsed[run.range].foregroundColor = Palette.accent }
        }
        return parsed
    }

    /// Give the phrase its background wherever it stands in the leaf, and the one the reader was
    /// taken to a stronger one than the rest.
    static func marking(_ text: AttributedString, query: String,
                        activeOccurrence: Int?) -> AttributedString {
        var out = text
        let plain = String(text.characters)
        for (index, range) in ConversationFind.ranges(in: plain, query: query).enumerated() {
            guard let lower = AttributedString.Index(range.lowerBound, within: out),
                  let upper = AttributedString.Index(range.upperBound, within: out) else { continue }
            if index == activeOccurrence {
                out[lower..<upper].backgroundColor = Palette.accent
                out[lower..<upper].foregroundColor = Palette.onAccent
            } else {
                out[lower..<upper].backgroundColor = Palette.accentSoft
            }
        }
        return out
    }

    /// `renderMarkdown()` hands back the block as Markdown, heading hashes and all; the inline
    /// parser would print those hashes out as text.
    private static func stripBlockSyntax(_ markdown: String, leaf: Leaf) -> String {
        let trimmed = markdown.trimmingCharacters(in: .newlines)
        guard case .heading = leaf else { return trimmed }
        var rest = Substring(trimmed)
        while rest.first == "#" { rest = rest.dropFirst() }
        return String(rest.drop(while: { $0 == " " }))
    }
}

// MARK: - The one place the prose styles are written down

/// The fonts and sizes the agent's prose is set in.
///
/// Read by `Theme.bulava`, which draws the prose, and by `ProseHighlight`, which redraws a single
/// leaf of it while the phrase inside is being marked. Two copies of these numbers would drift,
/// and the way that shows is a paragraph changing height the moment you search for a word in it.
nonisolated enum ProseStyle {
    static let bodySize: CGFloat = 13.5
    static let inlineCodeSize: CGFloat = 12
    static let codeBlockSize: CGFloat = 11.5

    static let bodyLineSpacing = 0.22
    static let codeBlockLineSpacing = 0.2

    /// Rounded, because that is the size MarkdownUI actually draws: `Font.withProperties` takes
    /// `round(size * scale)`, so a `FontSize(13.5)` in the theme comes out as a 14pt face. Asking
    /// SwiftUI for 13.5 here instead gave a line one point shorter, and a three-line paragraph
    /// therefore rose by three points the moment somebody searched a word in it — the exact
    /// relayout this whole file exists to prevent.
    static let body = Font.system(size: drawn(bodySize))
    static let inlineCode = Font.system(size: drawn(inlineCodeSize), design: .monospaced)
    static let codeBlock = Font.system(size: drawn(codeBlockSize), design: .monospaced)

    /// The point size MarkdownUI resolves a `FontSize` to.
    static func drawn(_ size: CGFloat) -> CGFloat { size.rounded() }

    static func headingSize(_ level: Int) -> CGFloat {
        switch level {
        case 1:  16
        case 2:  14.5
        default: 13.5
        }
    }

    static func heading(_ level: Int) -> Font {
        .system(size: drawn(headingSize(level)), weight: .semibold)
    }
}

// MARK: - A leaf of the prose, drawing itself

/// One paragraph, heading or code block of an answer, drawn by the app rather than by MarkdownUI
/// because the phrase inside it has to be marked.
///
/// It also lays down the anchors for the occurrences it holds: a jump into a long answer goes to
/// the block first and then to one of these, which is what puts the phrase under the find bar
/// instead of putting the top of the answer there.
struct ProseLeaf<Label: View>: View {
    let find: ProseFind?
    let markdown: String
    let leaf: ProseHighlight.Leaf
    @ViewBuilder let label: () -> Label

    var body: some View {
        if let find, let shown = marked(find) {
            // The font and the ink have to be stated. Inside a Markdown view the resolved style
            // lives in MarkdownUI's own environment, not in SwiftUI's, so a bare `Text` here
            // falls back to the system body face — and the answer relays itself by two or three
            // points per paragraph the moment somebody searches it.
            Text(shown.text)
                .font(leaf.font)
                .foregroundStyle(leaf.colour)
                .textSelection(.enabled)
                .overlay(alignment: .topLeading) { anchors(shown.occurrences, find) }
        } else {
            label()
        }
    }

    private struct Marked {
        var text: AttributedString
        var occurrences: [Int]
    }

    private func marked(_ find: ProseFind) -> Marked? {
        guard let base = ProseHighlight.attributed(markdown: markdown, leaf: leaf) else { return nil }
        let plain = String(base.characters)
        let hits = ConversationFind.ranges(in: plain, query: find.query)
        guard !hits.isEmpty else { return nil }

        // Which of the answer's results these are. Unknown for a paragraph that appears twice
        // word for word; it then marks its matches without claiming one of them is the active
        // one, rather than pointing at the wrong line.
        let before = find.occurrencesBefore(leaf: plain)
        let mine = before.map { start in hits.indices.map { start + $0 } } ?? []
        let activeHere = find.activeOccurrence.flatMap { active in
            mine.firstIndex(of: active)
        }

        return Marked(text: ProseHighlight.marking(base, query: find.query,
                                                   activeOccurrence: activeHere),
                      occurrences: mine)
    }

    /// Weightless markers the scroll can aim at. In an overlay so they take no part in layout —
    /// a paragraph must not change height because somebody searched for a word in it.
    @ViewBuilder private func anchors(_ occurrences: [Int], _ find: ProseFind) -> some View {
        ForEach(occurrences, id: \.self) { occurrence in
            Color.clear
                .frame(width: 1, height: 1)
                .id(ConversationFind.proseAnchor(entry: find.entryID, block: find.blockID,
                                                 occurrence: occurrence))
        }
    }
}
