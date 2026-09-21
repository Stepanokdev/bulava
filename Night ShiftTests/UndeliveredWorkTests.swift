import XCTest
@testable import Bulava

nonisolated final class UndeliveredWorkTests: XCTestCase {

    private let project = "/tmp/bulava-undelivered"

    @MainActor
    private func model() -> (AppModel, URL) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("bulava-undelivered-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(atPath: project, withIntermediateDirectories: true)
        setenv("BULAVA_STATE_DIR", dir.path, 1)
        return (AppModel(), dir)
    }

    private func run(dispatchID: String?, reason: String?, runID: String = "RUN-1") -> SupervisorInstance {
        var inst = SupervisorInstance(slug: Slug.forPath(project), projectPath: project,
                                      session: "night-x", watchdogAlive: true,
                                      hasPlan: false, hasResearch: false)
        inst.runID = runID
        inst.injectFailure = reason
        inst.injectFailureDispatchID = dispatchID
        return inst
    }

    @MainActor
    func testACardWhoseTaskNeverArrivedIsHandedBack() {
        let (model, dir) = self.model()
        defer { try? FileManager.default.removeItem(at: dir); unsetenv("BULAVA_STATE_DIR") }

        var task = BacklogTask(title: "Померджи main і зроби нову гілку", projectPath: project,
                               type: .feature, priority: .p2, state: .executing)
        task.dispatchedAt = Date()
        task.boundDispatchID = "D-1"
        _ = model.backlog.add(task)

        model.surfaceUndeliveredWork([run(dispatchID: "D-1", reason: "задача не дійшла до воркера")])

        let after = model.backlog.task(id: task.id)
        XCTAssertEqual(after?.state, .ready, "the card kept claiming it was working")
        XCTAssertNil(after?.dispatchedAt, "it still looks dispatched, so nothing will start it again")
    }

    @MainActor
    func testAnotherCardInTheSameProjectIsLeftAlone() {
        let (model, dir) = self.model()
        defer { try? FileManager.default.removeItem(at: dir); unsetenv("BULAVA_STATE_DIR") }

        var mine = BacklogTask(title: "Та, що не дійшла", projectPath: project,
                               type: .feature, priority: .p2, state: .executing)
        mine.dispatchedAt = Date(); mine.boundDispatchID = "D-1"
        _ = model.backlog.add(mine)
        var other = BacklogTask(title: "Та, що працює", projectPath: project,
                                type: .feature, priority: .p2, state: .executing)
        other.dispatchedAt = Date(); other.boundDispatchID = "D-2"
        _ = model.backlog.add(other)

        model.surfaceUndeliveredWork([run(dispatchID: "D-1", reason: "задача не дійшла до воркера")])

        XCTAssertEqual(model.backlog.task(id: mine.id)?.state, .ready)
        XCTAssertEqual(model.backlog.task(id: other.id)?.state, .executing,
                       "a working card was rolled back by another card's failure")
    }

    @MainActor
    func testItIsSaidOnceHoweverOftenTheAppRefreshes() {
        let (model, dir) = self.model()
        defer { try? FileManager.default.removeItem(at: dir); unsetenv("BULAVA_STATE_DIR") }

        var task = BacklogTask(title: "Робота", projectPath: project,
                               type: .feature, priority: .p2, state: .executing)
        task.dispatchedAt = Date(); task.boundDispatchID = "D-1"
        _ = model.backlog.add(task)

        let runs = [run(dispatchID: "D-1", reason: "задача не дійшла до воркера")]
        model.surfaceUndeliveredWork(runs)
        model.surfaceUndeliveredWork(runs)
        model.surfaceUndeliveredWork(runs)

        XCTAssertEqual(model.events.events.filter { $0.taskID == task.id }.count, 1,
                       "the same failure was announced more than once")
    }

    @MainActor
    func testARunWithoutADispatchIdIsMatchedByItsNonce() {
        let (model, dir) = self.model()
        defer { try? FileManager.default.removeItem(at: dir); unsetenv("BULAVA_STATE_DIR") }

        var task = BacklogTask(title: "Робота", projectPath: project,
                               type: .feature, priority: .p2, state: .executing)
        task.dispatchedAt = Date(); task.boundRunID = "RUN-1"
        _ = model.backlog.add(task)

        model.surfaceUndeliveredWork([run(dispatchID: nil, reason: "задача не дійшла до воркера")])

        XCTAssertEqual(model.backlog.task(id: task.id)?.state, .ready)
    }

    @MainActor
    func testNothingHappensWhenTheTaskDidArrive() {
        let (model, dir) = self.model()
        defer { try? FileManager.default.removeItem(at: dir); unsetenv("BULAVA_STATE_DIR") }

        var task = BacklogTask(title: "Робота", projectPath: project,
                               type: .feature, priority: .p2, state: .executing)
        task.dispatchedAt = Date(); task.boundDispatchID = "D-1"
        _ = model.backlog.add(task)

        model.surfaceUndeliveredWork([run(dispatchID: "D-1", reason: nil)])

        XCTAssertEqual(model.backlog.task(id: task.id)?.state, .executing)
    }
}
