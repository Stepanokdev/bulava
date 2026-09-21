import XCTest
@testable import Bulava

/// Taking a message back to edit it, the way Escape does in Claude Code and in Codex.
///
/// The whole point of these is that the two outcomes are NOT the same, and the app must not blur
/// them: a message still in the undelivered queue can genuinely be un-sent, and one the agent has
/// already read cannot be — it can only be superseded, out loud.
nonisolated final class TakeBackAMessageTests: XCTestCase {

    private let wanted = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
    private let other = UUID(uuidString: "99999999-8888-7777-6666-555555555555")!

    private func line(_ id: UUID, _ text: String) -> String {
        #"{"ts":"2026-09-04 01:00:00","message":"\#(text)","id":"\#(id.uuidString)"}"#
    }

    // MARK: - Editing the queue

    func testAQueuedMessageComesOutAndTheRestStays() throws {
        let queue = [line(other, "first"), line(wanted, "half a thought"), line(other, "third")]
            .joined(separator: "\n") + "\n"
        let after = try XCTUnwrap(MessageWithdrawal.removing(wanted, from: queue))
        XCTAssertFalse(after.contains("half a thought"))
        XCTAssertTrue(after.contains("first"))
        XCTAssertTrue(after.contains("third"))
        XCTAssertEqual(after.split(separator: "\n").count, 2)
        XCTAssertTrue(after.hasSuffix("\n"), "the queue is line-based and stays line-based")
    }

    func testTakingBackTheOnlyQueuedMessageEmptiesTheFile() throws {
        let after = try XCTUnwrap(MessageWithdrawal.removing(wanted, from: line(wanted, "oops") + "\n"))
        XCTAssertTrue(after.isEmpty, "an empty queue file is deleted by the caller")
    }

    func testAMessageThatIsNotInTheQueueChangesNothing() {
        XCTAssertNil(MessageWithdrawal.removing(wanted, from: line(other, "someone else") + "\n"),
                     "nil is how the caller learns the agent already has it")
    }

    /// This removes ONE message; it is not a chance to quietly drop a queue it could not parse.
    func testLinesItCannotParseAreLeftExactlyAsTheyWere() throws {
        let queue = "not json at all\n" + line(wanted, "mine") + "\n{\"message\":\"no id\"}\n"
        let after = try XCTUnwrap(MessageWithdrawal.removing(wanted, from: queue))
        XCTAssertTrue(after.contains("not json at all"))
        XCTAssertTrue(after.contains("no id"))
        XCTAssertFalse(after.contains("\"mine\""))
    }

    func testTheIdIsMatchedRegardlessOfCase() throws {
        let lowercased = #"{"message":"m","id":"\#(wanted.uuidString.lowercased())"}"# + "\n"
        XCTAssertNotNil(MessageWithdrawal.removing(wanted, from: lowercased))
    }

    func testTheSameIdTwiceOnlyLosesOneLine() throws {
        let queue = line(wanted, "a") + "\n" + line(wanted, "b") + "\n"
        let after = try XCTUnwrap(MessageWithdrawal.removing(wanted, from: queue))
        XCTAssertEqual(after.split(separator: "\n").count, 1,
                       "a duplicate id is a bug elsewhere; removing both would hide it")
    }

    func testAnEmptyQueueIsNotAWithdrawal() {
        XCTAssertNil(MessageWithdrawal.removing(wanted, from: ""))
        XCTAssertNil(MessageWithdrawal.removing(wanted, from: "\n\n"))
    }

    // MARK: - Saying so when it cannot be un-said

    func testTheReplacementSaysWhatItReplaces() {
        LanguageBundle.adopt(.uk)
        defer { LanguageBundle.adopt(.system) }
        let preamble = MessageWithdrawal.supersedingPreamble()
        XCTAssertFalse(preamble.isEmpty)
        XCTAssertNotEqual(preamble,
                          "Ignore my previous message — I sent it before I had finished. This replaces it:",
                          "the line the agent reads has to be in his language, not the source key")
    }

    /// `.replaced` is his own decision, not something the engine's queue knows about, so it has to
    /// survive a round trip through the conversation store.
    func testTheReplacedMarkSurvivesBeingSavedAndReopened() throws {
        var entry = ConversationEntry(productID: UUID(), kind: .user, text: "half a thought")
        entry.delivery = .replaced
        let back = try JSONDecoder().decode(ConversationEntry.self,
                                            from: try JSONEncoder().encode(entry))
        XCTAssertEqual(back.delivery, .replaced)
    }

    func testADeliveryStateFromANewerBuildDoesNotBreakTheThread() throws {
        let json = #"{"productID":"\#(UUID().uuidString)","kind":"user","text":"hi","delivery":"teleported"}"#
        let entry = try JSONDecoder().decode(ConversationEntry.self, from: Data(json.utf8))
        XCTAssertNil(entry.delivery)
        XCTAssertEqual(entry.text, "hi")
    }
}
