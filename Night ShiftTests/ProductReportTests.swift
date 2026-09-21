import XCTest
@testable import Bulava

nonisolated final class ProductReportRequestTests: XCTestCase {

    func testHeAsksForTheWholeProduct() {
        XCTAssertTrue(ForemanBrain.asksForProductReport("зроби звіт по всій роботі"))
        XCTAssertTrue(ForemanBrain.asksForProductReport("Дай повний звіт по проєкту"))
        XCTAssertTrue(ForemanBrain.asksForProductReport("отчёт по всей работе"))
        XCTAssertTrue(ForemanBrain.asksForProductReport("report on everything we did"))
    }

    func testAskingAboutOneRunIsNotThis() {
        XCTAssertFalse(ForemanBrain.asksForProductReport("де звіт по цій задачі?"))
        XCTAssertFalse(ForemanBrain.asksForProductReport("покажи звіт"))
        XCTAssertFalse(ForemanBrain.asksForProductReport("чого воно мені звіт не дає"))
    }

    func testUnrelatedMessagesAreLeftAlone() {
        XCTAssertFalse(ForemanBrain.asksForProductReport("що по всій роботі лишилось?"))
        XCTAssertFalse(ForemanBrain.asksForProductReport("перенеси кнопку в хедер"))
    }
}

nonisolated final class ProductReportContentTests: XCTestCase {

    @MainActor
    func testItCoversEverythingThatReachedAnEnd() {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("bulava-preport-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        setenv("BULAVA_STATE_DIR", dir.path, 1)
        defer { try? FileManager.default.removeItem(at: dir) }
        let m = AppModel()
        let productID = m.products.add(name: "pocket-ledger").id

        func add(_ title: String, _ state: TaskState) {
            var t = BacklogTask(title: title, type: .feature, priority: .p2, state: state)
            t.id = UUID(); t.productID = productID; t.dispatchedAt = Date()
            m.backlog.add(t)
        }
        add("Кнопка «Новий чат» у хедері", .merged)
        add("Активація акаунта",           .blocked)
        add("Екран усіх чатів",            .review)
        add("Тексти сторів",               .executing)

        let ended = m.tasks(for: productID).filter { AppModel.hasStopped($0) || m.isFinished($0) }
        XCTAssertEqual(Set(ended.map(\.title)),
                       ["Кнопка «Новий чат» у хедері", "Активація акаунта", "Екран усіх чатів"],
                       "a parked run is a result; a running one is not yet")
    }
}
