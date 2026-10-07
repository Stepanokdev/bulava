import XCTest
@testable import Bulava

/// A new user's first chat stopped on Claude Code's theme picker, out of sight in tmux, and was
/// rolled back as if the hooks were broken. These pin the one flag that decides it and the write
/// that answers it.
nonisolated final class ClaudeOnboardingTests: XCTestCase {

    private func config(_ json: String?) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("bulava-onboarding-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent(".claude.json")
        if let json { try json.write(to: url, atomically: true, encoding: .utf8) }
        return url
    }

    // MARK: - Reading

    func testNoConfigAtAllMeansTheFirstRunIsAhead() throws {
        XCTAssertTrue(ClaudeOnboarding.needsSetup(configURL: try config(nil)))
    }

    func testSignedInButNeverOpenedStillNeedsSetup() throws {
        // What `claude auth login` leaves: an account, and no onboarding.
        let url = try config(#"{"oauthAccount":{"emailAddress":"a@b.c"},"numStartups":0}"#)
        XCTAssertTrue(ClaudeOnboarding.needsSetup(configURL: url))
    }

    func testAFalseFlagNeedsSetup() throws {
        // A logout writes it back to false; the next start shows the picker again.
        XCTAssertTrue(ClaudeOnboarding.needsSetup(configURL: try config(#"{"hasCompletedOnboarding":false}"#)))
    }

    func testCompletedOnboardingIsSetUp() throws {
        XCTAssertFalse(ClaudeOnboarding.needsSetup(configURL: try config(#"{"hasCompletedOnboarding":true}"#)))
    }

    func testAnUnreadableConfigBlocksNothing() throws {
        XCTAssertFalse(ClaudeOnboarding.needsSetup(configURL: try config("{ not json")),
                       "a guess must not stop a send; the engine reads the real screen if it matters")
    }

    // MARK: - Writing

    func testCompletingKeepsEverythingElse() throws {
        let url = try config(#"{"oauthAccount":{"emailAddress":"a@b.c"},"projects":{"/x":{"hasTrustDialogAccepted":true}}}"#)

        XCTAssertTrue(ClaudeOnboarding.complete(configURL: url))

        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        XCTAssertEqual(root["hasCompletedOnboarding"] as? Bool, true)
        XCTAssertEqual((root["oauthAccount"] as? [String: Any])?["emailAddress"] as? String, "a@b.c")
        XCTAssertEqual(((root["projects"] as? [String: Any])?["/x"] as? [String: Any])?["hasTrustDialogAccepted"] as? Bool, true)
        XCTAssertFalse(ClaudeOnboarding.needsSetup(configURL: url))
    }

    func testCompletingCreatesTheConfigOwnerOnly() throws {
        let url = try config(nil)

        XCTAssertTrue(ClaudeOnboarding.complete(configURL: url))

        XCTAssertFalse(ClaudeOnboarding.needsSetup(configURL: url))
        let mode = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int
        XCTAssertEqual(mode, 0o600, "the file carries the account session")
    }

    func testCompletingRefusesToOverwriteAConfigItCannotRead() throws {
        let url = try config("{ not json")

        XCTAssertFalse(ClaudeOnboarding.complete(configURL: url))
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "{ not json",
                       "replacing a file it could not read would wipe the account")
    }

    // MARK: - The engine's word

    func testTheEnginesVerdictIsReadOffItsOutput() {
        let said = """
        ⚠️ хуки не підтвердили run-id за 12s — робота може піти без нагляду.
           Claude Code ще не пройшов перше налаштування на цьому Mac
        handshake-blocked=onboarding
        ❌ підтвердження нема — відкат старту.
        """
        XCTAssertTrue(ClaudeOnboarding.engineSawIt(said))
        XCTAssertFalse(ClaudeOnboarding.engineSawIt(said.replacingOccurrences(of: "=onboarding", with: "=hooks")))
        XCTAssertFalse(ClaudeOnboarding.engineSawIt("the word handshake-blocked=onboarding inside a line"))
    }
}
