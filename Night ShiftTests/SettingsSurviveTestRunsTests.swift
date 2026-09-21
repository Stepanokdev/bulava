import XCTest
@testable import Bulava

/// A UI test must not be able to reconfigure the app he actually uses.
///
/// It happened: a UI-test launch wrote its fixture `stateDirPath` into the shared defaults domain,
/// the fixture was deleted with its scratchpad, and weeks later the live app was still pointed at
/// a directory that did not exist — so every screen fed by the engine had nothing behind it and
/// nothing said why.
nonisolated final class SettingsSurviveTestRunsTests: XCTestCase {

    func testADeadStateDirectoryIsPutBackToTheDefault() {
        var broken = AppSettings.fallback
        broken.stateDirPath = "/private/tmp/deleted-scratchpad-\(UUID().uuidString)/supervisor"
        XCTAssertEqual(broken.healed().stateDirPath, AppSettings.defaultStateDirPath)
    }

    func testAnEmptyStateDirectoryIsPutBackToTheDefault() {
        var broken = AppSettings.fallback
        broken.stateDirPath = "   "
        XCTAssertEqual(broken.healed().stateDirPath, AppSettings.defaultStateDirPath)
    }

    /// Healing must not become "the app overrules where he told it to look".
    func testADirectoryHeDeliberatelyChoseIsLeftAlone() throws {
        let chosen = FileManager.default.temporaryDirectory
            .appendingPathComponent("bulava-chosen-state-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: chosen, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: chosen) }

        var settings = AppSettings.fallback
        settings.stateDirPath = chosen.path
        XCTAssertEqual(settings.healed().stateDirPath, chosen.path)
    }

    /// The default is never second-guessed, even before it has been created.
    func testTheDefaultIsAcceptedWhetherOrNotItExistsYet() {
        var settings = AppSettings.fallback
        settings.stateDirPath = AppSettings.defaultStateDirPath
        XCTAssertEqual(settings.healed().stateDirPath, AppSettings.defaultStateDirPath)
    }

    func testHealingChangesNothingElse() {
        var settings = AppSettings.fallback
        settings.stateDirPath = "/private/tmp/gone-\(UUID().uuidString)"
        settings.chatMode = .codex
        settings.claudeModel = .fable
        settings.codexEffort = .low
        settings.interfaceLanguage = .uk

        let healed = settings.healed()
        XCTAssertEqual(healed.chatMode, .codex)
        XCTAssertEqual(healed.claudeModel, .fable)
        XCTAssertEqual(healed.codexEffort, .low)
        XCTAssertEqual(healed.interfaceLanguage, .uk)
    }

    /// A fixture launch is recognised by the same variable that already redirects every other
    /// store, so settings follow the rest of a test's state instead of leaking into his.
    ///
    /// This bundle itself runs with that variable set, which is the point: the store it gets is
    /// not the one his app writes to.
    func testAFixtureLaunchDoesNotGetHisSettings() throws {
        let fixture = try XCTUnwrap(ProcessInfo.processInfo.environment["BULAVA_STATE_DIR"],
                                    "the test host is expected to run against a fixture state dir")
        XCTAssertFalse(fixture.isEmpty)
        XCTAssertNotEqual(AppSettings.store, UserDefaults.standard,
                          "a test writing settings must not reconfigure the app he uses")
    }

    /// Whatever a test writes has to stay inside the test's own suite.
    func testWritingSettingsUnderAFixtureLeavesHisAlone() throws {
        let before = UserDefaults.standard.data(forKey: "com.nightshift.settings.v1")

        var settings = AppSettings.fallback
        settings.stateDirPath = "/private/tmp/fixture-\(UUID().uuidString)/supervisor"
        settings.save()

        XCTAssertEqual(UserDefaults.standard.data(forKey: "com.nightshift.settings.v1"), before)
    }
}
