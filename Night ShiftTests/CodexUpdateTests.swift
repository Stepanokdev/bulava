import XCTest
@testable import Bulava

/// A new model reaches the menu through a newer Codex. These pin how Bulava finds out there is one
/// and what it offers to run — never more than it can stand behind.
nonisolated final class CodexUpdateTests: XCTestCase {

    func testAnNPMInstallIsUpdatedWithTheNPMBesideIt() {
        let source = CodexUpdate.source(of: "/Users/x/.nvm/versions/node/v22/bin/codex",
                                        exists: { $0.hasSuffix("/bin/npm") },
                                        linkTarget: { _ in "../lib/node_modules/@openai/codex/bin/codex.js" },
                                        isNative: { _ in false })
        XCTAssertEqual(source, .npm(npm: "/Users/x/.nvm/versions/node/v22/bin/npm"))
        let command = CodexUpdate.command(for: source!)
        XCTAssertTrue(command.hasPrefix("PATH=\"/Users/x/.nvm/versions/node/v22/bin:$PATH\""),
                      "the node it was installed with comes first: \(command)")
        XCTAssertTrue(command.hasSuffix("install -g @openai/codex@latest"))
    }

    func testTheCaskIsUpgradedWithHomebrew() {
        let source = CodexUpdate.source(of: "/opt/homebrew/bin/codex",
                                        exists: { $0 == "/opt/homebrew/bin/brew" },
                                        linkTarget: { _ in nil }, isNative: { _ in true })
        XCTAssertEqual(source, .cask(brew: "/opt/homebrew/bin/brew"))
        XCTAssertEqual(CodexUpdate.command(for: source!), "/opt/homebrew/bin/brew upgrade --cask codex")
    }

    func testAnInstallNobodyCanPlaceIsLeftAlone() {
        XCTAssertNil(CodexUpdate.source(of: "/usr/local/bin/codex", exists: { _ in true },
                                        linkTarget: { _ in "/opt/my-wrapper.sh" }, isNative: { _ in false }))
    }

    func testOnlyANewerVersionIsOffered() {
        let npm = CodexUpdate.Source.npm(npm: "/n/npm")
        XCTAssertEqual(CodexUpdate.decide(installed: "0.156.0", latest: "0.160.1", source: npm)?.latest, "0.160.1")
        XCTAssertNil(CodexUpdate.decide(installed: "0.160.1", latest: "0.160.1", source: npm))
        XCTAssertNil(CodexUpdate.decide(installed: "0.161.0", latest: "0.160.1", source: npm),
                     "a newer local build is not downgraded")
        XCTAssertNil(CodexUpdate.decide(installed: "0.156.0", latest: nil, source: npm),
                     "offline: nothing is claimed")
    }

    func testWhatTheSourcesSayIsRead() {
        XCTAssertEqual(CodexUpdate.parseNPM("0.160.1\n"), "0.160.1")
        XCTAssertNil(CodexUpdate.parseNPM("npm ERR! network"))
        XCTAssertEqual(CodexUpdate.parseBrew(#"{"formulae":[],"casks":[{"token":"codex","version":"0.160.1"}]}"#), "0.160.1")
        XCTAssertNil(CodexUpdate.parseBrew("not json"))
    }

    /// The menu writes the model the way the service does: GPT-6.1 Sol, not GPT-6.1-Sol.
    func testTheNewModelReadsAsTheServiceWritesIt() {
        let model = CodexModel(slug: "gpt-6.1-sol", displayName: "GPT-6.1-Sol", summary: "",
                               levels: ["low", "medium"], defaultLevel: "low", priority: 1)
        XCTAssertEqual(model.shortLabel, "GPT-6.1 Sol")
    }
}
