import XCTest
import AppKit
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
}
