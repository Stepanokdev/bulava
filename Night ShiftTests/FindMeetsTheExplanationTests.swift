import XCTest
@testable import Bulava

/// ⌘F has to find the explanation too.
///
/// The two features arrived separately and neither could see this: Find threads a `find:` through
/// every piece of prose the thread draws, and the explanation panel is prose the thread draws —
/// but it is drawn from a store of its own, beside the conversation rather than in it, so the
/// index walked straight past it. `MarkdownProse.find` defaults to nil, so the panel compiled
/// perfectly while reporting no match for words the reader was looking straight at.
nonisolated final class FindMeetsTheExplanationTests: XCTestCase {

    private let product = UUID()

    private func turn(_ text: String, blocks: [ConversationBlock] = []) -> ConversationEntry {
        ConversationEntry(productID: product, kind: .foreman, text: text, blocks: blocks)
    }

    // MARK: - The words in the panel are results

    func testAPhraseOnlyInTheExplanationIsFound() {
        let answer = turn("зібрав і виклав")
        let found = ConversationFind.places(in: [answer], query: "запобіжник",
                                            explained: [answer.id: "тут стоїть запобіжник"])
        XCTAssertEqual(found.count, 1, "the reader is looking straight at the word")
        XCTAssertEqual(found.first?.blockID, ConversationFind.explainBlock)
        XCTAssertEqual(found.first?.entryID, answer.id)
    }

    /// Without an explanation there is nothing extra to find, and the index must not invent one.
    func testAnUnexplainedTurnIsUnchanged() {
        let answer = turn("зібрав і виклав")
        XCTAssertTrue(ConversationFind.places(in: [answer], query: "запобіжник").isEmpty)
    }

    /// One result for the panel, not one per paragraph: the reader can fold it away, and a jump
    /// has to land on something that is on screen. The count still says how many times the phrase
    /// is in there.
    func testThePanelIsOneResultThatCountsEveryMention() {
        let answer = turn("зібрав і виклав")
        let found = ConversationFind.places(in: [answer], query: "крок",
                                            explained: [answer.id: "перший крок, далі крок другий"])
        XCTAssertEqual(found.count, 1)
        XCTAssertEqual(found.first?.mentions, 2)
        XCTAssertEqual(found.first?.mark, .whole)
    }

    /// Folded away, it still has to be reachable — so the jump opens it, the way it opens a
    /// consultation.
    func testAFoldedPanelIsOpenedByTheJump() {
        let answer = turn("зібрав і виклав")
        let found = ConversationFind.places(in: [answer], query: "запобіжник",
                                            explained: [answer.id: "тут стоїть запобіжник"])
        XCTAssertEqual(found.first?.opensBlock, true)
    }

    // MARK: - Reading order

    /// The panel is drawn under the answer, so it is found after it. Out of order, ⌘G walks the
    /// thread backwards through a turn.
    func testTheExplanationIsFoundAfterTheAnswerItExplains() {
        let answer = turn("", blocks: [.markdown(id: "m1", "знайшов запобіжник у конфізі")])
        let found = ConversationFind.places(in: [answer], query: "запобіжник",
                                            explained: [answer.id: "запобіжник — це те, що спиняє"])
        XCTAssertEqual(found.map(\.blockID), ["m1", ConversationFind.explainBlock])
    }

    func testEachTurnKeepsItsOwnExplanation() {
        let first = turn("", blocks: [.markdown(id: "a", "нічого тут")])
        let second = turn("", blocks: [.markdown(id: "b", "і тут нічого")])
        let found = ConversationFind.places(in: [first, second], query: "запобіжник",
                                            explained: [second.id: "запобіжник"])
        XCTAssertEqual(found.count, 1)
        XCTAssertEqual(found.first?.entryID, second.id)
    }

    /// Anchors are keyed by entry AND block, so two explained turns cannot land on each other.
    func testTwoExplainedTurnsHaveDifferentAnchors() {
        let first = turn("один")
        let second = turn("два")
        let found = ConversationFind.places(in: [first, second], query: "запобіжник",
                                            explained: [first.id: "запобіжник",
                                                        second.id: "запобіжник"])
        XCTAssertEqual(found.count, 2)
        XCTAssertEqual(Set(found.map(\.id)).count, 2)
    }

    // MARK: - What the panel puts on screen

    /// The same rule as everywhere else in Find: the words as they are drawn, not the markup. The
    /// walk-through is under the short explanation, so it comes second.
    func testTheWalkThroughIsSearchedTogetherWithTheShortExplanation() throws {
        let text = ConversationFind.explainedText(brief: "коротко: **запобіжник**",
                                                  stepByStep: "1. поставив запобіжник")
        XCTAssertEqual(ConversationFind.mentions(in: text, query: "запобіжник"), 2)
        XCTAssertFalse(text.contains("**"), "asterisks are not on screen, so they are not searched")
        let short = try XCTUnwrap(text.range(of: "коротко"))
        let steps = try XCTUnwrap(text.range(of: "поставив"))
        XCTAssertTrue(short.lowerBound < steps.lowerBound,
                      "the walk-through is drawn under the short explanation")
    }

    func testAnExplanationAskedForButNotYetWrittenIsNotAResult() {
        XCTAssertTrue(ConversationFind.explainedText(brief: nil, stepByStep: nil).isEmpty)
    }

    // MARK: - The panel opens as it always did

    /// It is on screen because somebody pressed a button asking for it, so it starts open — and
    /// Find's loan still works the same way on top of that.
    func testTheExplanationStartsOpenAndStillFoldsBothWays() {
        var fold = FoldedByDefault(expanded: true)
        XCTAssertTrue(fold.showing(findOpened: false), "asked for, so it is open")

        fold.toggle(findOpened: false)
        XCTAssertFalse(fold.showing(findOpened: false), "and the reader can fold it away")

        XCTAssertTrue(fold.showing(findOpened: true), "a find jump opens it again")
        fold.toggle(findOpened: true)
        XCTAssertFalse(fold.showing(findOpened: true), "and Hide still hides it while Find is here")

        fold.findArrived()
        XCTAssertTrue(fold.showing(findOpened: true), "the next jump opens it once more")
    }
}
