//
//  StoppedCardUITests.swift
//  Night ShiftUITests
//
//  The one case this whole change exists for, pressed by a real click.
//
//  He came back to a card offering «What should I decide?» over a run that had asked nothing,
//  and the app carried on without ever telling him what had happened. Everything about that path —
//  the state, the button, the trail it opens, the fact that the answer STAYS in the conversation —
//  was until now proved by calling the model's own methods and rendering views off-screen. That
//  proves the model. It cannot prove that the button he sees is wired to it.
//
//  So this launches the built app against a throwaway state directory, finds the card, clicks the
//  button with the mouse, reads the conversation, quits, launches again and reads it a second time.
//
//  Nothing here touches his real state: `BULAVA_STATE_DIR` points the whole app at a temporary
//  folder, and the fixture's project lives under /tmp.
//

import XCTest

nonisolated final class StoppedCardUITests: XCTestCase {

    // MARK: - Fixture

    /// A product with one task that STOPPED: dispatched, blocked, nothing asked, and a real
    /// worker transcript on disk for the trail to read.
    private struct Fixture {
        var state: URL
        var project: String
        var transcript: URL
        var sessionDir: URL
    }

    private var fixture: Fixture?

    private func makeFixture() throws -> Fixture {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("bulava-ui-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)

        let project = tmp.appendingPathComponent("fixture-project").path
        try FileManager.default.createDirectory(atPath: project, withIntermediateDirectories: true)

        let productID = "11111111-1111-4111-8111-111111111111"
        let projectID = "22222222-2222-4222-8222-222222222222"
        let taskID = "33333333-3333-4333-8333-333333333333"
        let session = "44444444-4444-4444-8444-444444444444"
        let now = ISO8601DateFormatter().string(from: Date().addingTimeInterval(-3600))

        try """
        [{"id":"\(productID)","name":"Fixture Product","summary":"","resources":[],
          "pinned":false,"addedAt":"\(now)","brief":"","decisions":[]}]
        """.write(to: tmp.appendingPathComponent("products.json"), atomically: true, encoding: .utf8)

        try """
        [{"id":"\(projectID)","name":"fixture-project","path":"\(project)","kind":"unknown",
          "stacks":[],"pinned":false,"addedAt":"\(now)","notes":""}]
        """.write(to: tmp.appendingPathComponent("projects.json"), atomically: true, encoding: .utf8)

        // Blocked, dispatched, and NOTHING was asked: no pending question, no externalBlocker.
        // That is precisely the shape that used to render "What needs deciding?".
        try """
        [{"id":"\(taskID)","title":"Wire the export button","detail":"",
          "projectID":"\(projectID)","projectPath":"\(project)","productID":"\(productID)",
          "type":"feature","priority":2,"state":"blocked",
          "createdAt":"\(now)","updatedAt":"\(now)","dispatchedAt":"\(now)",
          "boundSessionID":"\(session)","boundRunID":"run-fixture"}]
        """.write(to: tmp.appendingPathComponent("backlog.json"), atomically: true, encoding: .utf8)

        // The card is anchored in the conversation, the way every task is: the entry is a pointer
        // and the live task is the truth. Without it the product opens on an empty thread.
        try """
        [{"id":"55555555-5555-4555-8555-555555555555","productID":"\(productID)",
          "kind":"task","at":"\(now)","text":"Wire the export button","blocks":[],
          "tone":"neutral","taskID":"\(taskID)","attachments":[]}]
        """.write(to: tmp.appendingPathComponent("conversations.json"), atomically: true, encoding: .utf8)

        // The worker's own transcript, where Claude Code keeps it for that project path.
        //
        // The REAL home, not `homeDirectoryForCurrentUser`: the test runner is sandboxed and that
        // API answers with its container, so the fixture was landing in
        // ~/Library/Containers/…xctrunner/Data/.claude while the app — which is not sandboxed —
        // read the real one and reported, correctly, that it had no session log for this run.
        let sessionDir = URL(fileURLWithPath: Self.realHome, isDirectory: true)
            .appendingPathComponent(".claude/projects")
            .appendingPathComponent(transcriptDirName(for: project))
        try FileManager.default.createDirectory(at: sessionDir, withIntermediateDirectories: true)
        let transcript = sessionDir.appendingPathComponent(session + ".jsonl")
        try Self.workerTranscript.write(to: transcript, atomically: true, encoding: .utf8)

        return Fixture(state: tmp, project: project, transcript: transcript, sessionDir: sessionDir)
    }

    /// The user's home as the kernel knows it, unaffected by the runner's container redirection.
    static var realHome: String {
        guard let pw = getpwuid(getuid()) else { return NSHomeDirectory() }
        return String(cString: pw.pointee.pw_dir)
    }

    /// Claude Code's own naming for a path's session folder. Kept identical to
    /// `WorkerActivity.transcriptDirName` — a UI test bundle cannot link the app's module, so this
    /// is a copy, and a wrong copy would silently produce a fixture the app never finds.
    private func transcriptDirName(for path: String) -> String {
        String(path.map { ch in
            (ch.isLetter && ch.isASCII) || ch.isNumber || ch == "-" ? ch : "-"
        })
    }

    private static let workerTranscript: String = {
        let steps = [("Read", "ExportButton.swift"), ("Grep", "exportTapped"), ("Edit", "ExportButton.swift")]
        var lines: [String] = []
        for (i, step) in steps.enumerated() {
            let id = "toolu_ui_\(i)"
            lines.append(#"{"type":"assistant","message":{"id":"m\#(i)","content":[{"type":"tool_use","id":"\#(id)","name":"\#(step.0)","input":{"file_path":"/x/\#(step.1)"}}]}}"#)
            lines.append(#"{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"\#(id)","is_error":false}]}}"#)
        }
        lines.append(#"{"type":"assistant","message":{"id":"m-said","content":[{"type":"text","text":"I could not find where the export sheet is presented."}]}}"#)
        return lines.joined(separator: "\n") + "\n"
    }()

    // MARK: - Lifecycle

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    private func setUpFixture() throws {
        fixture = try makeFixture()
    }

    override func tearDownWithError() throws {
        if let f = fixture {
            try? FileManager.default.removeItem(at: f.state)
            try? FileManager.default.removeItem(at: f.sessionDir)
        }
    }

    private func launch(_ f: Fixture) -> XCUIApplication {
        let app = BuiltApp.app(for: self)
        app.launchEnvironment["BULAVA_STATE_DIR"] = f.state.path
        // Put the window on the main display, at a known place.
        //
        // Window frames are restored from the user's own defaults, which are shared with his real
        // copy of the app — and his window lives on a second display, above the main one. The card
        // and its buttons were all there in the accessibility tree, at negative screen coordinates,
        // and every synthesized click went into empty space on the wrong screen. The launch-argument
        // domain outranks the saved value without touching what he has saved.
        app.launchArguments += ["-NSWindow Frame Bulava.ContentView-1-AppWindow-1",
                                "80 80 1200 800 0 0 1512 949 "]
        // And launch IN a language, any language.
        //
        // Bulava relaunches itself once at startup when its saved language is not the one it was
        // launched in — the only way macOS honours the choice. Under a UI test that relaunch kills
        // the process XCUITest is attached to, and the run hangs on "Launch" forever. Naming a
        // language here is what stops it; the assertions below read identifiers, not words, so
        // which language it is does not matter.
        app.launchArguments += ["-AppleLanguages", "(en)"]
        app.launch()
        // Frontmost, and on this screen. The window frame is restored from the user's own defaults,
        // which on a two-display Mac can put it where a synthetic click never lands.
        app.activate()
        return app
    }

    // MARK: - The flow

    func testTheStoppedCardOffersItsTrailAndKeepsItAfterARestart() throws {
        try setUpFixture()
        let f = try XCTUnwrap(fixture)
        var app = launch(f)

        // The product, then its card. The product's name is a fixture string, not UI copy, so it
        // is the same in every language; everything after this is found by role.
        let product = app.buttons.containing(NSPredicate(format: "label CONTAINS %@", "Fixture Product")).firstMatch
        XCTAssertTrue(product.waitForExistence(timeout: 20), "the fixture product never appeared")
        product.click()

        let card = app.staticTexts["Wire the export button"].firstMatch
        XCTAssertTrue(card.waitForExistence(timeout: 15),
                      "the stopped task's card never appeared:\n\(app.debugDescription)")

        // The button he actually sees. A run that asked nothing must not offer to answer it.
        let trailButton = app.buttons["task-action-trail"].firstMatch
        XCTAssertTrue(trailButton.waitForExistence(timeout: 10),
                      "the card did not offer the trail:\n\(app.debugDescription)")
        XCTAssertFalse(app.buttons["task-action-decide"].exists,
                       "nothing was asked, yet the card still offered to decide it")

        // Pressed with the mouse, through the real view.
        trailButton.click()

        let head = app.staticTexts["block-trail-head"].firstMatch
        let saved = (try? String(contentsOf: f.state.appendingPathComponent("conversations.json"),
                                 encoding: .utf8)) ?? "<no conversations.json>"
        XCTAssertTrue(head.waitForExistence(timeout: 20),
                      "clicking the button produced no trail in the conversation.\nSTATE: \(saved.prefix(2000))\n\(app.debugDescription)")
        XCTAssertTrue(app.descendants(matching: .any)
                        .containing(NSPredicate(format: "label CONTAINS[c] %@ OR value CONTAINS[c] %@",
                                                "ExportButton.swift", "ExportButton.swift")).firstMatch.exists,
                      "the trail arrived without the steps the worker actually took")

        // It is part of the record, not a sheet: quit, come back, still there.
        app.terminate()
        app = launch(f)
        let productAgain = app.buttons.containing(NSPredicate(format: "label CONTAINS %@", "Fixture Product")).firstMatch
        XCTAssertTrue(productAgain.waitForExistence(timeout: 20))
        productAgain.click()
        XCTAssertTrue(app.staticTexts["block-trail-head"].firstMatch.waitForExistence(timeout: 15),
                      "the trail did not survive a restart — it was never saved with the conversation")
        app.terminate()
    }
}
