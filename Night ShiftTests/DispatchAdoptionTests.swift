import XCTest
@testable import Bulava

nonisolated final class DispatchAdoptionTests: XCTestCase {

    private let project = "/tmp/bulava-dispatch-adopt"
    private let runID = "RUN-ONE"

    @MainActor private func store() -> (BacklogStore, URL) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("bulava-adopt-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(atPath: project, withIntermediateDirectories: true)
        return (BacklogStore(fileURL: dir.appendingPathComponent("backlog.json"),
                             adoptedURL: dir.appendingPathComponent("adopted.json")), dir)
    }

    private func finished(dispatch: DispatchRecord?, alsoFinished extra: [DispatchRecord] = [])
    -> SupervisorSnapshot {
        var snap = SupervisorSnapshot()
        var inst = SupervisorInstance(slug: Slug.forPath(project), projectPath: project,
                                      session: "night-x", watchdogAlive: false,
                                      hasPlan: false, hasResearch: false)
        inst.runID = runID
        inst.branch = "feat/x"
        inst.doneResult = "passed"
        inst.finishedAt = Date()
        inst.dispatch = dispatch

        inst.finishedDispatches = ([dispatch].compactMap { $0 } + extra).map {
            var r = $0
            r.result = r.result ?? "passed"
            r.finishedAt = r.finishedAt ?? Date()
            return r
        }
        snap.instances = [inst]
        return snap
    }

    @MainActor private func adopt(_ store: BacklogStore, _ snap: SupervisorSnapshot) {
        store.adopt(from: snap) { _ in nil }
    }

    // MARK: -

    @MainActor
    func testASecondJobInTheSameSessionGetsItsOwnCard() {
        let (store, dir) = self.store(); defer { try? FileManager.default.removeItem(at: dir) }

        var first = BacklogTask(title: "Перша робота", projectPath: project,
                                type: .feature, priority: .p2, state: .review)
        first.boundRunID = runID
        first.boundDispatchID = "DISPATCH-1"
        _ = store.add(first)

        adopt(store, finished(dispatch: DispatchRecord(id: "DISPATCH-2", at: Date(),
                                                       task: "Перевір запит на оцінку додатку\nдеталі нижче")))

        let adopted = store.tasks.filter { $0.boundDispatchID == "DISPATCH-2" }
        XCTAssertEqual(adopted.count, 1, "the second job produced no card")
        XCTAssertEqual(adopted.first?.title, "Перевір запит на оцінку додатку",
                       "a card named «Night run · …» is not something he can recognise")
        XCTAssertEqual(adopted.first?.state, .review)
    }

    @MainActor
    func testAdoptingTheSameDispatchTwiceChangesNothing() {
        let (store, dir) = self.store(); defer { try? FileManager.default.removeItem(at: dir) }
        let snap = finished(dispatch: DispatchRecord(id: "DISPATCH-2", at: Date(), task: "Робота"))

        adopt(store, snap)
        adopt(store, snap)
        adopt(store, snap)

        XCTAssertEqual(store.tasks.filter { $0.boundDispatchID == "DISPATCH-2" }.count, 1)
    }

    @MainActor
    func testWorkTheAppAlreadyKnowsAboutIsNotAdoptedAgain() {
        let (store, dir) = self.store(); defer { try? FileManager.default.removeItem(at: dir) }
        var mine = BacklogTask(title: "Моя задача", projectPath: project,
                               type: .feature, priority: .p2, state: .executing)
        mine.boundRunID = runID
        mine.boundDispatchID = "DISPATCH-2"
        mine.dispatchedAt = Date()
        _ = store.add(mine)

        adopt(store, finished(dispatch: DispatchRecord(id: "DISPATCH-2", at: Date(), task: "Моя задача")))

        XCTAssertEqual(store.tasks.count, 1, "the app's own task was adopted a second time")
    }

    @MainActor
    func testARunWithoutADispatchRecordStillKeysOnTheRunNonce() {
        let (store, dir) = self.store(); defer { try? FileManager.default.removeItem(at: dir) }
        var first = BacklogTask(title: "Перша робота", projectPath: project,
                                type: .feature, priority: .p2, state: .review)
        first.boundRunID = runID
        _ = store.add(first)

        adopt(store, finished(dispatch: nil))

        XCTAssertEqual(store.tasks.count, 1, "a run already represented was adopted again")
    }

    func testALongRequestIsNamedByItsFirstLine() {
        let long = String(repeating: "перевірити канали ", count: 12)
        let record = DispatchRecord(id: "d", at: nil, task: long)
        XCTAssertLessThanOrEqual(record.title.count, 81)
        XCTAssertTrue(record.title.hasSuffix("…"))
        XCTAssertFalse(record.title.contains("\n"))
    }
}

extension DispatchAdoptionTests {

    @MainActor
    func testTheCardOpensTheDirectoryTheWorkWasToldToWriteInto() {
        let (store, dir) = self.store(); defer { try? FileManager.default.removeItem(at: dir) }

        adopt(store, finished(dispatch: DispatchRecord(id: "DISPATCH-3", at: Date(),
                                                       task: "Перевір рейтинг", reportKey: "abc12345")))

        let task = store.tasks.first { $0.boundDispatchID == "DISPATCH-3" }
        XCTAssertEqual(task?.reportKey, "abc12345",
                       "the card looks for its report somewhere the worker was never sent")
    }

    @MainActor
    func testATaskWithoutADispatchKeyStillUsesItsOwnId() {
        var t = BacklogTask(title: "Моя задача")
        XCTAssertEqual(t.reportKey, String(t.id.uuidString.prefix(8)).lowercased())
        t.boundReportKey = "deadbeef"
        XCTAssertEqual(t.reportKey, "deadbeef")
    }
}

extension DispatchAdoptionTests {

    @MainActor
    func testTwoJobsThatFinishedWhileTheAppWasClosedBothArrive() {
        let (store, dir) = self.store(); defer { try? FileManager.default.removeItem(at: dir) }

        let first = DispatchRecord(id: "D-EARLY", at: Date().addingTimeInterval(-7200),
                                   task: "Перша робота", reportKey: "aaaa1111",
                                   result: "passed", finishedAt: Date().addingTimeInterval(-7000))
        let second = DispatchRecord(id: "D-LATE", at: Date().addingTimeInterval(-600),
                                    task: "Друга робота", reportKey: "bbbb2222",
                                    result: "needs-user", finishedAt: Date())

        adopt(store, finished(dispatch: second, alsoFinished: [first]))

        let titles = store.tasks.map(\.title).sorted()
        XCTAssertEqual(titles, ["Друга робота", "Перша робота"],
                       "a result the app was not running for was lost")
        XCTAssertEqual(store.tasks.first { $0.title == "Перша робота" }?.reportKey, "aaaa1111")
        XCTAssertEqual(store.tasks.first { $0.title == "Друга робота" }?.state, .blocked,
                       "a job that needs him must not read as reviewed")
    }

    @MainActor
    func testEachFinishedDispatchIsAdoptedOnce() {
        let (store, dir) = self.store(); defer { try? FileManager.default.removeItem(at: dir) }
        let snap = finished(dispatch: DispatchRecord(id: "D-1", at: Date(), task: "Робота",
                                                     reportKey: "cccc3333"))
        adopt(store, snap); adopt(store, snap); adopt(store, snap)
        XCTAssertEqual(store.tasks.count, 1)
    }
}
