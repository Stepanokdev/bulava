import XCTest
@testable import Bulava

/// Dev Learning Mode: the action that explains a finished result.
///
/// The claims worth pinning down are the ones a plausible wrong implementation gets wrong. That it
/// costs nothing until somebody presses it. That the button is not offered on work that has not
/// finished — and that "not finished" is read from what the feed wrote down rather than from
/// whether the chat looks busy, which is wrong in both directions. That the material it is written
/// from is the WORK, not only the prose the reader has already failed to understand. That a
/// cached answer is not handed back as current after the result, the profile or the language has
/// moved on. And that a setting nobody has written yet decodes to off with no profile, rather than
/// being lost on every launch by a hand-written decoder.
nonisolated final class ExplainTheResultTests: XCTestCase {

    // MARK: - The setting survives

    /// The decoder in `AppSettings` is written by hand, so a property with only a declaration
    /// default is silently reset on every launch. This is the test that catches that.
    func testSettingsWrittenBeforeThisFeatureDecodeToOffWithNoProfile() throws {
        let old = #"{"stateDirPath":"/tmp/x","pollSeconds":4}"#
        let settings = try JSONDecoder().decode(AppSettings.self, from: Data(old.utf8))

        XCTAssertFalse(settings.devLearningEnabled, "a mode nobody asked for must not arrive on")
        XCTAssertEqual(settings.learningProfile, "")
    }

    func testTheModeAndTheProfileSurviveAWriteAndARead() throws {
        var settings = AppSettings.fallback
        settings.devLearningEnabled = true
        settings.learningProfile = "iOS / Swift, little backend"

        let round = try JSONDecoder().decode(AppSettings.self,
                                             from: try JSONEncoder().encode(settings))
        XCTAssertTrue(round.devLearningEnabled)
        XCTAssertEqual(round.learningProfile, "iOS / Swift, little backend")
    }

    func testHealingDoesNotDisturbTheMode() {
        var settings = AppSettings.fallback
        settings.stateDirPath = "/private/tmp/gone-\(UUID().uuidString)"
        settings.devLearningEnabled = true
        settings.learningProfile = "designer"

        let healed = settings.healed()
        XCTAssertTrue(healed.devLearningEnabled)
        XCTAssertEqual(healed.learningProfile, "designer")
    }

    // MARK: - The profile

    func testWhitespaceIsNotAProfile() {
        XCTAssertEqual(LearningProfile.normalized("   \n\t "), "")
        XCTAssertFalse(LearningProfile.isGiven(" \n "))
    }

    func testAProfileIsOneLineAndBounded() {
        XCTAssertEqual(LearningProfile.normalized("  iOS\n  developer,\tSwift "),
                       "iOS developer, Swift")
        let long = String(repeating: "a", count: LearningProfile.limit + 500)
        XCTAssertEqual(LearningProfile.normalized(long).count, LearningProfile.limit)
    }

    // MARK: - When the button appears

    private func turn(blocks: [ConversationBlock], finished: Bool?,
                      kind: ConversationEntry.Kind = .foreman,
                      hidden: Bool? = nil) -> ConversationEntry {
        ConversationEntry(productID: UUID(), kind: kind, text: "", blocks: blocks,
                          hiddenNotice: hidden, turnFinished: finished)
    }

    private var oneAnswer: [ConversationBlock] { [.markdown(id: "m", "Done. Two files changed.")] }

    func testAnUnfinishedTurnIsNotOffered() {
        XCTAssertFalse(ExplainAvailability.isExplainable(turn: turn(blocks: oneAnswer,
                                                                   finished: false)))
    }

    /// The feed has never said anything about this entry. Unknown is not finished.
    func testATurnNothingHasRuledOnIsNotOffered() {
        XCTAssertFalse(ExplainAvailability.isExplainable(turn: turn(blocks: oneAnswer,
                                                                   finished: nil)))
    }

    func testAFinishedAnswerIsOffered() {
        XCTAssertTrue(ExplainAvailability.isExplainable(turn: turn(blocks: oneAnswer,
                                                                  finished: true)))
    }

    /// His own message, and Codex's, are not Bulava explaining its own work.
    func testHisOwnMessageAndCodexAreNotOffered() {
        XCTAssertFalse(ExplainAvailability.isExplainable(
            turn: turn(blocks: oneAnswer, finished: true, kind: .user)))
        XCTAssertFalse(ExplainAvailability.isExplainable(
            turn: turn(blocks: oneAnswer, finished: true, kind: .codex)))
    }

    /// The CLI's "sign in again" notice is hidden from the conversation for good. Explaining it
    /// would resurrect it under a heading.
    func testTheHiddenSignInNoticeIsNotOffered() {
        XCTAssertFalse(ExplainAvailability.isExplainable(
            turn: turn(blocks: oneAnswer, finished: true, hidden: true)))
    }

    func testOnlyARunThatHasComeToRestIsOffered() {
        for settled in [WorkState.reportReady, .partial, .stopped, .failed, .done] {
            XCTAssertTrue(ExplainAvailability.isExplainable(state: settled),
                          "\(settled) is an outcome and can be explained")
        }
        for open in [WorkState.planned, .running, .paused, .needsAnswer] {
            XCTAssertFalse(ExplainAvailability.isExplainable(state: open),
                           "\(open) has no result yet — explaining it would answer for work "
                           + "that has not happened")
        }
    }

    // MARK: - What it is written from

    private func activity(_ verb: String, _ object: String?,
                          _ status: BlockActivity.Status = .done) -> ConversationBlock {
        .activity(BlockActivity(toolCallID: UUID().uuidString, verbKey: verb,
                                object: object, status: status))
    }

    func testTheMaterialIsTheWorkAndNotOnlyPreviouslyUnreadProse() {
        let entry = turn(blocks: [
            .markdown(id: "m", "I moved the token refresh into the middleware."),
            activity("edits %@", "middleware.py"),
            activity("runs %@", "pytest -q"),
            .error(id: "e", "One test still fails: test_refresh_rotates"),
        ], finished: true)

        let context = ExplainContext.forTurn(entry)
        XCTAssertTrue(context.hasMaterial)
        XCTAssertTrue(context.prose.contains("middleware"))
        XCTAssertTrue(context.steps.contains("edits middleware.py"),
                      "the file names are the part he could not read: \(context.steps)")
        XCTAssertTrue(context.steps.contains("runs pytest -q"))
        XCTAssertEqual(context.problems.count, 1)
    }

    /// The case the whole feature exists for: a turn that said almost nothing and did a lot.
    func testATurnOfPureToolCallsStillHasSomethingToExplain() {
        let entry = turn(blocks: [activity("edits %@", "AppSettings.swift")], finished: true)
        XCTAssertTrue(ExplainContext.forTurn(entry).hasMaterial)
    }

    func testAnEmptyTurnHasNothingToExplain() {
        XCTAssertFalse(ExplainContext.forTurn(turn(blocks: [], finished: true)).hasMaterial)
    }

    func testAFailedStepSaysSo() {
        let line = ExplainContext.line(for: BlockActivity(toolCallID: "1", verbKey: "runs %@",
                                                          object: "swift build", status: .failed))
        XCTAssertEqual(line, "runs swift build (it failed)")
    }

    func testAVerbWithNoObjectIsStillASentence() {
        XCTAssertEqual(ExplainContext.line(for: BlockActivity(toolCallID: "1",
                                                              verbKey: "working")), "working")
    }

    // MARK: - The budget

    func testRepeatedStepsCollapseAndTheRestAreCountedNotDropped() {
        let repeated = Array(repeating: "reads Theme.swift", count: 30)
        let distinct = (0..<(ExplainContext.stepLimit + 10)).map { "edits file\($0).swift" }

        let (kept, dropped) = ExplainContext.fit(steps: repeated + distinct)
        XCTAssertEqual(kept.count, ExplainContext.stepLimit)
        XCTAssertEqual(kept.first, "reads Theme.swift", "the first of a repeat is kept, in order")
        XCTAssertEqual(kept.filter { $0 == "reads Theme.swift" }.count, 1,
                       "twenty-nine more of the same tell the reader nothing")
        XCTAssertEqual(dropped, 1 + distinct.count - ExplainContext.stepLimit)
    }

    func testLongProseLosesItsMiddleAndSaysSo() {
        let head = String(repeating: "H", count: 4_000)
        let tail = String(repeating: "T", count: 4_000)
        let (text, elided) = ExplainContext.fit(prose: head + tail)

        XCTAssertTrue(elided)
        XCTAssertTrue(text.hasPrefix("HHH"), "the opening says what it set out to do")
        XCTAssertTrue(text.hasSuffix("TTT"), "the ending says how it went")
        XCTAssertLessThan(text.count, ExplainContext.proseBudget + 200)
    }

    func testTheSameTurnAlwaysProducesTheSamePrompt() {
        let entry = turn(blocks: [.markdown(id: "m", String(repeating: "x ", count: 8_000)),
                                  activity("edits %@", "a.swift")], finished: true)
        let a = ExplainPrompt.build(context: ExplainContext.forTurn(entry), profile: "iOS",
                                    languageName: "Ukrainian", depth: .brief)
        let b = ExplainPrompt.build(context: ExplainContext.forTurn(entry), profile: "iOS",
                                    languageName: "Ukrainian", depth: .brief)
        XCTAssertEqual(a, b, "truncation has to be deterministic or nothing here is testable")
    }

    // MARK: - The request

    private func prompt(profile: String, depth: ExplainDepth = .brief,
                        language: String = "Ukrainian") -> String {
        let entry = turn(blocks: [.markdown(id: "m", "Rewired the settings decoder."),
                                  activity("edits %@", "AppSettings.swift")], finished: true)
        return ExplainPrompt.build(context: ExplainContext.forTurn(entry), profile: profile,
                                   languageName: language, depth: depth)
    }

    func testWithNoProfileItAsksForPlainWordsAndNamesNoRole() {
        let text = prompt(profile: "")
        XCTAssertTrue(text.contains("nothing is known"))
        XCTAssertTrue(text.contains("plain words"))
        XCTAssertFalse(text.contains("in their own words"),
                       "there is no profile to quote, so nothing may be quoted")
    }

    func testWithAProfileItIsQuotedWordForWord() {
        let text = prompt(profile: "  iOS developer,\nSwift  ")
        XCTAssertTrue(text.contains("«iOS developer, Swift»"),
                      "his own words, normalised but not paraphrased")
    }

    func testThePromptCarriesTheWorkAndTheLanguage() {
        let text = prompt(profile: "iOS")
        XCTAssertTrue(text.contains("AppSettings.swift"))
        XCTAssertTrue(text.contains("Write the answer in Ukrainian."))
    }

    func testTheTwoDepthsAskForDifferentThings() {
        XCTAssertTrue(prompt(profile: "", depth: .brief).contains("What was done"))
        XCTAssertTrue(prompt(profile: "", depth: .stepByStep).contains("Worth knowing next time"))
        XCTAssertNotEqual(prompt(profile: "", depth: .brief),
                          prompt(profile: "", depth: .stepByStep))
    }

    /// An explanation must never be able to claim the step list it was shown is the whole of the
    /// work, because past the budget it is not.
    func testACutStepListSaysHowManyAreMissing() {
        var blocks: [ConversationBlock] = [.markdown(id: "m", "Long night.")]
        for i in 0..<(ExplainContext.stepLimit + 7) {
            blocks.append(activity("edits %@", "file\(i).swift"))
        }
        let text = ExplainPrompt.build(context: ExplainContext.forTurn(turn(blocks: blocks,
                                                                           finished: true)),
                                       profile: "", languageName: "English", depth: .brief)
        XCTAssertTrue(text.contains("7 further steps"), text.suffix(400).description)
    }

    func testItIsToldNotToCallUnfinishedWorkFinished() {
        XCTAssertTrue(prompt(profile: "").contains("Do not call the work finished"))
    }

    // MARK: - The language it is written in

    func testAChosenLanguageIsUsed() {
        XCTAssertEqual(ExplainPrompt.languageName(interface: .uk, displayedCode: "en"), "Ukrainian")
        XCTAssertEqual(ExplainPrompt.languageName(interface: .ru, displayedCode: "en"), "Russian")
    }

    /// `AppLanguage.reportLanguageName` answers "English" for System, which is right for a report
    /// and wrong inside a Ukrainian-looking window.
    func testSystemFollowsTheLocalisationThatActuallyLoaded() {
        XCTAssertEqual(ExplainPrompt.languageName(interface: .system, displayedCode: "uk"),
                       "Ukrainian")
        XCTAssertEqual(ExplainPrompt.languageName(interface: .system, displayedCode: "en-US"),
                       "English")
    }

    func testSystemIsNeverPassedOnAsALanguage() {
        for code in ["", "system", "zz", "fr-CA"] {
            let name = ExplainPrompt.languageName(interface: .system, displayedCode: code)
            XCTAssertFalse(name.lowercased().contains("system"), "got «\(name)» for «\(code)»")
            XCTAssertFalse(name.isEmpty)
        }
    }

    // MARK: - A cached answer is not silently stale

    private func fingerprint(_ entry: ConversationEntry, profile: String = "",
                             language: String = "English",
                             depth: ExplainDepth = .brief) -> String {
        ExplainPrompt.fingerprint(context: ExplainContext.forTurn(entry), profile: profile,
                                  languageName: language, depth: depth)
    }

    func testTheSameRequestOnTheSameResultFingerprintsTheSame() {
        let entry = turn(blocks: oneAnswer, finished: true)
        XCTAssertEqual(fingerprint(entry), fingerprint(entry))
    }

    /// The defect this catches: a generic explanation handed back to somebody who has since
    /// written down who they are, with the button reading "up to date".
    func testWritingDownWhoYouAreMakesTheOldExplanationStale() {
        let entry = turn(blocks: oneAnswer, finished: true)
        XCTAssertNotEqual(fingerprint(entry, profile: ""), fingerprint(entry, profile: "iOS"))
    }

    func testChangingTheResultTheLanguageOrTheDepthMakesItStale() {
        let before = turn(blocks: oneAnswer, finished: true)
        let after = turn(blocks: oneAnswer + [activity("edits %@", "later.swift")], finished: true)

        XCTAssertNotEqual(fingerprint(before), fingerprint(after))
        XCTAssertNotEqual(fingerprint(before), fingerprint(before, language: "Ukrainian"))
        XCTAssertNotEqual(fingerprint(before), fingerprint(before, depth: .stepByStep))
    }

    // MARK: - Where explanations are kept

    @MainActor
    private func store() -> ExplanationStore {
        ExplanationStore(fileURL: URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("bulava-explanations-\(UUID().uuidString).json"))
    }

    private func made(_ text: String, at: Date = Date()) -> Explanation {
        Explanation(text: text, profile: "", languageName: "English", fingerprint: "f", at: at)
    }

    /// Keyed by record and depth. Keyed by chat, explaining one answer would lock out every other
    /// answer in the conversation and the panel would open under the wrong one.
    @MainActor
    func testTwoRecordsAndTwoDepthsAreIndependent() {
        let shop = store()
        let a = ExplainAnchor.turn(UUID())
        let b = ExplainAnchor.task(UUID())

        shop.put(made("A short"), for: a, depth: .brief)
        shop.put(made("A long"), for: a, depth: .stepByStep)
        shop.put(made("B short"), for: b, depth: .brief)

        XCTAssertEqual(shop.explanation(a, .brief)?.text, "A short")
        XCTAssertEqual(shop.explanation(a, .stepByStep)?.text, "A long")
        XCTAssertEqual(shop.explanation(b, .brief)?.text, "B short")
        XCTAssertNil(shop.explanation(b, .stepByStep))
    }

    /// Paid for once. It has to still be there tomorrow morning.
    @MainActor
    func testAnExplanationIsStillThereAfterARelaunch() {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("bulava-explanations-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let anchor = ExplainAnchor.turn(UUID())

        ExplanationStore(fileURL: url).put(made("kept"), for: anchor, depth: .brief)

        XCTAssertEqual(ExplanationStore(fileURL: url).explanation(anchor, .brief)?.text, "kept")
    }

    func testTheOldestGoFirstAndAlwaysTheSameOnes() {
        let now = Date()
        var all: [String: Explanation] = [:]
        for i in 0..<20 {
            all["k\(i)"] = made("e\(i)", at: now.addingTimeInterval(Double(i)))
        }
        let kept = ExplanationStore.pruned(all, capacity: 5)

        XCTAssertEqual(kept.count, 5)
        XCTAssertEqual(Set(kept.keys), Set(["k15", "k16", "k17", "k18", "k19"]))
        XCTAssertEqual(ExplanationStore.pruned(all, capacity: 5).keys.sorted(),
                       kept.keys.sorted(), "which ones survive cannot depend on dictionary order")
    }

    // MARK: - Finality is recorded, not guessed

    @MainActor
    private func conversations() -> (ConversationStore, URL, URL) {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("bulava-conv-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let entries = root.appendingPathComponent("conversations.json")
        let chats = root.appendingPathComponent("chats.json")
        return (ConversationStore(fileURL: entries, chatsURL: chats), entries, chats)
    }

    @MainActor
    func testTheFeedCanSetFinalityAndTakeItBack() {
        let (store, _, _) = conversations()
        let id = store.beginForemanTurn(productID: UUID())

        XCTAssertNil(store.entry(id: id)?.turnFinished, "nothing has ruled on it yet")
        store.setTurnFinished(entryID: id, true)
        XCTAssertEqual(store.entry(id: id)?.turnFinished, true)
        // A segment the fold decides to keep writing is not finished any more, and the action has
        // to disappear again while it is being written.
        store.setTurnFinished(entryID: id, false)
        XCTAssertEqual(store.entry(id: id)?.turnFinished, false)
    }

    /// Every answer in the history predates this field. At launch nothing is streaming, so they
    /// are finished — otherwise the button would be missing from everything ever said.
    @MainActor
    func testAnswersFromBeforeThisFeatureAreSettledAtLaunch() throws {
        let (store, entries, chats) = conversations()
        defer { try? FileManager.default.removeItem(at: entries.deletingLastPathComponent()) }
        let productID = UUID()
        let old = store.beginForemanTurn(productID: productID)
        store.appendUser("what did you do?", productID: productID)
        store.updateBlocks(entryID: old, blocks: [.markdown(id: "m", "Two files.")],
                           text: "Two files.", persist: true)

        // Strip the field, the way a file written by the previous build has it.
        var raw = try JSONSerialization.jsonObject(with: Data(contentsOf: entries)) as! [[String: Any]]
        for i in raw.indices { raw[i].removeValue(forKey: "turnFinished") }
        try JSONSerialization.data(withJSONObject: raw).write(to: entries)

        let relaunched = ConversationStore(fileURL: entries, chatsURL: chats)
        XCTAssertEqual(relaunched.entry(id: old)?.turnFinished, true)
        XCTAssertNil(relaunched.entries.first { $0.kind == .user }?.turnFinished,
                     "his own messages are not turns and are left alone")
    }

    // MARK: - A night task, described honestly

    private func manifest(_ json: String) -> ReportManifest {
        try! JSONDecoder().decode(ReportManifest.self, from: Data(json.utf8))
    }

    func testAPartlyDoneRunIsNotDressedUpAsAFinishedOne() {
        let context = ExplainContext.forTask(
            title: "Move the refresh into middleware",
            stateLabel: WorkState.partial.labelKey,
            outcome: "The rotation test still fails on CI.",
            manifest: manifest(#"""
            {"format":"notes","summary":"Most of it is in.",
             "sections":[{"title":"Token rotation","status":"not_closed","body":"Left as it was."}],
             "attention":["The CI job is red."]}
            """#),
            turns: [turn(blocks: [activity("edits %@", "middleware.py")], finished: true)])

        XCTAssertTrue(context.hasMaterial)
        XCTAssertTrue(context.headline.contains("Partly done"),
                      "which state it ended in is part of the request: \(context.headline)")
        XCTAssertTrue(context.prose.contains("not done"),
                      "a section nobody closed has to read as not done: \(context.prose)")
        XCTAssertTrue(context.prose.contains("The CI job is red."))
        XCTAssertTrue(context.prose.contains("The rotation test still fails"))
        XCTAssertTrue(context.steps.contains("edits middleware.py"))
    }

    /// No readable report is not the same as nothing to explain — a run that stopped and said why
    /// is exactly the case somebody needs explaining.
    func testARunWithNoReportButAReasonCanStillBeExplained() {
        let context = ExplainContext.forTask(title: "Upgrade the SDK",
                                             stateLabel: WorkState.stopped.labelKey,
                                             outcome: "No credentials for the private registry.",
                                             manifest: nil, turns: [])
        XCTAssertTrue(context.hasMaterial)
        XCTAssertTrue(context.prose.contains("No credentials"))
    }

    /// Nothing readable at all: no button rather than a button that produces "some work was done".
    func testARunWithNothingReadableIsNotOffered() {
        let context = ExplainContext.forTask(title: "", stateLabel: "", outcome: nil,
                                             manifest: nil, turns: [])
        XCTAssertFalse(context.hasMaterial)
    }
}
