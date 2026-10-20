import XCTest
@testable import Bulava

/// "Remove product" asks first, and what it takes away can be given back.
///
/// 14 Oct: Meetings Recorder went with one click while a run was still working in it. Adding the same
/// folder again made a new product, the working chat stayed bound to the old one, and it came back
/// only by editing the app's files by hand.
nonisolated final class ProductRemovalTests: XCTestCase {

    private var state: URL!
    private var folderURL: URL!

    override func setUp() async throws {
        state = FileManager.default.temporaryDirectory.appendingPathComponent("bulava-removal-\(UUID().uuidString)")
        folderURL = state.appendingPathComponent("Meetings Recorder")
        try FileManager.default.createDirectory(at: folderURL, withIntermediateDirectories: true)
        FixtureState.use(state.appendingPathComponent("app").path)
    }

    override func tearDown() async throws {
        FixtureState.restore()
        try? FileManager.default.removeItem(at: state)
    }

    @MainActor
    private func ready() -> (AppModel, Product, Project, Chat) {
        let model = AppModel()
        let folder = model.projects.add(path: folderURL.path)
        let product = model.products.add(name: "Meetings Recorder",
                                         resources: [ProductResource(name: "App", projectID: folder.id)])
        let chat = model.conversations.newChat(for: product.id)
        model.conversations.appendUser("Розбери вчорашні мітинги", productID: product.id, chatID: chat.id)
        return (model, product, folder, chat)
    }

    @MainActor
    func testRemovingAsksFirst() {
        let (model, product, _, _) = ready()
        model.askToRemoveProduct(product)
        XCTAssertEqual(model.removingProductID, product.id, "the question is on screen")
        XCTAssertNotNil(model.products.product(id: product.id), "and nothing is removed until it is answered")
        XCTAssertFalse(model.removalNote(for: product).isEmpty)
    }

    @MainActor
    func testUndoGivesBackTheSameProductWithItsChats() throws {
        let (model, product, _, chat) = ready()
        model.removeProduct(product)
        XCTAssertNil(model.products.product(id: product.id))
        XCTAssertTrue(model.conversations.chats(for: product.id).contains { $0.id == chat.id },
                      "the chat and its history are kept while the removal can be undone")
        XCTAssertFalse(model.conversations.entries(inChat: chat.id).isEmpty)
        let undo = try XCTUnwrap(model.toast?.actions.first, "the notice offers Undo")
        undo.perform()
        XCTAssertNotNil(model.products.product(id: product.id), "the same product, same id")
        XCTAssertEqual(model.conversations.chats(for: product.id).map(\.id), [chat.id])
        XCTAssertTrue(model.products.removed.isEmpty)
    }

    @MainActor
    func testAddingTheSameFolderAgainBringsTheChatsBack() {
        let (model, product, folder, chat) = ready()
        model.removeProduct(product)
        // What the add sheet does: the folder is known already, so it is the same project.
        let again = model.projects.add(path: folderURL.path)
        XCTAssertEqual(again.id, folder.id)
        let fresh = model.products.add(name: "Meetings Recorder",
                                       resources: [ProductResource(name: "App", projectID: again.id)])
        XCTAssertEqual(model.adoptRemovedProducts(into: fresh), 1)
        XCTAssertEqual(model.conversations.chats(for: fresh.id).map(\.id), [chat.id],
                       "the chat that worked in this folder is under the new product")
        XCTAssertFalse(model.conversations.entries(inChat: chat.id).isEmpty, "with its history")
        XCTAssertTrue(model.products.removed.isEmpty, "the old product is let go")
    }

    @MainActor
    func testARemovedProductIsLetGoAfterItsWaitAndItsHistoryWithIt() {
        let (model, product, _, chat) = ready()
        model.removeProduct(product)
        model.expireRemovedProducts(now: Date().addingTimeInterval(AppModel.removedProductKeep - 3600))
        XCTAssertFalse(model.products.removed.isEmpty, "still waiting to be undone")
        model.expireRemovedProducts(now: Date().addingTimeInterval(AppModel.removedProductKeep + 3600))
        XCTAssertTrue(model.products.removed.isEmpty)
        XCTAssertNil(model.conversations.chat(id: chat.id), "the chat goes with it")
        XCTAssertTrue(model.conversations.entries(inChat: chat.id).isEmpty)
    }

    @MainActor
    func testTheRemovedListSurvivesARestart() {
        let base = FileManager.default.temporaryDirectory
        let file = base.appendingPathComponent("products-\(UUID().uuidString).json")
        let flag = base.appendingPathComponent("adopted-\(UUID().uuidString).json")
        let store = ProductsStore(fileURL: file, migrationURL: flag)
        let product = store.add(name: "Ledger")
        store.remove(product.id)
        let reopened = ProductsStore(fileURL: file, migrationURL: flag)
        XCTAssertEqual(reopened.removed.map(\.product.id), [product.id])
        XCTAssertEqual(reopened.restore(product.id)?.id, product.id)
        XCTAssertEqual(reopened.products.map(\.id), [product.id])
    }
}
