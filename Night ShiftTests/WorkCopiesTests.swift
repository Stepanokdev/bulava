import XCTest
@testable import Bulava

/// A run's own copy, on real repositories in a temporary folder whose name has a space in it.
///
/// What is proved is the promise made to him: his folder, his branch and his uncommitted work are
/// untouched until he merges; a merge only moves his branch forward and never switches it; nothing
/// is removed that is not provably ours, and nothing with work in it is removed without force.
nonisolated final class WorkCopiesTests: XCTestCase {

    private var scratch: URL!

    override func setUp() {
        super.setUp()
        scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("bulava copies \(UUID().uuidString.prefix(6))", isDirectory: true)
        try? FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        setenv("BULAVA_COPIES_DIR", scratch.appendingPathComponent("owned").path, 1)
        setenv("GIT_AUTHOR_NAME", "Test", 1); setenv("GIT_AUTHOR_EMAIL", "t@example.com", 1)
        setenv("GIT_COMMITTER_NAME", "Test", 1); setenv("GIT_COMMITTER_EMAIL", "t@example.com", 1)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: scratch)
        unsetenv("BULAVA_COPIES_DIR")
        super.tearDown()
    }

    @discardableResult
    @MainActor private func sh(_ script: String, in dir: URL) async -> CommandResult {
        let r = await Shell.run(script, cwd: dir, timeout: 60)
        XCTAssertTrue(r.ok, "\(script) failed: \(r.combined)")
        return r
    }

    /// A repository on `main` with one commit, an ignored `.env` named in `.worktreeinclude`, and
    /// ignored build output.
    @MainActor private func repo(_ name: String = "My Repo") async -> URL {
        let dir = scratch.appendingPathComponent(name, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        await sh("""
        git init -q -b main . && printf 'one\\n' > a.txt && printf '.env\\nbuild/\\nnotes.local\\n' > .gitignore \
        && printf '.env\\n' > .worktreeinclude && printf 'KEY=1\\n' > .env \
        && git add a.txt .gitignore .worktreeinclude && git commit -qm init
        """, in: dir)
        return dir
    }

    @MainActor private func make(_ source: URL, base: String? = nil, branch: String = "bulava/test/1") async -> WorkCopy {
        let result = await WorkCopies.make(sourcePath: source.path, projectID: UUID(), baseRef: base,
                                           branch: branch, owner: .run(UUID()))
        guard case .success(let copy) = result else {
            XCTFail("could not make a copy: \(result)")
            fatalError()
        }
        return copy
    }

    @MainActor private func head(_ dir: String) async -> String {
        await Shell.run("git rev-parse HEAD", cwd: URL(fileURLWithPath: dir)).stdout
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    @MainActor private func branch(_ dir: String) async -> String {
        await WorkCopies.currentBranch(of: dir) ?? ""
    }

    // MARK: Making one

    @MainActor
    func testACopyIsItsOwnCheckoutOnItsOwnBranchOutsideHisFolder() async {
        let source = await repo()
        let copy = await make(source)

        XCTAssertNotEqual(Slug.canonicalPath(copy.path), Slug.canonicalPath(source.path))
        XCTAssertFalse((copy.checkoutRoot as NSString).lastPathComponent.contains(" "),
                       "a copy's folder has no space even when his folder's does")
        XCTAssertFalse(copy.path.hasPrefix(source.path), "never inside his repository")
        let copyBranch = await branch(copy.path)
        let sourceBranch = await branch(source.path)
        XCTAssertEqual(copyBranch, "bulava/test/1")
        XCTAssertEqual(sourceBranch, "main", "his checkout did not move")
        let sourceHead = await head(source.path)
        XCTAssertEqual(copy.baseSHA, sourceHead)
        XCTAssertEqual(copy.baseRef, "main")
        let ours = await WorkCopies.isOurs(copy)
        XCTAssertTrue(ours)
    }

    @MainActor
    func testIgnoredFilesNamedInWorktreeIncludeAreCopiedAndNothingElse() async {
        let source = await repo()
        try? FileManager.default.createDirectory(at: source.appendingPathComponent("build"), withIntermediateDirectories: true)
        try? "big".write(to: source.appendingPathComponent("build/out.o"), atomically: true, encoding: .utf8)
        let copy = await make(source)
        XCTAssertEqual(copy.copiedFiles, [".env"])
        XCTAssertEqual(try? String(contentsOfFile: copy.path + "/.env", encoding: .utf8), "KEY=1\n")
        XCTAssertFalse(FileManager.default.fileExists(atPath: copy.path + "/build/out.o"))
    }

    @MainActor
    func testAMissingBranchOrAFolderWithoutGitStopsTheRunInsteadOfFallingBack() async {
        let source = await repo()
        let noBranch = await WorkCopies.make(sourcePath: source.path, projectID: UUID(), baseRef: "release",
                                             branch: "bulava/x", owner: .run(UUID()))
        XCTAssertEqual(noBranch.failureValue, .noBase("release"))

        let plain = scratch.appendingPathComponent("plain", isDirectory: true)
        try? FileManager.default.createDirectory(at: plain, withIntermediateDirectories: true)
        let notGit = await WorkCopies.make(sourcePath: plain.path, projectID: UUID(), baseRef: nil,
                                           branch: "bulava/x", owner: .run(UUID()))
        XCTAssertEqual(notGit.failureValue, .notARepository)
    }

    @MainActor
    func testATakenBranchNameGetsANumberRatherThanReusingIt() async {
        let source = await repo()
        let first = await make(source, branch: "bulava/same")
        let second = await make(source, branch: "bulava/same")
        XCTAssertEqual(first.branch, "bulava/same")
        XCTAssertEqual(second.branch, "bulava/same-2")
    }

    // MARK: Ours or not

    @MainActor
    func testAFolderThatIsNotTheRecordedCopyIsNeitherAdoptedNorRemoved() async {
        let source = await repo()
        var copy = await make(source)
        copy.id = UUID()    // the record no longer matches the marker in the folder
        let ours = await WorkCopies.isOurs(copy)
        XCTAssertFalse(ours)
        let removed = await WorkCopies.remove(copy, force: true, branch: .delete)
        XCTAssertEqual(removed.failureValue, .notOurs)
        XCTAssertTrue(FileManager.default.fileExists(atPath: copy.checkoutRoot), "a folder not provably ours is left alone")
    }

    // MARK: What is in it

    @MainActor
    func testStatusTellsWorkFromBuildOutputAndFromKeepsakes() async {
        let source = await repo()
        let copy = await make(source)
        let dir = URL(fileURLWithPath: copy.path)

        var st = await WorkCopies.status(of: copy)
        XCTAssertFalse(st.hasWork)
        XCTAssertTrue(st.keepsakes.isEmpty, "the copied .env is not his work: \(st.keepsakes)")

        try? FileManager.default.createDirectory(at: dir.appendingPathComponent("build"), withIntermediateDirectories: true)
        try? "o".write(to: dir.appendingPathComponent("build/x.o"), atomically: true, encoding: .utf8)
        st = await WorkCopies.status(of: copy)
        XCTAssertTrue(st.keepsakes.isEmpty, "build output never holds a copy back")

        try? "mine".write(to: dir.appendingPathComponent("notes.local"), atomically: true, encoding: .utf8)
        st = await WorkCopies.status(of: copy)
        XCTAssertEqual(st.keepsakes, ["notes.local"], "an ignored file that is somebody's is a keepsake")

        try? "two\n".write(to: dir.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        st = await WorkCopies.status(of: copy)
        XCTAssertEqual(st.uncommitted, ["a.txt"])
        XCTAssertTrue(st.hasWork)

        await sh("git commit -qam change", in: dir)
        st = await WorkCopies.status(of: copy)
        XCTAssertEqual(st.commitsAhead, 1)
        XCTAssertTrue(st.uncommitted.isEmpty)
    }

    // MARK: Merging

    @MainActor
    func testMergeFastForwardsTheBranchHeHasOpenWhenItIsClean() async {
        let source = await repo()
        let copy = await make(source)
        try? "two\n".write(toFile: copy.path + "/a.txt", atomically: true, encoding: .utf8)

        let merged = await WorkCopies.merge(copy, message: "Bulava: change")
        guard case .success(let tip) = merged else { return XCTFail("\(merged)") }
        let sourceHead = await head(source.path)
        let sourceBranch = await branch(source.path)
        XCTAssertEqual(sourceHead, tip)
        XCTAssertEqual(sourceBranch, "main")
        XCTAssertEqual(try? String(contentsOf: source.appendingPathComponent("a.txt"), encoding: .utf8), "two\n",
                       "the work is in his folder now")
    }

    @MainActor
    func testMergeIntoABranchHeDoesNotHaveOpenLeavesHisCheckoutAndDirtyFileAlone() async {
        let source = await repo()
        let copy = await make(source)
        await sh("git checkout -qb feature && printf 'mine\\n' > a.txt", in: source)
        try? "two\n".write(toFile: copy.path + "/b.txt", atomically: true, encoding: .utf8)

        let merged = await WorkCopies.merge(copy, message: "Bulava: add b")
        guard case .success(let tip) = merged else { return XCTFail("\(merged)") }
        let sourceBranch = await branch(source.path)
        XCTAssertEqual(sourceBranch, "feature", "his checkout was not switched")
        XCTAssertEqual(try? String(contentsOf: source.appendingPathComponent("a.txt"), encoding: .utf8), "mine\n",
                       "his uncommitted change is exactly as he left it")
        let mainTip = await Shell.run("git rev-parse main", cwd: source).stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertEqual(mainTip, tip, "main moved forward to the work")
    }

    // MARK: A merge the app cannot do alone goes to the chat

    func testWhatStopsTheAppButNotAnAgentGoesToTheChat() {
        XCTAssertTrue(AppModel.chatCanMerge(.targetDirty("main")), "his uncommitted changes: the chat puts them aside")
        XCTAssertTrue(AppModel.chatCanMerge(.conflict(["a.txt"])), "a conflict: the chat resolves it")
        XCTAssertTrue(AppModel.chatCanMerge(.targetMoved))
        XCTAssertFalse(AppModel.chatCanMerge(.notOurs), "a folder that is not ours is never handed on")
        XCTAssertFalse(AppModel.chatCanMerge(.nothingToMerge))
    }

    @MainActor
    func testAChatAskedToMergeIsAllowedHisFolderOnlyForThat() async {
        let source = await repo()
        var copy = await make(source)
        let plain = AutomationBrief.copyRules(copy, buildCache: "/c", automation: true)
        XCTAssertTrue(plain.contains("НЕ изменяй её"), plain)
        copy.integrating = Date()
        let merging = AutomationBrief.copyRules(copy, buildCache: "/c", automation: true)
        XCTAssertFalse(merging.contains("НЕ изменяй её"), "the rule that made the chat refuse is gone: \(merging)")
        XCTAssertTrue(merging.contains("git stash push -u"), merging)
        XCTAssertTrue(merging.contains("--ff-only \(copy.branch)"), merging)
    }

    func testACopySavedBeforeHandedMergesStillLoads() throws {
        let copy = WorkCopy(path: "/c", checkoutRoot: "/c", sourcePath: "/s", sourceRoot: "/s", projectID: UUID(),
                            branch: "b", baseRef: "main", baseSHA: "abc", owner: .chat(UUID()))
        var json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(copy)) as! [String: Any]
        json.removeValue(forKey: "integrating")
        let back = try JSONDecoder().decode(WorkCopy.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertNil(back.integrating)
    }

    /// The steps the chat is given, done as written, on the case he hit: his folder dirty in every
    /// way at once, and main moved on since the copy was made. The merge lands and his work stays his.
    @MainActor
    func testTheStepsTheChatIsGivenMergeIntoADirtyFolderAndKeepHisWork() async {
        let source = await repo()
        let copy = await make(source)
        try? "two\n".write(toFile: copy.path + "/b.txt", atomically: true, encoding: .utf8)
        await sh("git add b.txt && git commit -qm 'add b'", in: URL(fileURLWithPath: copy.path))
        await sh("printf 'new\\n' > c.txt && git add c.txt && git commit -qm 'main moved'", in: source)
        await sh("printf 'staged\\n' > s.txt && git add s.txt && printf 'dirty\\n' >> a.txt && printf 'fresh\\n' > u.txt", in: source)
        let notMergedAlone = await WorkCopies.merge(copy, message: "x")
        XCTAssertEqual(notMergedAlone.failureValue, .targetDirty("main"))

        await sh("git rebase -q main", in: URL(fileURLWithPath: copy.path))
        await sh("""
            git stash push -q -u -m "bulava-merge \(copy.branch)" && git merge -q --ff-only \(copy.branch) && git stash pop -q
            """, in: source)

        let integrated = await WorkCopies.isIntegrated(copy)
        XCTAssertTrue(integrated, "main has the copy's work")
        XCTAssertEqual(try? String(contentsOf: source.appendingPathComponent("b.txt"), encoding: .utf8), "two\n")
        XCTAssertTrue((try? String(contentsOf: source.appendingPathComponent("a.txt"), encoding: .utf8))?.hasSuffix("dirty\n") == true,
                      "his unstaged change is there")
        XCTAssertEqual(try? String(contentsOf: source.appendingPathComponent("u.txt"), encoding: .utf8), "fresh\n", "his new file too")
        let status = await Shell.run("git status --porcelain", cwd: source).stdout
        XCTAssertTrue(status.contains("s.txt") && status.contains("a.txt") && status.contains("u.txt"),
                      "none of it was committed: \(status)")
        let stashes = await Shell.run("git stash list", cwd: source).stdout
        XCTAssertTrue(stashes.isEmpty, "nothing left behind in the stash: \(stashes)")
    }

    @MainActor
    func testMergeRefusesWhenTheOpenBranchHasUncommittedChanges() async {
        let source = await repo()
        let copy = await make(source)
        let before = await head(source.path)
        try? "dirty\n".write(to: source.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        try? "two\n".write(toFile: copy.path + "/b.txt", atomically: true, encoding: .utf8)

        let merged = await WorkCopies.merge(copy, message: "x")
        XCTAssertEqual(merged.failureValue, .targetDirty("main"))
        let after = await head(source.path)
        XCTAssertEqual(after, before)
        XCTAssertEqual(try? String(contentsOf: source.appendingPathComponent("a.txt"), encoding: .utf8), "dirty\n")
    }

    /// A question git did not answer is not "nothing to merge": the run would be marked merged and
    /// its copy taken for empty while the work in it had reached nobody.
    @MainActor
    func testAMergeGitCouldNotCountIsAFailureNotNothing() async {
        let source = await repo()
        var copy = await make(source)
        let before = await head(source.path)
        try? "two\n".write(toFile: copy.path + "/b.txt", atomically: true, encoding: .utf8)
        copy.baseSHA = String(repeating: "0", count: 39) + "1"

        let merged = await WorkCopies.merge(copy, message: "x")
        guard case .failure(.gitFailed) = merged else { return XCTFail("\(merged)") }
        let after = await head(source.path)
        XCTAssertEqual(after, before, "his branch did not move")
        XCTAssertEqual(try? String(contentsOfFile: copy.path + "/b.txt", encoding: .utf8), "two\n",
                       "and the work is still in the copy")
    }

    @MainActor
    func testAConflictStaysInTheCopyAndHisBranchDoesNotMove() async {
        let source = await repo()
        let copy = await make(source)
        try? "copy\n".write(toFile: copy.path + "/a.txt", atomically: true, encoding: .utf8)
        await sh("printf 'his\\n' > a.txt && git commit -qam his", in: source)
        let sourceBefore = await head(source.path)

        let merged = await WorkCopies.merge(copy, message: "x")
        guard case .failure(.conflict(let files)) = merged else { return XCTFail("\(merged)") }
        XCTAssertEqual(files, ["a.txt"])
        let sourceAfter = await head(source.path)
        XCTAssertEqual(sourceAfter, sourceBefore)
        let rebasing = FileManager.default.fileExists(atPath: copy.checkoutRoot + "/.git")
        XCTAssertTrue(rebasing)
        let st = await WorkCopies.status(of: copy)
        XCTAssertEqual(st.commitsAhead, 1, "the copy keeps its work, committed, ready to try again")
    }

    @MainActor
    func testMergeRefusesABranchOpenInAnotherCheckout() async {
        let source = await repo()
        let copy = await make(source)
        await sh("git checkout -qb other", in: source)
        let elsewhere = scratch.appendingPathComponent("elsewhere").path
        await sh("git worktree add -q \"\(elsewhere)\" main", in: source)
        try? "two\n".write(toFile: copy.path + "/b.txt", atomically: true, encoding: .utf8)

        let merged = await WorkCopies.merge(copy, message: "x")
        guard case .failure(.targetElsewhere) = merged else { return XCTFail("\(merged)") }
    }

    // MARK: Removing

    @MainActor
    func testAMergedCopyGoesWithItsBranchAndAnUnmergedOneKeepsItsBranch() async {
        let source = await repo()
        let merged = await make(source, branch: "bulava/merged")
        try? "two\n".write(toFile: merged.path + "/b.txt", atomically: true, encoding: .utf8)
        _ = await WorkCopies.merge(merged, message: "x")
        let removed = await WorkCopies.remove(merged, force: false, branch: .deleteIfIntegrated)
        XCTAssertNil(removed.failureValue)
        XCTAssertFalse(FileManager.default.fileExists(atPath: merged.checkoutRoot))
        let mergedBranchGone = !(await WorkCopies.refExists("refs/heads/bulava/merged", in: source.path))
        XCTAssertTrue(mergedBranchGone)

        let kept = await make(source, branch: "bulava/kept")
        try? "three\n".write(toFile: kept.path + "/c.txt", atomically: true, encoding: .utf8)
        _ = await WorkCopies.commitPending(kept, message: "keep")
        let refusedWithoutForce = await WorkCopies.remove(kept, force: false, branch: .deleteIfIntegrated)
        XCTAssertNil(refusedWithoutForce.failureValue)
        let keptBranch = await WorkCopies.refExists("refs/heads/bulava/kept", in: source.path)
        XCTAssertTrue(keptBranch, "work not on his branch keeps its branch")
    }

    @MainActor
    func testRemovingWithoutForceRefusesUncommittedWork() async {
        let source = await repo()
        let copy = await make(source)
        try? "wip\n".write(toFile: copy.path + "/wip.txt", atomically: true, encoding: .utf8)
        let removed = await WorkCopies.remove(copy, force: false, branch: .keep)
        XCTAssertNotNil(removed.failureValue)
        XCTAssertTrue(FileManager.default.fileExists(atPath: copy.path + "/wip.txt"), "uncommitted work survives")
        let stillOurs = await WorkCopies.isOurs(copy)
        XCTAssertTrue(stillOurs, "and the copy is locked again, still ours")
    }

    @MainActor
    func testDiscardTakesTheCopyItsWorkAndItsBranch() async {
        let source = await repo()
        let copy = await make(source, branch: "bulava/discard")
        try? "wip\n".write(toFile: copy.path + "/wip.txt", atomically: true, encoding: .utf8)
        let removed = await WorkCopies.remove(copy, force: true, branch: .delete)
        XCTAssertNil(removed.failureValue)
        XCTAssertFalse(FileManager.default.fileExists(atPath: copy.checkoutRoot))
        let branchGone = !(await WorkCopies.refExists("refs/heads/bulava/discard", in: source.path))
        XCTAssertTrue(branchGone)
        let sourceBranch = await branch(source.path)
        XCTAssertEqual(sourceBranch, "main")
    }

    @MainActor
    func testReportsInArtifactsOutliveTheCopy() async {
        let source = await repo()
        await sh("printf 'artifacts/\\n' >> .gitignore && git commit -qam ignore-artifacts", in: source)
        let copy = await make(source)
        try? FileManager.default.createDirectory(atPath: copy.path + "/artifacts", withIntermediateDirectories: true)
        try? "report".write(toFile: copy.path + "/artifacts/r.md", atomically: true, encoding: .utf8)
        let st = await WorkCopies.status(of: copy)
        XCTAssertTrue(st.keepsakes.isEmpty, "artifacts are carried out, so they do not hold the copy")
        _ = await WorkCopies.remove(copy, force: false, branch: .delete)
        let kept = WorkCopies.keptArtifacts(for: copy).appendingPathComponent("r.md")
        XCTAssertEqual(try? String(contentsOf: kept, encoding: .utf8), "report")
        try? FileManager.default.removeItem(at: kept.deletingLastPathComponent().deletingLastPathComponent())
    }

    func testWhereCopiesLiveHasNoSpaceAndIsInNoRepository() {
        unsetenv("BULAVA_COPIES_DIR")
        defer { setenv("BULAVA_COPIES_DIR", scratch.appendingPathComponent("owned").path, 1) }
        let root = WorkCopies.root.path
        // The test host is Bulava Dev, whose copies live apart from his (`AppChannel`).
        XCTAssertEqual(root, AppChannel.current.developerFolder().appendingPathComponent("copies").path)
        XCTAssertTrue(AppChannel.production.developerFolder().path.hasSuffix("/Library/Developer/Bulava"))
        for channel in [AppChannel.production, .dev] {
            XCTAssertFalse(channel.developerFolder().path.replacingOccurrences(of: NSHomeDirectory(), with: "")
                .contains(" "), "\(channel)")
        }
        XCTAssertFalse(root.replacingOccurrences(of: NSHomeDirectory(), with: "").contains(" "))
    }

    func testTrustIsGivenUnderTheRealPathClaudeLooksUp() throws {
        let config = scratch.appendingPathComponent("claude-real.json")
        try JSONSerialization.data(withJSONObject: ["projects": [String: Any]()]).write(to: config)
        // The temporary folder lives under /private: Claude names it /private/var/…, Foundation /var/….
        let folder = scratch.appendingPathComponent("trusted").path
        try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        XCTAssertTrue(ClaudeFolderTrust.grant(forProjectPath: folder, configURL: config))
        let projects = (try JSONSerialization.jsonObject(with: Data(contentsOf: config)) as! [String: Any])["projects"] as! [String: Any]
        let real = ClaudeFolderTrust.realPath(folder)
        XCTAssertTrue(real.hasPrefix("/private/"), real)
        XCTAssertEqual((projects[real] as? [String: Any])?["hasTrustDialogAccepted"] as? Bool, true)
    }

    func testARemovedCopysTrustEntryIsForgottenAndALiveFoldersIsNot() throws {
        let config = scratch.appendingPathComponent("claude.json")
        let live = scratch.appendingPathComponent("live").path
        try FileManager.default.createDirectory(atPath: live, withIntermediateDirectories: true)
        let gone = scratch.appendingPathComponent("gone").path
        let json: [String: Any] = ["projects": [gone: ["hasTrustDialogAccepted": true],
                                                live: ["hasTrustDialogAccepted": true]],
                                   "other": 1]
        try JSONSerialization.data(withJSONObject: json).write(to: config)

        XCTAssertTrue(ClaudeFolderTrust.forget(forProjectPath: gone, configURL: config))
        XCTAssertFalse(ClaudeFolderTrust.forget(forProjectPath: live, configURL: config), "a folder that exists is never forgotten")
        let after = try JSONSerialization.jsonObject(with: Data(contentsOf: config)) as! [String: Any]
        let projects = after["projects"] as! [String: Any]
        XCTAssertNil(projects[gone])
        XCTAssertNotNil(projects[live])
        XCTAssertEqual(after["other"] as? Int, 1, "nothing else in his config is touched")
    }

    @MainActor
    func testAnUnreadableReportFolderKeepsTheCopy() async {
        let source = await repo()
        await sh("printf 'artifacts/\\n' >> .gitignore && git commit -qam ignore-artifacts", in: source)
        let copy = await make(source)
        let artifacts = copy.path + "/artifacts"
        try? FileManager.default.createDirectory(atPath: artifacts, withIntermediateDirectories: true)
        try? "report".write(toFile: artifacts + "/r.md", atomically: true, encoding: .utf8)
        chmod(artifacts, 0o000)
        defer { chmod(artifacts, 0o755) }
        let removed = await WorkCopies.remove(copy, force: true, branch: .delete)
        XCTAssertNotNil(removed.failureValue, "a report that cannot be read is not taken with the copy")
        XCTAssertTrue(FileManager.default.fileExists(atPath: copy.checkoutRoot))
    }

    // MARK: Pure helpers

    func testPorcelainRenamesDoNotLeakTheirOldPath() {
        let text = "R  new name.txt\0old name.txt\0 M a.txt\0?? b.txt\0"
        XCTAssertEqual(WorkCopies.porcelainPaths(text), ["new name.txt", "a.txt", "b.txt"])
    }

    func testBranchNamesAreTypableFromUkrainianTitles() {
        XCTAssertEqual(WorkCopies.branchSlug("Моделі для Наради"), "modeli-dla-naradi")
        XCTAssertEqual(WorkCopies.branchSlug("Mobile parity!"), "mobile-parity")
        XCTAssertEqual(WorkCopies.branchSlug("   "), "run")
    }

    func testWhatIsDisposable() {
        XCTAssertTrue(WorkCopies.isDisposable("build_dd/", copied: []))
        XCTAssertTrue(WorkCopies.isDisposable("DerivedData/", copied: []))
        XCTAssertTrue(WorkCopies.isDisposable("app/build/", copied: []))
        XCTAssertTrue(WorkCopies.isDisposable(".env", copied: [".env"]))
        XCTAssertFalse(WorkCopies.isDisposable(".env", copied: []))
        XCTAssertFalse(WorkCopies.isDisposable("secrets/key.pem", copied: []))
    }
}

extension Result {
    var failureValue: Failure? {
        if case .failure(let f) = self { return f }
        return nil
    }
}
