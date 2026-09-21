import XCTest
@testable import Bulava

nonisolated final class OneJobOneCardTests: XCTestCase {

    private let project = "/tmp/bulava-one-job"

    @MainActor private func store() -> (BacklogStore, URL) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("bulava-onejob-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(atPath: project, withIntermediateDirectories: true)
        return (BacklogStore(fileURL: dir.appendingPathComponent("backlog.json"),
                             adoptedURL: dir.appendingPathComponent("adopted.json")), dir)
    }

    private func finished(_ record: DispatchRecord) -> SupervisorSnapshot {
        var snap = SupervisorSnapshot()
        var inst = SupervisorInstance(slug: Slug.forPath(project), projectPath: project,
                                      session: "night-x", watchdogAlive: false,
                                      hasPlan: false, hasResearch: false)
        inst.runID = "RUN-ONE"
        inst.branch = "main"
        inst.doneResult = record.result ?? "needs-user"
        inst.finishedAt = Date()
        inst.dispatch = record
        var stamped = record
        stamped.result = record.result ?? "needs-user"
        stamped.finishedAt = record.finishedAt ?? Date()
        inst.finishedDispatches = [stamped]
        snap.instances = [inst]
        return snap
    }

    // MARK: - The card the app dispatched is the card the result comes back to

    @MainActor
    func testTheAppsOwnDispatchIsNotAdoptedAsSomebodyElsesWork() {
        let (store, dir) = self.store(); defer { try? FileManager.default.removeItem(at: dir) }

        var mine = BacklogTask(title: "Діагностувати ненадходження листів верифікації",
                               projectPath: project, type: .feature, priority: .p2, state: .executing)
        mine.dispatchedAt = Date()
        _ = store.add(mine)

        let dispatchID = UUID().uuidString
        store.bindDispatch(mine.id, dispatchID: dispatchID)

        store.adopt(from: finished(DispatchRecord(id: dispatchID, at: Date(),
                                                 task: "Діагностувати ненадходження листів верифікації",
                                                 reportKey: mine.reportKey))) { _ in nil }

        XCTAssertEqual(store.tasks.count, 1,
                       "the app's own job came back as a second card: \(store.tasks.map(\.title))")
        XCTAssertEqual(store.tasks.first?.id, mine.id)
    }

    @MainActor
    func testACardFromBeforeIdsWereStampedIsStillRecognisedByItsReportDirectory() {
        let (store, dir) = self.store(); defer { try? FileManager.default.removeItem(at: dir) }

        var legacy = BacklogTask(title: "Перевір рейтинг", projectPath: project,
                                 type: .feature, priority: .p2, state: .blocked)
        legacy.dispatchedAt = Date()
        _ = store.add(legacy)
        XCTAssertNil(store.tasks.first?.boundDispatchID, "the premise: no id was ever stamped")

        store.adopt(from: finished(DispatchRecord(id: "ENGINE-MINTED-ID", at: Date(),
                                                 task: "Перевір рейтинг",
                                                 reportKey: legacy.reportKey))) { _ in nil }

        XCTAssertEqual(store.tasks.count, 1, "a card that already owns that report got a twin")
    }

    @MainActor
    func testARevisionStillArrivesAsItsOwnCard() {
        let (store, dir) = self.store(); defer { try? FileManager.default.removeItem(at: dir) }

        var first = BacklogTask(title: "Перша робота", projectPath: project,
                                type: .feature, priority: .p2, state: .review)
        first.dispatchedAt = Date()
        _ = store.add(first)
        store.bindDispatch(first.id, dispatchID: "DISPATCH-1")

        store.adopt(from: finished(DispatchRecord(id: "REVISION-1", at: Date(),
                                                 task: "Ще дороби пошук",
                                                 reportKey: "9f9f9f9f", result: "passed"))) { _ in nil }

        XCTAssertEqual(store.tasks.count, 2, "the revision was swallowed by the card it followed")
        XCTAssertEqual(store.tasks.first?.title, "Ще дороби пошук")
    }

    // MARK: - One transcript, one console

    @MainActor
    func testTheSameSessionIsReadIntoOneTurnOnly() {
        let transcript = URL(fileURLWithPath: "/tmp/bulava-one-job/session.jsonl")

        var older = BacklogTask(title: "Робота", projectPath: project)
        older.dispatchedAt = Date().addingTimeInterval(-3600)
        var newer = BacklogTask(title: "Та сама робота, інша картка", projectPath: project)
        newer.dispatchedAt = Date()

        let picked = AppModel.onePerTranscript([(older, UUID(), transcript), (newer, UUID(), transcript)])
        XCTAssertEqual(picked.count, 1, "the same night was going to be shown twice")
        XCTAssertEqual(picked.first?.0.id, newer.id, "the card that is running should hold the feed")

        let reversed = AppModel.onePerTranscript([(newer, UUID(), transcript), (older, UUID(), transcript)])
        XCTAssertEqual(reversed.first?.0.id, newer.id)
    }

    @MainActor
    func testTwoDifferentSessionsAreBothFollowed() {
        var a = BacklogTask(title: "A", projectPath: project); a.dispatchedAt = Date()
        var b = BacklogTask(title: "B", projectPath: project); b.dispatchedAt = Date()
        let picked = AppModel.onePerTranscript([
            (a, UUID(), URL(fileURLWithPath: "/tmp/bulava-one-job/a.jsonl")),
            (b, UUID(), URL(fileURLWithPath: "/tmp/bulava-one-job/b.jsonl"))])
        XCTAssertEqual(picked.count, 2)
    }

    // MARK: - A revision inside a worktree still gets a card

    @MainActor
    func testARevisionInsideAWorktreeBecomesItsOwnCardOnTheProject() {
        let (store, dir) = self.store(); defer { try? FileManager.default.removeItem(at: dir) }
        let worktree = project + "/.nightshift-worktrees/one-job-AAAA1111"
        try? FileManager.default.createDirectory(atPath: worktree, withIntermediateDirectories: true)

        var original = BacklogTask(title: "Початкова робота", projectPath: project,
                                   type: .feature, priority: .p2, state: .blocked)
        original.dispatchedAt = Date()
        original.boundDispatchID = "D-FIRST"
        original.worktree = worktree
        original.productID = UUID()
        _ = store.add(original)

        var snap = SupervisorSnapshot()
        var inst = SupervisorInstance(slug: Slug.forPath(worktree), projectPath: worktree,
                                      session: "night-x", watchdogAlive: false,
                                      hasPlan: false, hasResearch: false)
        inst.runID = "RUN-ONE"
        inst.doneResult = "needs-user"
        inst.finishedAt = Date()
        inst.finishedDispatches = [DispatchRecord(id: "D-REVISION", at: Date(),
                                                  task: "Влий у main і доведи перевірку",
                                                  reportKey: "revi5ion", result: "needs-user",
                                                  finishedAt: Date())]
        snap.instances = [inst]
        store.adopt(from: snap) { _ in nil }

        let revision = store.tasks.first { $0.boundDispatchID == "D-REVISION" }
        XCTAssertNotNil(revision, "the revision produced a report with no card to open it from")
        XCTAssertEqual(revision?.reportKey, "revi5ion")
        XCTAssertEqual(revision?.projectPath, project,
                       "the card points at a worktree, which exists only while that run does")
        XCTAssertEqual(revision?.productID, original.productID,
                       "the revision landed outside the product it belongs to")
        XCTAssertEqual(revision?.worktree, worktree, "the run it came from is not recorded")
        XCTAssertEqual(store.tasks.count, 2)
    }

    @MainActor
    func testTheCardThatAskedForTheWorktreeIsNotDuplicatedByIt() {
        let (store, dir) = self.store(); defer { try? FileManager.default.removeItem(at: dir) }
        let worktree = project + "/.nightshift-worktrees/one-job-BBBB2222"
        try? FileManager.default.createDirectory(atPath: worktree, withIntermediateDirectories: true)

        var original = BacklogTask(title: "Робота", projectPath: project,
                                   type: .feature, priority: .p2, state: .executing)
        original.dispatchedAt = Date()
        original.boundDispatchID = "D-FIRST"
        original.worktree = worktree
        _ = store.add(original)

        var snap = SupervisorSnapshot()
        var inst = SupervisorInstance(slug: Slug.forPath(worktree), projectPath: worktree,
                                      session: "night-x", watchdogAlive: false,
                                      hasPlan: false, hasResearch: false)
        inst.runID = "RUN-ONE"; inst.doneResult = "passed"; inst.finishedAt = Date()
        inst.finishedDispatches = [DispatchRecord(id: "D-FIRST", at: Date(), task: "Робота",
                                                  reportKey: original.reportKey,
                                                  result: "passed", finishedAt: Date())]
        snap.instances = [inst]
        store.adopt(from: snap) { _ in nil }

        XCTAssertEqual(store.tasks.count, 1, "its own run gave the card a twin")
    }
}
