import XCTest
@testable import Bulava

/// The conversation as it is actually rendered, once the CLI has answered with its sign-in notice.
///
/// The classifier knowing the sentence is not the fix. The fix is that the sentence stops being on
/// screen dressed as the worker's answer, and that the one thing to do about it appears next to the
/// message it failed to answer — and nowhere else.
nonisolated final class LoginNoticeInConversationTests: XCTestCase {

    private let notice = "Login expired · Please run /login"

    @MainActor
    private func chatWithProduct() -> (AppModel, Chat, UUID) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("bulava-login-notice-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        setenv("BULAVA_STATE_DIR", dir.path, 1)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: dir)
            unsetenv("BULAVA_STATE_DIR")
        }
        let model = AppModel()
        // A real product with no folders attached: the retry can resolve it, and then stops at
        // "choose a primary project folder" without spawning anything.
        let productID = model.products.add(name: "Bulava").id
        let chat = model.conversations.newChat(for: productID)
        return (model, chat, productID)
    }

    @MainActor
    @discardableResult
    private func say(_ model: AppModel, _ chat: Chat, _ productID: UUID,
                     _ kind: ConversationEntry.Kind, _ text: String) -> UUID {
        var entry = ConversationEntry(productID: productID, kind: kind, text: text)
        entry.chatID = chat.id
        model.conversations.append(entry)
        return entry.id
    }

    // MARK: The notice itself

    @MainActor
    func testTheNoticeIsNotRenderedAsTheWorkersAnswer() {
        let (model, chat, productID) = chatWithProduct()
        let asked = say(model, chat, productID, .user, "порахуй рядки в цьому файлі")
        let noticeID = say(model, chat, productID, .foreman, notice)

        XCTAssertTrue(model.visibleEntries(inChat: chat.id).contains { $0.id == noticeID },
                      "before it is noticed, the notice is on screen — that is the bug")

        model.noticeExpiredLogin(in: chat)

        let shown = model.visibleEntries(inChat: chat.id)
        XCTAssertFalse(shown.contains { $0.id == noticeID },
                       "the CLI's notice must not stay on screen as something the worker said")
        XCTAssertFalse(shown.contains { $0.text.contains("/login") },
                       "nothing left in the thread tells the reader to type /login")
        XCTAssertTrue(shown.contains { $0.id == asked }, "their own message stays")
        XCTAssertEqual(model.conversations.entry(id: asked)?.delivery, .failed,
                       "it was never answered, so it is not delivered")
        XCTAssertEqual(model.signInPromptEntryID(inChat: chat.id), asked,
                       "the sign-in offer belongs beside the message that went unanswered")
    }

    @MainActor
    func testARealAnswerIsNeverHidden() {
        let (model, chat, productID) = chatWithProduct()
        say(model, chat, productID, .user, "що там з логіном")
        let answer = say(model, chat, productID, .foreman,
                         "Signing in is at /login in the web app; the CLI uses a different flow.")
        model.noticeExpiredLogin(in: chat)
        XCTAssertTrue(model.visibleEntries(inChat: chat.id).contains { $0.id == answer })
        XCTAssertNil(model.signInPromptEntryID(inChat: chat.id))
    }

    // MARK: Where the offer attaches

    /// A chat carries old failures — a folder that was not trusted, a run that held the project.
    /// Keyed by chat alone, the sign-in panel appeared under every one of them.
    @MainActor
    func testAnOlderFailedMessageDoesNotGetTheSignInOffer() {
        let (model, chat, productID) = chatWithProduct()
        let old = say(model, chat, productID, .user, "це впало минулого тижня")
        model.conversations.updateDelivery(entryID: old, .failed)
        say(model, chat, productID, .foreman, "готово, змерджив")
        let recent = say(model, chat, productID, .user, "а тепер онови залежності")
        say(model, chat, productID, .foreman, notice)

        model.noticeExpiredLogin(in: chat)

        XCTAssertEqual(model.signInPromptEntryID(inChat: chat.id), recent)
        XCTAssertNotEqual(model.signInPromptEntryID(inChat: chat.id), old,
                          "an unrelated old failure must not sprout a sign-in button")
    }

    // MARK: Twice in a row

    @MainActor
    func testASecondExpiredAnswerAfterARetryRaisesTheWallAgain() {
        let (model, chat, productID) = chatWithProduct()
        let first = say(model, chat, productID, .user, "перша спроба")
        say(model, chat, productID, .foreman, notice)
        model.noticeExpiredLogin(in: chat)
        XCTAssertEqual(model.signInPromptEntryID(inChat: chat.id), first)

        // They press Send again without having actually signed in. The retry clears the block…
        model.signInBlocked[chat.id] = nil
        model.chatErrors[chat.id] = nil
        model.conversations.updateDelivery(entryID: first, nil)

        // …and the CLI says the same thing again, in a new turn.
        let second = say(model, chat, productID, .user, "друга спроба")
        let secondNotice = say(model, chat, productID, .foreman, notice)
        model.noticeExpiredLogin(in: chat)

        XCTAssertEqual(model.signInBlocked[chat.id]?.noticeEntryID, secondNotice,
                       "the second notice has to be caught too — it is a different entry")
        XCTAssertEqual(model.signInPromptEntryID(inChat: chat.id), second,
                       "and the offer moves to the message that just went unanswered")
        XCTAssertEqual(model.conversations.entry(id: second)?.delivery, .failed)
        XCTAssertFalse(model.visibleEntries(inChat: chat.id).contains { $0.id == secondNotice })
        XCTAssertTrue(model.directPhase(for: chat.id).isFailure,
                      "the chat says so rather than looking like it worked")
    }

    /// Send again has to take the wall down with it. Driven through the real retry, not by
    /// clearing the flag by hand: the panel outliving the attempt to clear it is a button that
    /// lies about the state of the chat.
    @MainActor
    func testPressingSendAgainTakesTheOfferDown() {
        let (model, chat, productID) = chatWithProduct()
        let asked = say(model, chat, productID, .user, "спроба")
        say(model, chat, productID, .foreman, notice)
        model.noticeExpiredLogin(in: chat)
        XCTAssertEqual(model.signInPromptEntryID(inChat: chat.id), asked)

        model.retryDirectMessage(entryID: asked)

        XCTAssertNil(model.signInBlocked[chat.id], "the retry has to clear what it is retrying past")
        XCTAssertNil(model.signInPromptEntryID(inChat: chat.id),
                     "no sign-in button hanging around after the message was sent again")
    }

    // MARK: Hiding is permanent; the offer is not
    //
    // One value used to do both jobs, so clearing either cleared the other: Send again put
    // "Please run /login" back on screen as the worker's answer, and the refresh that followed
    // found it still last in the thread and raised the wall over a message that had just been
    // re-sent.

    @MainActor
    func testTheNoticeStaysHiddenAfterSendAgain() {
        let (model, chat, productID) = chatWithProduct()
        let asked = say(model, chat, productID, .user, "спроба")
        let noticeID = say(model, chat, productID, .foreman, notice)
        model.noticeExpiredLogin(in: chat)

        model.retryDirectMessage(entryID: asked)

        XCTAssertFalse(model.visibleEntries(inChat: chat.id).contains { $0.id == noticeID },
                       "Send again must not put the CLI's notice back on screen")
        XCTAssertNil(model.signInPromptEntryID(inChat: chat.id), "but the offer is done with")
    }

    @MainActor
    func testTheNextRefreshDoesNotRaiseTheSameWallAgain() {
        let (model, chat, productID) = chatWithProduct()
        let asked = say(model, chat, productID, .user, "спроба")
        let noticeID = say(model, chat, productID, .foreman, notice)
        model.noticeExpiredLogin(in: chat)
        model.retryDirectMessage(entryID: asked)

        // The answer has not come back yet, so that old notice is still the last thing in the
        // thread — and sync runs about once a second.
        model.noticeExpiredLogin(in: chat)
        model.noticeExpiredLogin(in: chat)

        XCTAssertNil(model.signInPromptEntryID(inChat: chat.id),
                     "the message was re-sent; nothing new has failed")
        XCTAssertNotEqual(model.conversations.entry(id: asked)?.delivery, .failed,
                          "a message on its way must not be marked failed by an old notice")
        XCTAssertFalse(model.directPhase(for: chat.id).isFailure)
        XCTAssertFalse(model.visibleEntries(inChat: chat.id).contains { $0.id == noticeID })
    }

    @MainActor
    func testTheNoticeStaysHiddenOnceARealAnswerArrives() {
        let (model, chat, productID) = chatWithProduct()
        say(model, chat, productID, .user, "спроба")
        let noticeID = say(model, chat, productID, .foreman, notice)
        model.noticeExpiredLogin(in: chat)

        let answer = say(model, chat, productID, .foreman, "Готово — 412 рядків.")
        model.noticeExpiredLogin(in: chat)
        model.noticeExpiredLogin(in: chat)

        let shown = model.visibleEntries(inChat: chat.id)
        XCTAssertFalse(shown.contains { $0.id == noticeID },
                       "a later answer does not make the old notice worth showing")
        XCTAssertFalse(shown.contains { $0.text.contains("/login") })
        XCTAssertTrue(shown.contains { $0.id == answer })
        XCTAssertNil(model.signInPromptEntryID(inChat: chat.id))
    }

    /// Hiding has to outlive the process. It was a set in memory, so the morning after, the
    /// notice was back on screen as the worker's answer — and the first refresh raised the wall
    /// again over a message that had been re-sent the night before.
    @MainActor
    func testTheNoticeIsStillHiddenAfterARelaunch() {
        let (model, chat, productID) = chatWithProduct()
        let asked = say(model, chat, productID, .user, "спроба")
        let noticeID = say(model, chat, productID, .foreman, notice)
        model.noticeExpiredLogin(in: chat)
        model.retryDirectMessage(entryID: asked)

        // A second model over the same state directory is what the next launch sees.
        let relaunched = AppModel()
        let reopened = try! XCTUnwrap(relaunched.conversations.chat(id: chat.id))

        XCTAssertFalse(relaunched.visibleEntries(inChat: chat.id).contains { $0.id == noticeID },
                       "the notice came back on screen after a relaunch")
        relaunched.noticeExpiredLogin(in: reopened)
        XCTAssertNil(relaunched.signInPromptEntryID(inChat: chat.id),
                     "and the wall was raised again over a message already re-sent")
        XCTAssertFalse(relaunched.visibleEntries(inChat: chat.id).contains { $0.id == noticeID })
        XCTAssertFalse(relaunched.directPhase(for: chat.id).isFailure)
    }

    /// Signing in and getting a real answer puts the chat back to normal on its own.
    @MainActor
    func testARealAnswerAfterwardsClearsTheWall() {
        let (model, chat, productID) = chatWithProduct()
        say(model, chat, productID, .user, "спроба")
        say(model, chat, productID, .foreman, notice)
        model.noticeExpiredLogin(in: chat)
        XCTAssertNotNil(model.signInBlocked[chat.id])

        say(model, chat, productID, .foreman, "Готово — 412 рядків.")
        model.noticeExpiredLogin(in: chat)

        XCTAssertNil(model.signInBlocked[chat.id])
        XCTAssertNil(model.signInPromptEntryID(inChat: chat.id))
        XCTAssertFalse(model.directPhase(for: chat.id).isFailure)
    }
}

/// The commit a run is measured against, as the app reads it off disk.
///
/// Instance folders written before the engine stopped trusting `git rev-parse HEAD` still hold the
/// word HEAD in `base-sha`. A name that resolves to whatever HEAD is now answers every later
/// question wrongly — nothing has changed since the work was committed, and a branch looks merged
/// into itself.
nonisolated final class BaseCommitIsACommitTests: XCTestCase {

    func testTheWordHEADIsNotACommit() {
        XCTAssertNil(SupervisorClient.commitID("HEAD"))
        XCTAssertNil(SupervisorClient.commitID("HEAD\n"))
        XCTAssertNil(SupervisorClient.commitID("refs/heads/main"))
        XCTAssertNil(SupervisorClient.commitID("main"))
        XCTAssertNil(SupervisorClient.commitID(""))
        XCTAssertNil(SupervisorClient.commitID(nil))
    }

    func testARealObjectIdIsRead() {
        XCTAssertEqual(SupervisorClient.commitID("2fd905eea0a8b7e9a84351f2497d64edfdf21746"),
                       "2fd905eea0a8b7e9a84351f2497d64edfdf21746")
        XCTAssertEqual(SupervisorClient.commitID("  2fd905e \n"), "2fd905e", "short ids are used too")
    }
}
