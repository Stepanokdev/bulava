import XCTest
@testable import Bulava

/// Cards and copies: a card started while its project is busy works in the same managed copy an
/// automation run gets; a copy that cannot be made stops the start and leaves everything as it was;
/// a card never runs in a copy that is gone; and approving a card never switches his branch.
nonisolated final class CardCopiesTests: XCTestCase {

    private var scratch: URL!

    override func setUp() {
        super.setUp()
        scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("bulava-cards-\(UUID().uuidString.prefix(6))", isDirectory: true)
        try? FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        setenv("BULAVA_STATE_DIR", scratch.appendingPathComponent("state").path, 1)
        setenv("BULAVA_COPIES_DIR", scratch.appendingPathComponent("copies").path, 1)
        setenv("GIT_AUTHOR_NAME", "Test", 1); setenv("GIT_AUTHOR_EMAIL", "t@example.com", 1)
        setenv("GIT_COMMITTER_NAME", "Test", 1); setenv("GIT_COMMITTER_EMAIL", "t@example.com", 1)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: scratch)
        unsetenv("BULAVA_COPIES_DIR")
        super.tearDown()
    }

    @discardableResult
    @MainActor private func sh(_ script: String, in dir: URL) async -> String {
        let r = await Shell.run(script, cwd: dir, timeout: 60)
        XCTAssertTrue(r.ok, "\(script): \(r.combined)")
        return r.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    @MainActor private func folder(_ name: String, commit: Bool = true) async -> URL {
        let dir = scratch.appendingPathComponent(name, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        await sh("git init -q -b main .", in: dir)
        if commit { await sh("printf 'one\\n' > a.txt && git add a.txt && git commit -qm init", in: dir) }
        return dir
    }

    @MainActor private func model() -> AppModel {
        let m = AppModel()
        m.readyCopyOverride = { _ in }
        return m
    }

    @MainActor private func card(_ m: AppModel, path: String, worktree: String? = nil,
                                 state: TaskState = .ready) -> BacklogTask {
        var t = BacklogTask(title: "Закріпити кнопку", projectPath: path, type: .feature, priority: .p2, state: state)
        t.id = UUID()
        t.worktree = worktree
        return m.backlog.add(t)
    }

    // MARK: A copy that cannot be made

    @MainActor
    func testACopyThatCannotBeMadeLeavesTheCardUndispatchedAndHisFolderUntouched() async {
        let m = model()
        // A repository with nothing committed has no branch a copy could start from.
        let repo = await folder("Empty Repo", commit: false)
        try? "draft\n".write(to: repo.appendingPathComponent("notes.txt"), atomically: true, encoding: .utf8)
        let statusBefore = await sh("git status --porcelain", in: repo)
        let task = card(m, path: repo.path)
        let before = m.backlog.task(id: task.id)!

        m.backlog.markDispatched(task.id)     // what dispatch does before it looks for a folder
        let folder = await m.prepareCardFolder(task: task, projectPath: repo.path, isolated: true, continuing: false)
        guard case .refused(let why) = folder else { return XCTFail("a copy that cannot be made must stop the start: \(folder)") }
        m.abandonCardStart(before, reason: why)

        let after = m.backlog.task(id: task.id)!
        XCTAssertNil(after.dispatchedAt, "the card is not dispatched")
        XCTAssertEqual(after.state, before.state)
        XCTAssertNil(after.worktree)
        XCTAssertNotNil(m.toast, "and it says why")
        let statusAfter = await sh("git status --porcelain", in: repo)
        XCTAssertEqual(statusAfter, statusBefore, "his folder is exactly as it was")
        let worktrees = await sh("git worktree list", in: repo)
        XCTAssertEqual(worktrees.split(separator: "\n").count, 1, "no copy was left behind")
    }

    @MainActor
    func testABusyProjectsCardGetsAManagedCopyNotANestedOne() async {
        let m = model()
        let repo = await folder("Map Alerts")
        let task = card(m, path: repo.path)

        let folder = await m.prepareCardFolder(task: task, projectPath: repo.path, isolated: true, continuing: false)
        guard case .folder(let path) = folder else { return XCTFail("\(folder)") }
        XCTAssertNotEqual(Slug.canonicalPath(path), Slug.canonicalPath(repo.path))
        XCTAssertFalse(path.contains(".nightshift-worktrees"), "the old nested copies are not made any more")
        XCTAssertTrue(path.hasPrefix(WorkCopies.root.path))
        XCTAssertEqual(m.backlog.task(id: task.id)?.worktree, path)
        guard let copy = m.automations.copies.first(where: { $0.path == path }) else { return XCTFail("not on the record") }
        XCTAssertEqual(copy.owner, .task(task.id))
        XCTAssertEqual(copy.state, .active)
        let ours = await WorkCopies.isOurs(copy)
        XCTAssertTrue(ours)
        XCTAssertTrue(copy.branch.hasPrefix("night/task-"))
    }

    @MainActor
    func testAnotherCardsCopyIsNotThisCardsFolder() async {
        let m = model()
        let repo = await folder("Shared")
        let first = card(m, path: repo.path)
        guard case .folder(let path) = await m.prepareCardFolder(task: first, projectPath: repo.path,
                                                                 isolated: true, continuing: false) else {
            return XCTFail("no copy")
        }
        let second = card(m, path: repo.path, worktree: path)
        let usable = await m.cardCopyIsUsable(path, projectPath: repo.path, taskID: second.id)
        XCTAssertFalse(usable, "a copy belongs to the card it was made for")
    }

    // MARK: A recorded copy that is gone

    @MainActor
    func testACardWhoseCopyIsGoneStartsInItsFolderAndKeepsThePathForItsHistory() async {
        let m = model()
        let repo = await folder("Clear Sky")
        let gone = scratch.appendingPathComponent(".nightshift-worktrees/Map Alerts-6B1B9FAE").path
        let task = card(m, path: repo.path, worktree: gone)

        let folder = await m.prepareCardFolder(task: task, projectPath: repo.path, isolated: false, continuing: false)
        XCTAssertEqual(folder, .folder(repo.path), "a fresh start goes where it should, not to a folder that is not there")
        let after = m.backlog.task(id: task.id)!
        XCTAssertNil(after.worktree)
        XCTAssertEqual(after.retiredWorktrees, [gone], "kept where its old transcripts are looked for")
    }

    @MainActor
    func testContinuingInACopyThatIsGoneIsRefusedNotSentElsewhere() async {
        let m = model()
        let repo = await folder("phone-app")
        let gone = scratch.appendingPathComponent("copies/gone").path
        let task = card(m, path: repo.path, worktree: gone, state: .review)

        let folder = await m.prepareCardFolder(task: task, projectPath: repo.path, isolated: false, continuing: true)
        guard case .refused = folder else { return XCTFail("a follow-up for work that lived in a gone copy must not land in his folder: \(folder)") }
        XCTAssertNil(m.backlog.task(id: task.id)?.worktree)
    }

    @MainActor
    func testAFolderThatIsNotACheckoutOfTheProjectIsNotUsed() async {
        let m = model()
        let repo = await folder("App")
        let stranger = await folder("Someone Else")
        let task = card(m, path: repo.path, worktree: stranger.path)
        let folder = await m.prepareCardFolder(task: task, projectPath: repo.path, isolated: false, continuing: false)
        XCTAssertEqual(folder, .folder(repo.path))
        XCTAssertEqual(m.backlog.task(id: task.id)?.retiredWorktrees, [stranger.path])
    }

    @MainActor
    func testAnOlderCopyThatIsStillACheckoutOfTheProjectIsStillUsed() async {
        let m = model()
        let repo = await folder("Pocket Ledger")
        let legacy = scratch.appendingPathComponent(".nightshift-worktrees/Pocket Ledger-3CC6DEF7").path
        await sh("git worktree add -q -b night/task-3CC6DEF7 \"\(legacy)\"", in: repo)
        let task = card(m, path: repo.path, worktree: legacy, state: .review)
        let folder = await m.prepareCardFolder(task: task, projectPath: repo.path, isolated: false, continuing: true)
        XCTAssertEqual(folder, .folder(legacy), "the work of an open card stays where it is")
    }

    @MainActor
    func testDeadPointersAreRetiredAtLaunchAndLiveOnesKept() async {
        let m = model()
        let repo = await folder("Narada")
        let live = scratch.appendingPathComponent("live-copy")
        try? FileManager.default.createDirectory(at: live, withIntermediateDirectories: true)
        let dead = card(m, path: repo.path, worktree: scratch.appendingPathComponent("dead").path)
        let alive = card(m, path: repo.path, worktree: live.path)
        let retired = m.backlog.retireDeadWorktrees()
        XCTAssertEqual(retired, 1)
        XCTAssertNil(m.backlog.task(id: dead.id)?.worktree)
        XCTAssertEqual(m.backlog.task(id: alive.id)?.worktree, live.path)
    }

    @MainActor
    func testAFinishedCardsCopyGoesAndItsBranchWithItsCommitsStays() async {
        let m = model()
        let repo = await folder("Ledger")
        let task = card(m, path: repo.path)
        guard case .folder(let path) = await m.prepareCardFolder(task: task, projectPath: repo.path,
                                                                 isolated: true, continuing: false) else {
            return XCTFail("no copy")
        }
        await sh("printf 'two\\n' > b.txt && git add b.txt && git commit -qm work", in: URL(fileURLWithPath: path))
        let copy = m.automations.copies.first { $0.path == path }!

        await m.sweepCopies()
        XCTAssertTrue(FileManager.default.fileExists(atPath: path), "an open card keeps its copy")

        m.backlog.setState(task.id, .merged)
        await m.sweepCopies()
        XCTAssertFalse(FileManager.default.fileExists(atPath: path), "a finished card's copy goes")
        let branchKept = await WorkCopies.refExists("refs/heads/\(copy.branch)", in: repo.path)
        XCTAssertTrue(branchKept, "its commits live on in its branch")
    }

    // MARK: Approving a card

    @MainActor private func cardBranch(_ repo: URL) async {
        await sh("git checkout -qb night/task-1 && printf 'card\\n' > card.txt && git add card.txt && git commit -qm card && git checkout -q main", in: repo)
    }

    @MainActor
    func testApprovingIntoTheBranchHeHasOpenMergesThereAsBefore() async {
        let repo = await folder("In Place")
        await cardBranch(repo)
        let result = await SupervisorClient(paths: SupervisorPaths(stateDir: scratch)).merge(
            projectPath: repo.path, branch: "night/task-1", target: "main")
        XCTAssertTrue(result.isSuccess, "\(result)")
        let branch = await sh("git branch --show-current", in: repo)
        XCTAssertEqual(branch, "main")
        XCTAssertTrue(FileManager.default.fileExists(atPath: repo.appendingPathComponent("card.txt").path))
    }

    @MainActor
    func testApprovingWhileHeIsOnAnotherBranchNeverSwitchesItOrTouchesHisWork() async {
        let repo = await folder("Elsewhere")
        await cardBranch(repo)
        await sh("git checkout -qb his-feature && printf 'mine\\n' > a.txt", in: repo)
        let result = await SupervisorClient(paths: SupervisorPaths(stateDir: scratch)).merge(
            projectPath: repo.path, branch: "night/task-1", target: "main")
        XCTAssertTrue(result.isSuccess, "\(result)")
        let branch = await sh("git branch --show-current", in: repo)
        XCTAssertEqual(branch, "his-feature", "his branch was not switched")
        XCTAssertEqual(try? String(contentsOf: repo.appendingPathComponent("a.txt"), encoding: .utf8), "mine\n",
                       "his uncommitted change is as he left it")
        XCTAssertFalse(FileManager.default.fileExists(atPath: repo.appendingPathComponent("card.txt").path),
                       "his folder did not get the card's files")
        let onMain = await sh("git ls-tree --name-only main", in: repo)
        XCTAssertTrue(onMain.contains("card.txt"), "main has the card's work")
        let worktrees = await sh("git worktree list", in: repo)
        XCTAssertEqual(worktrees.split(separator: "\n").count, 1, "the temporary checkout is gone")
    }

    @MainActor
    func testATargetOpenInAnotherCheckoutIsNotMovedUnderIt() async {
        let repo = await folder("Open Elsewhere")
        await cardBranch(repo)
        await sh("git checkout -qb his-feature", in: repo)
        let other = scratch.appendingPathComponent("other-checkout").path
        await sh("git worktree add -q \"\(other)\" main", in: repo)
        let before = await sh("git rev-parse main", in: repo)
        let result = await SupervisorClient(paths: SupervisorPaths(stateDir: scratch)).merge(
            projectPath: repo.path, branch: "night/task-1", target: "main")
        guard case .failed = result else { return XCTFail("\(result)") }
        let after = await sh("git rev-parse main", in: repo)
        XCTAssertEqual(after, before)
    }

    @MainActor
    func testAConflictMovesNothingAndLeavesNoCheckoutBehind() async {
        let repo = await folder("Conflict")
        await sh("git checkout -qb night/task-1 && printf 'card\\n' > a.txt && git commit -qam card && git checkout -q main && printf 'main\\n' > a.txt && git commit -qam main && git checkout -qb his-feature", in: repo)
        let before = await sh("git rev-parse main", in: repo)
        let result = await SupervisorClient(paths: SupervisorPaths(stateDir: scratch)).merge(
            projectPath: repo.path, branch: "night/task-1", target: "main")
        guard case .conflict = result else { return XCTFail("\(result)") }
        let after = await sh("git rev-parse main", in: repo)
        XCTAssertEqual(after, before)
        let branch = await sh("git branch --show-current", in: repo)
        XCTAssertEqual(branch, "his-feature")
        let worktrees = await sh("git worktree list", in: repo)
        XCTAssertEqual(worktrees.split(separator: "\n").count, 1)
    }
}
