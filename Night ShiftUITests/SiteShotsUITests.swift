//
//  SiteShotsUITests.swift
//  Night ShiftUITests
//
//  The pictures on bulava.app, taken by the test runner rather than by a person.
//
//  Screen recording is granted to a RESPONSIBLE process, and every path that starts Bulava from a
//  script — a shell, tmux, the engine — hands it a responsible process that has no such grant. The
//  toggle in System Settings says Bulava is allowed and ScreenCaptureKit still answers "the user
//  declined", which is true and useless. UI testing does not go through that door at all: the
//  runner photographs the app it is driving.
//
//  Skipped unless BULAVA_SHOOT_SITE is set, because it writes files and the ordinary suite must
//  not. The frames land in ~/.claude/supervisor/site-shots — the one place outside its container
//  the sandboxed runner may write (see NightShiftUITests.entitlements) — and site/demo/shoot.sh
//  moves them into site/assets.
//

import XCTest

nonisolated final class SiteShotsUITests: XCTestCase {

    private var stateDir: URL?

    override func setUpWithError() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["BULAVA_SHOOT_SITE"] == "1",
                          "set BULAVA_SHOOT_SITE=1 to take the website's pictures")
        continueAfterFailure = false
    }

    /// Where the frames are collected. Inside ~/.claude on purpose: the runner is sandboxed and
    /// this is the exception it already carries.
    private static var outDir: URL {
        let home = URL(fileURLWithPath: realHome, isDirectory: true)
        return home.appendingPathComponent(".claude/supervisor/site-shots")
    }

    private static var realHome: String {
        guard let pw = getpwuid(getuid()) else { return NSHomeDirectory() }
        return String(cString: pw.pointee.pw_dir)
    }

    func testTheRunnerCanPhotographTheApp() throws {
        let out = Self.outDir
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

        let app = BuiltApp.app(for: self)
        let state = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("bulava-shot-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: state, withIntermediateDirectories: true)
        stateDir = state

        app.launchEnvironment["BULAVA_STATE_DIR"] = state.path
        app.launchEnvironment["SUPERVISOR_STATE_DIR"] = state.appendingPathComponent("engine").path
        app.launchArguments += ["-AppleLanguages", "(en)"]
        app.launch()

        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 30), "the app never came up")
        let window = app.windows.firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 30), "no window to photograph")

        let shot = window.screenshot()
        let png = shot.pngRepresentation
        try png.write(to: out.appendingPathComponent("probe.png"))

        // A screenshot that is a few bytes is a screenshot of nothing, and would have been
        // reported as a success by the write above.
        XCTAssertGreaterThan(png.count, 50_000,
                             "the frame is \(png.count) bytes — that is not a window")
        app.terminate()
    }

    override func tearDownWithError() throws {
        if let stateDir { try? FileManager.default.removeItem(at: stateDir) }
    }
}
