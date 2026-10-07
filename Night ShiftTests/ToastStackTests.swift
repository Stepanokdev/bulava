import XCTest
@testable import Bulava

/// The corner cards. What was wrong with the single capsule they replaced is what these pin:
/// a later "Saved" erased an earlier refusal, the same failure five times was five messages, and
/// the long reason was cut at two lines.
nonisolated final class ToastStackTests: XCTestCase {

    @MainActor func testGoodNewsDoesNotEraseAnError() {
        var stack = ToastStack.post(ToastMessage(text: "The engine cannot be replaced while a watchdog.sh is going.",
                                                 kind: .error), into: [])
        stack = ToastStack.post(ToastMessage(text: "Settings saved", kind: .success), into: stack)
        XCTAssertEqual(stack.map(\.kind), [.error, .success],
                       "the refusal is still there to be read after the next message arrives")
    }

    @MainActor func testTheSameErrorRepeatedIsCountedNotStacked() {
        var stack: [ToastMessage] = []
        for _ in 0..<5 {
            stack = ToastStack.post(ToastMessage(text: "Could not save the PDF", kind: .error), into: stack)
        }
        XCTAssertEqual(stack.count, 1)
        XCTAssertEqual(stack.first?.count, 5)
    }

    /// One story under one key: "not updated" followed by "updated" replaces the card in place —
    /// same identity, so it does not jump — and does not count as a repeat.
    @MainActor func testAKeyedMessageContinuesItsStory() {
        var stack = ToastStack.post(ToastMessage(text: "Not updated", kind: .error, key: "engine.install"), into: [])
        let firstID = stack[0].id
        stack = ToastStack.post(ToastMessage(text: "Updated", kind: .success, key: "engine.install"), into: stack)
        XCTAssertEqual(stack.count, 1)
        XCTAssertEqual(stack[0].id, firstID)
        XCTAssertEqual(stack[0].kind, .success)
        XCTAssertEqual(stack[0].count, 1)
    }

    /// A full corner drops its oldest good news first; errors wait to be read.
    @MainActor func testOverflowDropsGoodNewsBeforeErrors() {
        var stack: [ToastMessage] = []
        stack = ToastStack.post(ToastMessage(text: "E1", kind: .error), into: stack)
        stack = ToastStack.post(ToastMessage(text: "S1", kind: .success), into: stack)
        stack = ToastStack.post(ToastMessage(text: "E2", kind: .error), into: stack)
        stack = ToastStack.post(ToastMessage(text: "E3", kind: .error), into: stack)
        stack = ToastStack.post(ToastMessage(text: "E4", kind: .error), into: stack)
        XCTAssertEqual(stack.map(\.text), ["E1", "E2", "E3", "E4"])
        stack = ToastStack.post(ToastMessage(text: "E5", kind: .error), into: stack)
        XCTAssertEqual(stack.map(\.text), ["E2", "E3", "E4", "E5"], "only errors left: the oldest goes")
    }

    @MainActor func testErrorsWaitAndGoodNewsLeaves() {
        XCTAssertFalse(ToastMessage(text: "x", kind: .error).dismissesItself)
        XCTAssertTrue(ToastMessage(text: "x", kind: .success).dismissesItself)
        XCTAssertFalse(ToastMessage(text: "x", kind: .info, inProgress: true).dismissesItself,
                       "a repair under way stays until it says how it went")
        XCTAssertFalse(ToastMessage(text: "x", kind: .info, actions: [ToastAction(title: "Do") {}]).dismissesItself,
                       "a card with a button stays long enough to press it")
    }

}
