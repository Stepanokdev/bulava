import XCTest
@testable import Bulava

nonisolated final class AttachmentContextTests: XCTestCase {

    func testWhatWasReadIsFoldedIntoTheMessage() {
        let enriched = AppModel.withAttachmentContext(
            "Ось що треба зробити в мобільному додатку.",
            described: "Прохання перенести кнопку «Новий чат» у шапку, щоб вона лишалась при скролі.",
            count: 1)
        XCTAssertTrue(enriched.hasPrefix("Ось що треба зробити в мобільному додатку."),
                      "his own words come first and are not rewritten")
        XCTAssertTrue(enriched.contains("Новий чат"), "and the router sees what is in the picture")
    }

    func testAnUnreadableAttachmentIsSaidOutLoud() {
        let enriched = AppModel.withAttachmentContext("Ось що треба зробити.", described: nil, count: 2)
        XCTAssertTrue(enriched.contains("не вдалося прочитати"))
        XCTAssertTrue(enriched.contains("Не вигадуй"))
    }

    func testEmptyOutputCountsAsUnread() {
        let enriched = AppModel.withAttachmentContext("Глянь", described: "   \n ", count: 1)
        XCTAssertTrue(enriched.contains("не вдалося прочитати"))
    }
}

nonisolated final class AttachmentsReachTheWorkerTests: XCTestCase {

    @MainActor private func model() -> (AppModel, URL) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("bulava-attach-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        setenv("BULAVA_STATE_DIR", dir.path, 1)
        return (AppModel(), dir)
    }

    private var shot: Attachment {
        Attachment(kind: .image, filename: "shot.png", relativePath: "AAAA-1111.png")
    }

    @MainActor
    func testTheFilesSurviveTheConfirmation() {
        let (m, dir) = model(); defer { try? FileManager.default.removeItem(at: dir) }
        let proposal = ForemanProposal(action: .createTask, taskID: nil, label: "план",
                                       draftSubtasks: [], sourceMessage: "Ось що треба зробити.",
                                       attachments: [shot])
        m.pendingAttachments = []
        m.executeProposal(proposal)
        XCTAssertEqual(m.pendingAttachments.map(\.filename), ["shot.png"],
                       "the plan hands its files back before any task is built")
    }

    @MainActor
    func testTheWorkerIsGivenTheAbsolutePath() {
        var task = BacklogTask(title: "Перенести кнопку", detail: "З чату в шапку",
                               projectPath: "/tmp/p", type: .feature, priority: .p2, state: .ready,
                               attachments: [shot])
        task.id = UUID()
        let text = task.dispatchText
        XCTAssertTrue(text.contains("shot.png"))
        XCTAssertTrue(text.contains(AppSupport.attachments.appendingPathComponent("AAAA-1111.png").path))
    }
}

nonisolated final class AttachmentsSurviveIntoTheTaskTests: XCTestCase {

    @MainActor
    func testAConfirmedPlanCreatesWorkThatCarriesTheFile() {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("bulava-attach2-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        setenv("BULAVA_STATE_DIR", dir.path, 1)
        defer { try? FileManager.default.removeItem(at: dir) }
        let m = AppModel()

        let gone = dir.appendingPathComponent("no-such-project").path
        let productID = m.products.add(name: "pocket-ledger").id
        m.conversationTarget = productID
        let draft = SubtaskDraft(title: "Перенести кнопку «Новий чат» у хедер",
                                 detail: "Щоб лишалась при скролі.", acceptance: [],
                                 projectID: nil, projectPath: gone, projectName: "pocket-ledger",
                                 dependsOn: [], visual: true)
        let shot = Attachment(kind: .image, filename: "peters-request.png",
                              relativePath: "BBBB-2222.png")

        m.pendingAttachments = []
        m.executeProposal(ForemanProposal(action: .createTask, taskID: nil, label: "план",
                                          draftSubtasks: [draft],
                                          sourceMessage: "Ось що треба зробити в мобільному додатку.",
                                          attachments: [shot]))

        guard let created = m.backlog.tasks.first(where: { $0.title.contains("Новий чат") }) else {
            return XCTFail("the plan created no task")
        }
        XCTAssertEqual(created.attachments.map(\.filename), ["peters-request.png"])
        XCTAssertTrue(created.dispatchText.contains("BBBB-2222.png"),
                      "and the worker is told where to find it")
    }
}
