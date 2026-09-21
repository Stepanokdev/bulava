//
//  TerminalDispatchReportUITests.swift
//  Night ShiftUITests
//
//  The whole path he actually walked, end to end: a job dispatched from the terminal finishes, the
//  app adopts it into a card, he presses «Open report» — and the report opens.
//
//  Every station on that path has failed him in turn. The run finished and produced no card,
//  because the app told work apart by a run nonce a reused session cannot change. Then the card
//  appeared and the button opened nothing, because the instruction that asks a worker for a report
//  lived in the app and a terminal dispatch never got it. Then the report existed and the card
//  looked for it under a key derived from its own id, which the worker had never been told.
//
//  Each of those was fixed and unit-tested on its own, and the director still had a button that
//  did nothing — because nothing had ever pressed it. This does.
//

import XCTest

nonisolated final class TerminalDispatchReportUITests: XCTestCase {

    private var state: URL!          // the app's own state
    private var supervisor: URL!     // the engine's state: instances, reports
    private var project: URL!

    private let dispatchID = "D-UITEST-0001"
    private let reportKey = "feed1234"

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    override func tearDownWithError() throws {
        for url in [state, supervisor, project].compactMap({ $0 }) {
            try? FileManager.default.removeItem(at: url)
        }
    }

    /// Everything the engine leaves behind for a finished terminal dispatch, and nothing else:
    /// no task in the app's backlog, no conversation, no card. Exactly the state his machine was
    /// in when he asked where the report was.
    private func seed() throws {
        let fm = FileManager.default
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("bulava-e2e-\(UUID().uuidString)")
        state = root.appendingPathComponent("app-state")
        supervisor = root.appendingPathComponent("supervisor")
        project = root.appendingPathComponent("Map Alerts")
        for dir in [state!, supervisor!, project!] {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }

        // The instance, finished.
        let slug = slugForPath(project.path)
        let idir = supervisor.appendingPathComponent("instances/\(slug)")
        try fm.createDirectory(at: idir.appendingPathComponent("dispatches"),
                               withIntermediateDirectories: true)
        try project.path.write(to: idir.appendingPathComponent("project"), atomically: true, encoding: .utf8)
        try "feat/checks".write(to: idir.appendingPathComponent("branch"), atomically: true, encoding: .utf8)
        try "RUN-OLD".write(to: idir.appendingPathComponent("run-id"), atomically: true, encoding: .utf8)
        try "passed".write(to: idir.appendingPathComponent("done"), atomically: true, encoding: .utf8)

        let record = """
        {"id":"\(dispatchID)","at":"\(ISO8601DateFormatter().string(from: Date().addingTimeInterval(-1800)))",
         "task":"Перевір запит на оцінку і канали перед публікацією","report_key":"\(reportKey)"}
        """
        try record.write(to: idir.appendingPathComponent("dispatch.json"), atomically: true, encoding: .utf8)
        try record.write(to: idir.appendingPathComponent("dispatches/\(dispatchID).json"),
                         atomically: true, encoding: .utf8)
        try "passed".write(to: idir.appendingPathComponent("dispatches/\(dispatchID).done"),
                           atomically: true, encoding: .utf8)

        // The report the worker was told to write, where it was told to write it.
        let reportDir = supervisor.appendingPathComponent("reports/\(reportKey)")
        try fm.createDirectory(at: reportDir, withIntermediateDirectories: true)
        try """
        {"format":"notes","language":"Ukrainian",
         "title":"Канали і запит на оцінку",
         "summary":"Обидва пункти були зламані, обидва полагоджені.",
         "body":"## Канали\\n\\nВимкнений канал далі опитувався.\\n\\n## Рейтинг\\n\\nНа iPad не викликався взагалі."}
        """.write(to: reportDir.appendingPathComponent("report.json"), atomically: true, encoding: .utf8)
    }

    /// The engine's own slug, computed by the engine's own pipeline.
    ///
    /// Reimplementing it in Swift is how a fixture ends up in a directory the app never reads —
    /// the hash is `shasum` (SHA-1) over the CANONICAL path, and a temporary directory is
    /// /var/folders to Foundation and /private/var/folders to the kernel. One shell call keeps the
    /// two definitions from drifting.
    private func slugForPath(_ path: String) -> String {
        let script = """
        p="$(cd "$1" 2>/dev/null && pwd -P || printf %s "$1")"
        base="$(basename "$p" | tr -c 'A-Za-z0-9' '-' | sed 's/--*/-/g; s/^-//; s/-$//')"
        printf '%s-%s' "$base" "$(printf '%s' "$p" | shasum | cut -c1-12)"
        """
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        task.arguments = ["-c", script, "sh", path]
        let out = Pipe()
        task.standardOutput = out
        try? task.run()
        let data = (try? out.fileHandleForReading.readToEnd()) ?? Data()
        task.waitUntilExit()
        return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    // MARK: - The path

    func testATerminalDispatchBecomesACardWhoseReportOpens() throws {
        try seed()

        let app = BuiltApp.app(for: self)
        app.launchEnvironment["BULAVA_STATE_DIR"] = state.path
        app.launchEnvironment["SUPERVISOR_STATE_DIR"] = supervisor.path
        app.launchArguments += ["-NSWindow Frame Bulava.ContentView-1-AppWindow-1",
                                "80 80 1200 800 0 0 1512 949 ",
                                "-AppleLanguages", "(uk)"]
        app.launch()
        app.activate()

        // The card, adopted from a journal entry with no task behind it.
        let card = app.staticTexts["Перевір запит на оцінку і канали перед публікацією"].firstMatch
        XCTAssertTrue(card.waitForExistence(timeout: 25),
                      "a finished terminal dispatch produced no card:\n\(app.debugDescription)")

        // The button, pressed with the mouse.
        let open = app.buttons["task-action-report"].firstMatch
        XCTAssertTrue(open.waitForExistence(timeout: 10),
                      "the card does not offer the report:\n\(app.debugDescription)")
        open.click()

        // And the document itself — the thing that used to open nothing at all.
        let title = app.staticTexts["report-title"].firstMatch
        XCTAssertTrue(title.waitForExistence(timeout: 20),
                      "«Відкрити звіт» opened nothing:\n\(app.debugDescription)")

        // Rendered from the manifest the worker was told to write, not from a placeholder.
        let html = supervisor.appendingPathComponent("reports/\(reportKey)/report.html")
        XCTAssertTrue(FileManager.default.fileExists(atPath: html.path),
                      "no document was rendered into the report directory")
        let text = (try? String(contentsOf: html, encoding: .utf8)) ?? ""
        XCTAssertTrue(text.contains("Канали і запит на оцінку"), "the rendered page is not this report")
        XCTAssertTrue(text.contains("iPad"), "the report's own findings are missing from the page")

        app.terminate()
    }
}
