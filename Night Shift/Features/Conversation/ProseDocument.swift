import AppKit
import SwiftUI
import cmark_gfm
import cmark_gfm_extensions

// MARK: - What an answer is made of, once it is drawn

/// One answer of the agent's prose, parsed once and laid out as long runs of selectable text.
///
/// ## Why this exists
///
/// MarkdownUI drew every paragraph, heading, list item and code block as a SwiftUI `Text` of its
/// own, and `.textSelection(.enabled)` cannot reach across two of them. So a reader who wanted to
/// copy an answer had to copy it a paragraph at a time. Here the whole answer becomes ONE
/// attributed string for one `NSTextView`, so one drag selects from the first heading to the last
/// line of code, and ⌘C hands over the text in order — the bullets and numbers of the lists
/// included, the lines of the code kept.
///
/// Tables and pictures live in the same text: a table as TextKit's own `NSTextTable`, its cells
/// paragraphs of the run, and a picture as an attachment. Nothing breaks the run, so a drag goes
/// from the paragraph above a table, through its rows, to the line below it — and copies the table
/// as rows of tab-separated cells.
///
/// It is parsed with the same cmark-gfm, and the same extensions, that MarkdownUI uses, so the
/// blocks — and which lists are tight — are the ones the library would have seen.
nonisolated final class ProseDocument: @unchecked Sendable {

    enum Segment {
        /// A run of blocks drawn as one selectable text.
        case text(ProseTextSegment)
    }

    struct Part {
        let segment: Segment

        /// The words this part puts on screen, the way Find counts them.
        let displayed: String

        /// The gap above this part, the one MarkdownUI's block sequence would have left.
        let spacingBefore: CGFloat
    }

    let parts: [Part]

    /// Every word the answer puts on screen, part after part. What Find indexes, so the numbering
    /// of the results and the marks on the page cannot disagree.
    let displayed: String

    private init(parts: [Part]) {
        self.parts = parts
        self.displayed = parts.map(\.displayed).joined(separator: "\n")
    }

    // MARK: Building, remembered

    /// The document for `markdown`, built once and then remembered: the thread asks for every
    /// answer on every redraw, and answers do not change once they are finished.
    ///
    /// `roots` are the folders a picture may come from; one from anywhere else is shown as its
    /// name, a link. They change what is drawn and not what is read, so Find counts the same words
    /// with them or without.
    static func make(_ markdown: String, roots: [URL] = []) -> ProseDocument {
        let key = roots.isEmpty ? markdown : roots.map(\.path).joined(separator: "\n") + "\u{0}" + markdown
        if let cached = ProseDocumentCache.shared.value(for: key) { return cached }
        let built = ProseBuilder(source: markdown, roots: roots).build()
        ProseDocumentCache.shared.store(built, for: key)
        return built
    }

    fileprivate static func assemble(_ parts: [Part]) -> ProseDocument { ProseDocument(parts: parts) }
}

/// One run of blocks — paragraphs, headings, lists, quotes, code — drawn as one text.
nonisolated final class ProseTextSegment: @unchecked Sendable {

    /// What the text view shows, list markers and all.
    let attributed: NSAttributedString

    /// What the reader would call the words: `attributed` without the markers the renderer put
    /// in on its own. Find searches this.
    let searchable: String

    /// The renderer's own characters in `attributed`, in order — list markers, the tabs that
    /// align them, a rule's placeholder.
    let markers: [NSRange]

    /// `cellBreaks` are the line breaks that end a table cell inside its row. They are read as
    /// tabs — one character for one, so nothing after them moves — and a phrase is never found
    /// across two cells.
    init(attributed: NSAttributedString, markers: [NSRange], cellBreaks: [Int] = []) {
        self.attributed = attributed
        self.markers = markers
        let shown = NSMutableString(string: attributed.string)
        for at in cellBreaks { shown.replaceCharacters(in: NSRange(location: at, length: 1), with: "\t") }
        let string = shown as NSString
        var out = ""
        var cursor = 0
        for marker in markers {
            if marker.location > cursor {
                out += string.substring(with: NSRange(location: cursor, length: marker.location - cursor))
            }
            cursor = marker.location + marker.length
        }
        if cursor < string.length { out += string.substring(from: cursor) }
        self.searchable = out
    }

    /// Where a range of `searchable` stands in `attributed`.
    func rendered(_ range: NSRange) -> NSRange {
        func map(_ offset: Int) -> Int {
            var shift = 0
            for marker in markers {
                if marker.location <= offset + shift { shift += marker.length } else { break }
            }
            return offset + shift
        }
        let start = map(range.location)
        guard range.length > 0 else { return NSRange(location: start, length: 0) }
        let end = map(range.location + range.length - 1) + 1
        return NSRange(location: start, length: end - start)
    }

    // MARK: Size

    private let measuring = NSLock()
    private var measurer: (storage: NSTextStorage, layout: NSLayoutManager, container: NSTextContainer)?
    private var heights: [CGFloat: CGFloat] = [:]

    /// How tall the text is in a column `width` wide, laid out once per width and remembered.
    func height(forWidth width: CGFloat) -> CGFloat {
        measuring.lock(); defer { measuring.unlock() }
        if let known = heights[width] { return known }
        let used = layOut(width)
        let height = ceil(used.maxY)
        heights[width] = height
        return height
    }

    /// How wide its longest line is in a column `width` wide.
    func usedWidth(forWidth width: CGFloat) -> CGFloat {
        measuring.lock(); defer { measuring.unlock() }
        return ceil(layOut(width).width)
    }

    private func layOut(_ width: CGFloat) -> NSRect {
        let stack: (storage: NSTextStorage, layout: NSLayoutManager, container: NSTextContainer)
        if let measurer { stack = measurer } else {
            let storage = NSTextStorage(attributedString: attributed)
            let layout = NSLayoutManager()
            layout.allowsNonContiguousLayout = false
            let container = NSTextContainer(size: NSSize(width: width, height: .greatestFiniteMagnitude))
            container.lineFragmentPadding = 0
            layout.addTextContainer(container)
            storage.addLayoutManager(layout)
            stack = (storage, layout, container)
            measurer = stack
        }
        if stack.container.size.width != width {
            stack.container.size = NSSize(width: width, height: .greatestFiniteMagnitude)
        }
        stack.layout.ensureLayout(for: stack.container)
        return stack.layout.usedRect(for: stack.container)
    }

    /// Every occurrence of `query` in what the reader sees, as ranges of `attributed`.
    func matches(of query: String) -> [NSRange] {
        let text = searchable
        return ConversationFind.ranges(in: text, query: query).map { rendered(NSRange($0, in: text)) }
    }
}

extension NSAttributedString.Key {
    /// Marks characters the renderer put in itself (a list marker, the tabs aligning it). The
    /// value is what a copy should carry in their place.
    nonisolated static let proseMarker = NSAttributedString.Key("app.bulava.prose.marker")
}

// MARK: - The look, in AppKit terms

/// The prose's own numbers — `ProseStyle`, `Palette`, `Metrics` — turned into AppKit fonts,
/// colours and paragraph metrics.
nonisolated enum ProseInk {
    static let text = NSColor(Palette.text)
    static let secondary = NSColor(Palette.textSecondary)
    static let tertiary = NSColor(Palette.textTertiary)
    static let accent = NSColor(Palette.accent)
    static let accentSoft = NSColor(Palette.accentSoft)
    static let onAccent = NSColor(Palette.onAccent)
    static let panelMuted = NSColor(Palette.panelMuted)
    static let line = NSColor(Palette.line)

    /// MarkdownUI measures `.em` against the size the theme asked for, before rounding.
    static let bodyLineSpacing = ProseStyle.bodySize * ProseStyle.bodyLineSpacing
    static let codeLineSpacing = ProseStyle.codeBlockSize * ProseStyle.codeBlockLineSpacing

    static let codePadding: CGFloat = 11

    /// A list marker sits right-aligned in a column 1.5em wide, and the item's text starts this
    /// far after it — MarkdownUI's `ListItemView` label.
    static let markerColumn = ProseStyle.bodySize * 1.5
    static let markerGap: CGFloat = 9

    /// MarkdownUI's disc, circle and square: SF Symbols at a third of the body size. Drawn here
    /// as geometric shapes in a small face, and copied out as the ordinary bullet characters.
    static let bullets: [(drawn: String, copied: String)] = [("●", "•"), ("○", "◦"), ("■", "▪")]
    static var bulletFont: NSFont { .systemFont(ofSize: 7) }

    /// How far a bullet is raised so that it sits on the middle of the first line's lowercase
    /// letters, where MarkdownUI centres its symbol.
    static let bulletLifts: [CGFloat] = bullets.map { bullet in
        let body = font(size: ProseStyle.bodySize)
        let bounds = (bullet.drawn as NSString).boundingRect(
            with: NSSize(width: 100, height: 100), options: [.usesDeviceMetrics],
            attributes: [.font: bulletFont])
        return (body.xHeight / 2 - bounds.midY).rounded()
    }

    /// The face of a list's numbers, and how wide `12.` is in it: its digits all have one width.
    static var numberFont: NSFont {
        NSFont.monospacedDigitSystemFont(ofSize: ProseStyle.drawn(ProseStyle.bodySize), weight: .regular)
    }
    private static let digitWidth = ("0" as NSString).size(withAttributes: [.font: numberFont]).width
    private static let dotWidth = ("." as NSString).size(withAttributes: [.font: numberFont]).width
    static func numberWidth(_ number: Int) -> CGFloat {
        CGFloat(String(number).count) * digitWidth + dotWidth
    }

    /// The height SwiftUI gives one line of a heading. TextKit rounds a line of the larger
    /// headings a point shorter; a heading set at TextKit's height pulls everything under it up.
    static let headingLineHeights: [CGFloat] = (1...3).map { level in
        let font = font(size: ProseStyle.headingSize(level), weight: .semibold)
        return max(font.ascender.rounded() + (-font.descender).rounded(.up),
                   NSLayoutManager().defaultLineHeight(for: font))
    }

    static let quoteBar: CGFloat = 2
    static let quoteGap: CGFloat = 10

    static func font(size: CGFloat, weight: NSFont.Weight = .regular,
                     italic: Bool = false, monospaced: Bool = false) -> NSFont {
        let key = FontKey(size: size, weight: weight.rawValue, italic: italic, monospaced: monospaced)
        return FontCache.shared.font(for: key) {
            let drawn = ProseStyle.drawn(size)
            var font = monospaced ? NSFont.monospacedSystemFont(ofSize: drawn, weight: weight)
                                  : NSFont.systemFont(ofSize: drawn, weight: weight)
            if italic {
                let descriptor = font.fontDescriptor.withSymbolicTraits(
                    font.fontDescriptor.symbolicTraits.union(.italic))
                font = NSFont(descriptor: descriptor, size: drawn) ?? font
            }
            return font
        }
    }

    fileprivate struct FontKey: Hashable {
        var size: CGFloat, weight: CGFloat, italic: Bool, monospaced: Bool
    }

    /// The handful of faces the prose uses, made once: looking a system font up by weight is the
    /// single most repeated thing in building an answer.
    fileprivate final class FontCache: @unchecked Sendable {
        static let shared = FontCache()
        private let lock = NSLock()
        private var fonts: [FontKey: NSFont] = [:]

        func font(for key: FontKey, make: () -> NSFont) -> NSFont {
            lock.lock(); defer { lock.unlock() }
            if let font = fonts[key] { return font }
            let font = make()
            fonts[key] = font
            return font
        }
    }
}

// MARK: - The pieces of text that are not text

/// A block of the prose that spans the column: it is as wide as the space it is given, and it
/// draws inside its margins.
nonisolated class ProseBlock: NSTextBlock {
    override init() {
        super.init()
        // Without a width a block shrinks to its first line, and the next paragraph falls out
        // of it.
        setContentWidth(100, type: .percentageValueType)
    }

    required init?(coder: NSCoder) { super.init(coder: coder) }

    /// The frame TextKit hands over includes the margins; the panel is drawn inside them.
    func panel(_ frame: NSRect) -> NSRect {
        let left = width(for: .margin, edge: .minX)
        let top = width(for: .margin, edge: .minY)
        let right = width(for: .margin, edge: .maxX)
        let bottom = width(for: .margin, edge: .maxY)
        return NSRect(x: frame.minX + left, y: frame.minY + top,
                      width: max(0, frame.width - left - right),
                      height: max(0, frame.height - top - bottom))
    }
}

/// A fenced code block: the rounded `panelMuted` panel MarkdownUI's theme draws behind the code.
nonisolated final class ProseCodeBlock: ProseBlock {
    override func drawBackground(withFrame frameRect: NSRect, in controlView: NSView?,
                                 characterRange charRange: NSRange, layoutManager: NSLayoutManager) {
        ProseInk.panelMuted.setFill()
        NSBezierPath(roundedRect: panel(frameRect), xRadius: Metrics.radiusControl,
                     yRadius: Metrics.radiusControl).fill()
    }
}

/// A blockquote: the thin bar down its left side, as tall as its text.
nonisolated final class ProseQuoteBlock: ProseBlock {
    override func drawBackground(withFrame frameRect: NSRect, in controlView: NSView?,
                                 characterRange charRange: NSRange, layoutManager: NSLayoutManager) {
        let frame = panel(frameRect)
        // TextKit leaves the last line's spacing under it inside the quote; the bar stops at the
        // text, the way MarkdownUI's does.
        let last = max(0, NSMaxRange(charRange) - 1)
        let style = layoutManager.textStorage.flatMap { storage in
            last < storage.length
                ? storage.attribute(.paragraphStyle, at: last, effectiveRange: nil) as? NSParagraphStyle
                : nil
        }
        // Only a line set directly in the quote; a code panel that closes it accounts for its own.
        let trailing = style?.textBlocks.last === self ? style?.lineSpacing ?? 0 : 0
        ProseInk.line.setFill()
        NSRect(x: frame.minX, y: frame.minY, width: ProseInk.quoteBar,
               height: max(0, frame.height - trailing)).fill()
    }
}

/// A thematic break: a hairline across the column.
nonisolated final class ProseRuleBlock: ProseBlock {
    override func drawBackground(withFrame frameRect: NSRect, in controlView: NSView?,
                                 characterRange charRange: NSRange, layoutManager: NSLayoutManager) {
        let frame = panel(frameRect)
        ProseInk.line.setFill()
        NSRect(x: frame.minX, y: frame.midY - 0.5, width: frame.width, height: 1).fill()
    }
}

// MARK: - The builder

/// cmark-gfm's tree, walked once into parts.
nonisolated private struct ProseBuilder {
    let source: String
    let roots: [URL]

    func build() -> ProseDocument {
        cmark_gfm_core_extensions_ensure_registered()
        guard let parser = cmark_parser_new(CMARK_OPT_DEFAULT) else { return .assemble([]) }
        defer { cmark_parser_free(parser) }
        for name in ["autolink", "strikethrough", "tagfilter", "tasklist", "table"] {
            if let ext = cmark_find_syntax_extension(name) {
                cmark_parser_attach_syntax_extension(parser, ext)
            }
        }
        cmark_parser_feed(parser, source, source.utf8.count)
        guard let document = cmark_parser_finish(parser) else { return .assemble([]) }
        defer { cmark_node_free(document) }

        var text = ProseTextWriter(roots: roots)
        var previous: CNode?
        for block in CNode(document).children {
            if let previous { text.space(ProseMargins.gap(before: block, after: previous, tight: false)) }
            text.block(block, context: .root)
            previous = block
        }
        guard !text.isEmpty else { return .assemble([]) }
        let segment = text.finish()
        return .assemble([.init(segment: .text(segment), displayed: segment.searchable, spacingBefore: 0)])
    }
}

/// The margins MarkdownUI's theme gives each block, and the gap its `BlockSequence` leaves
/// between two of them: the larger of the one above's bottom and the one below's top, or only
/// the top inside a tight list.
nonisolated enum ProseMargins {
    struct Margin { var top: CGFloat?; var bottom: CGFloat? }

    static func of(_ node: CNode) -> Margin {
        switch node.type {
        case "paragraph", "html_block":
            return Margin(top: 0, bottom: 10)
        case "heading":
            switch node.headingLevel {
            case 1:  return Margin(top: 16, bottom: 6)
            case 2:  return Margin(top: 14, bottom: 5)
            case 3:  return Margin(top: 12, bottom: 4)
            default: return Margin(top: nil, bottom: nil)
            }
        case "code_block":
            return Margin(top: 4, bottom: 12)
        case "table":
            return Margin(top: 4, bottom: 12)
        case "thematic_break":
            return Margin(top: 12, bottom: 12)
        case "block_quote":
            return merge(Margin(top: 6, bottom: 10), children(node))
        case "item", "tasklist":
            return merge(Margin(top: 3, bottom: nil), children(node))
        case "list":
            return children(node)
        default:
            return Margin(top: nil, bottom: nil)
        }
    }

    /// A container reports the largest margins of everything inside it, the way MarkdownUI's
    /// margin preference rolls up.
    private static func children(_ node: CNode) -> Margin {
        node.children.reduce(Margin(top: nil, bottom: nil)) { merge($0, of($1)) }
    }

    private static func merge(_ a: Margin, _ b: Margin) -> Margin {
        Margin(top: [a.top, b.top].compactMap { $0 }.max(),
               bottom: [a.bottom, b.bottom].compactMap { $0 }.max())
    }

    static func gap(before node: CNode, after previous: CNode, tight: Bool) -> CGFloat {
        let top = of(node).top
        let bottom = tight ? nil : of(previous).bottom
        // Neither said anything: SwiftUI's own default padding.
        return [top, bottom].compactMap { $0 }.max() ?? 8
    }
}

/// The words a table or a picture paragraph shows, for Find.
nonisolated enum ProsePlain {
    static func text(of node: CNode) -> String {
        switch node.type {
        case "table":
            return node.children.map { row in
                row.children.map { inline($0) }.joined(separator: "\t")
            }.joined(separator: "\n")
        default:
            return inline(node)
        }
    }

    private static func inline(_ node: CNode) -> String {
        switch node.type {
        case "text", "code", "html_inline": return node.literal
        case "softbreak": return " "
        case "linebreak": return "\n"
        case "image": return ""
        default: return node.children.map(inline).joined()
        }
    }
}

// MARK: - Writing one text segment

/// Where the walk is standing: inside which lists and quotes, at what indent, in what ink.
nonisolated private struct ProseContext {
    var blocks: [NSTextBlock] = []
    /// From the left edge of the innermost block.
    var indent: CGFloat = 0
    var listLevel = 0
    var tight = false
    var ink: NSColor = ProseInk.secondary

    static var root: ProseContext { ProseContext() }
}

/// The inline style in force, the way MarkdownUI composes its text styles: outer first, inner
/// on top.
nonisolated private struct InlineStyle {
    var size: CGFloat = ProseStyle.bodySize
    var weight: NSFont.Weight = .regular
    var italic = false
    var monospaced = false
    var color: NSColor = ProseInk.secondary
    var background: NSColor?
    var link: URL?
    var strike = false

    var attributes: [NSAttributedString.Key: Any] {
        var out: [NSAttributedString.Key: Any] = [
            .font: ProseInk.font(size: size, weight: weight, italic: italic, monospaced: monospaced),
            .foregroundColor: color,
        ]
        if let background { out[.backgroundColor] = background }
        if let link { out[.link] = link }
        if strike { out[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
        return out
    }
}

nonisolated private struct ProseTextWriter {
    /// The folders a picture may be drawn from.
    let roots: [URL]

    private let out = NSMutableAttributedString()
    private var markers: [NSRange] = []
    private var cellBreaks: [Int] = []

    init(roots: [URL] = []) { self.roots = roots }

    /// Vertical space owed before the next thing drawn.
    private var pending: CGFloat = 0

    /// TextKit adds a paragraph's line spacing under its last line too; SwiftUI does not. What
    /// the last paragraph added is taken back off the next gap.
    private var lastLineSpacing: CGFloat = 0

    /// The marker of a list item, waiting for the item's first line.
    private var pendingMarker: PendingMarker?

    private struct PendingMarker {
        var text: String
        /// What a copy carries instead: the marker and a space, indented by its level.
        var copy: String
        var attributes: [NSAttributedString.Key: Any]
        /// The ink of the line, for the tabs around the marker.
        var ink: NSColor
        /// Where the list starts, and where the marker's right edge stands.
        var outer: CGFloat
        var column: CGFloat
    }

    var isEmpty: Bool { out.length == 0 }

    mutating func space(_ gap: CGFloat) { pending += gap }

    func finish() -> ProseTextSegment {
        ProseTextSegment(attributed: out, markers: markers, cellBreaks: cellBreaks)
    }

    // MARK: Blocks

    mutating func block(_ node: CNode, context: ProseContext) {
        switch node.type {
        case "paragraph":
            var style = InlineStyle(); style.color = context.ink
            paragraph(inlines(node, style), context: context, lineSpacing: ProseInk.bodyLineSpacing)

        case "html_block":
            var style = InlineStyle(); style.color = context.ink
            let literal = node.literal.hasSuffix("\n") ? String(node.literal.dropLast()) : node.literal
            paragraph(NSAttributedString(string: literal, attributes: style.attributes),
                      context: context, lineSpacing: ProseInk.bodyLineSpacing)

        case "heading":
            var style = InlineStyle()
            let level = node.headingLevel
            if level <= 3 {
                style.size = ProseStyle.headingSize(level)
                style.weight = .semibold
                style.color = ProseInk.text
            } else {
                // The theme leaves levels four to six alone: they read as body text.
                style.color = context.ink
            }
            paragraph(inlines(node, style), context: context, lineSpacing: 0,
                      lineHeight: level <= 3 ? ProseInk.headingLineHeights[level - 1] : 0)

        case "code_block":
            codeBlock(node, context: context)

        case "block_quote":
            let quote = ProseQuoteBlock()
            quote.setWidth(ProseInk.quoteBar + ProseInk.quoteGap, type: .absoluteValueType,
                           for: .padding, edge: .minX)
            if context.indent > 0 {
                quote.setWidth(context.indent, type: .absoluteValueType, for: .margin, edge: .minX)
            }
            enterBlock(quote, context: context)
            var inner = context
            inner.blocks.append(quote)
            inner.indent = 0
            inner.ink = ProseInk.tertiary
            sequence(node.children, context: inner)

        case "list":
            list(node, context: context)

        case "thematic_break":
            rule(context: context)

        case "table":
            table(node, context: context)

        default:
            // Anything cmark adds later still shows its words.
            var style = InlineStyle(); style.color = context.ink
            let words = inlines(node, style)
            if words.length > 0 {
                paragraph(words, context: context, lineSpacing: ProseInk.bodyLineSpacing)
            }
        }
    }

    private mutating func sequence(_ children: [CNode], context: ProseContext) {
        var previous: CNode?
        for child in children {
            if let previous {
                pending += ProseMargins.gap(before: child, after: previous, tight: context.tight)
            }
            block(child, context: context)
            previous = child
        }
    }

    private mutating func list(_ node: CNode, context: ProseContext) {
        let ordered = cmark_node_get_list_type(node.pointer) == CMARK_ORDERED_LIST
        let start = Int(cmark_node_get_list_start(node.pointer))
        let items = node.children
        let tasks = items.contains { $0.type == "tasklist" }
        let level = context.listLevel + 1

        func marker(_ index: Int, _ item: CNode) -> String {
            if tasks {
                return cmark_gfm_extensions_get_tasklist_item_checked(item.pointer) ? "☑" : "☐"
            }
            if ordered { return "\(start + index)." }
            return ProseInk.bullets[min(level, 3) - 1].drawn
        }
        func copied(_ index: Int, _ item: CNode) -> String {
            guard !tasks, !ordered else { return marker(index, item) }
            return ProseInk.bullets[min(level, 3) - 1].copied
        }
        var markerAttributes: [NSAttributedString.Key: Any] = [.foregroundColor: context.ink]
        if tasks {
            markerAttributes[.font] = ProseInk.font(size: ProseStyle.bodySize)
        } else if ordered {
            markerAttributes[.font] = ProseInk.numberFont
        } else {
            markerAttributes[.font] = ProseInk.bulletFont
            markerAttributes[.baselineOffset] = ProseInk.bulletLifts[min(level, 3) - 1]
        }

        // Numbers line up on their right edge in a column as wide as the widest of them.
        var column = ProseInk.markerColumn
        if ordered && !tasks, !items.isEmpty {
            let widest = max(abs(start), abs(start + items.count - 1))
            column = max(column, ceil(ProseInk.numberWidth(widest)))
        }

        var inner = context
        inner.listLevel = level
        inner.tight = cmark_node_get_list_tight(node.pointer) != 0
        inner.indent = context.indent + column + ProseInk.markerGap

        var previous: CNode?
        for (index, item) in items.enumerated() {
            if let previous {
                pending += ProseMargins.gap(before: item, after: previous, tight: inner.tight)
            }
            let text = marker(index, item)
            let indentation = String(repeating: "    ", count: level - 1)
            pendingMarker = PendingMarker(text: text,
                                          copy: indentation + copied(index, item) + " ",
                                          attributes: markerAttributes, ink: context.ink,
                                          outer: context.indent, column: context.indent + column)
            sequence(item.children, context: inner)
            if pendingMarker != nil {
                // An empty item still shows its marker.
                paragraph(NSAttributedString(), context: inner, lineSpacing: ProseInk.bodyLineSpacing)
            }
            previous = item
        }
    }

    private mutating func codeBlock(_ node: CNode, context: ProseContext) {
        if pendingMarker != nil {
            paragraph(NSAttributedString(), context: context, lineSpacing: ProseInk.bodyLineSpacing)
        }
        var code = node.literal
        if code.hasSuffix("\n") { code.removeLast() }

        let block = ProseCodeBlock()
        block.setWidth(ProseInk.codePadding, type: .absoluteValueType, for: .padding)
        // Measured against MarkdownUI's panel: TextKit sets the first line a point lower inside
        // the padding, and puts the last line's spacing inside the panel above the bottom padding.
        block.setWidth(ProseInk.codePadding - 1, type: .absoluteValueType, for: .padding, edge: .minY)
        block.setWidth(ProseInk.codePadding - 1 - ProseInk.codeLineSpacing, type: .absoluteValueType,
                       for: .padding, edge: .maxY)
        if context.indent > 0 {
            block.setWidth(context.indent, type: .absoluteValueType, for: .margin, edge: .minX)
        }
        enterBlock(block, context: context)

        var style = InlineStyle()
        style.size = ProseStyle.codeBlockSize
        style.monospaced = true
        style.color = context.ink
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.textBlocks = context.blocks + [block]
        paragraphStyle.lineSpacing = ProseInk.codeLineSpacing
        paragraphStyle.lineBreakMode = .byWordWrapping

        separate()
        let start = out.length
        out.append(NSAttributedString(string: code, attributes: style.attributes))
        out.addAttribute(.paragraphStyle, value: paragraphStyle,
                         range: NSRange(location: start, length: out.length - start))
        lastLineSpacing = 0
        pending = 0
    }

    /// A table: TextKit's own, inside the run, each cell a paragraph in a cell block. The breaks
    /// between the cells of a row copy as tabs, so a pasted table is rows of tab-separated cells
    /// — the way it pastes into a spreadsheet — and the words stay in order.
    private mutating func table(_ node: CNode, context: ProseContext) {
        if pendingMarker != nil {
            paragraph(NSAttributedString(), context: context, lineSpacing: ProseInk.bodyLineSpacing)
        }
        let rows = node.children
        let columns = rows.map { $0.children.count }.max() ?? 0
        guard columns > 0 else { return }

        let table = NSTextTable()
        table.numberOfColumns = columns
        table.layoutAlgorithm = .automaticLayoutAlgorithm
        table.collapsesBorders = true
        table.hidesEmptyCells = false
        if context.indent > 0 {
            table.setWidth(context.indent, type: .absoluteValueType, for: .margin, edge: .minX)
        }
        enterBlock(table, context: context)

        for (r, row) in rows.enumerated() {
            var style = InlineStyle(); style.color = context.ink
            if row.type == "table_header" { style.weight = .semibold; style.color = ProseInk.text }
            for c in 0..<columns {
                let cell = NSTextTableBlock(table: table, startingRow: r, rowSpan: 1,
                                            startingColumn: c, columnSpan: 1)
                cell.setBorderColor(ProseInk.line)
                cell.setWidth(1, type: .absoluteValueType, for: .border)
                cell.setWidth(5, type: .absoluteValueType, for: .padding, edge: .minY)
                cell.setWidth(5, type: .absoluteValueType, for: .padding, edge: .maxY)
                cell.setWidth(9, type: .absoluteValueType, for: .padding, edge: .minX)
                cell.setWidth(9, type: .absoluteValueType, for: .padding, edge: .maxX)
                let paragraphStyle = NSMutableParagraphStyle()
                paragraphStyle.textBlocks = context.blocks + [cell]
                paragraphStyle.lineBreakMode = .byWordWrapping

                if r == 0 && c == 0 {
                    separate()
                } else {
                    // The end of the cell before. Within a row it is a cell boundary, and goes out
                    // as a tab; at the end of a row it is the line break it looks like.
                    var attributes = out.attributes(at: out.length - 1, effectiveRange: nil)
                        .filter { [.font, .paragraphStyle, .foregroundColor].contains($0.key) }
                    if c > 0 { attributes[.proseMarker] = "\t" }
                    if c > 0 { cellBreaks.append(out.length) }
                    out.append(NSAttributedString(string: "\n", attributes: attributes))
                }
                var words = c < row.children.count ? inlines(row.children[c], style) : NSAttributedString()
                // An empty cell still has to be a paragraph of its own, or the table loses a column.
                if words.length == 0 { words = NSAttributedString(string: " ", attributes: style.attributes) }
                let start = out.length
                appendTracked(words)
                out.addAttribute(.paragraphStyle, value: paragraphStyle,
                                 range: NSRange(location: start, length: out.length - start))
            }
        }
        lastLineSpacing = 0
        pending = 0
    }

    /// Appends, and takes note of the renderer's own characters inside — a picture, whose place
    /// in the text is an object character that is not a word.
    private mutating func appendTracked(_ content: NSAttributedString) {
        let start = out.length
        out.append(content)
        content.enumerateAttribute(.proseMarker, in: NSRange(location: 0, length: content.length)) { value, range, _ in
            guard value != nil else { return }
            markers.append(NSRange(location: start + range.location, length: range.length))
        }
    }

    private mutating func rule(context: ProseContext) {
        let block = ProseRuleBlock()
        if context.indent > 0 {
            block.setWidth(context.indent, type: .absoluteValueType, for: .margin, edge: .minX)
        }
        enterBlock(block, context: context)
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.textBlocks = context.blocks + [block]
        paragraphStyle.minimumLineHeight = 1
        paragraphStyle.maximumLineHeight = 1
        separate()
        let start = out.length
        out.append(NSAttributedString(string: " ", attributes: [
            .font: NSFont.systemFont(ofSize: 1),
            .foregroundColor: NSColor.clear,
            .paragraphStyle: paragraphStyle,
            .proseMarker: "",
        ]))
        markers.append(NSRange(location: start, length: 1))
        lastLineSpacing = 0
        pending = 0
    }

    /// A quote or a code panel starts: the space owed goes above it, outside its frame.
    private mutating func enterBlock(_ block: NSTextBlock, context: ProseContext) {
        let gap = max(0, pending - lastLineSpacing)
        if gap > 0 { block.setWidth(gap, type: .absoluteValueType, for: .margin, edge: .minY) }
        pending = 0
        lastLineSpacing = 0
    }

    /// Ends the paragraph before, if there is one. The newline takes that paragraph's look, so
    /// it does not start a block of its own.
    private mutating func separate() {
        guard out.length > 0 else { return }
        let attributes = out.attributes(at: out.length - 1, effectiveRange: nil)
            .filter { [.font, .paragraphStyle, .foregroundColor].contains($0.key) }
        out.append(NSAttributedString(string: "\n", attributes: attributes))
    }

    /// A paragraph or a heading: one leaf, with the list marker in front of it if it opens an
    /// item.
    private mutating func paragraph(_ content: NSAttributedString, context: ProseContext,
                                    lineSpacing: CGFloat, lineHeight: CGFloat = 0) {
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.textBlocks = context.blocks
        paragraphStyle.lineSpacing = lineSpacing
        paragraphStyle.minimumLineHeight = lineHeight
        paragraphStyle.lineBreakMode = .byWordWrapping
        paragraphStyle.firstLineHeadIndent = context.indent
        paragraphStyle.headIndent = context.indent
        paragraphStyle.paragraphSpacingBefore = max(0, pending - lastLineSpacing)

        separate()
        let start = out.length

        if let marker = pendingMarker {
            pendingMarker = nil
            paragraphStyle.firstLineHeadIndent = marker.outer
            paragraphStyle.tabStops = [
                NSTextTab(textAlignment: .right, location: marker.column),
                NSTextTab(textAlignment: .left, location: context.indent),
            ]
            // The tabs are set in the body face, so the line keeps its height even when the
            // marker is a small dot.
            let tab: [NSAttributedString.Key: Any] = [
                .font: ProseInk.font(size: ProseStyle.bodySize),
                .foregroundColor: marker.ink,
                .proseMarker: marker.copy,
            ]
            var glyph = marker.attributes
            glyph[.proseMarker] = marker.copy
            out.append(NSAttributedString(string: "\t", attributes: tab))
            out.append(NSAttributedString(string: marker.text, attributes: glyph))
            out.append(NSAttributedString(string: "\t", attributes: tab))
            markers.append(NSRange(location: start, length: out.length - start))
        }

        appendTracked(content)
        let range = NSRange(location: start, length: out.length - start)
        out.addAttribute(.paragraphStyle, value: paragraphStyle, range: range)

        // A hard line break inside the paragraph is a newline too; only the first line owes the
        // space above.
        let string = out.mutableString
        let firstEnd = string.range(of: "\n", options: [], range: range)
        if firstEnd.location != NSNotFound {
            let rest = NSRange(location: firstEnd.location + 1,
                               length: range.location + range.length - firstEnd.location - 1)
            let continued = paragraphStyle.mutableCopy() as! NSMutableParagraphStyle
            continued.paragraphSpacingBefore = 0
            continued.firstLineHeadIndent = context.indent
            continued.tabStops = []
            out.addAttribute(.paragraphStyle, value: continued, range: rest)
        }

        lastLineSpacing = lineSpacing
        pending = 0
    }

    // MARK: Inlines

    private func inlines(_ node: CNode, _ style: InlineStyle) -> NSAttributedString {
        let result = NSMutableAttributedString()
        var skipWhitespace = false
        render(node.children, style, into: result, skipWhitespace: &skipWhitespace)
        return result
    }

    private func render(_ nodes: [CNode], _ style: InlineStyle, into result: NSMutableAttributedString,
                        skipWhitespace: inout Bool) {
        for node in nodes {
            switch node.type {
            case "text":
                var text = node.literal
                if skipWhitespace {
                    skipWhitespace = false
                    text = String(text.drop(while: { $0.isWhitespace }))
                }
                result.append(NSAttributedString(string: text, attributes: style.attributes))

            case "softbreak":
                if skipWhitespace { skipWhitespace = false; continue }
                result.append(NSAttributedString(string: " ", attributes: style.attributes))

            case "linebreak":
                result.append(NSAttributedString(string: "\n", attributes: style.attributes))

            case "code":
                var code = style
                code.monospaced = true
                code.size = ProseStyle.inlineCodeSize
                code.color = ProseInk.text
                code.background = ProseInk.panelMuted
                result.append(NSAttributedString(string: node.literal, attributes: code.attributes))

            case "html_inline":
                let html = node.literal
                let tag = html.lowercased().filter { !$0.isWhitespace }
                if tag == "<br>" || tag == "<br/>" {
                    result.append(NSAttributedString(string: "\n", attributes: style.attributes))
                    skipWhitespace = true
                } else {
                    result.append(NSAttributedString(string: html, attributes: style.attributes))
                }

            case "emph":
                var inner = style; inner.italic = true
                render(node.children, inner, into: result, skipWhitespace: &skipWhitespace)

            case "strong":
                var inner = style; inner.weight = .semibold; inner.color = ProseInk.text
                render(node.children, inner, into: result, skipWhitespace: &skipWhitespace)

            case "strikethrough":
                var inner = style; inner.strike = true
                render(node.children, inner, into: result, skipWhitespace: &skipWhitespace)

            case "link":
                var inner = style
                inner.color = ProseInk.accent
                inner.link = URL(string: node.url)
                render(node.children, inner, into: result, skipWhitespace: &skipWhitespace)

            case "image":
                // A picture from this machine, inside its folders, is drawn where it stands; one
                // from anywhere else is its name, as a link that opens it. Either way it is not a
                // word: Find skips it, and a copy carries its name.
                // The alt text is the picture's children; the picture itself reads as nothing.
                let alt = node.children.map { ProsePlain.text(of: $0) }.joined()
                let url = URL(string: node.url)
                let file = url.flatMap { FilePathLinks.target(of: $0, roots: roots) }
                let name = !alt.isEmpty ? alt : (file ?? url)?.lastPathComponent ?? node.url
                var inner = style
                inner.color = ProseInk.accent
                inner.link = url
                var attributes = inner.attributes
                attributes[.proseMarker] = name
                if let url, let picture = ProsePicture.attachment(for: url, roots: roots) {
                    let drawn = NSMutableAttributedString(attachment: picture)
                    drawn.addAttributes(attributes, range: NSRange(location: 0, length: drawn.length))
                    result.append(drawn)
                } else {
                    result.append(NSAttributedString(string: name, attributes: attributes))
                }

            default:
                render(node.children, style, into: result, skipWhitespace: &skipWhitespace)
            }
        }
    }
}

// MARK: - cmark, at arm's length

nonisolated struct CNode {
    let pointer: UnsafeMutablePointer<cmark_node>

    init(_ pointer: UnsafeMutablePointer<cmark_node>) { self.pointer = pointer }

    var type: String { String(cString: cmark_node_get_type_string(pointer)) }

    var children: [CNode] {
        var out: [CNode] = []
        var child = cmark_node_first_child(pointer)
        while let node = child {
            out.append(CNode(node))
            child = cmark_node_next(node)
        }
        return out
    }

    var literal: String { cmark_node_get_literal(pointer).map { String(cString: $0) } ?? "" }
    var url: String { cmark_node_get_url(pointer).map { String(cString: $0) } ?? "" }
    var headingLevel: Int { Int(cmark_node_get_heading_level(pointer)) }

    var containsImage: Bool {
        type == "image" || children.contains { $0.containsImage }
    }
}

// MARK: - Remembered

/// Markdown source → its document. Same shape as the plain-text memo Find used to keep: enough
/// for a long thread, and past that the oldest half goes.
nonisolated private final class ProseDocumentCache: @unchecked Sendable {
    static let shared = ProseDocumentCache()
    private static let capacity = 600

    private let lock = NSLock()
    private var memo: [String: ProseDocument] = [:]
    private var order: [String] = []

    func value(for source: String) -> ProseDocument? {
        lock.lock(); defer { lock.unlock() }
        return memo[source]
    }

    func store(_ document: ProseDocument, for source: String) {
        lock.lock(); defer { lock.unlock() }
        if memo.updateValue(document, forKey: source) == nil {
            order.append(source)
            if order.count > Self.capacity {
                for key in order.prefix(Self.capacity / 2) { memo[key] = nil }
                order.removeFirst(Self.capacity / 2)
            }
        }
    }
}

// MARK: - Pictures

/// A picture from this machine, sized and framed the way the answer has always shown one: no
/// wider than the prose, no taller than 420 points, with rounded corners and a hairline.
nonisolated enum ProsePicture {
    static let maxHeight: CGFloat = 420

    static func attachment(for url: URL, roots: [URL]) -> NSTextAttachment? {
        guard let file = FilePathLinks.target(of: url, roots: roots), FilePathLinks.isImage(file),
              let image = NSImage(contentsOf: file), image.size.width > 0, image.size.height > 0 else {
            return nil
        }
        let scale = min(1, MarkdownProse.proseWidth / image.size.width, maxHeight / image.size.height)
        let size = NSSize(width: floor(image.size.width * scale), height: floor(image.size.height * scale))
        let radius = Metrics.radiusControl
        let framed = NSImage(size: size, flipped: false) { rect in
            let shape = NSBezierPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), xRadius: radius, yRadius: radius)
            NSGraphicsContext.saveGraphicsState()
            shape.addClip()
            image.draw(in: rect)
            NSGraphicsContext.restoreGraphicsState()
            ProseInk.line.setStroke()
            shape.lineWidth = 1
            shape.stroke()
            return true
        }
        let attachment = NSTextAttachment()
        attachment.image = framed
        attachment.bounds = NSRect(origin: .zero, size: size)
        return attachment
    }
}
