import XCTest
@testable import Bulava

/// Codex's weekly window is the one that actually runs out — 91% used with four days to go, as
/// this was written. A conversation that reaches that wall came back as an error where an answer
/// should be. Claude takes the message instead, and the thread is told.
nonisolated final class ClaudeStandsInForCodexTests: XCTestCase {

    private func usage(week: Double?, fiveHour: Double = 3,
                       resetsAt: Date? = nil, present: Bool = true) -> UsageSnapshot {
        UsageSnapshot(fiveHour: UsageWindow(usedPercent: fiveHour, resetsAt: nil),
                      sevenDay: week.map { UsageWindow(usedPercent: $0, resetsAt: resetsAt) },
                      plan: "plus", updatedAt: Date(), present: present)
    }

    // MARK: - Before a turn is sent

    func testAWeekThatIsSpentSendsTheMessageToClaude() {
        let reason = CodexStandIn.insteadOfCodex(usage: usage(week: 100), enabled: true)
        guard case .weeklyQuotaSpent(let percent, _)? = reason else {
            return XCTFail("expected the weekly quota to be the reason")
        }
        XCTAssertEqual(percent, 100)
    }

    /// The reserve this used to keep. Standing Codex down at 97 meant paying for a week of quota
    /// and using 97% of it, and the three per cent bought nothing that Codex refusing a turn does
    /// not already handle.
    func testAWeekWithRoomLeftStillGoesToCodex() {
        for used in [40.0, 91.0, 97.0, 99.0] {
            XCTAssertNil(CodexStandIn.insteadOfCodex(usage: usage(week: used), enabled: true),
                         "\(used)% is not spent — there is quota there and it was paid for")
        }
    }

    /// The five-hour window resetting is not the weekly one. It was at 3% while the week was at
    /// 91%, so reading the wrong one would have said everything was fine.
    func testTheFiveHourWindowIsNotWhatDecides() {
        XCTAssertNotNil(CodexStandIn.insteadOfCodex(usage: usage(week: 100, fiveHour: 1),
                                                     enabled: true))
        XCTAssertNil(CodexStandIn.insteadOfCodex(usage: usage(week: 10, fiveHour: 100),
                                                  enabled: true))
    }

    /// An unread quota is not a spent one. Refusing to use Codex because a JSON file is missing
    /// would be its own bug.
    func testUnknownQuotaIsNotTreatedAsExhausted() {
        XCTAssertNil(CodexStandIn.insteadOfCodex(usage: usage(week: nil), enabled: true))
        XCTAssertNil(CodexStandIn.insteadOfCodex(usage: .empty, enabled: true))
        XCTAssertNil(CodexStandIn.insteadOfCodex(usage: usage(week: 100, present: false),
                                                  enabled: true))
    }

    func testTurningItOffMeansCodexOrNothing() {
        XCTAssertNil(CodexStandIn.insteadOfCodex(usage: usage(week: 100), enabled: false))
    }

    func testHeIsToldWhichOneAnsweredAndWhen() {
        let resets = Date(timeIntervalSince1970: 1_788_749_561)
        let reason = CodexStandIn.Reason.weeklyQuotaSpent(percent: 99.4, resetsAt: resets)
        let sentence = reason.sentence
        XCTAssertTrue(sentence.contains("99"), sentence)
        XCTAssertTrue(sentence.contains("Claude"), sentence)
        XCTAssertFalse(sentence.contains("%@"), "the format was never filled in: \(sentence)")

        let withoutReset = CodexStandIn.Reason.weeklyQuotaSpent(percent: 99, resetsAt: nil).sentence
        XCTAssertFalse(withoutReset.contains("%@"), withoutReset)
    }

    // MARK: - After a turn was sent and refused

    func testARefusalAboutQuotaIsRecognised() {
        for failure in ["You've hit your usage limit.",
                        "Rate limit reached for this account",
                        "insufficient_quota",
                        "429 Too many requests",
                        "Weekly quota exhausted"] {
            XCTAssertNotNil(CodexStandIn.refusal(in: failure), failure)
        }
    }

    /// Narrow on purpose: a wrong match costs a duplicated answer from Claude, so only messages
    /// that actually name a limit count.
    func testAnOrdinaryFailureIsNotAQuotaProblem() {
        for failure in ["Codex could not be started.",
                        "Codex stopped without answering (exit 1).",
                        "Stopped. The thread is intact — carry on when you want.",
                        "error: no such file or directory",
                        ""] {
            XCTAssertNil(CodexStandIn.refusal(in: failure), failure)
        }
        XCTAssertNil(CodexStandIn.refusal(in: nil))
    }

    func testTheRefusalSentenceNamesWhoAnswered() {
        let sentence = CodexStandIn.Reason.refusedMidTurn("You've hit your usage limit.").sentence
        XCTAssertTrue(sentence.contains("Claude"), sentence)
    }

    /// The wall on its own, for the reading where nothing has been substituted yet.
    ///
    /// `sentence` ends in "Claude answered this one". Reusing it for the offer would put that
    /// claim on screen beside a message nobody had answered — the exact untruth the switch to an
    /// explicit press exists to remove.
    func testTheWallSentenceDoesNotClaimAnybodyAnswered() {
        let wall = CodexStandIn.Reason.refusedMidTurn("You've hit your usage limit.").wall
        XCTAssertFalse(wall.contains("Claude"), wall)
        let spent = CodexStandIn.Reason.weeklyQuotaSpent(percent: 100, resetsAt: nil).wall
        XCTAssertFalse(spent.contains("Claude"), spent)
    }

    // MARK: - The setting

    /// It used to default ON, and the answer Claude gave in Codex's place was one nobody had asked
    /// for. Off by default now: the thread says Codex is out and the substitution is a button.
    func testItIsOffUnlessHeTurnsItOn() {
        XCTAssertFalse(AppSettings.fallback.claudeStandsInForCodex)
    }

    func testSettingsFromBeforeThisExistedHaveItOff() throws {
        let json = #"{"stateDirPath":"/tmp","pollSeconds":4}"#
        let settings = try JSONDecoder().decode(AppSettings.self, from: Data(json.utf8))
        XCTAssertFalse(settings.claudeStandsInForCodex)
    }

    /// Changing a default does not reach a value that is already written down, and every machine
    /// that has run this app has the old `true` in its settings file. Without the retirement below
    /// the change would have landed everywhere except the installs it was written for.
    func testASettingsFileFromBeforeThisChangeStopsSubstitutingByItself() throws {
        let json = #"{"stateDirPath":"/tmp","pollSeconds":4,"claudeStandsInForCodex":true}"#
        let settings = try JSONDecoder().decode(AppSettings.self, from: Data(json.utf8))
        XCTAssertFalse(settings.claudeStandsInForCodex,
                       "a stored true from the old default must not keep answering as Claude by itself")
        XCTAssertTrue(settings.standInMigrated, "and it must be retired once, not asked again every launch")
    }

    /// The other half of "once": a deliberate re-enable has to survive the next launch, or the
    /// setting would be one nobody could ever turn on.
    func testTurningItBackOnAfterTheMigrationSticks() throws {
        var settings = AppSettings.fallback
        settings.claudeStandsInForCodex = true
        let back = try JSONDecoder().decode(AppSettings.self,
                                            from: try JSONEncoder().encode(settings))
        XCTAssertTrue(back.claudeStandsInForCodex)
        XCTAssertTrue(back.standInMigrated)
    }

    func testTurningItOnSurvivesAPersistRoundTrip() throws {
        var settings = AppSettings.fallback
        settings.claudeStandsInForCodex = true
        let back = try JSONDecoder().decode(AppSettings.self,
                                            from: try JSONEncoder().encode(settings))
        XCTAssertTrue(back.claudeStandsInForCodex)
    }
}
