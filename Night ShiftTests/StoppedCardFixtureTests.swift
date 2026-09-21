import XCTest
@testable import Bulava

nonisolated final class StoppedCardFixtureTests: XCTestCase {

    static let productID = UUID(uuidString: "11111111-1111-4111-8111-111111111111")!
    static let projectID = UUID(uuidString: "22222222-2222-4222-8222-222222222222")!
    static let taskID = UUID(uuidString: "33333333-3333-4333-8333-333333333333")!

    @MainActor
    private func seededModel(project: String) -> (AppModel, URL) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("bulava-fixture-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let now = ISO8601DateFormatter().string(from: Date().addingTimeInterval(-3600))
        func write(_ name: String, _ json: String) {
            try? json.write(to: dir.appendingPathComponent(name), atomically: true, encoding: .utf8)
        }
        write("products.json", """
        [{"id":"\(Self.productID)","name":"Fixture Product","summary":"","resources":[],
          "pinned":false,"addedAt":"\(now)","brief":"","decisions":[]}]
        """)
        write("projects.json", """
        [{"id":"\(Self.projectID)","name":"fixture-project","path":"\(project)","kind":"unknown",
          "stacks":[],"pinned":false,"addedAt":"\(now)","notes":""}]
        """)
        write("backlog.json", """
        [{"id":"\(Self.taskID)","title":"Wire the export button","detail":"",
          "projectID":"\(Self.projectID)","projectPath":"\(project)","productID":"\(Self.productID)",
          "type":"feature","priority":2,"state":"blocked",
          "createdAt":"\(now)","updatedAt":"\(now)","dispatchedAt":"\(now)",
          "boundSessionID":"44444444-4444-4444-8444-444444444444","boundRunID":"run-fixture"}]
        """)
        write("conversations.json", """
        [{"id":"55555555-5555-4555-8555-555555555555","productID":"\(Self.productID)",
          "kind":"task","at":"\(now)","text":"Wire the export button","blocks":[],
          "tone":"neutral","taskID":"\(Self.taskID)","attachments":[]}]
        """)
        setenv("BULAVA_STATE_DIR", dir.path, 1)
        return (AppModel(), dir)
    }

    @MainActor
    func testTheFixtureLoadsAsAStoppedCardInTheProductsOwnThread() {
        let project = FileManager.default.temporaryDirectory
            .appendingPathComponent("fixture-project-\(UUID().uuidString)").path
        let (m, dir) = seededModel(project: project)
        defer { try? FileManager.default.removeItem(at: dir) }

        XCTAssertNotNil(m.products.product(id: Self.productID), "the product did not load")
        let task = m.backlog.task(id: Self.taskID)
        XCTAssertNotNil(task, "the task did not load")
        XCTAssertEqual(m.productID(for: task!), Self.productID,
                       "the task did not land in its product")

        XCTAssertEqual(m.conversations.all(for: Self.productID).count, 1,
                       "the anchor entry did not decode")
        let chatID = m.conversations.currentChatID(for: Self.productID)
        XCTAssertNotNil(chatID, "the seeded entry was not adopted into a thread")
        XCTAssertEqual(m.looseTasks(inChat: chatID, productID: Self.productID).map(\.title),
                       ["Wire the export button"],
                       "the card is not in the thread the product opens on")

        XCTAssertEqual(m.workState(of: task!), .stopped)
        XCTAssertEqual(TaskPresentation.cardActions(for: task!, model: m).first?.id, "trail",
                       "the first thing offered must be what happened")
    }
}
