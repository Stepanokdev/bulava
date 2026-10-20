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

/// "Open report" when the report it remembers was rebuilt elsewhere (19 Oct: "Файлу звіту немає",
/// with the report right there under its new name).
nonisolated final class ReportMovedTests: XCTestCase {

    private var state: URL!

    override func setUp() async throws {
        state = FileManager.default.temporaryDirectory.appendingPathComponent("bulava-moved-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: state, withIntermediateDirectories: true)
        FixtureState.use(state.appendingPathComponent("app").path)
    }

    override func tearDown() async throws {
        FixtureState.restore()
        try? FileManager.default.removeItem(at: state)
    }

    /// A report folder as the engine leaves it: the page, and the request Bulava wrote, copied in.
    private func report(_ name: String, title: String, request: String, in root: URL) throws -> String {
        let folder = root.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let marks = SupervisorClient.reportRequestMarks(title: title, originalRequest: request)
        try "# ОКРЕМИЙ ХІД: ЛИШЕ ЗВІТ\n\n\(marks[0])\n\nПочатковий запит:\n\(marks[1])\n"
            .write(to: folder.appendingPathComponent("REPORT-REQUEST.md"), atomically: true, encoding: .utf8)
        let page = folder.appendingPathComponent("index.html")
        try "<html>\(name)</html>".write(to: page, atomically: true, encoding: .utf8)
        return page.path
    }

    @MainActor
    func testAReportRebuiltUnderANewNameIsFoundForItsOwnChatOnly() throws {
        let root = state.appendingPathComponent("project/artifacts", isDirectory: true)
        let model = AppModel()
        let product = model.products.add(name: "Bulava")
        let chat = model.conversations.newChat(for: product.id)
        model.conversations.appendUser("Знайди мені баги за тиждень", productID: product.id, chatID: chat.id)
        model.conversations.bindSession(ChatSessionBinding(primaryProjectID: nil, projectPath: state.path, claudeSessionID: "S"), to: chat.id)
        let mine = try XCTUnwrap(model.conversations.chat(id: chat.id))

        let first = try report("2026-10-19-1106-баги", title: mine.title, request: mine.firstMessage, in: root)
        model.conversations.addReport(first, to: chat.id)
        let rebuilt = try report("2026-10-19-1123-баги", title: mine.title, request: mine.firstMessage, in: root)
        // Another chat, same title, a different request — and the newest of all.
        Thread.sleep(forTimeInterval: 1.1)
        _ = try report("2026-10-19-1130-баги", title: mine.title, request: "Інша розмова зовсім", in: root)
        try FileManager.default.removeItem(at: URL(fileURLWithPath: first).deletingLastPathComponent())
        // The engine's `latest` link points at it too — but it is a pointer that moves, never a home.
        try FileManager.default.createSymbolicLink(atPath: root.appendingPathComponent("latest").path,
                                                   withDestinationPath: "2026-10-19-1123-баги")

        XCTAssertTrue(model.healReportPaths(in: chat.id))
        XCTAssertEqual(model.conversations.chat(id: chat.id)?.session?.reportPaths, [rebuilt],
                       "this chat's report, rebuilt — not the newer one of another chat with the same title")
        model.openChatReport(chatID: chat.id, path: first, title: "")
        XCTAssertEqual(model.reportViewer?.htmlURL.path, rebuilt, "the button opens it, not an error")
        XCTAssertFalse(model.healReportPaths(in: chat.id), "nothing left to repair")

        // Nothing of this chat's left at all: nothing is taken in its place.
        try FileManager.default.removeItem(at: URL(fileURLWithPath: rebuilt).deletingLastPathComponent())
        XCTAssertFalse(model.healReportPaths(in: chat.id))
        XCTAssertEqual(model.conversations.chat(id: chat.id)?.session?.reportPaths, [rebuilt])
    }
}
