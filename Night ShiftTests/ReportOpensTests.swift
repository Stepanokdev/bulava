import XCTest
@testable import Bulava

nonisolated final class ReportOpensTests: XCTestCase {

    private var supervisor: URL!

    override func setUp() async throws {
        supervisor = FileManager.default.temporaryDirectory
            .appendingPathComponent("bulava-report-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: supervisor, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: supervisor)
    }

    private func client() -> SupervisorClient {
        SupervisorClient(paths: SupervisorPaths(stateDir: supervisor))
    }

    private func writeManifest(key: String) throws {
        let dir = supervisor.appendingPathComponent("reports/\(key)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try """
        {"format":"notes","language":"Ukrainian","title":"Канали і запит на оцінку",
         "summary":"Обидва пункти були зламані, обидва полагоджені.",
         "body":"## Канали\\n\\nВимкнений канал далі опитувався.\\n\\n## Рейтинг\\n\\nНа iPad не викликався взагалі."}
        """.write(to: dir.appendingPathComponent("report.json"), atomically: true, encoding: .utf8)
    }

    func testTheKeyFromTheDispatchRendersTheWorkersReport() async throws {
        try writeManifest(key: "feed1234")

        var task = BacklogTask(title: "Перевір запит на оцінку і канали")
        task.boundReportKey = "feed1234"
        XCTAssertEqual(task.reportKey, "feed1234")

        let c = client()
        let url = await c.renderReport(task8: task.reportKey, fallbackTitle: task.title)
        let rendered = try XCTUnwrap(url, "«Відкрити звіт» had nothing to open")

        let html = try String(contentsOf: rendered, encoding: .utf8)
        XCTAssertTrue(html.contains("Канали і запит на оцінку"), "a different report was rendered")
        XCTAssertTrue(html.contains("iPad"), "the worker's own findings are not on the page")
        XCTAssertEqual(rendered.deletingLastPathComponent().lastPathComponent, "feed1234",
                       "the page was written somewhere the card does not look")
    }

    func testACardThatInventsItsOwnKeyFindsNothing() async throws {
        try writeManifest(key: "feed1234")
        let task = BacklogTask(title: "Перевір запит на оцінку і канали")
        let url = await client().renderReport(task8: task.reportKey, fallbackTitle: task.title)
        XCTAssertNil(url, "a key nobody was told must not resolve to somebody else's report")
    }

    func testNoManifestMeansNoDocument() async throws {
        var task = BacklogTask(title: "Робота")
        task.boundReportKey = "0badc0de"
        let url = await client().renderReport(task8: task.reportKey, fallbackTitle: task.title)
        XCTAssertNil(url)
    }

    func testChatReportIsPublishedInsideProjectAndIgnoredByGit() async throws {
        let project = supervisor.appendingPathComponent("client-project")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        try "build/\n".write(to: project.appendingPathComponent(".gitignore"),
                              atomically: true, encoding: .utf8)
        let source = supervisor.appendingPathComponent("session-report.html")
        try "<html><body>done</body></html>".write(to: source, atomically: true, encoding: .utf8)

        let published = await client().publishChatReport(htmlPath: source.path,
                                                         projectPath: project.path,
                                                         title: "Client follow-up")
        let path = try XCTUnwrap(published)
        XCTAssertTrue(path.hasPrefix(project.appendingPathComponent("artifacts").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: path))
        let ignore = try String(contentsOf: project.appendingPathComponent(".gitignore"), encoding: .utf8)
        XCTAssertTrue(ignore.contains("build/"), "the project's existing ignore rules were replaced")
        XCTAssertEqual(ignore.components(separatedBy: "artifacts/").count - 1, 1)
    }

    func testDirectChatReportRequestUsesTheRichContractAndExplicitArtifactCommand() async throws {
        let project = supervisor.appendingPathComponent("client-project")
        let engine = supervisor.appendingPathComponent("engine")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: engine.appendingPathComponent("supervisor"),
                                                withIntermediateDirectories: true)
        try """
        ЗВІТ {{DIR}} {{LANG}} {{CONTINUING}}
        Наприкінці виклич `$IDIR/artifact`.
        """.write(to: engine.appendingPathComponent("supervisor/REPORT-DIRECTIVE.md"),
                  atomically: true, encoding: .utf8)
        let id = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!

        let request = await client().prepareChatReportRequest(
            projectPath: project.path, orchestratorHome: engine.path,
            language: "Ukrainian", title: "Законодавство",
            originalRequest: "Додай вкладку і покажи два екрани.", id: id)
        let prepared = try XCTUnwrap(request)
        let text = try String(contentsOf: prepared.instructionFile, encoding: .utf8)

        XCTAssertTrue(text.contains("ЛИШЕ ЗВІТ"))
        XCTAssertTrue(text.contains("не аудит усього продукту"))
        XCTAssertTrue(text.contains("Додай вкладку і покажи два екрани."))
        XCTAssertTrue(text.contains("повторно використай реальні кадри/відео"))
        XCTAssertTrue(text.contains("$IDIR/artifact \"\(prepared.directory.path)\" \"\(project.path)\""))
        XCTAssertTrue(prepared.relayMessage.contains(prepared.instructionFile.path))
    }

    func testDirectChatReportAcceptsOnlyItsOwnArtifactPointerInsideTheProject() async throws {
        let project = supervisor.appendingPathComponent("client-project")
        let engine = supervisor.appendingPathComponent("engine")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: engine.appendingPathComponent("supervisor"),
                                                withIntermediateDirectories: true)
        try "{{DIR}} {{LANG}} {{CONTINUING}}".write(
            to: engine.appendingPathComponent("supervisor/REPORT-DIRECTIVE.md"),
            atomically: true, encoding: .utf8)
        let c = client()
        let maybeRequest = await c.prepareChatReportRequest(
            projectPath: project.path, orchestratorHome: engine.path,
            language: "Ukrainian", title: "Result", originalRequest: "Do it")
        let request = try XCTUnwrap(maybeRequest)
        let page = project.appendingPathComponent("artifacts/2026-08-24-result/index.html")
        try FileManager.default.createDirectory(at: page.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try "<html>rich report</html>".write(to: page, atomically: true, encoding: .utf8)
        try (page.path + "\n").write(to: request.artifactPointer, atomically: true, encoding: .utf8)

        let resolved = await c.completedChatReport(request)
        XCTAssertEqual(resolved, page.path)

        let outside = supervisor.appendingPathComponent("some-other-report/index.html")
        try FileManager.default.createDirectory(at: outside.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try "<html>wrong</html>".write(to: outside, atomically: true, encoding: .utf8)
        try outside.path.write(to: request.artifactPointer, atomically: true, encoding: .utf8)
        let rejected = await c.completedChatReport(request)
        XCTAssertNil(rejected)
    }
}
