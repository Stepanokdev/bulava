import XCTest
@testable import Bulava

/// Two starts the engine stopped for something only the person can clear, which 1.14 took for
/// breakages: it offered to repair them and sent each to us as an anonymous `chat.start_failed`
/// report (20 Oct). The output below is the engine's, as those reports carried it.
nonisolated final class StartRefusalTests: XCTestCase {

    private let notSignedIn = """
        ⚠️ хуки не підтвердили run-id за 12s — робота може піти без нагляду.
           Claude Code не ввійшов в акаунт і чекає входу. Увійди: claude auth login
        handshake-blocked=login
        ❌ підтвердження нема — відкат старту.
        """

    private let workspace = """
        ❌ У цій теці 2 репозиторії. Це робоча тека, а не репозиторій — Bulava не робить git поверх чужих репозиторіїв.
          • mfes/frontend-app-learning
          • src/edx-platform
        Підключи кожен репозиторій окремо (Bulava робить це сама, коли додаєш теку) і запускай у ньому.
        start-refused=folder
        """

    @MainActor
    private func model() -> (AppModel, UUID, UUID) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("bulava-start-refusal-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        setenv("BULAVA_STATE_DIR", dir.path, 1)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: dir)
            unsetenv("BULAVA_STATE_DIR")
        }
        let m = AppModel()
        m.settings.autoRepair = true
        m.settings.shareErrorReports = false
        let product = m.products.add(name: "pocket-ledger")
        let chat = m.conversations.newChat(for: product.id)
        let entry = m.conversations.appendUser("ship it", productID: product.id, chatID: chat.id)
        m.conversations.updateDelivery(entryID: entry.id, .failed)
        return (m, chat.id, entry.id)
    }

    func testTheMarkersAreReadAsWholeLinesOnly() {
        XCTAssertTrue(StartRefusal.needsSignIn(notSignedIn))
        XCTAssertFalse(StartRefusal.notAProject(notSignedIn))
        XCTAssertTrue(StartRefusal.notAProject(workspace))
        XCTAssertFalse(StartRefusal.needsSignIn(workspace))
        XCTAssertFalse(StartRefusal.needsSignIn("the word handshake-blocked=login inside a line"))
        XCTAssertFalse(StartRefusal.notAProject("Night Shift did not start."))
    }

    @MainActor
    func testANotSignedInStartAsksForTheSignInAndIsNotRepaired() {
        let (m, chat, entry) = model()
        XCTAssertTrue(m.stopOnStartTheyMustClear(chatID: chat, entryID: entry, output: notSignedIn))
        XCTAssertNil(m.repairs[chat], "a login is not a breakage — nothing is repaired or reported")
        XCTAssertEqual(m.signInPromptEntryID(inChat: chat), entry,
                       "the sign-in row stands under the message that did not go")
        XCTAssertTrue(m.chatHasAQuestionForYou(chat))
        XCTAssertFalse(m.chatErrors[chat]?.contains("handshake-blocked") ?? true,
                       "the engine's marker is not shown to the person")
    }

    /// A chat that ran before keeps its binding, so the refresh looks for a sign-in notice in it.
    /// There is none — the start never began — and that must not take the row away again.
    @MainActor
    func testTheRefreshDoesNotTakeAStartsSignInRowAway() {
        let (m, chat, entry) = model()
        m.stopOnStartTheyMustClear(chatID: chat, entryID: entry, output: notSignedIn)
        m.noticeExpiredLogin(in: m.conversations.chats.first { $0.id == chat }!)
        XCTAssertEqual(m.signInPromptEntryID(inChat: chat), entry)
        XCTAssertNotNil(m.chatErrors[chat])
    }

    @MainActor
    func testAFolderThatIsNotAProjectIsSaidAndNotRepaired() {
        let (m, chat, entry) = model()
        XCTAssertTrue(m.stopOnStartTheyMustClear(chatID: chat, entryID: entry, output: workspace))
        XCTAssertNil(m.repairs[chat], "the folder is the person's to change, not ours to repair")
        XCTAssertTrue(m.chatErrors[chat]?.contains("робоча тека, а не репозиторій") == true,
                      "the engine's reason is what the person reads")
        XCTAssertFalse(m.chatErrors[chat]?.contains("start-refused=") ?? true)
        XCTAssertTrue(m.toast?.actions.isEmpty == true, "and no Fix it button")
    }

    /// 30 Oct, 1.16.3: a chat whose folder was gone sent «Проєкт не знайдено» to us five times in a
    /// minute, each with a repair that could not bring a folder back. Now it is asked before the start.
    @MainActor
    func testAFolderThatIsGoneIsSaidBeforeTheStartAndNotRepaired() {
        let (m, chat, entry) = model()
        let gone = FileManager.default.temporaryDirectory
            .appendingPathComponent("bulava-moved-away-\(UUID().uuidString)").path
        XCTAssertTrue(m.stopOnFolderTheyMustClear(chatID: chat, entryID: entry, path: gone, name: "pocket-ledger"))
        XCTAssertNil(m.repairs[chat], "a folder that is gone is not ours to repair or report")
        XCTAssertTrue(m.chatErrors[chat]?.contains(gone) == true, "the person is told which folder")
        XCTAssertTrue(m.chatErrors[chat]?.contains("pocket-ledger") == true)
        XCTAssertTrue(m.toast?.actions.isEmpty == true, "and no Fix it button")
    }

    /// A folder macOS keeps Bulava out of is there: saying it is gone would send the person looking
    /// for something right where they left it.
    func testAFolderBulavaCannotEnterIsNotCalledGone() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("bulava-closed-\(UUID().uuidString)")
        let inner = root.appendingPathComponent("project")
        try FileManager.default.createDirectory(at: inner, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: root.path)
        addTeardownBlock {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: root.path)
            try? FileManager.default.removeItem(at: root)
        }
        let closed = try XCTUnwrap(StartRefusal.folderProblem(path: inner.path, name: "p"))
        XCTAssertEqual(closed, String(format: String(localized: "I cannot read the folder of “%@” (%@). Give Bulava access to it in System Settings, or connect another path."), "p", inner.path))
    }

    func testAFolderThatIsThereIsNoProblem() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("bulava-here-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        XCTAssertNil(StartRefusal.folderProblem(path: dir.path, name: "p"))
        // Enterable but not listable is enough for the engine, so it is enough here.
        let enterOnly = dir.appendingPathComponent("enter-only")
        try FileManager.default.createDirectory(at: enterOnly, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o300], ofItemAtPath: enterOnly.path)
        addTeardownBlock { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: enterOnly.path) }
        XCTAssertNil(StartRefusal.folderProblem(path: enterOnly.path, name: "p"), "the engine can cd into it")
        let file = dir.appendingPathComponent("not-a-folder")
        FileManager.default.createFile(atPath: file.path, contents: Data())
        XCTAssertNotNil(StartRefusal.folderProblem(path: file.path, name: "p"), "a file where the folder was is not one")
    }

    /// The engine's own refusal of a missing folder carries the marker too, for a folder that goes
    /// between the check above and the start (`engine/tests/test-workspace-container.sh`).
    @MainActor
    func testTheEnginesMissingFolderRefusalIsNotRepaired() {
        let (m, chat, entry) = model()
        let out = "❌ Проєкт не знайдено: /Users/someone/Projects/app\nstart-refused=folder"
        XCTAssertTrue(m.stopOnStartTheyMustClear(chatID: chat, entryID: entry, output: out))
        XCTAssertNil(m.repairs[chat])
        XCTAssertEqual(m.chatErrors[chat], "❌ Проєкт не знайдено: /Users/someone/Projects/app")
    }

    @MainActor
    func testAnyOtherFailedStartIsLeftToTheRepair() {
        let (m, chat, entry) = model()
        XCTAssertFalse(m.stopOnStartTheyMustClear(chatID: chat, entryID: entry,
                                                  output: "install.sh: line 3: jq: command not found"))
        XCTAssertNil(m.chatErrors[chat])
    }

    /// A resume of a signed-out Claude: it exited before its sign-in screen could be read, and the
    /// engine now asks Claude Code and says `handshake-blocked=login` (21.10, two reports).
    func testAResumeThatStoppedOnASignInIsReadAsOne() {
        let out = "⚠️ хуки не підтвердили run-id за 60s\nhandshake-blocked=login\n❌ не вдалося відновити\nTIER=none"
        let result = RelayResult.read(output: out, exitCode: 3, launched: true, endedBy: .exited)
        XCTAssertEqual(result.tier, .none)
        XCTAssertTrue(result.needsSignIn)
        let other = RelayResult.read(output: "❌ не вдалося відновити\nTIER=none", exitCode: 3, launched: true, endedBy: .exited)
        XCTAssertFalse(other.needsSignIn, "an ordinary failed resume is still one")
    }

    /// A resume of a conversation Claude Code no longer keeps (1.16.1, 23.10): worker-send's own
    /// output, as `tests/test-resume-gone.sh` pins it — nothing to repair, nothing to report.
    @MainActor
    func testAConversationClaudeNoLongerKeepsIsSaidAndNotRepaired() {
        let out = "resume-refused=transcript\nTIER=none\nнема живої/відновлюваної сесії — потрібен свіжий воркер"
        let result = RelayResult.read(output: out, exitCode: 3, launched: true, endedBy: .exited)
        XCTAssertEqual(result.tier, .none)
        XCTAssertTrue(result.conversationGone)
        XCTAssertFalse(result.needsSignIn)
        XCTAssertEqual(StartRefusal.withoutMarkers("resume-refused=transcript\nok"), "ok")
        XCTAssertFalse(RelayResult.read(output: "TIER=none", exitCode: 3, launched: true,
                                        endedBy: .exited).conversationGone,
                       "an ordinary failed resume is still one")

        let (m, chat, _) = model()
        m.failChat(chat, "gone", .needsYou)
        XCTAssertNil(m.repairs[chat], "a conversation that is gone is not repaired or reported")
        XCTAssertTrue(m.toast?.actions.isEmpty == true, "and no Fix it button")
    }
}
