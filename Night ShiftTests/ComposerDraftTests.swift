import XCTest
@testable import Bulava

nonisolated final class ComposerDraftTests: XCTestCase {

    @MainActor private func model() -> AppModel {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("bulava-draft-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        setenv("BULAVA_STATE_DIR", dir.path, 1)
        return AppModel()
    }

    // MARK: - Coming back

    @MainActor func testADraftSurvivesLeavingTheProduct() {
        let model = model()
        let product = UUID()

        model.setDraftText("half a thought", for: product)

        XCTAssertEqual(model.draftText(for: product), "half a thought",
                       "the words must still be there when you come back")
    }

    @MainActor func testTwoProductsKeepTheirOwnDrafts() {
        let model = model()
        let here = UUID(), there = UUID()

        model.setDraftText("about the chat", for: here)
        model.setDraftText("about the other thing", for: there)

        XCTAssertEqual(model.draftText(for: here), "about the chat")
        XCTAssertEqual(model.draftText(for: there), "about the other thing",
                       "a draft belongs to one product and must not leak into another")
    }

    @MainActor func testAProductNeverTypedInHasNoDraft() {
        XCTAssertEqual(model().draftText(for: UUID()), "")
    }

    // MARK: - Sending

    @MainActor func testSendingConsumesTheDraft() {
        let model = model()
        let product = UUID()
        model.setDraftText("going out now", for: product)

        XCTAssertEqual(model.takeDraftText(for: product), "going out now")
        XCTAssertEqual(model.draftText(for: product), "", "the field must not keep a copy")
    }

    @MainActor func testClearingTheFieldForgetsTheDraft() {
        let model = model()
        let product = UUID()

        model.setDraftText("typed", for: product)
        model.setDraftText("", for: product)

        XCTAssertEqual(model.draftText(for: product), "")
        XCTAssertNil(model.composerDrafts[product], "an empty draft should not be stored at all")
    }

    @MainActor func testSendingInOneProductLeavesTheOtherDraftAlone() {
        let model = model()
        let sending = UUID(), waiting = UUID()
        model.setDraftText("this one goes", for: sending)
        model.setDraftText("this one waits", for: waiting)

        _ = model.takeDraftText(for: sending)

        XCTAssertEqual(model.draftText(for: waiting), "this one waits")
    }
}

nonisolated final class ComposerHeightTests: XCTestCase {

    func testTheMinimumHeightIsASingleLine() {
        XCTAssertGreaterThan(Metrics.composerRestingHeight, 0)
        XCTAssertLessThan(Metrics.composerRestingHeight, 60,
                          "the resting height is one line, not a paragraph-sized box")
    }

    func testAGrownFieldIsTallerThanTheMinimum() {
        let grown = Metrics.composerRestingHeight * 3
        XCTAssertGreaterThan(grown, Metrics.composerRestingHeight)
    }

}

/// Each chat of a product has a field of its own, and what finishes late finds its own chat.
nonisolated final class ChatDraftSlotTests: XCTestCase {

    @MainActor private func model() -> AppModel {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("bulava-draftslot-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        setenv("BULAVA_STATE_DIR", dir.path, 1)
        return AppModel()
    }

    @MainActor func testTwoChatsOfOneProductKeepTheirOwnFields() {
        let app = model()
        let product = UUID()
        let first = app.conversations.newChat(for: product)
        let second = app.conversations.newChat(for: product)

        app.conversations.open(first.id, for: product)
        app.setDraftText("про перший", for: product)
        app.conversations.open(second.id, for: product)
        XCTAssertEqual(app.draftText(for: product), "", "the other chat's field is its own")
        app.setDraftText("про другий", for: product)

        app.conversations.open(first.id, for: product)
        XCTAssertEqual(app.draftText(for: product), "про перший")
        app.conversations.open(second.id, for: product)
        XCTAssertEqual(app.draftText(for: product), "про другий")
    }

    @MainActor func testAFinishedTranscriptionGoesToTheChatItWasRecordedIn() {
        let app = model()
        let product = UUID()
        let recordedIn = app.conversations.newChat(for: product)
        let other = app.conversations.newChat(for: product)
        app.conversations.open(recordedIn.id, for: product)
        app.setDraftText("вже набране", for: product)
        let slot = app.draftSlot(for: product)

        // He moved on while the words were being read.
        app.conversations.open(other.id, for: product)
        app.setDraftText("інше", for: product)
        app.appendToDraft("продиктоване", slot: slot)

        XCTAssertEqual(app.draftText(for: product), "інше", "the open chat is left alone")
        app.conversations.open(recordedIn.id, for: product)
        XCTAssertEqual(app.draftText(for: product), "вже набране\nпродиктоване")
    }

    @MainActor func testATakenBackMessageReturnsToItsOwnChatWithItsFiles() {
        let app = model()
        let product = UUID()
        let sentIn = app.conversations.newChat(for: product)
        let other = app.conversations.newChat(for: product)
        let file = Attachment(id: UUID(), kind: .file, filename: "plan.pdf", relativePath: "plan.pdf")
        let entry = app.conversations.appendUser("Зроби звіт", productID: product,
                                                   chatID: sentIn.id, attachments: [file])
        app.conversations.open(sentIn.id, for: product)
        app.setDraftText("і ще", for: product)

        app.conversations.open(other.id, for: product)
        app.setDraftText("чернетка іншого", for: product)
        app.handBackToComposer(entry)

        XCTAssertEqual(app.draftText(for: product), "чернетка іншого")
        XCTAssertTrue(app.draftAttachments(for: product).isEmpty)
        app.conversations.open(sentIn.id, for: product)
        XCTAssertEqual(app.draftText(for: product), "Зроби звіт\nі ще",
                       "the words come back, with what was half-typed kept")
        XCTAssertEqual(app.draftAttachments(for: product).map { $0.filename }, ["plan.pdf"])
    }

    @MainActor func testSwitchingChatsWhileRecordingKeepsTheWordsInTheChatItStartedIn() {
        let app = model()
        let product = UUID()
        let startedIn = app.conversations.newChat(for: product)
        let movedTo = app.conversations.newChat(for: product)
        app.conversations.open(startedIn.id, for: product)
        app.beginDictation(for: product)                 // he presses the mic here…

        app.conversations.open(movedTo.id, for: product) // …moves on while talking…
        app.setDraftText("пише тут", for: product)
        let slot = app.takeDictationSlot(for: product)   // …and stops the recording there
        app.appendToDraft("сказане в першому", slot: slot)
        let file = Attachment(id: UUID(), kind: .audio, filename: "note.m4a", relativePath: "note.m4a")
        app.addDraftAttachment(file, slot: slot)          // or the recording, if unread

        XCTAssertEqual(app.draftText(for: product), "пише тут")
        XCTAssertTrue(app.draftAttachments(for: product).isEmpty)
        app.conversations.open(startedIn.id, for: product)
        XCTAssertEqual(app.draftText(for: product), "сказане в першому")
        XCTAssertEqual(app.draftAttachments(for: product).map { $0.filename }, ["note.m4a"])
        XCTAssertNil(app.dictationSlots[product], "the next recording starts from nothing")
    }

    @MainActor func testARecordingThatNeverStartedFixesNothing() {
        let app = model()
        let product = UUID()
        let first = app.conversations.newChat(for: product)
        let second = app.conversations.newChat(for: product)
        app.conversations.open(first.id, for: product)
        app.beginDictation(for: product)
        app.cancelDictation(for: product)                 // the microphone was refused
        app.conversations.open(second.id, for: product)
        XCTAssertEqual(app.takeDictationSlot(for: product), second.id)
    }
}

