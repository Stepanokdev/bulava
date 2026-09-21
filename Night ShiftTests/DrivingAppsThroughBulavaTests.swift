import XCTest
import AppKit
@testable import Bulava

/// One grant, given to Bulava once, instead of one per project.
///
/// A worker runs under a tmux daemon whose code identity changes with every rebuild, so macOS can
/// never keep an Accessibility grant for it — and granting Accessibility to the `node` or terminal
/// binary it runs through hands those rights to everything else that uses the same binary. So the
/// worker asks Bulava, which is signed and stable, to click for it. These pin down the parts that
/// can be tested without a second app on screen: the refusals, the key names, and the refs.
nonisolated final class DrivingAppsThroughBulavaTests: XCTestCase {

    // MARK: - What Bulava will not drive

    /// Not security theatre and not a complete defence — macOS itself ignores synthetic events on
    /// its own consent dialogs. It is a line about intent: these are the windows where a click
    /// grants a permission, reveals a secret or runs a command.
    func testTheSurfacesThatGrantPermissionsAreRefused() {
        for bundle in ["com.apple.systempreferences",
                       "com.apple.SystemPreferences",
                       "com.apple.keychainaccess",
                       "com.apple.Terminal",
                       "com.googlecode.iterm2",
                       "com.apple.SecurityAgent",
                       "com.1password.1password"] {
            XCTAssertTrue(UIControl.isRefused(bundleIdentifier: bundle), bundle)
        }
    }

    func testOrdinaryAppsAreDrivable() {
        for bundle in ["stepanok.com.Night-Shift", "com.apple.Safari", "com.google.Chrome",
                       "com.example.some-client-app", "com.apple.dt.Xcode"] {
            XCTAssertFalse(UIControl.isRefused(bundleIdentifier: bundle), bundle)
        }
    }

    /// Matched on bundle identifier, because a window title is whatever the app feels like saying
    /// — an app called "System Settings" is not the same thing as the app that IS System Settings.
    func testTheRefusalIsByIdentityNotByName() {
        XCTAssertFalse(UIControl.isRefused(bundleIdentifier: "com.impostor.System-Settings"))
        XCTAssertTrue(UIControl.isRefused(bundleIdentifier: "com.apple.systempreferences"))
    }

    @MainActor
    func testARefusalSaysWhyAndWhatToDoInstead() throws {
        // Bulava itself is drivable, so a refusal has to come from the list and nothing else.
        guard let terminal = NSRunningApplication
            .runningApplications(withBundleIdentifier: "com.apple.Terminal").first else {
            throw XCTSkip("Terminal is not running on this machine")
        }
        let refusal = UIControl.refusalForTarget(terminal)
        XCTAssertNotNil(refusal)
        XCTAssertTrue(refusal?.contains("yourself") == true, refusal ?? "")
    }

    // MARK: - Refs

    /// A ref is a PATH — "window 0, child 4, child 1" — resolved again at the moment of the
    /// action. It is not a promise that the element is still there, and that is the point: if the
    /// layout moved, resolving fails instead of clicking whatever now sits at those coordinates.
    func testAWellFormedRefLooksLikeAPath() {
        for ref in ["w0", "w0.c1", "w1.c0.c12.c3"] {
            XCTAssertTrue(UIControl.isWellFormed(ref: ref), ref)
        }
    }

    func testATypoIsRefusedBeforeAnythingIsClicked() {
        for ref in ["", "c1", "w", "wx.c1", "w0.c", "w0.x1", "w0.c1.", "button", "w0 c1",
                    "w0.c-1"] {
            XCTAssertFalse(UIControl.isWellFormed(ref: ref), "‘\(ref)’ should not pass")
        }
    }

    func testAPointIsTwoNumbersOrNothing() {
        XCTAssertEqual(UIControl.point(from: "120,340"), CGPoint(x: 120, y: 340))
        XCTAssertEqual(UIControl.point(from: " 120 , 340 "), CGPoint(x: 120, y: 340))
        for bad in ["", "120", "120,340,5", "a,b", "120;340"] {
            XCTAssertNil(UIControl.point(from: bad), bad)
        }
    }

    // MARK: - Keys

    func testTheKeysAPersonWouldNameAreUnderstood() {
        XCTAssertEqual(Keystroke("return")?.code, 36)
        XCTAssertEqual(Keystroke("enter")?.code, 36)
        XCTAssertEqual(Keystroke("escape")?.code, 53)
        XCTAssertEqual(Keystroke("esc")?.code, 53)
        XCTAssertEqual(Keystroke("tab")?.code, 48)
        XCTAssertEqual(Keystroke("space")?.code, 49)
        XCTAssertEqual(Keystroke("up")?.code, 126)
    }

    func testModifiersCombine() {
        guard let save = Keystroke("cmd+s") else { return XCTFail("cmd+s not understood") }
        XCTAssertEqual(save.code, 1)
        XCTAssertTrue(save.flags.contains(.maskCommand))

        guard let deep = Keystroke("cmd+shift+k") else { return XCTFail("cmd+shift+k") }
        XCTAssertTrue(deep.flags.contains(.maskCommand))
        XCTAssertTrue(deep.flags.contains(.maskShift))
    }

    func testCaseAndSeparatorDoNotMatter() {
        XCTAssertEqual(Keystroke("CMD+S")?.code, Keystroke("cmd+s")?.code)
        XCTAssertEqual(Keystroke("cmd-s")?.flags, Keystroke("cmd+s")?.flags)
    }

    /// A key nobody can name must fail rather than press something arbitrary.
    func testAnUnknownKeyIsRefused() {
        for keys in ["", "banana", "cmd+banana", "hyper+s", "cmd+"] {
            XCTAssertNil(Keystroke(keys), keys)
        }
    }

    /// Found by using it: `cmd+[` is Back in this app and in half the others on the platform, and
    /// the table did not have a bracket at all.
    func testBracketsAndPunctuationAreThere() {
        XCTAssertEqual(Keystroke("[")?.code, 33)
        XCTAssertEqual(Keystroke("]")?.code, 30)
        XCTAssertEqual(Keystroke("leftbracket")?.code, Keystroke("[")?.code)
        XCTAssertEqual(Keystroke("rightbracket")?.code, Keystroke("]")?.code)

        guard let back = Keystroke("cmd+[") else { return XCTFail("cmd+[ not understood") }
        XCTAssertEqual(back.code, 33)
        XCTAssertTrue(back.flags.contains(.maskCommand))
    }

    /// The parser splits on `+` and `-`, so a literal minus cannot be written as one — it has a
    /// name, and the name has to work.
    func testAKeyTheSeparatorSwallowsHasAName() {
        XCTAssertNotNil(Keystroke("cmd+minus"))
        XCTAssertNotNil(Keystroke("cmd+equal"))
        XCTAssertNil(Keystroke("cmd+-"), "an empty last part is not a key")
    }

    // MARK: - The worker's side of the protocol

    /// The whole point of the arrangement: the script the worker runs contains no Accessibility
    /// call at all. If it ever grows one, the grant stops being Bulava's and this test says so.
    func testTheWorkerScriptAsksRatherThanActs() throws {
        let script = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("engine/bin/worker-ui.sh")
        let text = try String(contentsOf: script, encoding: .utf8)

        for forbidden in ["osascript", "AXUIElement", "cliclick", "System Events", "screencapture"] {
            XCTAssertFalse(text.contains(forbidden),
                           "the worker script must not act on its own: found \(forbidden)")
        }
        XCTAssertTrue(text.contains("ui-requests"), "it has to ask through the request directory")
        XCTAssertTrue(text.contains("service.json"),
                      "and it has to notice when Bulava is not running")
    }
}
