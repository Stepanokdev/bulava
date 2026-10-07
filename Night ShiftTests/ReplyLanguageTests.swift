import XCTest
@testable import Bulava

/// Bulava answers people in the language they write to it in.
///
/// Someone who wrote in English or Russian was answered in Ukrainian: a chat was started and sent to
/// with no language at all, so the engine's own default decided; runs started from the queue, a
/// retry or an answered blocker carried a hard-coded "Ukrainian"; and the report the app asked for
/// was requested in Ukrainian words. The engine now names the person's language with every message
/// (`task_language_line`); the app's part is to say where a worker starts, on every path, and to mark
/// the words it sends itself so they are not taken for the person's.
nonisolated final class ReplyLanguageTests: XCTestCase {

    func testAWorkerStartsInTheChosenLanguageOrTheOneTheAppIsShownIn() {
        var s = AppSettings.fallback
        s.reportLanguage = .ru
        XCTAssertEqual(s.workLanguageName, "Russian")
        s.reportLanguage = .system
        s.interfaceLanguage = .en
        XCTAssertEqual(s.workLanguageName, "English", "System follows the interface, not a fixed language")
        s.interfaceLanguage = .uk
        XCTAssertEqual(s.workLanguageName, "Ukrainian")
    }

    func testEveryRunCarriesItNotAFixedUkrainian() {
        var s = AppSettings.fallback
        s.reportLanguage = .en
        // The queue, a retry, an answered blocker: all start from `.standing`.
        XCTAssertEqual(RunStrategy.standing.overridden(by: s).reportLanguage, "English")
        XCTAssertEqual(SupervisorClient.launchEnv(RunStrategy.standing.overridden(by: s))["SUPERVISOR_REPORT_LANGUAGE"], "English")
        XCTAssertNotEqual(RunStrategy.standing.reportLanguage, "Ukrainian", "no run is Ukrainian by default any more")
    }

    func testAChatIsStartedAndSentToWithIt() {
        let run = SupervisorClient.runEnv(claudeEffort: "", claudeModel: "", codexEffort: "", codexModel: "",
                                          collaboration: "", language: "Russian")
        XCTAssertEqual(run["SUPERVISOR_REPORT_LANGUAGE"], "Russian")
        let start = SupervisorClient.chatEnv(contextFile: "/tmp/c", extraDirsFile: "/tmp/d", claudeEffort: "",
                                             claudeModel: "", language: "English")
        XCTAssertEqual(start["SUPERVISOR_REPORT_LANGUAGE"], "English")
    }

    /// The app's request for a report is its own words, marked so; the report follows the person.
    func testTheReportRequestIsMarkedAsTheAppsAndFollowsThePerson() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("reply-language-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let project = root.appendingPathComponent("project")
        let engine = root.appendingPathComponent("engine")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: engine.appendingPathComponent("supervisor"), withIntermediateDirectories: true)
        try "{{DIR}} {{LANG}} {{CONTINUING}}".write(to: engine.appendingPathComponent("supervisor/REPORT-DIRECTIVE.md"),
                                                    atomically: true, encoding: .utf8)
        let client = SupervisorClient(paths: SupervisorPaths(stateDir: root.appendingPathComponent("state")))
        let prepared = await client.prepareChatReportRequest(
            projectPath: project.path, orchestratorHome: engine.path,
            language: "English", title: "Export", originalRequest: "Why does export stay grey?")
        let request = try XCTUnwrap(prepared)
        XCTAssertTrue(request.relayMessage.hasPrefix("[BULAVA]"), "the engine is told these words are the app's")
        XCTAssertTrue(request.relayMessage.contains("in the language the person has been writing to you in"))
        let contract = try String(contentsOf: request.instructionFile, encoding: .utf8)
        XCTAssertTrue(contract.contains("the report is written in the language the person has been writing to you in"))
    }
}
