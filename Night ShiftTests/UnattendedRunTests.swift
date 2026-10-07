import XCTest
import SwiftUI
import AppKit
@testable import Bulava

/// An automation's run has nobody at the computer, and everything that would have asked him — a
/// dialog in the pane, a browser that needs his Chrome — is decided before it can stall the night.
nonisolated final class UnattendedRunTests: XCTestCase {

    /// The engine reads SUPERVISOR_UNATTENDED from the run's choices: its permission gate answers
    /// for the run, and the run gets a browser of its own.
    @MainActor
    func testAnAutomationsSendsSayNobodyIsThere() {
        let m = AppModel()
        XCTAssertEqual(m.engineChoices(run: RunChoices(), unattended: true)["SUPERVISOR_UNATTENDED"], "1")
        XCTAssertNil(m.engineChoices(run: RunChoices())["SUPERVISOR_UNATTENDED"],
                     "a chat he is in keeps Claude Code's own dialogs")
    }

    /// The readiness screen read ~/.claude/mcp.json, which nothing writes, and said the browser was
    /// not wired up on a Mac where it had been for months.
    func testTheBrowserBridgeIsFoundWhereClaudeCodeKeepsIt() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("mcp-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let config = dir.appendingPathComponent(".claude.json")

        try JSONSerialization.data(withJSONObject: ["mcpServers": ["chrome-devtools": [
            "command": "npx", "args": ["-y", "chrome-devtools-mcp@latest", "--wsEndpoint", "ws://127.0.0.1:9222/devtools/browser"]]]])
            .write(to: config)
        XCTAssertTrue(PreflightRunner.chromeDevtoolsConfigured(claudeConfig: config))

        try JSONSerialization.data(withJSONObject: ["mcpServers": ["web": [
            "command": "npx", "args": ["-y", "chrome-devtools-mcp@1.10.1"]]]]).write(to: config)
        XCTAssertTrue(PreflightRunner.chromeDevtoolsConfigured(claudeConfig: config), "found by what it runs, whatever it is called")

        try JSONSerialization.data(withJSONObject: ["mcpServers": ["atlassian": ["command": "x"]]]).write(to: config)
        XCTAssertFalse(PreflightRunner.chromeDevtoolsConfigured(claudeConfig: config))
        XCTAssertFalse(PreflightRunner.chromeDevtoolsConfigured(claudeConfig: dir.appendingPathComponent("missing.json")))
    }

    /// What an automation will need is known from what it is set to do — so it can be asked for
    /// while he is making it, not the first time a run touches it at night.
    func testWhatAnAutomationNeedsIsKnownWhenItIsMade() {
        let meeting = AutomationTrigger.event(AutomationEvent(kind: .meetingEnded(titleContains: "")))
        XCTAssertEqual(AutomationNeeds.needs(trigger: meeting, brief: "Summarise the call"), [.calendar])
        let mail = AutomationTrigger.event(AutomationEvent(kind: .mail(from: "bank", subject: "")))
        XCTAssertEqual(AutomationNeeds.needs(trigger: mail, brief: "x"), [.mail])

        let downloads = (NSHomeDirectory() as NSString).appendingPathComponent("Downloads/Invoices")
        let guarded = AutomationTrigger.event(AutomationEvent(kind: .folder(path: downloads)))
        XCTAssertEqual(AutomationNeeds.needs(trigger: guarded, brief: "x"), [.folder(downloads)])
        let project = AutomationTrigger.event(AutomationEvent(kind: .folder(path: "/Users/x/Developer/app/inbox")))
        XCTAssertEqual(AutomationNeeds.needs(trigger: project, brief: "x"), [], "a folder macOS does not guard needs nothing")

        let weekly = AutomationTrigger.schedule(AutomationSchedule(cadence: .weekly(days: [6]), hour: 3, minute: 0))
        XCTAssertEqual(AutomationNeeds.needs(trigger: weekly, brief: "Перевір, що сайт відкривається, і зроби скріншот головної"),
                       [.browser, .screen], "what the brief asks for is offered")
        XCTAssertEqual(AutomationNeeds.needs(trigger: weekly, brief: "Сходи на репозиторій бекенду"), [])
        XCTAssertTrue(AutomationNeed.calendar.comesFromTrigger && !AutomationNeed.browser.comesFromTrigger)
    }

    func testOnlyTheFoldersMacOSGuardsAreAskedAbout() {
        let home = "/Users/someone"
        XCTAssertTrue(AutomationNeeds.isGuarded("/Users/someone/Desktop", home: home))
        XCTAssertTrue(AutomationNeeds.isGuarded("/Users/someone/Documents/Contracts/", home: home))
        XCTAssertTrue(AutomationNeeds.isGuarded("/Users/someone/Library/Mobile Documents/com~apple~CloudDocs/x", home: home))
        XCTAssertTrue(AutomationNeeds.isGuarded("/Volumes/Backup/In", home: home))
        XCTAssertFalse(AutomationNeeds.isGuarded("/Users/someone/DesktopApps", home: home), "a name that only starts the same")
        XCTAssertFalse(AutomationNeeds.isGuarded("/Users/someone/Developer/app", home: home))
        XCTAssertFalse(AutomationNeeds.isGuarded("", home: home))
    }

    /// Mail's Apple Events answer, read without asking: only "never asked" may be asked, and only by day.
    func testMailsAnswerIsRead() {
        XCTAssertEqual(AutomationNeeds.mailState(OSStatus(noErr)), .ready)
        XCTAssertEqual(AutomationNeeds.mailState(-1744), .askNow, "errAEEventWouldRequireUserConsent")
        XCTAssertEqual(AutomationNeeds.mailState(-1743), .blocked, "errAEEventNotPermitted")
        XCTAssertEqual(AutomationNeeds.mailState(OSStatus(procNotFound)), .atRunTime, "Mail is closed")
        XCTAssertTrue(NeedState.askNow.stopsTheTrigger && NeedState.blocked.stopsTheTrigger)
        XCTAssertFalse(NeedState.atRunTime.stopsTheTrigger || NeedState.ready.stopsTheTrigger)
    }

    /// Laid out and drawn, in both appearances: what it needs, where each stands, and the button.
    @MainActor
    func testTheNeedsSectionRenders() throws {
        let trigger = AutomationTrigger.event(AutomationEvent(kind: .meetingEnded(titleContains: "")))
        let brief = "Після дзвінка перевір сайт і зроби скріншот"
        for scheme in [ColorScheme.light, .dark] {
            let view = AutomationNeedsSection(trigger: trigger, brief: brief, blocking: .constant(true),
                                              known: ["calendar": .askNow, "browser": .ready, "screen": .blocked])
                .frame(width: 600)
                .padding(18)
                .background(Palette.content)
                .environment(\.colorScheme, scheme)
            let renderer = ImageRenderer(content: view)
            renderer.scale = 2
            let image = try XCTUnwrap(renderer.nsImage, "the section draws")
            XCTAssertGreaterThan(image.size.height, 150, "four rows, not an empty box")
            if let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
               let png = rep.representation(using: .png, properties: [:]) {
                try png.write(to: FileManager.default.temporaryDirectory
                    .appendingPathComponent("bulava-needs-section-\(scheme == .dark ? "dark" : "light").png"))
            }
        }
    }

    /// A dialog on screen is something the snapshot knows about, so the pane is read for it even
    /// when the worker's status line has not said "waiting".
    @MainActor
    func testADialogOnScreenIsInTheSnapshot() async throws {
        let state = FileManager.default.temporaryDirectory.appendingPathComponent("perm-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: state) }
        let project = state.appendingPathComponent("project")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let paths = SupervisorPaths(stateDir: state)
        let dir = paths.instanceDir(slug: Slug.forPath(project.path))
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try project.path.write(to: dir.appendingPathComponent("project"), atomically: true, encoding: .utf8)
        try "night-none".write(to: dir.appendingPathComponent("session"), atomically: true, encoding: .utf8)
        try #"{"at": 1790000000, "message": "Claude needs your permission to use Bash"}"#
            .write(to: dir.appendingPathComponent("permission-wait.json"), atomically: true, encoding: .utf8)
        let client = SupervisorClient(paths: paths)
        let found = await client.readInstances().first { $0.projectPath == project.path }
        XCTAssertEqual(found?.permissionWaitSince, Date(timeIntervalSince1970: 1_790_000_000))
    }
}
