import XCTest
import UserNotifications
@testable import Bulava

/// What waits for the director is told on the Mac too, not only on the phone.
///
/// Only automations used to raise a notification on the Mac; a question, a permission dialog or a
/// request in an ordinary chat stayed silent until he looked at Bulava. Pinned here: the first
/// reading is only the starting line, nothing is raised while Bulava is in front of him, something
/// new is raised once with the chat it is about, an automation's chat and the Mac's own setup say
/// nothing here, and a burst is folded rather than spread over the screen.
nonisolated final class DesktopNoticesTests: XCTestCase {

    private var dir: URL!

    override func setUp() async throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("bulava-desktop-notices-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        setenv("BULAVA_STATE_DIR", dir.path, 1)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private func item(_ id: String, product: UUID, chat: UUID?, kind: String = "question", at: Int64 = 1) -> AttentionDTO {
        AttentionDTO(id: id, productID: product.uuidString, chatID: chat?.uuidString, kind: kind,
                     title: "Which one, \(id)?", body: "The export can be CSV or JSON.", tone: "attention",
                     atMs: at, actions: [])
    }

    @MainActor
    func testWhatWaitsIsToldOnTheMacOnceWithItsChatAndOnlyWhenBulavaIsNotInFront() throws {
        let model = AppModel()
        let product = model.products.add(name: "Narada")
        let chat = model.conversations.newChat(for: product.id)
        let notices = DesktopNotices()
        notices.model = model
        var active = false
        var posted: [UNNotificationRequest] = []
        notices.isAppActive = { active }
        notices.post = { posted.append($0) }

        let old = item("q-old", product: product.id, chat: chat.id)
        XCTAssertTrue(notices.changed([old]).isEmpty, "what was there at start is in front of him once he opens Bulava")

        active = true
        let seenWhileThere = item("q-seen", product: product.id, chat: chat.id, at: 2)
        XCTAssertTrue(notices.changed([old, seenWhileThere]).isEmpty, "with Bulava in front of him, nothing is raised")

        active = false
        let fresh = item("q-new", product: product.id, chat: chat.id, at: 3)
        let raised = notices.changed([old, seenWhileThere, fresh])
        XCTAssertEqual(raised.map(\.identifier), ["bulava.attention.q-new"], "only what is new, and only once")
        let content = try XCTUnwrap(raised.first?.content)
        XCTAssertEqual(content.title, "Which one, q-new?")
        XCTAssertEqual(content.subtitle, "Narada")
        XCTAssertEqual(content.userInfo["chatID"] as? String, chat.id.uuidString, "a click opens its chat")
        XCTAssertTrue(notices.changed([old, seenWhileThere, fresh]).isEmpty, "read again, it is not raised again")
        XCTAssertEqual(posted.count, 1)
    }

    @MainActor
    func testAutomationsAndTheMacsSetupSayNothingHereAndABurstIsFolded() throws {
        let model = AppModel()
        let product = model.products.add(name: "Narada")
        let chat = model.conversations.newChat(for: product.id)
        let automation = model.conversations.newAutomationChat(id: UUID(), for: product.id, runID: UUID(),
                                                               copyID: UUID(), title: "Nightly")
        let notices = DesktopNotices()
        notices.model = model
        notices.isAppActive = { false }
        var posted: [UNNotificationRequest] = []
        notices.post = { posted.append($0) }
        notices.changed([])

        let quiet = notices.changed([
            item("q-auto", product: product.id, chat: automation.id),
            item("setup", product: product.id, chat: nil, kind: "readiness"),
        ])
        XCTAssertTrue(quiet.isEmpty, "an automation says it itself, and the Mac's setup is a banner inside Bulava")

        let burst = (1...6).map { item("q-\($0)", product: product.id, chat: chat.id, at: Int64($0)) }
        let raised = notices.changed(burst)
        XCTAssertEqual(raised.count, DesktopNotices.perReading + 1, "three of them and one for the rest")
        XCTAssertEqual(raised.first?.identifier, "bulava.attention.q-6", "the newest first")
        XCTAssertTrue(raised.last?.content.body.contains("3") == true, raised.last?.content.body ?? "")
        XCTAssertEqual(posted.count, raised.count)
    }
}
