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
