import XCTest
@testable import Bulava

nonisolated final class FeedFollowsTheCardTests: XCTestCase {

    private static let productID = UUID(uuidString: "AAAAAAAA-0000-4000-8000-000000000001")!
    private static let projectID = UUID(uuidString: "AAAAAAAA-0000-4000-8000-000000000002")!

    private static let oldChat = UUID(uuidString: "AAAAAAAA-0000-4000-8000-00000000000A")!

    private static let newChat = UUID(uuidString: "AAAAAAAA-0000-4000-8000-00000000000B")!

    @MainActor
    private func seededModel() -> (AppModel, URL) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("bulava-feedchat-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let project = dir.appendingPathComponent("proj").path
        try? FileManager.default.createDirectory(atPath: project, withIntermediateDirectories: true)
        let old = ISO8601DateFormatter().string(from: Date().addingTimeInterval(-12 * 86_400))
        let now = ISO8601DateFormatter().string(from: Date().addingTimeInterval(-600))

        func write(_ name: String, _ json: String) {
            try? json.write(to: dir.appendingPathComponent(name), atomically: true, encoding: .utf8)
        }
        write("products.json", """
        [{"id":"\(Self.productID)","name":"Fixture","summary":"","resources":[],
          "pinned":false,"addedAt":"\(old)","brief":"","decisions":[]}]
        """)
        write("projects.json", """
        [{"id":"\(Self.projectID)","name":"proj","path":"\(project)","kind":"unknown",
          "stacks":[],"pinned":false,"addedAt":"\(old)","notes":""}]
        """)
        write("chats.json", """
        [{"id":"\(Self.oldChat)","productID":"\(Self.productID)","title":"Давня розмова",
          "createdAt":"\(old)","updatedAt":"\(old)","archived":false,"pinned":false,"firstMessage":""},
         {"id":"\(Self.newChat)","productID":"\(Self.productID)","title":"Сьогоднішня",
          "createdAt":"\(now)","updatedAt":"\(now)","archived":false,"pinned":false,"firstMessage":""}]
        """)

        write("backlog.json", """
        [{"id":"BBBBBBBB-0000-4000-8000-000000000001","title":"Питали тут","detail":"",
          "projectID":"\(Self.projectID)","projectPath":"\(project)","productID":"\(Self.productID)",
          "type":"feature","priority":2,"state":"executing","createdAt":"\(now)","updatedAt":"\(now)",
          "dispatchedAt":"\(now)","chatID":"\(Self.newChat)"},
         {"id":"BBBBBBBB-0000-4000-8000-000000000002","title":"Прийшло з термінала","detail":"",
          "projectID":"\(Self.projectID)","projectPath":"\(project)","productID":"\(Self.productID)",
          "type":"feature","priority":2,"state":"executing","createdAt":"\(now)","updatedAt":"\(now)",
          "dispatchedAt":"\(now)"}]
        """)

        write("conversations.json", """
        [{"id":"CCCCCCCC-0000-4000-8000-000000000001","productID":"\(Self.productID)",
          "kind":"user","at":"\(old)","text":"Давня розмова","blocks":[],"tone":"neutral",
          "chatID":"\(Self.oldChat)","attachments":[]},
         {"id":"CCCCCCCC-0000-4000-8000-000000000002","productID":"\(Self.productID)",
          "kind":"user","at":"\(now)","text":"Питали тут","blocks":[],"tone":"neutral",
          "chatID":"\(Self.newChat)","attachments":[]}]
        """)
        setenv("BULAVA_STATE_DIR", dir.path, 1)
        return (AppModel(), dir)
    }

    @MainActor
    func testTheConsoleAndTheCardAlwaysLandInTheSameThread() {
        let (model, dir) = seededModel()
        defer { try? FileManager.default.removeItem(at: dir); unsetenv("BULAVA_STATE_DIR") }

        let tasks = model.looseTasks(for: Self.productID)
        XCTAssertEqual(tasks.count, 2, "the fixture did not load: \(tasks.map(\.title))")

        for task in tasks {
            let chat = model.chatShowing(task, productID: Self.productID)
            XCTAssertTrue(model.looseTasks(inChat: chat, productID: Self.productID)
                            .contains(where: { $0.id == task.id }),
                          "«\(task.title)»: the console would be written to a thread its card is not in")
        }
    }

    @MainActor
    func testWorkAskedInThisThreadStaysInThisThread() {
        let (model, dir) = seededModel()
        defer { try? FileManager.default.removeItem(at: dir); unsetenv("BULAVA_STATE_DIR") }

        let asked = model.looseTasks(for: Self.productID).first { $0.title == "Питали тут" }
        XCTAssertEqual(model.chatShowing(XCTUnwrap2(asked), productID: Self.productID), Self.newChat)
    }

    private func XCTUnwrap2(_ task: BacklogTask?) -> BacklogTask {
        guard let task else {
            XCTFail("the fixture's own task is missing")
            return BacklogTask(title: "—")
        }
        return task
    }
}
