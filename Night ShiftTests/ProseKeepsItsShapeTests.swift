import XCTest
import SwiftUI
import AppKit
@testable import Bulava

/// A paragraph that Find redraws must occupy exactly the space it did a moment ago.
///
/// This is the one risk the approach carries. The agent's prose is drawn by MarkdownUI; while a
/// search is running, a paragraph holding the phrase is drawn by the app instead, out of an
/// `AttributedString` where a range can be given a background. If the two drawings disagree about
/// the font, the line spacing or the inline code, the thread relays itself the moment somebody
/// types — the answer above jumps, and the result you were reading walks off the screen.
///
/// So this measures both, headless, and holds them to a point of each other. It needs no window
/// server, which is why it can run where a UI test cannot.
nonisolated final class ProseKeepsItsShapeTests: XCTestCase {

    /// Real shapes out of this app's own answers: plain prose, inline code, bold, a link, two
    /// paragraphs, a heading, a list, a fenced block.
    private static let corpus: [String] = [
        "Готово.",
        "панель у верхньому safe-area стрічки, лічильник оновлюється на кожен символ, Return і хрестик закривають пошук",
        "**⌘F у відкритому діалозі**, як у браузері: панель у `safe-area` стрічки — довів це тестом.",
        "MarkdownUI 2.4.1 не має публічного API підсвітити діапазон символів (`InlineNode` internal), тож markdown-блок можна позначити лише цілком. Довів це читанням чекауту.",
        "дивись [цей звіт](https://mooring.example/report) — там усе довів",
        "перший абзац, у якому є довів\n\nдругий абзац, у якому теж довів, і ще раз довів",
        "## Чого я НЕ довів — і чому\n\nВізуального доказу немає: UI-тести тут не запускаються.",
        "- перший пункт, де довів\n- другий пункт\n- третій пункт, знову довів",
        "Ось код:\n\n```swift\nlet довів = true\nprint(довів)\n```\n\nі текст після нього",
        "Дуже довгий абзац, який точно переноситься на кілька рядків у колонці шириною 680 точок, "
        + "бо в ньому багато слів, і серед них є довів, а далі ще більше слів, щоб перенос стався "
        + "не один раз, а принаймні тричі, і щоб різниця у міжрядковому інтервалі стала помітною.",
    ]

    @MainActor
    private func height(_ markdown: String, find: ProseFind?) -> CGFloat {
        let view = MarkdownProse(text: markdown, find: find)
            .frame(width: MarkdownProse.proseWidth, alignment: .leading)
        let host = NSHostingView(rootView: view)
        host.frame = NSRect(x: 0, y: 0, width: MarkdownProse.proseWidth, height: 10_000)
        host.layoutSubtreeIfNeeded()
        return host.fittingSize.height
    }

    @MainActor
    private func searching(_ markdown: String, _ query: String, active: Int?) -> ProseFind {
        ProseFind(query: query,
                  displayed: ConversationFind.displayedText(ofMarkdown: markdown),
                  entryID: UUID(), blockID: "m1", activeOccurrence: active)
    }

    /// Typing the phrase must not move a single line of the answer.
    @MainActor
    func testMarkingThePhraseDoesNotRelayTheAnswer() {
        for markdown in Self.corpus {
            let plain = height(markdown, find: nil)
            XCTAssertGreaterThan(plain, 0, "nothing was laid out for:\n\(markdown)")

            let marked = height(markdown, find: searching(markdown, "довів", active: 0))
            XCTAssertEqual(marked, plain, accuracy: 1,
                           "the answer changed height when the phrase in it was marked:\n\(markdown)")
        }
    }

    /// And stepping from one result to the next must not move it either — the active mark is a
    /// different colour, not a different size.
    @MainActor
    func testWalkingTheResultsDoesNotRelayTheAnswer() {
        let markdown = "перший абзац, у якому є довів\n\nдругий абзац, де довів, і ще раз довів"
        let first = height(markdown, find: searching(markdown, "довів", active: 0))
        for active in [1, 2, nil] {
            XCTAssertEqual(height(markdown, find: searching(markdown, "довів", active: active)),
                           first, accuracy: 1)
        }
    }

    /// A phrase that is not in the answer leaves it exactly as MarkdownUI drew it, because no
    /// leaf takes over the drawing at all.
    @MainActor
    func testAnAnswerWithoutThePhraseIsNotTouched() {
        for markdown in Self.corpus {
            XCTAssertEqual(height(markdown, find: searching(markdown, "цього тут немає", active: nil)),
                           height(markdown, find: nil), accuracy: 0.01)
        }
    }
}
