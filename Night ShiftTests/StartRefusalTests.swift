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
}
