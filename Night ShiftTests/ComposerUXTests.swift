import XCTest
@testable import Bulava

nonisolated final class ComposerUXTests: XCTestCase {

    /// Shift is what people arrive with: every chat window breaks a line that way, and reaching
    /// for it here used to send the message half-written.
    func testBothShiftAndOptionBreakTheLineAndPlainReturnSends() {
        XCTAssertFalse(ComposerKeyPolicy.wantsNewline(shift: false, option: false))
        XCTAssertTrue(ComposerKeyPolicy.wantsNewline(shift: true, option: false))
        XCTAssertTrue(ComposerKeyPolicy.wantsNewline(shift: false, option: true))
        XCTAssertTrue(ComposerKeyPolicy.wantsNewline(shift: true, option: true))

        XCTAssertEqual(ComposerKeyPolicy.returnAction(newline: false, hasMarkedText: false), .send)
        XCTAssertEqual(ComposerKeyPolicy.returnAction(newline: true, hasMarkedText: false), .newline)
    }

    func testReturnCommitsIMETextBeforeItCanSend() {
        XCTAssertEqual(ComposerKeyPolicy.returnAction(newline: false, hasMarkedText: true), .system)
        XCTAssertEqual(ComposerKeyPolicy.returnAction(newline: true, hasMarkedText: true), .system)
    }

    func testAutocompleteOwnsNavigationButNeverStealsALineBreakOrIME() {
        XCTAssertEqual(ComposerKeyPolicy.autocompleteAction(keyCode: 125, newline: false,
                                                            hasMarkedText: false), .next)
        XCTAssertEqual(ComposerKeyPolicy.autocompleteAction(keyCode: 126, newline: false,
                                                            hasMarkedText: false), .previous)
        XCTAssertEqual(ComposerKeyPolicy.autocompleteAction(keyCode: 48, newline: false,
                                                            hasMarkedText: false), .complete)
        XCTAssertEqual(ComposerKeyPolicy.autocompleteAction(keyCode: 53, newline: false,
                                                            hasMarkedText: false), .dismiss)
        // Return picks the highlighted completion; Return that is breaking a line does not.
        XCTAssertEqual(ComposerKeyPolicy.autocompleteAction(keyCode: 36, newline: false,
                                                            hasMarkedText: false), .complete)
        XCTAssertNil(ComposerKeyPolicy.autocompleteAction(keyCode: 36, newline: true,
                                                          hasMarkedText: false))
        XCTAssertNil(ComposerKeyPolicy.autocompleteAction(keyCode: 76, newline: true,
                                                          hasMarkedText: false))
        XCTAssertNil(ComposerKeyPolicy.autocompleteAction(keyCode: 125, newline: false,
                                                          hasMarkedText: true))
    }

    func testMinimumWindowKeepsAllThreeColumnsOnScreen() {
        let requiredWidth = Metrics.sidebarMinWidth
            + 320
            + Metrics.inspectorWidth

        XCTAssertGreaterThanOrEqual(Metrics.minimumWindowWidth, requiredWidth)
        XCTAssertLessThanOrEqual(Metrics.minimumWindowWidth, 1_024)
    }

    func testAWorkingFollowUpOutranksThePreviousDoneMarker() {
        var instance = SupervisorInstance(slug: "p", projectPath: "/tmp/p", session: "night-p",
                                          watchdogAlive: true, doneResult: "passed",
                                          hasPlan: false, hasResearch: false)
        instance.workerStatus = "busy"
        XCTAssertTrue(instance.turnRunning)
        XCTAssertEqual(instance.phase, .working)

        instance.reviewActive = true
        instance.reviewStage = "auditing"
        XCTAssertEqual(instance.phase, .reviewing)
    }

    func testANeedsUserDispositionDoesNotInventAMissingQuestion() {
        var instance = SupervisorInstance(slug: "p", projectPath: "/tmp/p", session: "night-p",
                                          watchdogAlive: true, doneResult: "needs-user",
                                          hasPlan: false, hasResearch: false)

        XCTAssertEqual(DirectChatPhase.resolve(instance: instance, bindingHasOutcome: true),
                       .needsReview,
                       "a parked review result is not an interactive Claude question")

        instance.pendingQuestion = PendingUserQuestion(
            questions: [.init(question: "Який варіант обрати?", header: nil,
                              options: ["A", "B"], multiSelect: false)],
            askedAt: Date())
        XCTAssertEqual(DirectChatPhase.resolve(instance: instance, bindingHasOutcome: true),
                       .needsAttention,
                       "only an actual question payload may claim an answer is required")
    }

    func testLiveWorkOutranksAStaleNeedsUserDisposition() {
        var instance = SupervisorInstance(slug: "p", projectPath: "/tmp/p", session: "night-p",
                                          watchdogAlive: true, doneResult: "needs-user",
                                          hasPlan: false, hasResearch: false)
        instance.workerStatus = "busy"
        XCTAssertEqual(DirectChatPhase.resolve(instance: instance, bindingHasOutcome: true), .working)
    }

    func testQueuedMessageStateSurvivesRelaunch() throws {
        var entry = ConversationEntry(productID: UUID(), kind: .user, text: "one more thing")
        entry.delivery = .queued
        let restored = try JSONDecoder().decode(ConversationEntry.self,
                                                from: JSONEncoder().encode(entry))
        XCTAssertEqual(restored.delivery, .queued)
    }
}
