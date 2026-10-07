import XCTest
import SwiftUI
import AppKit
@testable import Bulava

/// An answer selects as one: a drag runs across its paragraphs, headings, lists and code, and ⌘C
/// hands over the text in order.
///
/// The complaint this pins down: every block of an answer was its own SwiftUI `Text`, so a drag
/// stopped at the end of a paragraph and an answer had to be copied a paragraph at a time.
nonisolated final class ProseSelectsAsOneTests: XCTestCase {

    private static let mixed = """
    # Що зроблено

    Перший абзац із `кодом` і **жирним**.

    Другий абзац,
    з м'яким переносом.

    - перший пункт
    - другий пункт
      - вкладений

    1. раз
    2. два

    ```swift
    let a = 1

    print(a)
    ```

    Після коду.
    """

    // MARK: - The text, in order

    @MainActor
    func testAMixedAnswerIsOneTextWithItsLineBreaksBulletsAndNumbers() throws {
        let parts = ProseDocument.make(Self.mixed).parts
        XCTAssertEqual(parts.count, 1, "nothing in this answer needs to leave the text")
        guard case .text(let segment) = parts.first?.segment else { return XCTFail("not text") }

        XCTAssertEqual(segment.attributed.string, """
        Що зроблено
        Перший абзац із кодом і жирним.
        Другий абзац, з м'яким переносом.
        \t●\tперший пункт
        \t●\tдругий пункт
        \t○\tвкладений
        \t1.\tраз
        \t2.\tдва
        let a = 1

        print(a)
        Після коду.
        """)

        // What Find searches: the same words, without the markers the renderer put in.
        XCTAssertEqual(segment.searchable, """
        Що зроблено
        Перший абзац із кодом і жирним.
        Другий абзац, з м'яким переносом.
        перший пункт
        другий пункт
        вкладений
        раз
        два
        let a = 1

        print(a)
        Після коду.
        """)
        XCTAssertEqual(ConversationFind.displayedText(ofMarkdown: Self.mixed), segment.searchable)
    }

    @MainActor
    func testCopyingTheWholeAnswerKeepsBulletsNumbersAndCodeLines() throws {
        let view = ProseNSTextView.make()
        let segment = try XCTUnwrap(Self.textSegment(Self.mixed))
        view.load(segment)
        view.setFrameSize(NSSize(width: MarkdownProse.proseWidth, height: 600))
        view.selectAll(nil)

        let board = NSPasteboard(name: NSPasteboard.Name("bulava.test.\(UUID().uuidString)"))
        defer { board.releaseGlobally() }
        board.clearContents()
        XCTAssertTrue(view.writeSelection(to: board, types: [.string, .rtf]))
        XCTAssertEqual(board.string(forType: .string), """
        Що зроблено
        Перший абзац із кодом і жирним.
        Другий абзац, з м'яким переносом.
        • перший пункт
        • другий пункт
            ◦ вкладений
        1. раз
        2. два
        let a = 1

        print(a)
        Після коду.
        """)
    }

    @MainActor
    func testCopyingPartOfAListStillCarriesItsMarker() throws {
        let view = ProseNSTextView.make()
        let segment = try XCTUnwrap(Self.textSegment("- один\n- два\n- три"))
        view.load(segment)
        view.setFrameSize(NSSize(width: 400, height: 200))
        let string = segment.attributed.string as NSString
        let from = string.range(of: "дв").location
        let to = NSMaxRange(string.range(of: "три"))
        view.setSelectedRange(NSRange(location: from, length: to - from))

        let board = NSPasteboard(name: NSPasteboard.Name("bulava.test.\(UUID().uuidString)"))
        defer { board.releaseGlobally() }
        board.clearContents()
        _ = view.writeSelection(to: board, types: [.string])
        XCTAssertEqual(board.string(forType: .string), "два\n• три")
    }

    // MARK: - Find, on the same text

    @MainActor
    func testFindMarksLandOnTheRightWords() throws {
        let segment = try XCTUnwrap(Self.textSegment(Self.mixed))
        let string = segment.attributed.string as NSString
        let found = segment.matches(of: "пункт")
        XCTAssertEqual(found.count, 2)
        XCTAssertEqual(found.map { string.substring(with: $0) }, ["пункт", "пункт"])
        XCTAssertEqual(found.first?.location, string.range(of: "перший пункт").location + 7)

        // Past the list markers, numbering and ranges still agree.
        let code = segment.matches(of: "print")
        XCTAssertEqual(code.map { string.substring(with: $0) }, ["print"])
        let after = segment.matches(of: "після")
        XCTAssertEqual(after.map { string.substring(with: $0) }, ["Після"])
    }

    @MainActor
    func testAMarkerIsNeverAResult() {
        XCTAssertTrue(ProseDocument.make("1. раз\n2. два").parts.allSatisfy { part in
            if case .text(let segment) = part.segment { return segment.matches(of: "1.").isEmpty }
            return true
        })
        XCTAssertEqual(ConversationFind.mentions(
            in: ConversationFind.displayedText(ofMarkdown: "- a\n- b"), query: "•"), 0)
    }

    /// The marks are drawn over the text, the one being read stronger than the rest, and each
    /// one reports the height it is drawn at so the jump can land on it.
    @MainActor
    func testTheTextViewMarksThePhraseAndReportsWhereEachOneIs() throws {
        let segment = try XCTUnwrap(Self.textSegment(Self.mixed))
        let view = ProseNSTextView.make()
        view.load(segment)
        view.setFrameSize(NSSize(width: MarkdownProse.proseWidth, height: 600))

        let reported = expectation(description: "anchors")
        var offsets: [Int: CGFloat] = [:]
        view.onAnchors = { offsets = $0; reported.fulfill() }
        let ranges = segment.matches(of: "пункт")
        view.mark([ProseMatch(range: ranges[0], occurrence: 4, isActive: false),
                   ProseMatch(range: ranges[1], occurrence: 5, isActive: true)])
        wait(for: [reported], timeout: 2)

        let layout = try XCTUnwrap(view.layoutManager)
        let soft = layout.temporaryAttributes(atCharacterIndex: ranges[0].location, effectiveRange: nil)
        let strong = layout.temporaryAttributes(atCharacterIndex: ranges[1].location, effectiveRange: nil)
        XCTAssertEqual(soft[.backgroundColor] as? NSColor, ProseInk.accentSoft)
        XCTAssertEqual(strong[.backgroundColor] as? NSColor, ProseInk.accent)
        XCTAssertEqual(strong[.foregroundColor] as? NSColor, ProseInk.onAccent)
        XCTAssertNil(layout.temporaryAttributes(atCharacterIndex: 0, effectiveRange: nil)[.backgroundColor])

        XCTAssertEqual(Set(offsets.keys), [4, 5])
        let first = try XCTUnwrap(offsets[4]), second = try XCTUnwrap(offsets[5])
        XCTAssertGreaterThan(first, 60, "the list is below the heading and two paragraphs")
        XCTAssertGreaterThan(second, first, "the second item is drawn below the first")
        XCTAssertEqual(view.fittingHeight(width: MarkdownProse.proseWidth),
                       segment.height(forWidth: MarkdownProse.proseWidth),
                       "marking the phrase does not change the text's height")
    }

    @MainActor
    func testALinkClickGoesToTheAppsOwnRouting() throws {
        let segment = try XCTUnwrap(Self.textSegment("дивись [звіт](https://x.dev/report)"))
        let view = ProseNSTextView.make()
        view.load(segment)
        var opened: URL?
        view.onLink = { opened = $0 }
        let handled = view.delegate?.textView?(view, clickedOnLink: URL(string: "https://x.dev/report")!,
                                               at: 8)
        XCTAssertEqual(handled, true, "the text view does not open the link on its own")
        XCTAssertEqual(opened?.absoluteString, "https://x.dev/report")
    }

    /// A table inside a list cannot leave the text; it is drawn as its rows, cells a tab apart,
    /// so a phrase is never found across two cells.
    func testATableInsideAListIsDrawnAsItsRows() throws {
        let answer = "- пункт\n\n  | A | B |\n  |---|---|\n  | один | два |"
        let segment = try XCTUnwrap(Self.textSegment(answer))
        XCTAssertTrue(segment.searchable.hasSuffix("A\tB\nодин\tдва"), segment.searchable)
        XCTAssertTrue(segment.matches(of: "один два").isEmpty)
    }

    // MARK: - On screen

    @MainActor
    func testTheAnswerIsOneSelectableTextViewOnScreen() throws {
        let host = NSHostingView(rootView: MarkdownProse(text: Self.mixed)
            .frame(width: MarkdownProse.proseWidth, alignment: .leading))
        host.frame = NSRect(x: 0, y: 0, width: MarkdownProse.proseWidth, height: 2000)
        host.layoutSubtreeIfNeeded()

        let views = Self.textViews(in: host)
        XCTAssertEqual(views.count, 1, "one answer, one text: a drag can cross all of it")
        let view = try XCTUnwrap(views.first)
        XCTAssertTrue(view.isSelectable)
        XCTAssertFalse(view.isEditable)
        XCTAssertTrue(view.string.hasPrefix("Що зроблено\nПерший абзац"))
        XCTAssertTrue(view.string.hasSuffix("print(a)\nПісля коду."))

        // It is as tall as its text, and as wide as the column it was given.
        XCTAssertEqual(view.frame.width, MarkdownProse.proseWidth, accuracy: 0.5)
        XCTAssertEqual(view.frame.height, view.fittingHeight(width: view.frame.width), accuracy: 0.5)
        XCTAssertGreaterThan(view.frame.height, 200)
        XCTAssertEqual(host.fittingSize.height, view.frame.height, accuracy: 1)
    }

    @MainActor
    func testANarrowColumnMakesTheTextTallerNotWider() {
        func height(_ width: CGFloat) -> (CGFloat, CGFloat) {
            let host = NSHostingView(rootView: MarkdownProse(text: Self.mixed)
                .frame(width: width, alignment: .leading))
            host.frame = NSRect(x: 0, y: 0, width: width, height: 4000)
            host.layoutSubtreeIfNeeded()
            let view = Self.textViews(in: host).first
            return (view?.frame.width ?? 0, host.fittingSize.height)
        }
        let (wide, wideHeight) = height(MarkdownProse.proseWidth)
        let (narrow, narrowHeight) = height(160)
        XCTAssertEqual(wide, MarkdownProse.proseWidth, accuracy: 0.5)
        XCTAssertLessThanOrEqual(narrow, 160.5)
        XCTAssertGreaterThan(narrowHeight, wideHeight)
    }

    /// Nothing leaves the text any more: a table and a picture are in the same run as the
    /// paragraphs around them, so one drag goes through them and a copy keeps everything in order.
    @MainActor
    func testATableAndAPictureStayInTheOneRun() {
        let answer = "до таблиці\n\n| A | B |\n|---|---|\n| 1 | 2 |\n\nперед ![знімок](a.png) після\n\nпісля таблиці"
        let parts = ProseDocument.make(answer).parts
        XCTAssertEqual(parts.count, 1, "one selectable text for the whole answer")
        guard case .text(let segment)? = parts.first?.segment else { return XCTFail("no text") }
        XCTAssertTrue(segment.searchable.hasPrefix("до таблиці\n"))
        XCTAssertTrue(segment.searchable.contains("перед  після"), "the picture is not a word")
        XCTAssertTrue(segment.searchable.hasSuffix("після таблиці"))
        var tables = 0
        segment.attributed.enumerateAttribute(.paragraphStyle, in: NSRange(location: 0, length: segment.attributed.length)) { value, _, _ in
            if let style = value as? NSParagraphStyle, style.textBlocks.contains(where: { $0 is NSTextTableBlock }) { tables += 1 }
        }
        XCTAssertGreaterThan(tables, 0, "the table is TextKit's own, inside the run")

        // A copy of the picture's line carries its name, never an object character.
        let view = ProseNSTextView.make()
        view.load(segment)
        view.setFrameSize(NSSize(width: 600, height: 400))
        let string = segment.attributed.string as NSString
        let line = string.range(of: "перед")
        view.setSelectedRange(NSRange(location: line.location,
                                      length: NSMaxRange(string.range(of: "після", options: [], range: NSRange(location: line.location, length: string.length - line.location))) - line.location))
        let board = NSPasteboard(name: NSPasteboard.Name("bulava.test.\(UUID().uuidString)"))
        defer { board.releaseGlobally() }
        board.clearContents()
        _ = view.writeSelection(to: board, types: view.writablePasteboardTypes)
        XCTAssertEqual(board.string(forType: .string), "перед знімок після")
    }

    /// Paragraph, table, paragraph — selected in one drag, whichever way the drag went, and
    /// copied with the table's rows on their own lines and its cells a tab apart.
    @MainActor
    func testCopyingAcrossATableInBothDirections() throws {
        let answer = "Перед таблицею.\n\n| Що | Скільки |\n|---|---|\n| диск | 4 ГБ |\n| ліміт | 1 ГБ |\n\nПісля таблиці."
        let segment = try XCTUnwrap(Self.textSegment(answer))
        let view = ProseNSTextView.make()
        view.load(segment)
        view.setFrameSize(NSSize(width: 600, height: 400))
        let string = segment.attributed.string as NSString
        let from = string.range(of: "таблицею").location
        let to = NSMaxRange(string.range(of: "Після"))
        let expected = "таблицею.\nЩо\tСкільки\nдиск\t4 ГБ\nліміт\t1 ГБ\nПісля"
        for affinity in [NSSelectionAffinity.downstream, .upstream] {
            view.setSelectedRange(NSRange(location: from, length: to - from), affinity: affinity,
                                  stillSelecting: false)
            let board = NSPasteboard(name: NSPasteboard.Name("bulava.test.\(UUID().uuidString)"))
            defer { board.releaseGlobally() }
            board.clearContents()
            _ = view.writeSelection(to: board, types: [.string])
            XCTAssertEqual(board.string(forType: .string), expected, "dragged \(affinity == .downstream ? "down" : "up")")
        }

        // ⌘C itself, with the types the text view asks for on its own — RTFD among them once a
        // picture is in the text.
        view.setSelectedRange(NSRange(location: from, length: to - from))
        let board = NSPasteboard(name: NSPasteboard.Name("bulava.test.\(UUID().uuidString)"))
        defer { board.releaseGlobally() }
        board.clearContents()
        _ = view.writeSelection(to: board, types: view.writablePasteboardTypes)
        XCTAssertEqual(board.string(forType: .string), expected)
    }

    // MARK: - Helpers

    private static func textSegment(_ markdown: String) -> ProseTextSegment? {
        guard case .text(let segment) = ProseDocument.make(markdown).parts.first?.segment else { return nil }
        return segment
    }

    @MainActor private static func textViews(in view: NSView) -> [ProseNSTextView] {
        var out: [ProseNSTextView] = []
        if let text = view as? ProseNSTextView { out.append(text) }
        for sub in view.subviews { out += textViews(in: sub) }
        return out
    }
}
