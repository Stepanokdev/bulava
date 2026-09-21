import XCTest
@testable import Bulava

nonisolated final class WorktreeReconcileTests: XCTestCase {

    @MainActor private func store() -> (BacklogStore, URL) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("bulava-wt-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        setenv("BULAVA_STATE_DIR", dir.path, 1)
        return (BacklogStore(), dir)
    }

    private let project = "/tmp/pocket-ledger"
    private let worktree = "/tmp/.nightshift-worktrees/pocket-ledger-EF0F5C9E"

    @MainActor private func dispatchedTask(_ store: BacklogStore, inWorktree: Bool) -> UUID {
        var t = BacklogTask(title: "Закріпити кнопку у хедері", projectPath: project,
                            type: .feature, priority: .p2, state: .executing)
        t.id = UUID()

        t.dispatchedAt = Date().addingTimeInterval(-3600)
        if inWorktree { t.worktree = worktree }
        return store.add(t).id
    }

    @MainActor private func snapshot(runningAt path: String) -> SupervisorSnapshot {
        var snap = SupervisorSnapshot()
        snap.instances = [SupervisorInstance(slug: Slug.forPath(path), projectPath: path,
                                             session: "s", watchdogAlive: true,
                                             hasPlan: false, hasResearch: false)]
        return snap
    }

    @MainActor
    func testAWorkerInAWorktreeKeepsItsTaskAlive() {
        let (store, dir) = self.store(); defer { try? FileManager.default.removeItem(at: dir) }
        let id = dispatchedTask(store, inWorktree: true)

        store.reconcile(with: snapshot(runningAt: worktree))

        let after = store.task(id: id)
        XCTAssertEqual(after?.state, .executing, "its worker is alive — in the worktree")
        XCTAssertNotEqual(after?.lastOutcome, "gone")
    }

    @MainActor
    func testATaskWithNoWorkerAnywhereIsStillDeclaredGone() {
        let (store, dir) = self.store(); defer { try? FileManager.default.removeItem(at: dir) }
        let id = dispatchedTask(store, inWorktree: true)

        store.reconcile(with: SupervisorSnapshot())

        XCTAssertEqual(store.task(id: id)?.state, .failed)
        XCTAssertEqual(store.task(id: id)?.lastOutcome, "gone")
    }

    @MainActor
    func testAnOrdinaryTaskStillMatchesItsProject() {
        let (store, dir) = self.store(); defer { try? FileManager.default.removeItem(at: dir) }
        let id = dispatchedTask(store, inWorktree: false)

        store.reconcile(with: snapshot(runningAt: project))

        XCTAssertEqual(store.task(id: id)?.state, .executing)
    }
}
