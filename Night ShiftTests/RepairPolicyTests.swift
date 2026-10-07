import XCTest
@testable import Bulava

/// Which failures a repair is offered for. Only something BROKEN is handed to Codex: a folder to
/// choose, a login, another run in the way are the person's to answer, and the rows under the
/// message already ask them.
nonisolated final class RepairPolicyTests: XCTestCase {

    @MainActor
    private func model(autoRepair: Bool) -> (AppModel, UUID, UUID, URL) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("bulava-repair-policy-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        setenv("BULAVA_STATE_DIR", dir.path, 1)
        let m = AppModel()
        m.settings.autoRepair = autoRepair
        m.settings.shareErrorReports = false
        let product = m.products.add(name: "pocket-ledger")
        let chat = m.conversations.newChat(for: product.id)
        let entry = m.conversations.appendUser("ship it", productID: product.id, chatID: chat.id)
        m.conversations.updateDelivery(entryID: entry.id, .failed)
        return (m, chat.id, entry.id, dir)
    }

    @MainActor
    func testSomethingOnlyThePersonCanDoIsNotRepaired() {
        let (m, chat, _, dir) = model(autoRepair: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        m.failChat(chat, "Choose a primary project folder before sending.", .needsYou)
        XCTAssertNil(m.repairs[chat])
        XCTAssertTrue(m.toast?.actions.isEmpty == true, "and the card offers no repair either")
        XCTAssertEqual(m.chatErrors[chat], "Choose a primary project folder before sending.")
    }

    @MainActor
    func testABreakageIsOfferedWhenRepairsWaitForAButton() {
        let (m, chat, entry, dir) = model(autoRepair: false)
        defer { try? FileManager.default.removeItem(at: dir) }
        m.failChat(chat, "Night Shift did not start.\ninstall.sh: line 3: jq: command not found",
                   .unexpected("chat.start_failed"))
        let repair = m.repairs[chat]
        XCTAssertEqual(repair?.phase, .offered)
        XCTAssertEqual(repair?.entryID, entry, "the message that did not go is the one sent again")
        XCTAssertEqual(repair?.code, "chat.start_failed")
        XCTAssertEqual(m.toast?.actions.map(\.title), [String(localized: "Fix it")])
        XCTAssertEqual(m.toast?.text, "Night Shift did not start.\ninstall.sh: line 3: jq: command not found",
                       "the whole text is on the card, not its first line")
    }

    /// No message to send again means no way to tell whether a repair worked — so none is offered.
    @MainActor
    func testWithoutAMessageToResendNothingIsOffered() {
        let (m, chat, entry, dir) = model(autoRepair: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        m.conversations.updateDelivery(entryID: entry, nil)
        m.failChat(chat, "Could not generate the report.", .unexpected("chat.report_failed"))
        XCTAssertNil(m.repairs[chat])
    }

    /// The same failure in the same chat is not repaired again by itself straight after an attempt.
    @MainActor
    func testTheSameFailureIsNotRepairedInALoop() async {
        let (m, chat, _, dir) = model(autoRepair: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let text = "Night Shift did not start."
        let fp = ReportScrubber.fingerprint(code: "chat.start_failed",
                                            scrubbed: ReportScrubber.scrub(text, known: m.knownPrivateStrings(chatID: chat)))
        m.repairAttempts["\(chat.uuidString)|\(fp)"] = Date()
        m.failChat(chat, text, .unexpected("chat.start_failed"))
        try? await Task.sleep(for: .milliseconds(1600))
        XCTAssertEqual(m.repairs[chat]?.phase, .offered, "offered, not started again")
    }

    // MARK: - A message that may already have arrived

    /// Cut off after the engine began typing it: the message may be running. A repair is offered,
    /// never started by itself, and its result is never "send it again" without the person.
    @MainActor
    func testAMessageThatMayHaveArrivedIsNeverRepairedOrResentByItself() async {
        let (m, chat, _, dir) = model(autoRepair: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        m.failChat(chat, "worker-send.sh: line 148: interrupted", .uncertain("chat.delivery_uncertain"))
        XCTAssertEqual(m.repairs[chat]?.resendable, false)
        try? await Task.sleep(for: .milliseconds(1600))
        XCTAssertEqual(m.repairs[chat]?.phase, .offered, "offered, not started, though repairs start by themselves")
        XCTAssertEqual(m.toast?.actions.map(\.title), [String(localized: "Fix it")], "the press is the person's")

        var resent = 0
        let incident = m.repairs[chat]!.incidentID
        await m.concludeRepair(chatID: chat, incident: incident,
                               outcome: .answered(Self.fixed, .codex), resend: { _ in resent += 1 })
        XCTAssertEqual(resent, 0, "not sent again: twice could run the same work twice")
        XCTAssertEqual(m.repairs[chat]?.phase, .unconfirmed(summary: Self.fixed.summary, why: .notResent))
        XCTAssertEqual(m.toast?.actions.map(\.title), [String(localized: "Send again")])
    }

    // MARK: - "Fixed" means the engine said it was delivered

    private static let fixed = RepairSession.Finding(fixed: true, cause: "bulava_state",
                                                     summary: "Removed a stale lock.", changed: ["x"],
                                                     productBug: "", retrySafe: true)

    @MainActor
    private func concluded(_ resend: @escaping @MainActor (AppModel, UUID, UUID) -> Void,
                           deadline: TimeInterval = 3) async -> ChatRepair.Phase? {
        let (m, chat, _, dir) = model(autoRepair: false)
        defer { try? FileManager.default.removeItem(at: dir) }
        m.failChat(chat, "Night Shift did not start.", .unexpected("chat.start_failed"))
        let incident = m.repairs[chat]!.incidentID
        await m.concludeRepair(chatID: chat, incident: incident, outcome: .answered(Self.fixed, .codex),
                               verifyFor: deadline, resend: { entry in resend(m, chat, entry) })
        return m.repairs[chat]?.phase
    }

    @MainActor
    func testOnlyAConfirmedDeliveryIsFixed() async {
        let phase = await concluded { m, chat, entry in
            m.chatErrors[chat] = nil
            m.conversations.updateDelivery(entryID: entry, nil)
            m.confirmedDeliveries.insert(entry)
        }
        XCTAssertEqual(phase, .fixed(summary: Self.fixed.summary))
    }

    @MainActor
    func testAQueuedMessageIsNotCalledDelivered() async {
        let phase = await concluded { m, chat, entry in
            m.chatErrors[chat] = nil
            m.conversations.updateDelivery(entryID: entry, .queued)
        }
        XCTAssertEqual(phase, .unconfirmed(summary: Self.fixed.summary, why: .queued))
    }

    /// The engine took it and said nothing either way — no confirmation, no error.
    @MainActor
    func testASendThatEndsWithoutAWordIsUnconfirmed() async {
        let phase = await concluded { m, chat, entry in
            m.chatErrors[chat] = nil
            m.conversations.updateDelivery(entryID: entry, nil)
        }
        XCTAssertEqual(phase, .unconfirmed(summary: Self.fixed.summary, why: .stillSending))
    }

    /// Still sending when the watch runs out: neither fixed nor failed.
    @MainActor
    func testATimedOutSendIsUnconfirmedNotFixed() async {
        let phase = await concluded({ m, chat, entry in
            m.chatErrors[chat] = nil
            m.conversations.updateDelivery(entryID: entry, nil)
            m.sendingChatIDs.insert(chat)
        }, deadline: 1)
        XCTAssertEqual(phase, .unconfirmed(summary: Self.fixed.summary, why: .stillSending))
    }

    @MainActor
    func testFailingAgainIsNotFixed() async {
        let phase = await concluded { m, chat, entry in
            m.conversations.updateDelivery(entryID: entry, .failed)
            m.chatErrors[chat] = "Night Shift did not start."
        }
        guard case .notFixed? = phase else { return XCTFail("\(String(describing: phase))") }
    }

    /// Every state the chat can be in after a resend, judged on its own.
    func testTheVerdictTable() {
        typealias J = AppModel
        XCTAssertEqual(J.judge(error: "x", delivery: nil, confirmed: true, sending: false, questionForYou: false),
                       .failedAgain("x"), "an error outranks everything")
        XCTAssertEqual(J.judge(error: nil, delivery: nil, confirmed: true, sending: true, questionForYou: false),
                       .delivered)
        XCTAssertNil(J.judge(error: nil, delivery: nil, confirmed: false, sending: true, questionForYou: false),
                     "still sending: nothing to say yet")
        XCTAssertEqual(J.judge(error: nil, delivery: .queued, confirmed: false, sending: false, questionForYou: false),
                       .accepted)
        XCTAssertEqual(J.judge(error: nil, delivery: nil, confirmed: false, sending: false, questionForYou: false),
                       .pending, "no confirmation is not a delivery")
        XCTAssertEqual(J.judge(error: nil, delivery: .failed, confirmed: false, sending: false, questionForYou: true),
                       .questionForYou)
    }
}

/// When a failed send counts as never delivered. Only that kind is ever sent again by itself.
nonisolated final class RelayDeliveryCertaintyTests: XCTestCase {

    func testARefusalBeforeTryingIsProvenUndelivered() {
        let r = RelayResult.read(output: "❌ Нема такої теки: /x", exitCode: 1, launched: true, endedBy: .exited)
        XCTAssertEqual(r.tier, .error)
        XCTAssertTrue(r.undelivered)
    }

    /// Interrupted after the engine said it had handed the message over.
    func testCutOffAfterHandingItOverMayHaveArrived() {
        let r = RelayResult.read(output: "▶ Передано у живу сесію night-x\nTIER=live", exitCode: -1,
                                 launched: true, endedBy: .hitCeiling(after: 300))
        XCTAssertEqual(r.tier, .error)
        XCTAssertFalse(r.undelivered)
    }

    func testCutOffWhileTypingMayHaveArrived() {
        let r = RelayResult.read(output: "", exitCode: 15, launched: true, endedBy: .hitCeiling(after: 300))
        XCTAssertFalse(r.undelivered)
    }

    func testAShellErrorHalfwayMayHaveArrived() {
        let r = RelayResult.read(output: "worker-send.sh: line 148: rc: unbound variable", exitCode: 1,
                                 launched: true, endedBy: .exited)
        XCTAssertFalse(r.undelivered, "exit 1 without the engine's own refusal is not proof")
    }

    func testNeverStartedIsUndelivered() {
        XCTAssertTrue(RelayResult.read(output: "", exitCode: -1, launched: false, endedBy: .neverStarted).undelivered)
    }

    func testTheConfirmedTiersAreUnchanged() {
        let live = RelayResult.read(output: "TIER=live", exitCode: 0, launched: true, endedBy: .exited)
        XCTAssertEqual(live.tier, .live); XCTAssertTrue(live.confirmed)
        let unsure = RelayResult.read(output: "TIER=live", exitCode: 2, launched: true, endedBy: .exited)
        XCTAssertTrue(unsure.uncertain)
        XCTAssertEqual(RelayResult.read(output: "TIER=queued", exitCode: 2, launched: true, endedBy: .exited).tier, .queued)
        XCTAssertEqual(RelayResult.read(output: "TIER=none", exitCode: 3, launched: true, endedBy: .exited).tier, .none)
    }
}
