import XCTest
import SwiftUI
@testable import Bulava

/// ⌘F has to find what is on screen — every word of it, once each, and nothing that is not there.
///
/// The index is a pure function of the entries the thread draws, so all of this is decided
/// without a window. What it pins down is the handful of ways a find can look finished and be
/// wrong: counting the same answer twice because the prose is stored in two places, counting text
/// the thread never shows, losing the reader's place while an answer is still arriving.
nonisolated final class FindInThisChatTests: XCTestCase {

    private let product = UUID()

    private func entry(_ kind: ConversationEntry.Kind, _ text: String = "",
                       blocks: [ConversationBlock] = [],
                       decision: DecisionRecord? = nil) -> ConversationEntry {
        ConversationEntry(productID: product, kind: kind, text: text, blocks: blocks,
                          decision: decision)
    }

    // MARK: - The index says what the thread draws

    /// `ConversationStore.updateBlocks` writes the same prose into `entry.text` AND into the
    /// block, while `EntryViews` draws the block and ignores the text. Searching both would
    /// double every answer in the count.
    func testProseStoredTwiceIsStillOneResult() {
        let answer = entry(.foreman, "hello world",
                           blocks: [.markdown(id: "m1", "hello world")])
        let found = ConversationFind.places(in: [answer], query: "world")
        XCTAssertEqual(found.count, 1, "the answer is drawn once, so it is found once")
        XCTAssertEqual(found.first?.blockID, "m1", "the result is the block, which is what is drawn")
        XCTAssertEqual(found.first?.mentions, 1)
    }

    // MARK: - The index counts what is on screen, not the markup

    /// The bug this pins down: searching the Markdown SOURCE. `**фраза**` was never found,
    /// because there are four asterisks sitting between the letters the reader can see.
    func testAPhraseInsideBoldIsFound() {
        let answer = entry(.foreman, blocks: [.markdown(id: "m1", "це **справжня фраза** тут")])
        XCTAssertEqual(ConversationFind.places(in: [answer], query: "справжня фраза").count, 1)
    }

    func testAPhraseSpanningInlineCodeAndProseIsFoundAsItReads() {
        let answer = entry(.foreman, blocks: [.markdown(id: "m1", "панель у `safe-area` стрічки")])
        XCTAssertEqual(ConversationFind.places(in: [answer], query: "safe-area стрічки").count, 1)
    }

    /// The other direction: a link's destination is not on screen, so it is not a result. It
    /// could never be shown, and a result nobody can be taken to is a lie in the counter.
    func testALinkDestinationIsNotSearchedButItsWordsAre() {
        let answer = entry(.foreman, blocks: [.markdown(id: "m1", "дивись [цей звіт](https://mooring.example/report)")])
        XCTAssertTrue(ConversationFind.places(in: [answer], query: "mooring").isEmpty,
                      "the reader cannot see the address, so it is not a result")
        XCTAssertEqual(ConversationFind.places(in: [answer], query: "цей звіт").count, 1)
    }

    func testHeadingHashesAndListBulletsAreNotSearched() {
        let answer = entry(.foreman, blocks: [.markdown(id: "m1", "## Доказ\n\n- перший\n- другий")])
        XCTAssertTrue(ConversationFind.places(in: [answer], query: "## Доказ").isEmpty)
        XCTAssertEqual(ConversationFind.places(in: [answer], query: "Доказ").count, 1)
    }

    /// Only one thing is drawn when there are no blocks: the entry's own text.
    func testAnAnswerWithNoBlocksIsFoundByItsOwnText() {
        let found = ConversationFind.places(in: [entry(.foreman, "hello world")], query: "world")
        XCTAssertEqual(found.count, 1)
        XCTAssertNil(found.first?.blockID)
    }

    /// Entry kinds the conversation never puts on screen. `visibleEntries(inChat:)` filters them
    /// out before the index ever sees them; this makes sure the index does not put them back.
    func testKindsTheThreadNeverShowsAreNotSearched() {
        let hidden = [entry(.event, "world of events"),
                      entry(.decision, "a world was decided"),
                      entry(.report, "world report"),
                      entry(.task, "world task")]
        XCTAssertTrue(ConversationFind.places(in: hidden, query: "world").isEmpty)
    }

    /// The other half of the same rule, and the one that needs the model: a login notice the app
    /// hid is not part of the conversation any more, so it must not answer a search either.
    @MainActor
    func testAHiddenNoticeIsNotSearched() {
        let (model, dir) = freshModel(); defer { try? FileManager.default.removeItem(at: dir) }
        let product = UUID()
        model.conversations.appendUser("what happened to the login", productID: product)
        let chat = model.conversations.currentChat(for: product)
        model.conversations.appendForeman("Login expired · Please run /login",
                                          productID: product, chatID: chat.id)
        let notice = model.conversations.entries(inChat: chat.id).last!
        model.conversations.hideNotice(entryID: notice.id)

        let visible = model.visibleEntries(inChat: chat.id)
        XCTAssertTrue(ConversationFind.places(in: visible, query: "login expired").isEmpty,
                      "a notice taken out of the thread must not be findable in it")
        XCTAssertEqual(ConversationFind.places(in: visible, query: "login").count, 1,
                       "his own message still says it, and is still found")
    }

    /// Two chats in one product. ⌘F searches the open one; ⌘K is what searches the rest.
    @MainActor
    func testAnotherChatInTheSameProductIsNotSearched() {
        let (model, dir) = freshModel(); defer { try? FileManager.default.removeItem(at: dir) }
        let product = UUID()
        model.conversations.appendUser("the mooring line", productID: product)
        let first = model.conversations.currentChat(for: product)
        _ = model.conversations.newChat(for: product)
        model.conversations.appendUser("the mooring line again", productID: product)
        let second = model.conversations.currentChat(for: product)

        XCTAssertEqual(
            ConversationFind.places(in: model.visibleEntries(inChat: second.id),
                                    query: "mooring").count, 1)
        XCTAssertNotEqual(first.id, second.id)
    }

    // MARK: - What can be marked, and how finely

    /// His own message is text the app builds itself, so each occurrence is its own result and is
    /// marked exactly where it stands.
    func testEveryOccurrenceInHisOwnMessageIsItsOwnResult() {
        let found = ConversationFind.places(in: [entry(.user, "ship it, ship it, ship it")],
                                            query: "ship")
        XCTAssertEqual(found.count, 3)
        XCTAssertEqual(found.map(\.mark),
                       [.range(occurrence: 0), .range(occurrence: 1), .range(occurrence: 2)])
        XCTAssertEqual(Set(found.map(\.id)).count, 3, "three results need three identities")
    }

    /// The complaint this replaced: an answer that held the phrase was outlined whole, all sixty
    /// lines of it, and Next moved a number and nothing else. Every occurrence in the agent's
    /// prose is now its own result, and the paragraph holding it marks the phrase itself.
    func testEveryOccurrenceInTheAgentsProseIsItsOwnResult() {
        let answer = entry(.foreman, blocks: [.markdown(id: "m1", "ship it, ship it, ship it")])
        let found = ConversationFind.places(in: [answer], query: "ship")
        XCTAssertEqual(found.count, 3)
        XCTAssertEqual(found.map(\.mark),
                       [.range(occurrence: 0), .range(occurrence: 1), .range(occurrence: 2)])
        XCTAssertTrue(found.allSatisfy(\.inProse))
        XCTAssertEqual(found.map(\.mentions), [1, 1, 1], "no result stands for more than itself")
    }

    /// A jump goes to the message first and then to the paragraph, so it lands somewhere real
    /// even if the finer anchor is not in the hierarchy — and lands on the line when it is.
    func testAProseResultCarriesBothItsMessageAndItsParagraphAnchor() {
        let id = UUID()
        let place = FindPlace(entryID: id, blockID: "m1", mark: .range(occurrence: 2),
                              mentions: 1, opensBlock: false, inProse: true)
        XCTAssertEqual(place.blockScrollID, ConversationFind.anchor(entry: id, block: "m1"))
        XCTAssertEqual(place.scrollID,
                       ConversationFind.proseAnchor(entry: id, block: "m1", occurrence: 2))
        XCTAssertNotEqual(place.scrollID, place.blockScrollID)
    }

    /// His own message is not prose: it is a plain `Text`, marked directly, with no paragraph
    /// anchor under it.
    func testHisOwnMessageIsNotTreatedAsProse() {
        let found = ConversationFind.places(in: [entry(.user, "ship it")], query: "ship")
        XCTAssertFalse(found.first?.inProse ?? true)
        XCTAssertEqual(found.first?.scrollID, found.first?.blockScrollID)
    }

    /// The answer Codex gave is folded away by default. Finding it without being able to open it
    /// would be a result nobody can see.
    func testAFoldedCodexAnswerIsFoundAndSaysItMustBeOpened() {
        let consult = ConversationBlock.consult(id: "c1", agent: "Codex",
                                                ask: "is the fence still holding",
                                                answer: "The fence holds. The mooring does not.",
                                                status: .done)
        let found = ConversationFind.places(in: [entry(.foreman, blocks: [consult])],
                                            query: "mooring")
        XCTAssertEqual(found.count, 1)
        XCTAssertTrue(found.first?.opensBlock == true,
                      "arriving at a folded card has to open it")
    }

    /// The question it was asked is on the card's header even while the answer is folded.
    func testTheQuestionPutToCodexIsFindable() {
        let consult = ConversationBlock.consult(id: "c1", agent: "Codex",
                                                ask: "is the fence still holding",
                                                answer: "It holds.", status: .done)
        XCTAssertEqual(ConversationFind.places(in: [entry(.foreman, blocks: [consult])],
                                               query: "fence").count, 1)
    }

    func testAQuestionCardIsSearchedAsTheReaderSeesIt() {
        let decision = DecisionRecord(
            headline: "Which branch should this land on?",
            situation: "The mooring branch is three weeks behind.",
            items: [.init(question: "Rebase or merge?", header: nil, options: [], multiSelect: false)])
        let card = entry(.question, "Which branch should this land on?", decision: decision)

        XCTAssertEqual(ConversationFind.places(in: [card], query: "mooring").count, 1,
                       "the situation is on the card, so it is findable")
        XCTAssertEqual(ConversationFind.places(in: [card], query: "Rebase").count, 1,
                       "so is the question itself")
        XCTAssertEqual(ConversationFind.places(in: [card], query: "branch").first?.mentions, 2)
    }

    /// Step lines, files and galleries are the engine's record of what it did, not what was said.
    /// Counting them would fill the bar with results nobody asked for.
    func testStepLinesAndFilesAreNotSearched() {
        let blocks: [ConversationBlock] = [
            .activity(BlockActivity(toolCallID: "t1", verbKey: "reads %@",
                                    object: "mooring.swift", status: .done)),
            .file(id: "f1", ArtifactRef(runID: "r", relativePath: "mooring.png")),
            .gallery(id: "g1", [ArtifactRef(runID: "r", relativePath: "mooring.png")],
                     caption: "mooring shots"),
        ]
        XCTAssertTrue(ConversationFind.places(in: [entry(.foreman, blocks: blocks)],
                                              query: "mooring").isEmpty)
    }

    func testAnErrorBlockIsMarkedWhereThePhraseStands() {
        let found = ConversationFind.places(
            in: [entry(.foreman, blocks: [.error(id: "e1", "mooring failed, mooring gone")])],
            query: "mooring")
        XCTAssertEqual(found.count, 2)
        XCTAssertEqual(found.first?.mark, .range(occurrence: 0))
    }

    // MARK: - Matching

    func testCaseIsIgnoredAndЁIsStillItsOwnLetter() {
        XCTAssertEqual(ConversationFind.mentions(in: "Привет, ПРИВЕТ", query: "привет"), 2)
        XCTAssertEqual(ConversationFind.mentions(in: "Ёжик", query: "ёж"), 1)
        XCTAssertEqual(ConversationFind.mentions(in: "ёлка", query: "елка"), 0,
                       "е and ё are different letters, and folding them answers another question")
        XCTAssertEqual(ConversationFind.mentions(in: "ЩЕ РАЗ", query: "ще"), 1)
    }

    func testOverlappingTextIsCountedOnceEach() {
        XCTAssertEqual(ConversationFind.mentions(in: "aaaa", query: "aa"), 2)
    }

    func testAnEmptyPhraseFindsNothingRatherThanEverything() {
        XCTAssertTrue(ConversationFind.places(in: [entry(.user, "anything")], query: "").isEmpty)
        XCTAssertTrue(ConversationFind.ranges(in: "anything", query: "").isEmpty)
    }

    // MARK: - Walking the results

    private func session(_ entries: [ConversationEntry], _ query: String) -> FindSession {
        var session = FindSession()
        session.query = query
        session.refresh(ConversationFind.places(in: entries, query: query))
        return session
    }

    func testNextAndPreviousWrapAtBothEnds() {
        var s = session([entry(.user, "one two one two one")], "one")
        XCTAssertEqual(s.places.count, 3)
        XCTAssertEqual(s.activeIndex, 0)
        s.step(1); XCTAssertEqual(s.activeIndex, 1)
        s.step(1); XCTAssertEqual(s.activeIndex, 2)
        s.step(1); XCTAssertEqual(s.activeIndex, 0, "the last result wraps to the first")
        s.step(-1); XCTAssertEqual(s.activeIndex, 2, "and back the other way")
    }

    func testSteppingWithNoResultsDoesNothing() {
        var s = session([entry(.user, "nothing here")], "mooring")
        XCTAssertNil(s.step(1))
        XCTAssertNil(s.activeIndex)
    }

    /// The bug this guards: holding the cursor by index. An answer still streaming in adds
    /// results below the reader, the list grows, and "3 of 7" quietly becomes a different result.
    func testAnAnswerStillArrivingDoesNotMoveTheReaderOffTheirResult() {
        let his = entry(.user, "mooring one, mooring two, mooring three")
        var s = session([his], "mooring")
        s.step(1)
        let standingOn = s.active
        XCTAssertEqual(s.activeIndex, 1)

        let arriving = entry(.foreman, blocks: [.markdown(id: "m1", "the mooring and the mooring")])
        s.refresh(ConversationFind.places(in: [his, arriving], query: "mooring"))

        XCTAssertEqual(s.active, standingOn, "the reader is on the same result they were on")
        XCTAssertEqual(s.activeIndex, 1)
        XCTAssertEqual(s.places.count, 5, "the arriving answer brought two more results")
        XCTAssertEqual(s.mentions, 5)
    }

    /// And the same while the answer holding the reader's own result is the one still growing:
    /// text appended AFTER the occurrence must not renumber it.
    func testTextAppendedAfterTheReadersResultLeavesItsNumberAlone() {
        // The SAME entry, grown — which is what a streaming answer is.
        let id = UUID()
        func answer(_ prose: String) -> ConversationEntry {
            ConversationEntry(id: id, productID: product, kind: .foreman,
                              blocks: [.markdown(id: "m1", prose)])
        }
        var s = session([answer("mooring один")], "mooring")
        let standingOn = s.active
        XCTAssertEqual(standingOn?.mark, .range(occurrence: 0))

        s.refresh(ConversationFind.places(in: [answer("mooring один, і ще mooring два")],
                                          query: "mooring"))
        XCTAssertEqual(s.active, standingOn)
        XCTAssertEqual(s.activeIndex, 0)
        XCTAssertEqual(s.places.count, 2)
    }

    /// And when the result they were standing on is gone, they land somewhere real rather than
    /// nowhere.
    func testARetypedPhraseStartsFromTheFirstResult() {
        var s = session([entry(.user, "mooring")], "mooring")
        s.refresh(ConversationFind.places(in: [entry(.user, "fence")], query: "fence"))
        XCTAssertEqual(s.activeIndex, 0)
    }

    func testClearingLeavesNothingBehind() {
        var s = session([entry(.user, "mooring")], "mooring")
        s.clear()
        XCTAssertTrue(s.query.isEmpty)
        XCTAssertTrue(s.isEmpty)
        XCTAssertNil(s.activeIndex)
    }

    // MARK: - Marking the text

    /// The phrase is marked where it stands, and the one the reader was taken to is marked more
    /// firmly than the rest.
    @MainActor
    func testTheActiveOccurrenceIsMarkedApartFromTheOthers() {
        let id = UUID()
        let mark = FindMark(query: "ship", activeEntryID: id, activeBlockID: nil,
                            activeOccurrence: 1)
        let marked = mark.marked("ship it, ship it", entry: id)
        XCTAssertNotNil(marked)

        let backgrounds = marked!.runs.compactMap(\.backgroundColor)
        XCTAssertEqual(backgrounds.count, 2, "both occurrences are marked")
        XCTAssertEqual(backgrounds.filter { $0 == Palette.accent }.count, 1,
                       "exactly one of them is the one being read")
        XCTAssertEqual(backgrounds.filter { $0 == Palette.accentSoft }.count, 1)
    }

    @MainActor
    func testTextWithoutThePhraseIsLeftAlone() {
        let mark = FindMark(query: "mooring", activeEntryID: UUID())
        XCTAssertNil(mark.marked("nothing to mark here", entry: UUID()))
    }

    @MainActor
    func testAnotherEntrysMatchesAreMarkedButNoneOfThemIsTheActiveOne() {
        let mark = FindMark(query: "ship", activeEntryID: UUID(), activeOccurrence: 0)
        let marked = mark.marked("ship it", entry: UUID())
        XCTAssertEqual(marked?.runs.compactMap(\.backgroundColor), [Palette.accentSoft])
    }

    // MARK: - The phrase, marked where it stands inside the agent's prose

    /// The whole point of this pass. Before it, an answer holding the phrase was outlined from
    /// its first line to its last, and the reader had to find the phrase by eye all over again.
    @MainActor
    func testTheAgentsProseMarksThePhraseAndNothingElse() throws {
        let paragraph = "панель у safe-area стрічки — довів це тестом"
        let marked = try XCTUnwrap(ProseHighlight.attributed(markdown: paragraph, leaf: .paragraph))
        let painted = ProseHighlight.marking(marked, query: "довів", activeOccurrence: 0)

        XCTAssertEqual(String(painted.characters), paragraph,
                       "not one character of the paragraph may change")
        let coloured = painted.runs.filter { $0.backgroundColor != nil }
        XCTAssertEqual(coloured.count, 1, "exactly the phrase carries a background")
        XCTAssertEqual(coloured.map { String(painted[$0.range].characters) }, ["довів"])
        XCTAssertEqual(coloured.first?.backgroundColor, Palette.accent)
    }

    /// Safari marks every occurrence and the one you are on more strongly. A one-letter query is
    /// the case that used to paint half the thread: many soft marks are right, two strong ones
    /// never are.
    @MainActor
    func testOnlyOneOccurrenceIsTheOneBeingRead() throws {
        let marked = try XCTUnwrap(ProseHighlight.attributed(markdown: "а, а, а, а", leaf: .paragraph))
        let painted = ProseHighlight.marking(marked, query: "а", activeOccurrence: 2)

        let backgrounds = painted.runs.compactMap(\.backgroundColor)
        XCTAssertEqual(backgrounds.filter { $0 == Palette.accent }.count, 1)
        XCTAssertEqual(backgrounds.filter { $0 == Palette.accentSoft }.count, 3)
    }

    @MainActor
    func testNoneIsTheActiveOneWhenTheReaderIsStandingElsewhere() throws {
        let marked = try XCTUnwrap(ProseHighlight.attributed(markdown: "довів, довів", leaf: .paragraph))
        let painted = ProseHighlight.marking(marked, query: "довів", activeOccurrence: nil)
        XCTAssertTrue(painted.runs.compactMap(\.backgroundColor).allSatisfy { $0 == Palette.accentSoft })
    }

    /// Redrawing the paragraph must not cost it its formatting — otherwise searching a word
    /// silently unbolds the sentence it is in.
    @MainActor
    func testRedrawingAParagraphKeepsItsBoldCodeAndLinks() throws {
        let source = "**жирне**, `код` і [посилання](https://x.dev) разом"
        let marked = try XCTUnwrap(ProseHighlight.attributed(markdown: source, leaf: .paragraph))

        XCTAssertEqual(String(marked.characters), "жирне, код і посилання разом",
                       "the syntax goes, the words stay")
        func run(containing needle: String) -> AttributedString.Runs.Element? {
            marked.runs.first { String(marked[$0.range].characters).contains(needle) }
        }
        XCTAssertEqual(run(containing: "жирне")?.font, ProseStyle.body.weight(.semibold))
        XCTAssertEqual(run(containing: "код")?.font, ProseStyle.inlineCode)
        XCTAssertEqual(run(containing: "код")?.backgroundColor, Palette.panelMuted)
        XCTAssertEqual(run(containing: "посилання")?.link?.absoluteString, "https://x.dev")
        XCTAssertEqual(run(containing: "посилання")?.foregroundColor, Palette.accent)
    }

    @MainActor
    func testAHeadingIsRedrawnWithoutItsHashes() throws {
        let marked = try XCTUnwrap(
            ProseHighlight.attributed(markdown: "## Чого я НЕ довів", leaf: .heading(level: 2)))
        XCTAssertEqual(String(marked.characters), "Чого я НЕ довів")
    }

    @MainActor
    func testACodeBlockIsMarkedVerbatim() throws {
        let code = "let довів = true\nprint(довів)"
        let marked = try XCTUnwrap(ProseHighlight.attributed(markdown: code, leaf: .codeBlock))
        XCTAssertEqual(String(marked.characters), code, "code is not markdown and is not reparsed")
    }

    /// A paragraph carrying an inline image cannot be redrawn as text — the image would simply
    /// vanish. It keeps MarkdownUI's own drawing and marks nothing, which is the honest answer.
    @MainActor
    func testAParagraphWithAnInlineImageIsLeftToTheLibrary() {
        XCTAssertNil(ProseHighlight.attributed(markdown: "перед ![shot](a.png) після довів",
                                               leaf: .paragraph))
    }

    // MARK: - Which of the answer's results a paragraph is holding

    private func prose(_ markdown: String, query: String, active: Int? = nil) -> ProseFind {
        ProseFind(query: query,
                  displayed: ConversationFind.displayedText(ofMarkdown: markdown),
                  entryID: UUID(), blockID: "m1", activeOccurrence: active)
    }

    func testAParagraphKnowsHowManyResultsCameBeforeIt() {
        let answer = """
        довів перший раз

        нічого тут

        довів другий раз, і довів третій
        """
        let find = prose(answer, query: "довів")
        XCTAssertEqual(find.occurrencesBefore(leaf: "довів перший раз"), 0)
        XCTAssertEqual(find.occurrencesBefore(leaf: "довів другий раз, і довів третій"), 1)
    }

    /// Two paragraphs word for word the same, with a different number of results before each:
    /// this paragraph cannot tell which of them it is, and says so rather than guessing. It then
    /// marks its matches softly and claims none of them is the one being read.
    func testAParagraphThatCannotPlaceItselfSaysSo() {
        let answer = """
        довів

        те саме речення

        довів

        те саме речення
        """
        XCTAssertNil(prose(answer, query: "довів").occurrencesBefore(leaf: "те саме речення"))
    }

    /// The same paragraph twice with nothing between them that matches IS placeable — both
    /// copies stand after the same number of results, so the answer is unambiguous.
    func testRepeatedParagraphsWithNoResultsBetweenThemStillPlaceThemselves() {
        let answer = "те саме речення\n\nте саме речення"
        XCTAssertEqual(prose(answer, query: "довів").occurrencesBefore(leaf: "те саме речення"), 0)
    }

    // MARK: - A card Find opened, and the reader closing it again

    /// Find opening a folded card is a loan. The reader's own state is never written to, so
    /// closing the search folds every card back the way they had it.
    func testACardFindOpenedFoldsBackWhenTheSearchCloses() {
        var fold = FoldedByDefault()
        XCTAssertFalse(fold.showing(findOpened: false))
        XCTAssertTrue(fold.showing(findOpened: true), "Find takes it open")
        XCTAssertFalse(fold.showing(findOpened: false), "and the search closing hands it back")
    }

    /// The bug this pins down: with the card open on Find's account, its own Hide button said
    /// Hide, set the reader's flag, and left the card open — pressing it did nothing, twice.
    func testTheReaderCanFoldACardFindIsHoldingOpen() {
        var fold = FoldedByDefault()
        fold.toggle(findOpened: true)
        XCTAssertFalse(fold.showing(findOpened: true), "Hide has to hide it")

        // And back open again, still while Find is standing on it.
        fold.toggle(findOpened: true)
        XCTAssertTrue(fold.showing(findOpened: true))
    }

    /// Having shut it once does not make it stay shut for good: the next time a find jump lands
    /// here, the card opens again, because that is the whole point of jumping to it.
    func testFindComingBackOpensACardTheReaderHadShut() {
        var fold = FoldedByDefault()
        fold.toggle(findOpened: true)
        XCTAssertFalse(fold.showing(findOpened: true))

        fold.findArrived()
        XCTAssertTrue(fold.showing(findOpened: true))
    }

    func testAReaderWhoOpenedACardHimselfKeepsItOpenAfterTheSearch() {
        var fold = FoldedByDefault()
        fold.toggle(findOpened: false)
        XCTAssertTrue(fold.showing(findOpened: false))
        XCTAssertTrue(fold.showing(findOpened: true))
        XCTAssertTrue(fold.showing(findOpened: false), "his own choice outlives the search")
    }

    // MARK: - Helpers

    @MainActor private func freshModel() -> (AppModel, URL) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("bulava-find-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        setenv("BULAVA_STATE_DIR", dir.path, 1)
        return (AppModel(), dir)
    }
}

// MARK: - Its words, in every language the app speaks

/// Bulava is used in English, Russian and Ukrainian. A find bar that says «Not found» to a
/// Ukrainian-speaking reader is half a feature, and the catalogue is the only place that can be
/// checked without opening a window: this reads the COMPILED bundle, not the source file.
nonisolated final class FindSpeaksEveryLanguageTests: XCTestCase {

    private static let ours = [
        "Find…", "Find Next", "Find Previous", "Go to…",
        "Go to a product, chat or report (⌘K)",
        "Find in this chat…", "Not found",
        "Previous result (⇧⌘G)", "Next result (⌘G)", "Close the search (esc)",
        "Places this phrase appears in, in the order they were said",
        "%lld mentions",
    ]

    @MainActor
    func testEveryStringTheFindBarSaysIsTranslated() throws {
        let app = Bundle(for: AppModel.self)
        for code in ["ru", "uk"] {
            let path = try XCTUnwrap(app.path(forResource: code, ofType: "lproj"),
                                     "the app carries no \(code) bundle")
            let bundle = try XCTUnwrap(Bundle(path: path))
            for key in Self.ours {
                let translated = bundle.localizedString(forKey: key, value: "·MISSING·", table: nil)
                XCTAssertNotEqual(translated, "·MISSING·", "\(code) has no “\(key)”")
                XCTAssertNotEqual(translated, key,
                                  "\(code) left “\(key)” in English")
            }
        }
    }

    /// The count has to decline properly in Russian and Ukrainian — «1 згадка», «2 згадки»,
    /// «5 згадок» — and a single `%lld mentions` with no plural rules would say «5 згадка».
    @MainActor
    func testTheMentionCountDeclines() throws {
        for code in ["ru", "uk"] {
            let path = try XCTUnwrap(Bundle(for: AppModel.self).path(forResource: code,
                                                                     ofType: "lproj"))
            let bundle = try XCTUnwrap(Bundle(path: path))
            let format = bundle.localizedString(forKey: "%lld mentions", value: nil, table: nil)
            let locale = Locale(identifier: code)
            let said = [1, 2, 5].map { String(format: format, locale: locale, $0) }
            XCTAssertEqual(Set(said).count, 3, "\(code) says the same thing for 1, 2 and 5: \(said)")
        }
    }
}
