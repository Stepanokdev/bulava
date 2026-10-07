import XCTest
@testable import Bulava

/// Bulava and Bulava Dev are two apps to everything that is his: data, engine state, copies, the
/// engine itself, the tmux server, the signing key, the updater, the phone and the login item.
nonisolated final class AppChannelTests: XCTestCase {

    func testABuildThatSaysNothingIsProduction() {
        XCTAssertEqual(AppChannel.from(infoValue: nil), .production, "every release before channels")
        XCTAssertEqual(AppChannel.from(infoValue: ""), .production, "an unset build setting expands to nothing")
        XCTAssertEqual(AppChannel.from(infoValue: "production"), .production)
        XCTAssertEqual(AppChannel.from(infoValue: " dev "), .dev)
        XCTAssertEqual(AppChannel.from(infoValue: "DEV"), .dev)
    }

    func testTheChannelsKeepEverythingApart() {
        let home = URL(fileURLWithPath: "/Users/someone", isDirectory: true)
        let prod = AppChannel.production, dev = AppChannel.dev
        XCTAssertEqual(prod.supportFolderName, "NightShift", "his data stays where it always was")
        XCTAssertNotEqual(dev.supportFolderName, prod.supportFolderName)
        XCTAssertEqual(prod.defaultSupervisorStateDir(home: home).path, "/Users/someone/.claude/supervisor")
        XCTAssertNotEqual(dev.defaultSupervisorStateDir(home: home), prod.defaultSupervisorStateDir(home: home))
        XCTAssertEqual(prod.developerFolder(home: home).path, "/Users/someone/Library/Developer/Bulava")
        XCTAssertNotEqual(dev.developerFolder(home: home), prod.developerFolder(home: home),
                          "each sweeps the copies it has no record of")
        XCTAssertNotEqual(dev.signingKeyService, prod.signingKeyService, "no keychain prompt for his key")
        XCTAssertNil(prod.tmuxDir(stateDir: home), "his runs stay on the server they are on")
        XCTAssertNotNil(dev.tmuxDir(stateDir: home), "Dev's sessions cannot be taken for his")
        XCTAssertTrue(prod.ownsUpdates && prod.ownsPhoneLink && prod.ownsLoginItem)
        XCTAssertFalse(dev.ownsUpdates || dev.ownsPhoneLink || dev.ownsLoginItem)
    }

    func testDevSetsItsStateAndTmuxForEverythingItStarts() {
        var set: [String: String] = [:]
        AppChannel.prepareProcessEnvironment(.dev, setenv: { set[$0] = $1 }, environment: [:])
        XCTAssertEqual(set["SUPERVISOR_STATE_DIR"], AppChannel.dev.defaultSupervisorStateDir().path)
        XCTAssertEqual(set["TMUX_TMPDIR"],
                       AppChannel.dev.tmuxDir(stateDir: AppChannel.dev.defaultSupervisorStateDir())?.path)
        XCTAssertEqual(set["BULAVA_CHANNEL"], "dev")
    }

    func testAnOverrideAlreadyInPlaceIsLeftAlone() {
        var set: [String: String] = [:]
        AppChannel.prepareProcessEnvironment(.dev, setenv: { set[$0] = $1 },
                                             environment: ["SUPERVISOR_STATE_DIR": "/tmp/fixture-state",
                                                           "TMUX_TMPDIR": "/tmp/fixture-tmux"])
        XCTAssertNil(set["SUPERVISOR_STATE_DIR"], "a test fixture or a person's own override wins")
        XCTAssertNil(set["TMUX_TMPDIR"])
    }

    func testProductionChangesNothingInTheEnvironment() {
        var set: [String: String] = [:]
        AppChannel.prepareProcessEnvironment(.production, setenv: { set[$0] = $1 }, environment: [:])
        XCTAssertTrue(set.isEmpty)
    }

    /// The engine production runs is the one it was built with — never the repository's working
    /// copy, where every unsaved edit used to run inside his real jobs.
    func testProductionNeverRunsTheCheckout() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("channel-\(UUID().uuidString)")
        let checkout = home.appendingPathComponent("Developer/MyProjects/Night Shift/engine/bin")
        try FileManager.default.createDirectory(at: checkout, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: checkout.appendingPathComponent("verify.sh").path, contents: Data())
        defer { try? FileManager.default.removeItem(at: home) }
        XCTAssertNil(OrchestratorHome.developmentCheckout(channel: .production, home: home))
        XCTAssertEqual(OrchestratorHome.developmentCheckout(channel: .dev, home: home)?.path,
                       home.appendingPathComponent("Developer/MyProjects/Night Shift/engine").path)
    }

    /// The test host is a Debug build — Bulava Dev — and says so in its own Info.plist.
    func testTheDebugBuildIsDev() {
        XCTAssertEqual(Bundle.main.object(forInfoDictionaryKey: "BulavaChannel") as? String, "dev")
        XCTAssertEqual(AppChannel.current, .dev)
    }
}
