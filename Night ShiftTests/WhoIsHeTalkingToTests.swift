import XCTest
@testable import Bulava

nonisolated final class WhoIsHeTalkingToTests: XCTestCase {

    private func floor(lastSpeaker: ConversationEntry?, live: Bool) -> SupervisorInstance? {
        let taskID = UUID()
        var task = BacklogTask(title: "Робота", projectPath: "/tmp/bulava-floor-project",
                               type: .feature, priority: .p2, state: .executing)
        task.id = taskID
        var inst = SupervisorInstance(slug: "s", projectPath: "/tmp/bulava-floor-project",
                                      session: "night-x", watchdogAlive: live,
                                      hasPlan: false, hasResearch: false)
        inst.runID = "RUN-FLOOR"
        if !live { inst.doneResult = "passed" }

        var entry = lastSpeaker
        entry?.taskID = taskID
        return AppModel.runHoldingTheFloor(in: [entry].compactMap { $0 },
                                           task: { $0 == taskID ? task : nil },
                                           instance: { _ in inst })
    }

    private func workerTurn() -> ConversationEntry {
        var e = ConversationEntry(productID: UUID(), kind: .foreman,
                                  text: "План такий. Скажи «беру».")
        e.blocks = [.markdown(id: "m1", "План такий. Скажи «беру».")]
        return e
    }

    // MARK: -

    func testWhenTheRunSpokeLastHisAnswerGoesToTheRun() {
        XCTAssertNotNil(floor(lastSpeaker: workerTurn(), live: true),
                        "«Так, згоден! Роби» would be answered by the app instead of the worker")
    }

    func testWithNoRunSpeakingTheAppKeepsTheFloor() {
        XCTAssertNil(floor(lastSpeaker: nil, live: true))
    }

    func testAFinishedRunDoesNotHoldTheFloor() {
        XCTAssertNil(floor(lastSpeaker: workerTurn(), live: false),
                     "a run that has finished must not swallow the next request")
    }

    func testTheAppsOwnLineDoesNotHandTheFloorToAWorker() {
        var e = ConversationEntry(productID: UUID(), kind: .foreman, text: "Черга пуста.")
        e.taskID = nil
        let result = AppModel.runHoldingTheFloor(in: [e], task: { _ in nil }, instance: { _ in nil })
        XCTAssertNil(result)
    }

    func testAddressingTheForemanByNameKeepsItInTheApp() {
        XCTAssertTrue(AppModel.addressesTheForeman("бригадир, покажи чергу"))
        XCTAssertTrue(AppModel.addressesTheForeman("Булава, що там по лімітах?"))
        XCTAssertTrue(AppModel.addressesTheForeman("bulava status"))
        XCTAssertFalse(AppModel.addressesTheForeman("Так, згоден! Роби. 2 доби від встановлення адекватно."))
        XCTAssertFalse(AppModel.addressesTheForeman("беру"))
    }
}
