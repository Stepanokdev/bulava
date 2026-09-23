import XCTest
import AppKit
import SwiftUI
@testable import Bulava

/// "Open Bulava" in the menu bar brings back the window that is there, and opens one only when
/// there is none. `openWindow(id:)` on a `WindowGroup` makes another window every time, and every
/// window used to start its own copy of the app's machinery.
nonisolated final class MainWindowTests: XCTestCase {

    /// SwiftUI names `WindowGroup(id: "main")` windows `main-AppWindow-N`; the settings, skills and
    /// menu-bar panels are someone else's.
    @MainActor func testOnlyTheMainWindowsAreTheMainWindow() {
        func window(_ id: String?) -> NSWindow {
            let w = NSWindow(contentRect: .zero, styleMask: [.titled], backing: .buffered, defer: true)
            w.identifier = id.map { NSUserInterfaceItemIdentifier($0) }
            w.isReleasedWhenClosed = false
            return w
        }
        XCTAssertTrue(MainWindow.isMain(window("main-AppWindow-1")))
        XCTAssertTrue(MainWindow.isMain(window("main")))
        XCTAssertFalse(MainWindow.isMain(window("skills")))
        XCTAssertFalse(MainWindow.isMain(window("com_apple_SwiftUI_Settings_window")))
        XCTAssertFalse(MainWindow.isMain(window(nil)))
        XCTAssertFalse(MainWindow.isMain(window("mainly-something-else")))
    }

    /// A closed window is not one to come back to; bringing it forward would show an empty frame.
    @MainActor func testAClosedMainWindowIsNotBroughtBack() {
        let closed = NSWindow(contentRect: .zero, styleMask: [.titled], backing: .buffered, defer: true)
        closed.identifier = NSUserInterfaceItemIdentifier("main-AppWindow-1")
        closed.isReleasedWhenClosed = false
        XCTAssertNil(MainWindow.existing(in: [closed]), "never shown, never minimised: nothing to bring back")
    }

    // MARK: - The real window, the real action

    /// The action "Open Bulava" runs, against the app's own SwiftUI main window in this very process
    /// — the test host IS Bulava — with the `openWindow` the scene provides. Nothing here names a
    /// window by hand: the window is the one `WindowGroup(id: "main")` made, and a new one comes
    /// from SwiftUI the same way the menu bar's does.
    @MainActor func testOpenBulavaKeepsOneMainWindowWhateverStateItIsIn() throws {
        let opener = try sceneOpener()
        var opened = 0
        func openBulava() { MainWindow.reveal { opened += 1; opener(id: "main") } }

        // However the host started, begin from exactly one main window on screen.
        if MainWindow.existing() == nil { openBulava() }
        XCTAssertTrue(wait { self.visibleMainWindows.count == 1 }, "no main window to start from")
        // The steps before the close hold the window only inside this block. A test that kept a
        // strong reference to the closed window would be keeping alive something the app itself
        // lets go of — and SwiftUI, finding its scene's old window still around, shows it again
        // beside the new one. Nothing in the app holds a closed window; neither does this test.
        weak var closedWindow: NSWindow?
        do {
            let window = try XCTUnwrap(MainWindow.existing())

            // Open, and pressed again and again.
            for _ in 0..<4 { openBulava(); spin(0.2) }
            XCTAssertEqual(visibleMainWindows.count, 1, "pressing it with the window open added windows")
            XCTAssertTrue(MainWindow.existing() === window, "a different window came forward")

            // Minimised to the Dock.
            window.miniaturize(nil)
            XCTAssertTrue(wait { window.isMiniaturized }, "could not minimise the window to test with")
            openBulava(); openBulava()
            XCTAssertTrue(wait { !window.isMiniaturized && window.isVisible }, "the minimised window stayed in the Dock")
            XCTAssertEqual(mainWindows.count, 1, "a minimised window was answered with a new one")

            // Closed — the one case that must open a window, and exactly one, even from a double
            // click. Closed the way a person closes it: the red button, which goes through
            // SwiftUI's own delegate. `close()` would skip it, and SwiftUI would still count the
            // window as open.
            window.performClose(nil)
            closedWindow = window
        }
        XCTAssertTrue(wait { self.visibleMainWindows.isEmpty }, "could not close the window to test with")
        openBulava(); openBulava(); openBulava()
        XCTAssertTrue(wait { self.visibleMainWindows.count == 1 }, "closing it and pressing it gave no window")
        // Long enough for anything AppKit deferred to run.
        spin(1.5)
        XCTAssertEqual(visibleMainWindows.count, 1, "a rapid second press opened a second window")
        XCTAssertEqual(opened, 1, "three presses with no window asked SwiftUI for more than one")
        XCTAssertFalse(closedWindow?.isVisible ?? false, "the closed window came back")
        for _ in 0..<3 { openBulava(); spin(0.3) }
        XCTAssertEqual(visibleMainWindows.count, 1, "the reopened window was not the one brought back")
        XCTAssertFalse(closedWindow?.isVisible ?? false, "the closed window came back")

        // Last, the whole app hidden (⌘H). A test host cannot hide itself — macOS refuses ⌘H to a
        // process that is not the frontmost app, and this one never is — so the app is stood in for
        // by `HiddenApp`, which does to the REAL window what ⌘H does: takes it off screen without
        // closing it, until `unhide`. The action under test is the menu bar's own `reveal`. Last,
        // because the stand-in moves the window behind SwiftUI's back, and nothing after it should
        // have to live with that.
        let reopened = try XCTUnwrap(MainWindow.existing())
        let hidden = HiddenApp(window: reopened)
        XCTAssertTrue(wait { !reopened.isVisible }, "could not take the window off screen to test with")
        XCTAssertNil(MainWindow.existing(in: hidden.windows),
                     "a hidden app's window is invisible — looking before unhiding finds nothing")
        var openedWhileHidden = 0
        MainWindow.reveal(in: hidden) { openedWhileHidden += 1 }
        MainWindow.reveal(in: hidden) { openedWhileHidden += 1 }
        XCTAssertTrue(wait { !hidden.isHidden && reopened.isVisible }, "the hidden app stayed hidden")
        XCTAssertEqual(openedWhileHidden, 0, "a hidden window was answered with a new one")
        XCTAssertEqual(visibleMainWindows.count, 1)
    }

    // MARK: - Helpers

    @MainActor private var mainWindows: [NSWindow] {
        NSApp.windows.filter { MainWindow.isMain($0) && ($0.isVisible || $0.isMiniaturized) }
    }

    @MainActor private var visibleMainWindows: [NSWindow] {
        NSApp.windows.filter { MainWindow.isMain($0) && $0.isVisible }
    }

    @MainActor private func spin(_ seconds: TimeInterval) {
        RunLoop.current.run(until: Date().addingTimeInterval(seconds))
    }

    @MainActor private func wait(_ timeout: TimeInterval = 8, _ condition: () -> Bool) -> Bool {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end {
            if condition() { return true }
            spin(0.05)
        }
        return condition()
    }

    /// The scene's own `openWindow`, read from a SwiftUI view hosted in this app — the same action
    /// `MenuBarView` holds.
    @MainActor private func sceneOpener() throws -> OpenWindowAction {
        let box = OpenerBox()
        let host = NSWindow(contentRect: NSRect(x: -10_000, y: -10_000, width: 10, height: 10),
                            styleMask: [.borderless], backing: .buffered, defer: false)
        host.isReleasedWhenClosed = false
        host.contentView = NSHostingView(rootView: OpenerCapture(box: box))
        host.orderFrontRegardless()
        defer { host.orderOut(nil) }
        XCTAssertTrue(wait { box.action != nil }, "no openWindow action in this app's environment")
        return try XCTUnwrap(box.action)
    }
}

@MainActor private final class OpenerBox { var action: OpenWindowAction? }

private struct OpenerCapture: View {
    @Environment(\.openWindow) private var openWindow
    let box: OpenerBox
    var body: some View {
        Color.clear.onAppear { box.action = openWindow }
    }
}

/// ⌘H, done to the real main window: off screen but not closed, and back on `unhide`. Every other
/// question goes to the real application.
@MainActor private final class HiddenApp: MainWindowHost {
    private let window: NSWindow
    private(set) var isHidden = true
    init(window: NSWindow) {
        self.window = window
        window.orderOut(nil)
    }
    func unhide(_ sender: Any?) {
        isHidden = false
        window.orderFront(nil)
    }
    func bringToFront() {}
    var windows: [NSWindow] { NSApp.windows }
}
