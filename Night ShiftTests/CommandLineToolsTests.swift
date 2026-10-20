import XCTest
@testable import Bulava

/// A Mac without Apple's command line tools. There /usr/bin/git and /usr/bin/python3 are stand-ins
/// that ask macOS to install the tools and exit, and Bulava took them for the real thing: the
/// readiness screen said both were available while the engine's installer died on python3, at every
/// launch, with Apple's "See `man xcode-select`" as the reason (a 1.13 user's report, 2026-10-11).
nonisolated final class CommandLineToolsTests: XCTestCase {

    private let commandLineTools = "/Library/Developer/CommandLineTools"

    private func needs(_ name: String, at path: String, _ dir: DeveloperTools.Directory,
                       executables: Set<String> = [], links: [String: String] = [:],
                       asked: ((String) -> Void)? = nil) -> Bool {
        DeveloperTools.needsCommandLineTools(
            name, at: path, developerDirectory: dir,
            isExecutable: { asked?($0); return executables.contains($0) },
            resolve: { links[$0] ?? $0 })
    }

    // MARK: - The decision

    func testAStandInWithNoDeveloperDirectoryCannotRun() {
        XCTAssertTrue(needs("python3", at: "/usr/bin/python3", .absent),
                      "the reporter's Mac: python3 found on PATH, nothing behind it")
        XCTAssertTrue(needs("git", at: "/usr/bin/git", .absent))
    }

    func testTheCommandLineToolsPutTheRealToolBehindIt() {
        XCTAssertFalse(needs("python3", at: "/usr/bin/python3", .at(commandLineTools),
                             executables: [commandLineTools + "/usr/bin/python3"]))
    }

    func testXcodeAtAPathWithSpacesCountsToo() {
        let xcode = "/Applications/Xcode 27 beta.app/Contents/Developer"
        XCTAssertFalse(needs("git", at: "/usr/bin/git", .at(xcode), executables: [xcode + "/usr/bin/git"]))
    }

    /// `xcode-select -p` repeats DEVELOPER_DIR whether or not it exists, and keeps a selection
    /// after the tools it named are deleted. The directory's name proves nothing; its contents do.
    func testASelectedDirectoryWithoutTheToolIsNotEnough() {
        XCTAssertTrue(needs("git", at: "/usr/bin/git", .at("/Applications/Xcode.app/Contents/Developer")))
        XCTAssertTrue(needs("python3", at: "/usr/bin/python3", .at("/no/such/developer/dir")))
    }

    func testHomebrewsPythonDoesNotNeedThem() {
        XCTAssertFalse(needs("python3", at: "/opt/homebrew/bin/python3", .absent),
                       "a real python3 first on PATH runs whatever Apple's tools are doing")
    }

    /// The same stand-in under another name: a link in /usr/local/bin to /usr/bin/git.
    func testALinkToTheStandInIsTheStandIn() {
        XCTAssertTrue(needs("git", at: "/usr/local/bin/git", .absent,
                            links: ["/usr/local/bin/git": "/usr/bin/git"]))
    }

    /// macOS 15 ships a real jq in /usr/bin. Reading every /usr/bin tool as a stand-in would block
    /// work on every Mac without Xcode.
    func testOnlyGitAndPythonAreStandIns() {
        XCTAssertFalse(needs("jq", at: "/usr/bin/jq", .absent))
        XCTAssertFalse(DeveloperTools.isStandIn("jq", at: "/usr/bin/jq", resolve: { $0 }))
    }

    /// A probe that did not finish says nothing about the Mac. Claiming "missing" from it would stop
    /// every run on a Mac that works; the row is asked again at the next refresh.
    func testAnUnansweredProbeClaimsNothing() {
        XCTAssertFalse(needs("python3", at: "/usr/bin/python3", .unknown))
    }

    /// The decision is made from the disk. Asking whether /usr/bin/python3 itself is executable
    /// would prove nothing — it always is — and running it is the very dialog this exists to avoid.
    func testOnlyTheDeveloperDirectoryIsAsked() {
        var asked: [String] = []
        _ = needs("python3", at: "/usr/bin/python3", .at(commandLineTools), asked: { asked.append($0) })
        XCTAssertEqual(asked, [commandLineTools + "/usr/bin/python3"])
    }

    func testNothingFoundIsNotAStandIn() {
        XCTAssertFalse(needs("git", at: "", .absent), "not on PATH is its own row, with its own remedy")
    }

    /// The defaults, against this Mac's own disk rather than a table. /usr/bin/git is a hard link,
    /// not a symlink, so resolving leaves it where it is; a resolver that took it anywhere else
    /// would quietly switch the whole check off. Nothing here runs git.
    func testTheRealStandInIsRecognisedOnTheDisk() throws {
        XCTAssertTrue(DeveloperTools.isStandIn("git", at: "/usr/bin/git"))
        XCTAssertTrue(DeveloperTools.needsCommandLineTools("git", at: "/usr/bin/git",
                                                            developerDirectory: .at("/no/such/developer/dir")))
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("clt-link-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let link = dir.appendingPathComponent("git")
        try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: "/usr/bin/git")
        XCTAssertTrue(DeveloperTools.isStandIn("git", at: link.path), "a link to the stand-in is the stand-in")
    }

    // MARK: - The readiness row

    private func row(_ name: String, at path: String, needs: Bool) -> PreflightCheck {
        PreflightRunner.toolRow(name: name, foundAt: path, needsCommandLineTools: needs,
                                titleKey: "python3 is available",
                                detailKey: "Most of the engine's own tooling is written in it.",
                                brewFormula: name == "python3" ? "python" : nil)
    }

    func testTheRowNoLongerCallsTheStandInAvailable() {
        let check = row("python3", at: "/usr/bin/python3", needs: true)
        XCTAssertEqual(check.status, .missing)
        XCTAssertTrue(check.required, "work started here dies on its first python3 or git")
        XCTAssertEqual(check.fix, .installCommandLineTools,
                       "Homebrew is no way out: it needs Apple's command line tools itself")
        XCTAssertNotEqual(check.evidence, "/usr/bin/python3",
                          "the path was the false proof; the row says what is behind it")
    }

    func testARealToolIsStillReady() {
        let check = row("python3", at: "/opt/homebrew/bin/python3", needs: false)
        XCTAssertEqual(check.status, .ready)
        XCTAssertEqual(check.evidence, "/opt/homebrew/bin/python3")
        XCTAssertNil(check.fix)
    }

    func testNotOnPathKeepsItsOwnRemedy() {
        let check = row("python3", at: "", needs: false)
        XCTAssertEqual(check.status, .missing)
        XCTAssertEqual(check.fix, .brew(["python"]))
    }

    // MARK: - The button's answer

    // xcode-select's own sentences, as its binary carries them.

    @MainActor
    func testWhenMacOSPutsItsDialogUpBulavaAddsNothing() {
        XCTAssertNil(AppModel.commandLineToolsCard(
            xcodeSelectSaid: "xcode-select: note: install requested for command line developer tools\n"),
            "the dialog is the answer; a card on top of it would only cover it")
    }

    @MainActor
    func testWhenMacOSSaysTheyAreThereItsWordsAreShown() throws {
        let card = try XCTUnwrap(AppModel.commandLineToolsCard(xcodeSelectSaid:
            "xcode-select: note: Command line tools are already installed. Use \"Software Update\" in System Settings or the softwareupdate command line interface to install updates"),
            "pressing the button must never come to nothing")
        XCTAssertEqual(card.kind, .error)
        XCTAssertTrue(card.text.contains("already installed"), card.text)
    }

    @MainActor
    func testWhenNoInstallCouldBeRequestedThatIsSaid() throws {
        let card = try XCTUnwrap(AppModel.commandLineToolsCard(xcodeSelectSaid:
            "xcode-select: error: no developer tools were found, and no install could be requested (perhaps no UI is present), please install manually from 'developer.apple.com'."))
        XCTAssertTrue(card.text.contains("no install could be requested"), card.text)
    }

    @MainActor
    func testSilenceIsNotTakenForTheDialog() throws {
        let card = try XCTUnwrap(AppModel.commandLineToolsCard(xcodeSelectSaid: ""),
                                 "xcode-select that did not run said nothing — that is not a dialog on the screen")
        XCTAssertFalse(card.text.isEmpty)
    }

    // MARK: - The engine's installer

    /// An engine whose installer leaves a mark when it runs — the question is whether it runs.
    private func markingEngine(marker: URL) throws -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("engine-clt-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("bin"),
                                                withIntermediateDirectories: true)
        try "#!/bin/bash\ntouch \"\(marker.path)\"\n".write(to: dir.appendingPathComponent("install.sh"),
                                                            atomically: true, encoding: .utf8)
        try "#!/bin/bash\n".write(to: dir.appendingPathComponent("bin/verify.sh"),
                                  atomically: true, encoding: .utf8)
        try "202610149999\n".write(to: dir.appendingPathComponent(".engine-version"),
                                   atomically: true, encoding: .utf8)
        return dir
    }

    func testTheInstallIsRefusedBeforeAnythingIsCopied() async throws {
        let marker = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("ran-\(UUID().uuidString)")
        let bundled = try markingEngine(marker: marker)
        let target = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("engine-target-\(UUID().uuidString)")
        defer {
            try? FileManager.default.removeItem(at: bundled)
            try? FileManager.default.removeItem(at: target)
            try? FileManager.default.removeItem(at: marker)
        }

        let outcome = await EngineInstaller.install(from: bundled, to: target,
                                                    pythonNeedsCommandLineTools: { true })
        XCTAssertFalse(outcome.ok)
        XCTAssertTrue(outcome.needsCommandLineTools, "the refusal that comes with a button of its own")
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path),
                       "the installer ran — on that Mac, the run IS macOS's install dialog and a backup of Claude Code's settings")
        XCTAssertFalse(FileManager.default.fileExists(atPath: target.path), "nothing is copied for an install that cannot finish")
        XCTAssertFalse(outcome.log.contains("xcode-select"), "the reason is Bulava's sentence, not Apple's: \(outcome.log)")
        XCTAssertNil(OrchestratorHome.version(of: target))
    }

    func testWhereThePythonRunsTheInstallGoesAhead() async throws {
        let marker = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("ran-\(UUID().uuidString)")
        let bundled = try markingEngine(marker: marker)
        let target = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("engine-target-\(UUID().uuidString)")
        defer {
            try? FileManager.default.removeItem(at: bundled)
            try? FileManager.default.removeItem(at: target)
            try? FileManager.default.removeItem(at: marker)
        }

        let outcome = await EngineInstaller.install(from: bundled, to: target,
                                                    pythonNeedsCommandLineTools: { false })
        XCTAssertTrue(outcome.ok, "log: \(outcome.log)")
        XCTAssertFalse(outcome.needsCommandLineTools)
        XCTAssertTrue(FileManager.default.fileExists(atPath: marker.path), "and its installer is what ran")
        XCTAssertEqual(OrchestratorHome.version(of: target), "202610149999")
    }
}
