import XCTest
@testable import Bulava

/// Claude Code does not fail when its login has run out — it replies. "Login expired · Please run
/// /login" then arrives as the worker's answer, and Bulava showed it as one: a healthy-looking
/// conversation whose last message tells the reader to type a command into a terminal that is not
/// there. The person who met it asked where he was supposed to type it, then deleted the chat.
nonisolated final class LoginExpiredInChatTests: XCTestCase {

    func testTheCLIsOwnSignInNoticeIsRecognised() {
        for notice in ["Login expired · Please run /login",
                       "Invalid API key · Please run /login",
                       "OAuth token has expired · Please run /login"] {
            XCTAssertTrue(PreflightRunner.isSignInNotice(notice),
                          "this is the CLI asking to be signed in: \(notice)")
        }
    }

    /// The recogniser replaces the worker's answer with a wall, so it has to be sure. An answer
    /// that talks about signing in — even a short one-liner about OAuth, which is what an agent
    /// asked to work on sign-in code writes — is still an answer.
    func testARealAnswerAboutLoggingInIsLeftAlone() {
        let answers = [
            "I added a Sign in button to the readiness screen; it runs `claude auth login` in Terminal. The row now says \"Claude is not signed in\" instead of asking you to open a terminal yourself, and I have covered it with a test.",
            "The OAuth flow in AuthService.swift refreshes the token before it expires, so nothing has to be typed.",
            "Done — the login screen builds.",
            "Signing in is at /login in the web app; the CLI uses a different flow.",
            // Ends with the CLI's words but is not the CLI's sentence: no separator, and it goes
            // on afterwards. Matching the tail alone took this off the screen.
            "Please run /login, then retry",
            "If it asks you to, please run /login.",
        ]
        for answer in answers {
            XCTAssertFalse(PreflightRunner.isSignInNotice(answer),
                           "this is the worker answering, not the CLI refusing: \(answer.prefix(40))…")
        }
    }

    /// A wording nobody has seen is left on screen rather than guessed at. That is the state
    /// before this existed, so the cost of missing one is nothing gained — and the cost of a wrong
    /// guess is a real answer replaced by a wall.
    func testAnUnfamiliarAuthWordingIsLeftOnScreenRatherThanGuessedAt() {
        XCTAssertFalse(PreflightRunner.isSignInNotice("Failed to authenticate: session expired"))
    }

    func testEmptyOrLongTextIsNotANotice() {
        XCTAssertFalse(PreflightRunner.isSignInNotice(""))
        XCTAssertFalse(PreflightRunner.isSignInNotice("   \n  "))
        XCTAssertFalse(PreflightRunner.isSignInNotice(
            String(repeating: "please run /login ", count: 40)))
        XCTAssertFalse(PreflightRunner.isSignInNotice(
            "Here is what it printed:\nLogin expired · Please run /login\nand then it stopped."))
    }

    /// The same sentence, arriving through the readiness probe instead of a chat, has to reach the
    /// same verdict — there is one definition of "this is an account problem" in the app.
    func testTheReadinessScreenReachesTheSameVerdict() {
        XCTAssertEqual(PreflightRunner.classify(exitCode: 0, output: "Login expired · Please run /login"),
                       .notSignedIn)
        let runner = PreflightRunner.self
        XCTAssertEqual(runner.classify(exitCode: 1, output: "Invalid API key · Please run /login"),
                       .notSignedIn)
    }
}
