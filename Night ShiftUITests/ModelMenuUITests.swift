//
//  ModelMenuUITests.swift
//  Night ShiftUITests
//
//  Choosing which Claude does the work, driven through the real menus.
//
//  Everything about the catalogue can be proved in unit tests except the part that matters here:
//  that what the catalogue says reaches the menu, that choosing from it changes the depths on
//  offer, and that the line naming the next run agrees with both. Three surfaces, none of them
//  exercised by decoding a JSON string.
//
//  The catalogue is a fixture: `CLAUDE_CONFIG_DIR` points the app at a temporary folder holding a
//  cache file in the CLI's own shape, so the menu is the same on every machine and this test says
//  nothing about whichever models the CLI happens to have published today.
//

import XCTest

nonisolated final class ModelMenuUITests: XCTestCase {

    private var root: URL?

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    override func tearDownWithError() throws {
        if let root { try? FileManager.default.removeItem(at: root) }
    }

    // MARK: - The catalogue on disk

    /// Two current models and one previous version, in the shape the CLI writes: the document is
    /// base64 inside the cache file. Opus 4.6 has no `xhigh`, Haiku has no levels at all — the two
    /// facts the menus have to act on.
    private static let document = """
    {"surfaces":{"cc":{"model_selector_config":[{"id":"cc",
      "models":[
        {"id":"claude-opus-5","name":"Opus 5","short_name":"Opus","section":"main",
         "thinking":{"type":"effort"},
         "runtime":{"family":"opus","default_effort":"high",
                    "effort_levels":["low","medium","high","xhigh","max"]},
         "offered_on":["first_party"]},
        {"id":"claude-haiku-4-5-20251001","name":"Haiku 4.5","short_name":"Haiku","section":"main",
         "thinking":{"type":"none"},
         "runtime":{"family":"haiku"},
         "offered_on":["first_party"]},
        {"id":"claude-opus-4-6","name":"Opus 4.6","short_name":"Opus","section":"overflow",
         "thinking":{"type":"effort"},
         "runtime":{"family":"opus","default_effort":"high",
                    "effort_levels":["low","medium","high","max"]},
         "offered_on":["first_party"]}
      ],
      "provider_alias_targets":{
        "opus":{"default":"claude-opus-5"},
        "haiku":{"default":"claude-haiku-4-5-20251001"}
      }}],
      "model_selector_state":[{"id":"cc","model":"claude-opus-5",
        "thinking":{"type":"effort","effort":"high"},
        "thinking_by_model":[{"id":"claude-opus-5","thinking":{"type":"effort","effort":"high"}}]}]}}}
    """

    private func makeFixture() throws -> (state: URL, claudeHome: URL) {
        let fm = FileManager.default
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("bulava-models-ui-\(UUID().uuidString)")
        let state = root.appendingPathComponent("state")
        let claudeHome = root.appendingPathComponent("claude")
        let catalogue = claudeHome.appendingPathComponent("cache/model-catalog")
        for dir in [state, catalogue] {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        let encoded = Data(Self.document.utf8).base64EncodedString()
        try Data(#"{"fetchedAt":2,"documentBytes":"\#(encoded)"}"#.utf8)
            .write(to: catalogue.appendingPathComponent("published-test.json"))
        self.root = root
        return (state, claudeHome)
    }

    private func launch(_ f: (state: URL, claudeHome: URL)) -> XCUIApplication {
        let app = BuiltApp.app(for: self)
        app.launchEnvironment["BULAVA_STATE_DIR"] = f.state.path
        app.launchEnvironment["CLAUDE_CONFIG_DIR"] = f.claudeHome.path
        app.launchArguments += ["-NSWindow Frame Bulava.ContentView-1-AppWindow-1",
                                "80 80 1280 860 0 0 1512 949 "]
        app.launchArguments += ["-AppleLanguages", "(en)"]

        // A copy of Bulava may already be running — his own, or one left by an earlier test — and
        // it answers to the same bundle identifier. XCTest then drives THAT one: a different
        // build, on his real state directory, with none of this fixture's catalogue in it, and
        // every element this test looks for is missing. Terminating first is what makes the
        // window under test the one that was just built.
        app.terminate()
        app.launch()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 60),
                      "the app under test never came to the front")
        return app
    }

    /// Settings, opened by pressing the button that opens it.
    ///
    /// `⌘,` goes wherever the keyboard focus is, which on a machine with another window in front
    /// is not necessarily this app — the shortcut passed here and opened nothing, or opened it in
    /// somebody else's copy.
    private func openSettings(_ app: XCUIApplication) -> XCUIElement {
        let model = app.popUpButtons["claude.model"]
        let button = app.buttons["open.settings"]
        XCTAssertTrue(button.waitForExistence(timeout: 60), "the sidebar has no way into Settings")

        for attempt in 1...3 {
            app.activate()
            if button.waitForExistence(timeout: 5), button.isHittable {
                button.click()
            } else {
                app.typeKey(",", modifierFlags: .command)
            }
            if model.waitForExistence(timeout: 20) { return model }
            attach(app, "settings did not open — attempt \(attempt)")
        }
        let windows = app.windows.allElementsBoundByIndex.map { $0.title }
        XCTFail("Settings never opened. Windows: " + windows.joined(separator: ", "))
        return model
    }

    // MARK: - Helpers

    private func attach(_ app: XCUIApplication, _ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }

    private func openMenu(_ popup: XCUIElement) {
        popup.click()
        // The menu is a window of its own; give it the moment it takes to come up.
        _ = popup.menuItems.firstMatch.waitForExistence(timeout: 5)
    }

    /// Whatever the row currently says. A SwiftUI text with a frame around it can put its words in
    /// `value` rather than `label`, and the identifier lands on more than one element in the tree,
    /// so both are gathered and the one carrying the command line is the answer.
    private static func summaryText(_ app: XCUIApplication) -> String {
        let rows = app.staticTexts.matching(identifier: "next.run").allElementsBoundByIndex
        for row in rows {
            for text in [row.label, (row.value as? String) ?? ""] where text.contains("claude") {
                return text
            }
        }
        return rows.first.map { $0.label } ?? ""
    }

    /// The line naming the next run, read fresh each time.
    ///
    /// SwiftUI rebuilds the row when the choice changes, and a held proxy then points at an
    /// element that is gone — it answers with an empty label rather than the new one.
    private func nextRun(_ app: XCUIApplication, says needle: String,
                         line: UInt = #line) -> String {
        var seen = ""
        let deadline = Date().addingTimeInterval(10)
        repeat {
            seen = Self.summaryText(app)
            if seen.contains(needle) { return seen }
            usleep(200_000)
        } while Date() < deadline
        XCTFail("the next run never said “\(needle)” — it says “\(seen)”", line: line)
        return seen
    }

    // MARK: - The flow

    func testTheMenuOffersFamiliesAndVersionsAndTheDepthsFollowTheChoice() throws {
        let f = try makeFixture()
        let app = launch(f)

        let model = openSettings(app)
        let depth = app.popUpButtons["claude.depth"]
        XCTAssertTrue(depth.waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["next.run"].waitForExistence(timeout: 10))

        // 1. What the menu holds: automatic, the families with the version each resolves to
        //    today, and the versions themselves.
        openMenu(model)
        // Automatic names the model that answers when no `--model` is passed — the CLI's own
        // default, read from the catalogue's selector state.
        for item in ["Automatic · Opus 5", "Opus · Opus 5", "Haiku · Haiku 4.5", "Opus 5", "Opus 4.6"] {
            XCTAssertTrue(app.menuItems[item].exists, "the menu is missing “\(item)”")
        }
        attach(app, "1 · the model menu, families and versions")

        // Automatic first: it says what it resolves to, and still passes no --model.
        app.menuItems["Automatic · Opus 5"].click()
        XCTAssertEqual(model.value as? String, "Automatic · Opus 5")
        let automatic = nextRun(app, says: "--effort")
        XCTAssertFalse(automatic.contains("--model"),
                       "Automatic names a model without pinning one: \(automatic)")
        attach(app, "2 · Automatic, naming what answers")

        openMenu(model)

        // 2. A family: it names the version it runs, and depth is Bulava's to decide per task.
        app.menuItems["Opus · Opus 5"].click()
        XCTAssertEqual(model.value as? String, "Opus · Opus 5")
        XCTAssertEqual(depth.value as? String, "Automatic",
                       "a worker's Automatic is decided per task and must name no level")
        _ = nextRun(app, says: "--model opus")
        attach(app, "3 · the Opus family chosen")

        // 3. A pinned version whose levels are narrower: `xhigh` exists on Opus 5 and not here,
        //    so it must not be on offer.
        openMenu(model)
        app.menuItems["Opus 4.6"].click()
        XCTAssertEqual(model.value as? String, "Opus 4.6")
        _ = nextRun(app, says: "--model claude-opus-4-6")

        openMenu(depth)
        XCTAssertTrue(app.menuItems["High"].exists)
        XCTAssertFalse(app.menuItems["Very high"].exists,
                       "Opus 4.6 does not take xhigh and must not be offered it")
        attach(app, "4 · the depths Opus 4.6 accepts")
        app.menuItems["High"].click()
        XCTAssertEqual(depth.value as? String, "High")
        _ = nextRun(app, says: "--effort high")
        attach(app, "5 · Opus 4.6 at high")

        // 4. A model with no depth at all says so, and the next run carries no --effort.
        openMenu(model)
        app.menuItems["Haiku · Haiku 4.5"].click()
        XCTAssertEqual(model.value as? String, "Haiku · Haiku 4.5")
        XCTAssertEqual(depth.value as? String, "No depth setting")
        XCTAssertFalse(depth.isEnabled, "a depth that does nothing must not be operable")
        let haikuRun = nextRun(app, says: "--model haiku")
        XCTAssertFalse(haikuRun.contains("--effort"), "Haiku takes no --effort: \(haikuRun)")
        attach(app, "6 · Haiku, which has no depth")
    }
}
