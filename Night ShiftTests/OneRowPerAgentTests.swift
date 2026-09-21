import XCTest
@testable import Bulava

/// One CLI, one row, one thing to do about it.
///
/// A Mac without Codex used to answer with two red rows — "Codex is installed: not on PATH" from
/// the installation check, and "Codex does not answer: command not found" from the probe that ran
/// anyway — and once both learned to offer a button, two identical buttons. That is the screenshot
/// the first person to install Bulava sent back. The second row also cost a paid call, made
/// against a command the first row had just proved was not there.
nonisolated final class OneRowPerAgentTests: XCTestCase {

    // MARK: The CLI is not installed at all

    @MainActor
    func testAMissingAgentIsOneRowAndCostsNothing() async {
        for (id, cask) in [("claude-auth", "claude-code"), ("codex-auth", "codex")] {
            let runner = PreflightRunner()
            let probed = Probed()
            let row = await runner.agentCheck(
                id: id, foundAt: "", cask: cask, probe: true,
                missingTitleKey: "not installed", missingDetailKey: "d",
                run: { probed.yes = true
                       return PreflightCheck(id: id, titleKey: "t", detailKey: "d", status: .ready) })

            XCTAssertFalse(probed.yes,
                           "\(id): the paid probe ran against a CLI that is not on PATH")
            XCTAssertEqual(row.id, id)
            XCTAssertEqual(row.status, .missing)
            guard case .brewCask(let casks)? = row.fix else {
                return XCTFail("\(id): a missing CLI must offer to install it, got \(String(describing: row.fix))")
            }
            XCTAssertEqual(casks, [cask])
        }
    }

    @MainActor
    func testAnAgentThatIsOnPathIsAskedForReal() async {
        let runner = PreflightRunner()
        let probed = Probed()
        let row = await runner.agentCheck(
            id: "codex-auth", foundAt: "/opt/homebrew/bin/codex", cask: "codex", probe: true,
            missingTitleKey: "not installed", missingDetailKey: "d",
            run: { probed.yes = true
                   return PreflightCheck(id: "codex-auth", titleKey: "Codex answers",
                                         detailKey: "d", status: .ready) })
        XCTAssertTrue(probed.yes, "a CLI that is there has to actually be asked")
        XCTAssertEqual(row.status, .ready)
        XCTAssertNil(row.fix, "nothing to fix when it answered")
    }

    // MARK: Every other state, once it IS on PATH

    /// What each state must offer. Reinstalling is the answer to three different walls and signing
    /// in to exactly one; an unexplained failure gets no button at all, because there is nothing
    /// honest to put on it.
    @MainActor
    func testEachFailureStateOffersExactlyOneAndTheRightAction() {
        let runner = PreflightRunner()
        let expected: [(PreflightRunner.ProbeFailure, String)] = [
            (.notOnPath,         "install"),
            (.executableMissing, "install"),
            (.wrongArchitecture, "install"),
            (.blockedBySystem,   "install"),
            (.notSignedIn,       "sign in"),
            (.unknown,           "nothing"),
        ]
        for (failure, want) in expected {
            for (row, cask, login) in [
                (runner.claudeFailureRow(failure, evidence: "e"), "claude-code", "claude auth login"),
                (runner.codexFailureRow(failure, evidence: "e"), "codex", "codex login"),
            ] {
                XCTAssertEqual(row.status, .missing, "\(failure) must read as unmet")
                XCTAssertFalse(row.titleKey.isEmpty)
                switch (want, row.fix) {
                case ("install", .brewCask(let casks)?):
                    XCTAssertEqual(casks, [cask], "\(failure) offered the wrong cask")
                case ("sign in", .signIn(let command)?):
                    XCTAssertEqual(command, login, "\(failure) offered the wrong login command")
                case ("nothing", nil):
                    break
                default:
                    XCTFail("\(failure) on \(cask): wanted \(want), got \(String(describing: row.fix))")
                }
            }
        }
    }

    /// The wording is the claim. An unexplained failure must not be dressed up as a rate limit on
    /// a signed-in account, and only macOS's own refusal may be attributed to macOS.
    @MainActor
    func testTheRowDoesNotClaimMoreThanTheOutputProved() {
        let runner = PreflightRunner()
        for row in [runner.claudeFailureRow(.unknown, evidence: "e"),
                    runner.codexFailureRow(.unknown, evidence: "e")] {
            let text = (row.titleKey + " " + row.detailKey).lowercased()
            for invented in ["rate limit", "signed in", "malware", "xprotect", "trash", "npm"] {
                XCTAssertFalse(text.contains(invented),
                               "an unexplained failure must not assert \"\(invented)\": \(row.detailKey)")
            }
        }
        for row in [runner.claudeFailureRow(.executableMissing, evidence: "e"),
                    runner.codexFailureRow(.executableMissing, evidence: "e")] {
            let text = (row.titleKey + " " + row.detailKey).lowercased()
            for invented in ["malware", "xprotect", "gatekeeper"] {
                XCTAssertFalse(text.contains(invented),
                               "a missing program file does not prove \"\(invented)\": \(row.detailKey)")
            }
        }
        for row in [runner.claudeFailureRow(.blockedBySystem, evidence: "e"),
                    runner.codexFailureRow(.blockedBySystem, evidence: "e")] {
            XCTAssertTrue(row.titleKey.lowercased().contains("macos"),
                          "when macOS refused, the row may and should say so: \(row.titleKey)")
        }
    }
}

/// A box, because the probe closure is not escaping and Swift 6 will not let a captured local be
/// written from it directly.
private final class Probed { var yes = false }
