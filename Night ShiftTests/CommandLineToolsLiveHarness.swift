import XCTest
import AppKit
import SwiftUI
@testable import Bulava

/// A Mac without Apple's command line tools, in real windows of this build: the readiness rows,
/// the engine's refusal with its card, and what the "Install command line tools" button does —
/// for as long as it takes to look at each and take a frame.
///
/// Not a test that runs with the suite: it is skipped unless `BULAVA_CLT_HARNESS_DIR` names a
/// folder (give it to xcodebuild as `TEST_RUNNER_BULAVA_CLT_HARNESS_DIR`). Everything happens on an
/// isolated state directory, and this process is shown the Mac from the 1.13 report: DEVELOPER_DIR
/// names a folder that is not there, which is what `xcode-select -p` then answers, so /usr/bin/git
/// and /usr/bin/python3 have nothing behind them. The engine is installed into a temporary folder
/// only, and nothing else on the Mac is touched — except that pressing the button asks macOS for
/// its installer, which is the point of pressing it.
///
/// At each step it writes `<step>.ready` (this process's pid) and `<step>.txt` (what it saw) into
/// that folder, and waits for `<step>.done`:
///   readiness    the tool rows, from the check readiness runs
///   refused      the engine install refused by the real installer, and its card
///   pressed      the button's action: `xcode-select --install`, and what came of it
///   asked-again  readiness asked again afterwards, as coming back to Bulava asks it
///   tools-back   DEVELOPER_DIR as it was, and readiness asked again
nonisolated final class CommandLineToolsLiveHarness: XCTestCase {

    @MainActor
    func testAMacWithoutTheToolsByHand() async throws {
        guard let raw = ProcessInfo.processInfo.environment["BULAVA_CLT_HARNESS_DIR"], !raw.isEmpty else {
            throw XCTSkip("Set BULAVA_CLT_HARNESS_DIR to walk through it by hand.")
        }
        let dir = URL(fileURLWithPath: raw, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let state = dir.appendingPathComponent("state")
        try? FileManager.default.removeItem(at: state)
        try FileManager.default.createDirectory(at: state.appendingPathComponent("supervisor/instances"),
                                                withIntermediateDirectories: true)
        let developerDir = ProcessInfo.processInfo.environment["DEVELOPER_DIR"]
        setenv("BULAVA_STATE_DIR", state.path, 1)
        setenv("SUPERVISOR_STATE_DIR", state.appendingPathComponent("supervisor").path, 1)
        setenv("DEVELOPER_DIR", state.appendingPathComponent("no-developer-tools").path, 1)
        defer {
            unsetenv("BULAVA_STATE_DIR")
            unsetenv("SUPERVISOR_STATE_DIR")
            if let developerDir { setenv("DEVELOPER_DIR", developerDir, 1) } else { unsetenv("DEVELOPER_DIR") }
        }

        let model = AppModel()
        // Readiness counts as just checked, so the screen's own `.task` does not run the whole check
        // — two of its probes are paid calls — over the rows this walk-through draws.
        model.readinessCheckedAt = Date()

        let window = NSWindow(contentRect: NSRect(x: 160, y: 140, width: 780, height: 660),
                              styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = "Bulava"
        window.contentView = NSHostingView(rootView:
            PreflightView()
                .overlay(alignment: .topTrailing) { ToastStackView().zIndex(11) }
                .environment(model))
        // The only window this process shows while it lasts: a frame of "this process's window"
        // is then this one, and not the host's own main window.
        let others = NSApp.windows.filter { $0 !== window && $0.isVisible }
        others.forEach { $0.orderOut(nil) }
        window.orderFrontRegardless()
        defer {
            window.orderOut(nil)
            others.forEach { $0.orderFrontRegardless() }
        }

        // 1. What readiness says about the tools.
        try await ask(model)
        let git = try XCTUnwrap(model.readiness.checks.first { $0.id == "tool-git" })
        XCTAssertEqual(git.fix, .installCommandLineTools, "git here is /usr/bin/git with no developer directory")
        try await step("readiness", in: dir, saw: rows(model))

        // 2. The engine install, refused by the real installer before it copies anything.
        let bundled = try fixtureEngine(in: state)
        let outcome = await EngineInstaller.install(
            from: bundled, to: state.appendingPathComponent("installed-engine"),
            pythonNeedsCommandLineTools: { await DeveloperTools.needsCommandLineTools("python3", at: "/usr/bin/python3") })
        XCTAssertTrue(outcome.needsCommandLineTools)
        model.toast = model.engineInstallToast(for: outcome)
        try await step("refused", in: dir, saw: cards(model))

        // 3. The button. Its action is this call, on the row and on the card alike.
        let before = model.toasts.count
        model.installCommandLineTools()
        for _ in 0..<40 where model.toasts.count == before { try await Task.sleep(for: .milliseconds(250)) }
        let answer = model.toasts.count > before
            ? "Bulava's card: " + cards(model)
            : "no card: xcode-select said it requested the install, so macOS's own dialog is the answer"
        try await step("pressed", in: dir, saw: answer)

        // 4. Asked again after the dialog went away — dismissed, cancelled, or never there — with
        //    the cards read and closed, as a person would, so the row is in plain view.
        model.toasts.removeAll()
        try await ask(model)
        try await step("asked-again", in: dir, saw: rows(model))

        // 5. The tools back, and asked again.
        if let developerDir { setenv("DEVELOPER_DIR", developerDir, 1) } else { unsetenv("DEVELOPER_DIR") }
        try await ask(model)
        let gitNow = try XCTUnwrap(model.readiness.checks.first { $0.id == "tool-git" })
        XCTAssertEqual(gitNow.status, .ready)
        try await step("tools-back", in: dir, saw: rows(model))
    }

    // MARK: -

    /// Readiness's own tool checks — the ones `run` asks — drawn by the real screen.
    @MainActor
    private func ask(_ model: AppModel) async throws {
        model.readiness.overrideChecksForTesting(await model.readiness.toolChecks())
        try await Task.sleep(for: .milliseconds(400))
    }

    @MainActor
    private func rows(_ model: AppModel) -> String {
        model.readiness.checks.map { check in
            "\(check.id): \(check.status) · \(check.evidence ?? "-") · fix \(check.fix.map { "\($0)" } ?? "none")"
        }.joined(separator: "\n")
    }

    @MainActor
    private func cards(_ model: AppModel) -> String {
        model.toasts.map { "[\($0.title ?? "")] \($0.text) · actions: \($0.actions.map(\.title))" }
            .joined(separator: "\n")
    }

    @MainActor
    private func step(_ name: String, in dir: URL, saw: String) async throws {
        try saw.write(to: dir.appendingPathComponent("\(name).txt"), atomically: true, encoding: .utf8)
        try "\(getpid())\n".write(to: dir.appendingPathComponent("\(name).ready"), atomically: true, encoding: .utf8)
        let done = dir.appendingPathComponent("\(name).done")
        let end = Date().addingTimeInterval(900)
        while !FileManager.default.fileExists(atPath: done.path) {
            guard Date() < end else { return XCTFail("nobody finished the step «\(name)» within 15 minutes") }
            try await Task.sleep(for: .milliseconds(250))
        }
    }

    private func fixtureEngine(in state: URL) throws -> URL {
        let dir = state.appendingPathComponent("bundled-engine")
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("bin"), withIntermediateDirectories: true)
        try "#!/bin/bash\nexit 0\n".write(to: dir.appendingPathComponent("install.sh"), atomically: true, encoding: .utf8)
        try "#!/bin/bash\n".write(to: dir.appendingPathComponent("bin/verify.sh"), atomically: true, encoding: .utf8)
        try "202610149999\n".write(to: dir.appendingPathComponent(".engine-version"), atomically: true, encoding: .utf8)
        return dir
    }
}
