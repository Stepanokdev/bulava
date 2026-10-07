import SwiftUI
import AppKit

// MARK: - One run of prose, one selectable text

/// Where the phrase stands in one text part, and which of the answer's results each is.
nonisolated struct ProseMatch: Equatable, Sendable {
    /// In the part's `attributed` string.
    var range: NSRange
    /// Which occurrence of the answer this is — the number its anchor carries.
    var occurrence: Int
    var isActive: Bool
}

/// A text segment of an answer, drawn by one `NSTextView` so that a single drag selects across
/// all of its paragraphs, lists and code.
///
/// While a search is running it also lays down the scroll anchors of the occurrences it holds,
/// at the height each one is actually drawn at, so a jump puts the phrase itself under the find
/// bar rather than the top of a three-page answer.
struct ProseTextPart: View {
    let segment: ProseTextSegment
    var matches: [ProseMatch] = []
    var anchorPrefix: (entry: UUID, block: String?)?
    var onLink: (URL) -> Void = { _ in }

    @State private var anchorOffsets: [Int: CGFloat] = [:]

    var body: some View {
        ProseTextSurface(segment: segment, matches: matches, onLink: onLink,
                         onAnchors: anchorPrefix == nil || matches.isEmpty ? nil : { offsets in
                             if offsets != anchorOffsets { anchorOffsets = offsets }
                         })
            .overlay(alignment: .topLeading) {
                if let anchorPrefix, !matches.isEmpty {
                    // Weightless markers in an overlay: they take no part in layout, so marking a
                    // phrase cannot move a line of the answer.
                    ZStack(alignment: .topLeading) {
                        ForEach(matches, id: \.occurrence) { match in
                            Color.clear
                                .frame(width: 1, height: 1)
                                .id(ConversationFind.proseAnchor(entry: anchorPrefix.entry,
                                                                 block: anchorPrefix.block,
                                                                 occurrence: match.occurrence))
                                .padding(.top, anchorOffsets[match.occurrence] ?? 0)
                        }
                    }
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
                }
            }
    }
}

/// The AppKit side: a read-only, selectable TextKit 1 text view that sizes itself to its text.
struct ProseTextSurface: NSViewRepresentable {
    let segment: ProseTextSegment
    var matches: [ProseMatch] = []
    var onLink: (URL) -> Void = { _ in }
    var onAnchors: (([Int: CGFloat]) -> Void)? = nil

    func makeNSView(context: Context) -> ProseNSTextView {
        let view = ProseNSTextView.make()
        view.load(segment)
        return view
    }

    func updateNSView(_ view: ProseNSTextView, context: Context) {
        view.onLink = onLink
        view.onAnchors = onAnchors
        if view.segment !== segment { view.load(segment) }
        view.mark(matches)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView view: ProseNSTextView,
                      context: Context) -> CGSize? {
        let limit = MarkdownProse.proseWidth
        if let offered = proposal.width, offered.isFinite {
            let width = min(max(offered, 0), limit)
            // A probe for the smallest size gets an honest width and a sane height: laying a
            // long answer out a letter per line costs more than any layout is worth.
            return CGSize(width: width, height: view.fittingHeight(width: max(width, 60)))
        }
        // Asked for its ideal size: as wide as its longest line, up to the column.
        let height = view.fittingHeight(width: limit)
        return CGSize(width: min(limit, view.usedWidth(width: limit)), height: height)
    }
}

final class ProseNSTextView: NSTextView {

    private(set) var segment: ProseTextSegment?
    var onLink: (URL) -> Void = { _ in }
    var onAnchors: (([Int: CGFloat]) -> Void)?

    private var marked: [ProseMatch] = []
    private var reportedAnchors: [Int: CGFloat] = [:]

    static func make() -> ProseNSTextView {
        let storage = NSTextStorage()
        let layout = NSLayoutManager()
        layout.allowsNonContiguousLayout = false
        layout.usesFontLeading = true
        storage.addLayoutManager(layout)
        let container = NSTextContainer(size: NSSize(width: MarkdownProse.proseWidth,
                                                     height: .greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        container.widthTracksTextView = true
        container.heightTracksTextView = false
        layout.addTextContainer(container)

        let view = ProseNSTextView(frame: .zero, textContainer: container)
        view.isEditable = false
        view.isSelectable = true
        view.isRichText = true
        view.importsGraphics = false
        view.allowsUndo = false
        view.drawsBackground = false
        view.backgroundColor = .clear
        view.textContainerInset = .zero
        view.isVerticallyResizable = false
        view.isHorizontallyResizable = false
        view.autoresizingMask = []
        view.usesFindBar = false
        view.usesFindPanel = false
        view.isAutomaticLinkDetectionEnabled = false
        view.isAutomaticDataDetectionEnabled = false
        view.displaysLinkToolTips = false
        view.focusRingType = .none
        // The links' look is in the string itself — accent, or the code's own ink for a path in
        // backticks — exactly as MarkdownUI drew them. The text view adds only the hand.
        view.linkTextAttributes = [.cursor: NSCursor.pointingHand]
        view.delegate = view.linkDelegate
        view.setAccessibilityRole(.textArea)
        view.setAccessibilityIdentifier("conversation.prose")
        return view
    }

    private lazy var linkDelegate = LinkDelegate(owner: self)

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: NSView.noIntrinsicMetric)
    }

    func load(_ segment: ProseTextSegment) {
        self.segment = segment
        marked = []
        reportedAnchors = [:]
        textStorage?.setAttributedString(segment.attributed)
        let whole = NSRange(location: 0, length: textStorage?.length ?? 0)
        layoutManager?.removeTemporaryAttribute(.backgroundColor, forCharacterRange: whole)
        layoutManager?.removeTemporaryAttribute(.foregroundColor, forCharacterRange: whole)
        setSelectedRange(NSRange(location: 0, length: 0))
    }

    // MARK: Size

    /// Measured by the segment, not by this view: SwiftUI asks at several widths, and asking the
    /// view's own layout would re-lay what is on screen each time. The segment also remembers,
    /// so a message scrolled out of a lazy stack and back costs nothing to size again.
    func fittingHeight(width: CGFloat) -> CGFloat {
        segment?.height(forWidth: width) ?? 0
    }

    func usedWidth(width: CGFloat) -> CGFloat {
        segment?.usedWidth(forWidth: width) ?? width
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        reportAnchors()
    }

    // MARK: Find

    /// The phrase, marked where it stands. Temporary attributes: drawn over the text, never part
    /// of its layout, so marking it moves nothing.
    func mark(_ matches: [ProseMatch]) {
        guard matches != marked, let layout = layoutManager else { return }
        let whole = NSRange(location: 0, length: textStorage?.length ?? 0)
        layout.removeTemporaryAttribute(.backgroundColor, forCharacterRange: whole)
        layout.removeTemporaryAttribute(.foregroundColor, forCharacterRange: whole)
        for match in matches where NSMaxRange(match.range) <= whole.length {
            if match.isActive {
                layout.addTemporaryAttributes([.backgroundColor: ProseInk.accent,
                                               .foregroundColor: ProseInk.onAccent],
                                              forCharacterRange: match.range)
            } else {
                layout.addTemporaryAttribute(.backgroundColor, value: ProseInk.accentSoft,
                                             forCharacterRange: match.range)
            }
        }
        marked = matches
        reportAnchors()
    }

    /// The height of each marked occurrence, for the scroll anchors laid over this view.
    private func reportAnchors() {
        guard let onAnchors, !marked.isEmpty, frame.width > 0,
              let container = textContainer, let layout = layoutManager else { return }
        layout.ensureLayout(for: container)
        var offsets: [Int: CGFloat] = [:]
        for match in marked {
            let glyphs = layout.glyphRange(forCharacterRange: match.range, actualCharacterRange: nil)
            let rect = layout.boundingRect(forGlyphRange: glyphs, in: container)
            offsets[match.occurrence] = max(0, floor(rect.minY + textContainerOrigin.y))
        }
        guard offsets != reportedAnchors else { return }
        reportedAnchors = offsets
        // Never from inside SwiftUI's own update pass.
        DispatchQueue.main.async { onAnchors(offsets) }
    }

    /// Clicking into another answer, or into the composer, lets go of the selection here, the
    /// way SwiftUI's selectable text did — otherwise every answer ever selected keeps a grey
    /// selection on screen.
    override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        if resigned, selectedRange().length > 0 {
            setSelectedRange(NSRange(location: selectedRange().location, length: 0))
        }
        return resigned
    }

    // MARK: Copy

    /// The list markers go out as "• " and "1. ", indented by level, rather than as the tabs
    /// that align them on screen; a table's cells a tab apart; a picture as its name.
    ///
    /// The plain text is written whatever types the copy asked for. ⌘C on a text holding a picture
    /// asks for RTFD first and names plain text in its legacy spelling, and a check for `.string`
    /// alone let the raw text through — every cell on a line of its own, an object character where
    /// the picture was.
    override func writeSelection(to pboard: NSPasteboard, types: [NSPasteboard.PasteboardType]) -> Bool {
        let wrote = super.writeSelection(to: pboard, types: types)
        guard let storage = textStorage else { return wrote }
        var out = ""
        for value in selectedRanges {
            let range = value.rangeValue
            guard range.length > 0 else { continue }
            if !out.isEmpty { out += "\n" }
            storage.enumerateAttribute(.proseMarker, in: range) { marker, piece, _ in
                if let marker = marker as? String {
                    // A marker cut in half by the selection still goes out whole, once.
                    out += marker
                } else {
                    out += (storage.string as NSString).substring(with: piece)
                }
            }
        }
        if !out.isEmpty {
            if pboard.types?.contains(.string) != true { pboard.addTypes([.string], owner: nil) }
            pboard.setString(out, forType: .string)
        }
        return wrote || !out.isEmpty
    }

    // MARK: Links

    private final class LinkDelegate: NSObject, NSTextViewDelegate {
        weak var owner: ProseNSTextView?
        init(owner: ProseNSTextView) { self.owner = owner }

        func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
            let url = (link as? URL) ?? (link as? String).flatMap(URL.init(string:))
            guard let url, let owner else { return false }
            owner.onLink(url)
            return true
        }
    }
}
