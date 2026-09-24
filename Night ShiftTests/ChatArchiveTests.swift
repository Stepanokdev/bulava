import XCTest
@testable import Bulava

nonisolated final class ChatArchiveTests: XCTestCase {

    @MainActor private func model() -> AppModel {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("bulava-archive-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        setenv("BULAVA_STATE_DIR", dir.path, 1)
        return AppModel()
    }

    // MARK: - Archiving

    @MainActor func testArchivingTheOpenChatMovesToAnotherLiveOne() {
        let model = model()
        let product = UUID()
        let older = model.conversations.newChat(for: product)
        let open = model.conversations.newChat(for: product)
        model.openChat(open)

        model.archiveChat(open)

        XCTAssertEqual(model.conversations.currentChatID(for: product), older.id)
        XCTAssertEqual(model.conversations.archivedChats(for: product).map(\.id), [open.id])
    }

    @MainActor func testArchivingTheLastLiveChatLeavesAFreshOne() {
        let model = model()
        let product = UUID()
        let only = model.conversations.newChat(for: product)
        model.openChat(only)

        model.archiveChat(only)

        let live = model.conversations.chats(for: product)
        XCTAssertEqual(live.count, 1)
        XCTAssertNotEqual(live.first?.id, only.id)
        XCTAssertEqual(model.conversations.currentChatID(for: product), live.first?.id)
    }

    @MainActor func testArchivingAnotherChatKeepsTheOpenOne() {
        let model = model()
        let product = UUID()
        let other = model.conversations.newChat(for: product)
        let open = model.conversations.newChat(for: product)
        model.openChat(open)

        model.archiveChat(other)

        XCTAssertEqual(model.conversations.currentChatID(for: product), open.id,
                       "archiving a chat in the background must not change what is on screen")
    }

    @MainActor func testAStaleConfirmationDoesNothing() {
        let model = model()
        let product = UUID()
        let keep = model.conversations.newChat(for: product)
        let gone = model.conversations.newChat(for: product)
        model.openChat(gone)
        model.archiveChat(gone)
        let openAfter = model.conversations.currentChatID(for: product)

        model.archiveChat(gone)

        XCTAssertEqual(model.conversations.currentChatID(for: product), openAfter)
        XCTAssertEqual(model.conversations.chats(for: product).map(\.id), [keep.id])
    }

    // MARK: - Per product

    @MainActor func testEachProductKeepsItsOwnArchives() {
        let model = model()
        let a = UUID(), b = UUID()
        let inA = model.conversations.newChat(for: a)
        _ = model.conversations.newChat(for: b)

        model.archiveChat(inA)

        XCTAssertEqual(model.conversations.archivedChats(for: a).map(\.id), [inA.id])
        XCTAssertTrue(model.conversations.archivedChats(for: b).isEmpty)
    }

    // MARK: - Reading an archived chat

    @MainActor func testOpeningFromArchivesShowsThatChatReadOnly() {
        let model = model()
        let product = UUID()
        let archived = model.conversations.newChat(for: product)
        let live = model.conversations.newChat(for: product)
        model.openChat(live)
        model.archiveChat(archived)

        model.viewArchivedChat(archived)

        XCTAssertEqual(model.conversations.displayedChatID(for: product), archived.id,
                       "the screen must show the chat that was clicked")
        XCTAssertEqual(model.conversations.viewedArchivedChat(for: product)?.id, archived.id)
        XCTAssertEqual(model.conversations.archivedChats(for: product).map(\.id), [archived.id],
                       "opening it to read must not take it out of Archives")
        XCTAssertEqual(model.conversations.currentChatID(for: product), live.id,
                       "the live chat stays where the app writes")
        XCTAssertEqual(model.route, .product(product))
    }

    @MainActor func testWritesWhileReadingTheArchiveLandInTheLiveChat() {
        let model = model()
        let product = UUID()
        let archived = model.conversations.newChat(for: product)
        let live = model.conversations.newChat(for: product)
        model.openChat(live)
        model.archiveChat(archived)
        model.viewArchivedChat(archived)

        _ = model.conversations.appendUser("Звіт із фонової роботи", productID: product)

        XCTAssertTrue(model.conversations.entries(inChat: archived.id).isEmpty,
                      "nothing may be written into an archived chat just because it is on screen")
        XCTAssertEqual(model.conversations.entries(inChat: live.id).count, 1)
        XCTAssertEqual(model.conversations.chat(id: archived.id)?.archived, true)
    }

    @MainActor func testOpeningALiveChatLeavesTheArchive() {
        let model = model()
        let product = UUID()
        let archived = model.conversations.newChat(for: product)
        let live = model.conversations.newChat(for: product)
        model.archiveChat(archived)
        model.viewArchivedChat(archived)

        model.openChat(live)

        XCTAssertNil(model.conversations.viewedArchivedChat(for: product))
        XCTAssertEqual(model.conversations.displayedChatID(for: product), live.id)
    }

    @MainActor func testANewChatLeavesTheArchive() {
        let model = model()
        let product = UUID()
        let archived = model.conversations.newChat(for: product)
        model.archiveChat(archived)
        model.viewArchivedChat(archived)

        model.newChat(in: product)

        XCTAssertNil(model.conversations.viewedArchivedChat(for: product))
    }

    @MainActor func testALiveChatCannotBeOpenedAsArchived() {
        let model = model()
        let product = UUID()
        let live = model.conversations.newChat(for: product)

        model.viewArchivedChat(live)

        XCTAssertNil(model.conversations.viewedArchivedChat(for: product))
    }

    // MARK: - Coming back

    @MainActor func testUnarchiveReturnsTheViewedChatAndItsComposer() {
        let model = model()
        let product = UUID()
        let archived = model.conversations.newChat(for: product)
        let live = model.conversations.newChat(for: product)
        model.openChat(live)
        model.archiveChat(archived)
        model.viewArchivedChat(archived)

        model.unarchiveChat(archived)

        XCTAssertNil(model.conversations.viewedArchivedChat(for: product),
                     "back in the list, the chat is no longer read only")
        XCTAssertEqual(model.conversations.currentChatID(for: product), archived.id)
        XCTAssertEqual(model.conversations.displayedChatID(for: product), archived.id)
        XCTAssertTrue(model.conversations.archivedChats(for: product).isEmpty)
    }

    @MainActor func testArchivingAgainDoesNotReopenAnOldReading() {
        let model = model()
        let product = UUID()
        let chat = model.conversations.newChat(for: product)
        _ = model.conversations.newChat(for: product)
        model.archiveChat(chat)
        model.viewArchivedChat(chat)
        model.conversations.setArchived(chat.id, false)

        model.archiveChat(chat)

        XCTAssertNil(model.conversations.viewedArchivedChat(for: product),
                     "archiving must not drop the reader back into a read-only screen they had left")
    }
}
