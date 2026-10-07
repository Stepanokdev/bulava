import XCTest
import SwiftUI
@testable import Bulava

/// A start meets the director's uncommitted work, and nothing is committed until they say so.
///
/// It used to be: the engine answered a dirty folder with `git add -A` and a commit as `night-shift`
/// into the director's own branch. Now it stops with exit 77 and Bulava asks. These tests hold the
/// two halves to one contract — what the engine reports is what the app shows — and the app's side
/// of the promise: an answer is used once, «Not now» sends nothing later, and a folder that comes
/// clean sends the message exactly once.
nonisolated final class UncommittedWorkTests: XCTestCase {

    // MARK: The engine's report, as the app reads it

    private var engine: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("engine")
    }

    private func git(_ dir: URL, _ args: String...) throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        p.arguments = ["-C", dir.path] + args
        p.environment = ["HOME": dir.path, "GIT_CONFIG_NOSYSTEM": "1", "PATH": "/usr/bin:/bin"]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try p.run(); p.waitUntilExit()
        XCTAssertEqual(p.terminationStatus, 0, "git \(args.joined(separator: " "))")
    }

    private func dirtyRepo() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("bulava-dirty-\(UUID().uuidString)").resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        try git(dir, "init", "-q", "-b", "main")
        try git(dir, "config", "user.name", "Ihor Director")
        try git(dir, "config", "user.email", "ihor@example.com")
        try "one\n".write(to: dir.appendingPathComponent("a.spec.ts"), atomically: true, encoding: .utf8)
        try "two\n".write(to: dir.appendingPathComponent("b.txt"), atomically: true, encoding: .utf8)
        try git(dir, "add", ".")
        try git(dir, "commit", "-qm", "base")
        try "one\nCONTRAST(1)\n".write(to: dir.appendingPathComponent("a.spec.ts"), atomically: true, encoding: .utf8)
        try "two\nstaged\n".write(to: dir.appendingPathComponent("b.txt"), atomically: true, encoding: .utf8)
        try git(dir, "add", "b.txt")
        try "draft\n".write(to: dir.appendingPathComponent("notes.md"), atomically: true, encoding: .utf8)
        return dir
    }

    @MainActor
    func testTheEnginesReportIsWhatTheAppReads() async throws {
        let dir = try dirtyRepo()
        let r = await Shell.run("bash \"$1/bin/night-shift.sh\" dirty-state \"$2\"",
                                args: [engine.path, dir.path], timeout: 60)
        XCTAssertEqual(r.exitCode, 0, r.stderr)
        let tree = try XCTUnwrap(DirtyTree.parse(r.stdout), "unparseable: \(r.stdout)")
        XCTAssertTrue(tree.dirty)
        XCTAssertFalse(tree.unborn)
        XCTAssertTrue(tree.keepPossible)
        XCTAssertFalse(tree.isSettled)
        XCTAssertEqual(tree.branch, "main")
        XCTAssertEqual(tree.author, "Ihor Director <ihor@example.com>",
                       "the sheet names the director's own identity, never night-shift")
        XCTAssertEqual(Set(tree.files.map(\.path)), ["a.spec.ts", "b.txt", "notes.md"])
        XCTAssertEqual(tree.files.first { $0.path == "notes.md" }?.kind, .untracked)
        XCTAssertEqual(tree.files.first { $0.path == "a.spec.ts" }?.kind, .modified)
        XCTAssertTrue(tree.hasStagedSplit, "b.txt is staged, the others are not — the sheet says so")
        XCTAssertFalse(tree.digest.isEmpty)
    }

    func testAPlainRepositoryReadsAsSettled() throws {
        let json = #"{"dirty":false,"unborn":false,"head":"abc","branch":"main","digest":"d","author":null,"keep_possible":true,"total":0,"files":[]}"#
        let tree = try XCTUnwrap(DirtyTree.parse(json))
        XCTAssertTrue(tree.isSettled)
        XCTAssertNil(tree.author)
    }

    func testARepositoryWithNoCommitIsNeverSettledAndCannotBeLeftAsItIs() throws {
        let json = #"{"dirty":true,"unborn":true,"head":"","branch":"main","digest":"d","author":"A <a@b>","keep_possible":false,"total":0,"files":[]}"#
        let tree = try XCTUnwrap(DirtyTree.parse(json))
        XCTAssertFalse(tree.isSettled)
        XCTAssertFalse(tree.keepPossible)
        XCTAssertEqual(tree.suggestedMessage, "Initial commit")
    }

    func testTheKindsReadTheWayAPersonReadsThem() {
        func kind(_ xy: String) -> DirtyTree.Entry.Kind { DirtyTree.Entry(xy: xy, path: "x").kind }
        XCTAssertEqual(kind(" M"), .modified)
        XCTAssertEqual(kind("MM"), .modified)
        XCTAssertEqual(kind("A "), .added)
        XCTAssertEqual(kind(" D"), .deleted)
        XCTAssertEqual(kind("D "), .deleted)
        XCTAssertEqual(kind("R "), .renamed)
        XCTAssertEqual(kind("??"), .untracked)
        XCTAssertEqual(kind("UU"), .conflicted)
    }

    func testTheAnswerReachesTheEngineAsItsOwnVariables() {
        XCTAssertEqual(DirtyTreeChoice.keep.env, ["SUPERVISOR_DIRTY": "keep"])
        XCTAssertEqual(DirtyTreeChoice.commit(message: "  test: pin it  ", digest: "abc").env,
                       ["SUPERVISOR_DIRTY": "commit", "SUPERVISOR_DIRTY_DIGEST": "abc",
                        "SUPERVISOR_COMMIT_MESSAGE": "test: pin it"])
        XCTAssertNil(DirtyTreeChoice.commit(message: " ", digest: "abc").env["SUPERVISOR_COMMIT_MESSAGE"],
                     "an empty message lets the engine write its own, with the file list")
    }

    // MARK: The app's half of the promise

    @MainActor
    private func chatWithProduct() -> (AppModel, Chat, UUID) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("bulava-dirty-state-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        setenv("BULAVA_STATE_DIR", dir.path, 1)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: dir)
            unsetenv("BULAVA_STATE_DIR")
        }
        let model = AppModel()
        // A product with no folder: a retry resolves it and stops at «choose a primary folder»
        // without starting anything — which is exactly how a retry is observed here.
        let productID = model.products.add(name: "Bulava").id
        let chat = model.conversations.newChat(for: productID)
        return (model, chat, productID)
    }

    @MainActor
    private func failedMessage(_ model: AppModel, _ chat: Chat, _ productID: UUID) -> UUID {
        var entry = ConversationEntry(productID: productID, kind: .user, text: "test")
        entry.chatID = chat.id
        model.conversations.append(entry)
        model.conversations.updateDelivery(entryID: entry.id, .failed)
        return entry.id
    }

    private func tree(settled: Bool = false) -> DirtyTree {
        let json = settled
            ? #"{"dirty":false,"unborn":false,"head":"abc","branch":"main","digest":"clean","author":"A <a@b>","keep_possible":true,"total":0,"files":[]}"#
            : #"{"dirty":true,"unborn":false,"head":"abc","branch":"main","digest":"d1","author":"A <a@b>","keep_possible":true,"total":1,"files":[{"xy":" M","path":"a.spec.ts"}]}"#
        return DirtyTree.parse(json)!
    }

    @MainActor
    func testAnAnswerIsUsedByOneStartAndThenGone() async throws {
        let (model, chat, productID) = chatWithProduct()
        let entryID = failedMessage(model, chat, productID)
        model.dirtyTreeBlocked[chat.id] = .init(entryID: entryID, folder: "/nowhere", tree: tree())

        model.leaveChangesAndSend(entryID: entryID, in: chat.id)

        XCTAssertNil(model.dirtyTreeBlocked[chat.id], "the question is answered, so the row goes")
        XCTAssertNil(model.dirtyTreeAnswer[chat.id],
                     "the send took the answer with it — it must not wait around for a later start")
    }

    @MainActor
    func testNoAnswerIsRecordedWithoutAQuestion() {
        let (model, chat, productID) = chatWithProduct()
        let entryID = failedMessage(model, chat, productID)
        model.leaveChangesAndSend(entryID: entryID, in: chat.id)
        XCTAssertNil(model.dirtyTreeAnswer[chat.id], "nothing was asked, so nothing can be answered")
    }

    @MainActor
    func testACleanFolderSendsTheMessageOnceAndNotNowSendsNothing() async throws {
        let dir = try dirtyRepo()
        try git(dir, "stash", "-u")                     // the director sorted it out their own way

        // Watched: the message goes out by itself — the retry is visible as the «choose a folder»
        // stop this product without folders makes.
        let (model, chat, productID) = chatWithProduct()
        let entryID = failedMessage(model, chat, productID)
        await model.stopOnDirtyTree(chatID: chat.id, entryID: entryID, folder: dir.path, tree: tree())
        XCTAssertNotNil(model.dirtyTreeBlocked[chat.id])
        try await waitUntil(timeout: 15) { model.dirtyTreeBlocked[chat.id] == nil }
        try await waitUntil(timeout: 5) { model.chatErrors[chat.id] != nil }
        XCTAssertNil(model.dirtyTreeWatchers["chat:\(chat.id)"], "the watcher is done after its one send")

        // Dismissed: the same clean folder, and nothing is sent.
        let (other, otherChat, otherProduct) = chatWithProduct()
        let otherEntry = failedMessage(other, otherChat, otherProduct)
        await other.stopOnDirtyTree(chatID: otherChat.id, entryID: otherEntry, folder: dir.path, tree: tree())
        other.dismissDirtyTree(chatID: otherChat.id)
        try await Task.sleep(for: .seconds(5))
        XCTAssertNil(other.chatErrors[otherChat.id], "«Not now» must not send the message later")
        XCTAssertEqual(other.conversations.entry(id: otherEntry)?.delivery, .failed,
                       "it stays undelivered, with «Send again» beside it")
        XCTAssertNil(other.dirtyTreeWatchers["chat:\(otherChat.id)"])
    }

    /// The director sent a second message while the first was still waiting on the question. The
    /// row moves to the newest, and the first one is carried with it — not left «Not delivered».
    @MainActor
    func testAnEarlierHeldMessageIsCarriedWithTheNewOne() async throws {
        let (model, chat, productID) = chatWithProduct()
        let first = failedMessage(model, chat, productID)
        let second = failedMessage(model, chat, productID)
        await model.stopOnDirtyTree(chatID: chat.id, entryID: first, folder: "/nowhere", tree: tree())
        await model.stopOnDirtyTree(chatID: chat.id, entryID: second, folder: "/nowhere", tree: tree())
        model.stopDirtyTreeWatch("chat:\(chat.id)")
        let block = try XCTUnwrap(model.dirtyTreeBlocked[chat.id])
        XCTAssertEqual(block.entryID, second, "the row sits under the newest message")
        XCTAssertEqual(block.held, [first, second], "both go out, oldest first")
    }

    /// Every build names the questions it answers with buttons, on both ways a start is made, so an
    /// engine newer than the app can tell an old copy apart and say so instead of printing flags.
    func testTheAppTellsTheEngineWhichQuestionsItAnswers() {
        XCTAssertEqual(SupervisorClient.chatEnv(contextFile: "c", extraDirsFile: "d", claudeEffort: "",
                                                claudeModel: "")["SUPERVISOR_APP_ANSWERS"], "dirty mcp git heavy")
        XCTAssertEqual(SupervisorClient.launchEnv(.standing)["SUPERVISOR_APP_ANSWERS"], "dirty mcp git heavy")
    }

    /// A newer build takes the place of an older copy that is still running; the same build, or a
    /// newer one already running, keeps its place.
    func testANewerBuildTakesThePlaceOfAnOlderOne() {
        XCTAssertTrue(SingleInstance.isOlder("202609241142", than: "202609242016"))
        XCTAssertFalse(SingleInstance.isOlder("202609242016", than: "202609241142"))
        XCTAssertFalse(SingleInstance.isOlder("202609241142", than: "202609241142"))
        XCTAssertFalse(SingleInstance.isOlder(nil, than: "202609241142"), "an unreadable build is left alone")
        XCTAssertFalse(SingleInstance.isOlder("1", than: nil))
        XCTAssertTrue(SingleInstance.isOlder("99", than: "100"), "numbers, not strings")
    }

    /// A Debug build is «1». Read as it was, it was older than every release, and an installed 1.10
    /// that was opened quit a Debug build with newer code in the middle of an automation's run.
    func testABuildWithoutAReleaseNumberIsDatedByWhenItWasBuilt() throws {
        func local(_ y: Int, _ mo: Int, _ d: Int, _ h: Int, _ mi: Int) throws -> Date {
            try XCTUnwrap(Calendar.current.date(from: DateComponents(year: y, month: mo, day: d, hour: h, minute: mi)))
        }
        let release = "202610012016"
        XCTAssertEqual(SingleInstance.effectiveBuild(release, builtAt: try local(2026, 9, 1, 0, 0)), release,
                       "a release's own number wins over any file date")
        let todaysDebug = SingleInstance.effectiveBuild("1", builtAt: try local(2026, 10, 4, 14, 0))
        XCTAssertEqual(todaysDebug, "202610041400")
        XCTAssertFalse(SingleInstance.isOlder(todaysDebug, than: release), "a newer Debug build is not quit by an older release")
        XCTAssertTrue(SingleInstance.isOlder(release, than: todaysDebug), "it takes the older release's place instead")
        let staleDebug = SingleInstance.effectiveBuild("1", builtAt: try local(2026, 9, 30, 9, 5))
        XCTAssertTrue(SingleInstance.isOlder(staleDebug, than: release),
                      "a Debug build left over from before the release still gives way to it")
        XCTAssertNil(SingleInstance.effectiveBuild("1", builtAt: nil), "undated is unreadable, and left alone")
        XCTAssertNotNil(SingleInstance.build(of: Bundle.main), "this very build can be dated")
    }

    /// The copies already installed cannot learn a new comparison: 1.10 reads the other copy's
    /// `CFBundleVersion` as it is. So the number in the built bundle itself must already put this
    /// build after them — checked against the app this test runs in, with 1.10's code as released.
    func testTheBuiltBundleIsNewerThanAReleaseThatCameBeforeIt() throws {
        // `SingleInstance.isOlder` as it shipped in 1.10 (13ebfec), unchanged.
        func releasedIsOlder(_ theirs: String?, than mine: String?) -> Bool {
            guard let theirs, let mine, !theirs.isEmpty, !mine.isEmpty else { return false }
            return theirs.compare(mine, options: .numeric) == .orderedAscending
        }
        let built = try XCTUnwrap(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String)
        XCTAssertEqual(built.count, 12, "stamped with the minute it was built, not «1»: \(built)")
        XCTAssertTrue(built.allSatisfy { $0.isASCII && $0.isNumber }, built)
        XCTAssertTrue(releasedIsOlder(built, than: "202610012016") == false,
                      "an installed 1.10 does not take this build for an older copy and quit it")
        XCTAssertTrue(releasedIsOlder("202610012016", than: built),
                      "it sees itself as the older one, and gives way")
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX"); f.timeZone = .current; f.dateFormat = "yyyyMMddHHmm"
        let stampedAt = try XCTUnwrap(f.date(from: built))
        XCTAssertLessThanOrEqual(stampedAt, Date().addingTimeInterval(60), "the minute it was built, not a number from the future")
    }

    /// Laid out and drawn, not only compiled: the list, the three answers, the watching note.
    @MainActor
    func testTheRowRenders() throws {
        let (model, chat, productID) = chatWithProduct()
        let entryID = failedMessage(model, chat, productID)
        let block = AppModel.DirtyTreeBlock(entryID: entryID, folder: "/Users/me/omnis", tree: tree(),
                                            problem: "git commit failed: pre-commit hook said no")
        let view = DirtyTreeRow(block: block, entryID: entryID, chatID: chat.id)
            .environment(model)
            .frame(width: 640)
            .padding(12)
            .background(Palette.content)
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        let image = try XCTUnwrap(renderer.nsImage, "the row did not render")
        XCTAssertGreaterThan(image.size.height, 90, "the list, the problem and the buttons all have room")
        if let out = ProcessInfo.processInfo.environment["BULAVA_RENDER_DIR"],
           let tiff = image.tiffRepresentation,
           let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
            try png.write(to: URL(fileURLWithPath: out).appendingPathComponent("dirty-row.png"))
        }
    }

    @MainActor
    private func waitUntil(timeout: TimeInterval, _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline { XCTFail("timed out"); return }
            try await Task.sleep(for: .milliseconds(200))
        }
    }
}
