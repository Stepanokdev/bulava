import AppKit

/// What "Open Bulava" needs from the application: whether it is hidden, the way back, and its
/// windows. `NSApplication` is the only one in the app; the protocol exists because a test host
/// cannot hide itself — macOS refuses ⌘H to a process that is not the frontmost app — so the hidden
/// case is exercised through a stand-in that hides the real main window the way ⌘H does.
@MainActor protocol MainWindowHost: AnyObject {
    var isHidden: Bool { get }
    func unhide(_ sender: Any?)
    func bringToFront()
    var windows: [NSWindow] { get }
}

extension NSApplication: MainWindowHost {
    func bringToFront() { activate(ignoringOtherApps: true) }
}

/// The app's main window, found among whatever AppKit has.
@MainActor enum MainWindow {

    /// SwiftUI names the windows of `WindowGroup(id: "main")` `main-AppWindow-1`, `-2`, … — the
    /// same name the saved frame is filed under (`SavedSplitLayout.mainWindowFrameKey`).
    static func isMain(_ window: NSWindow) -> Bool {
        guard let id = window.identifier?.rawValue else { return false }
        return id == "main" || id.hasPrefix("main-")
    }

    /// A main window that is still there to come back to: on screen, behind other windows, on
    /// another Space, or in the Dock. A closed one is none of these, and bringing it forward would
    /// show a frame SwiftUI has already emptied.
    static func existing() -> NSWindow? { existing(in: NSApp.windows) }

    static func existing(in windows: [NSWindow]) -> NSWindow? {
        windows.first { isMain($0) && ($0.isVisible || $0.isMiniaturized) }
    }

    /// When a new main window was last asked for. SwiftUI creates it on a later turn of the run
    /// loop, so for a moment after asking there is still no window to find — and a second press in
    /// that moment used to ask again, which is two windows from a double click.
    private static var openRequestedAt: Date?

    /// What "Open Bulava" does: bring back the window that is there — unhiding the app,
    /// un-minimising it, fetching it from another Space — and open one only when there is none.
    ///
    /// `openWindow(id:)` on a `WindowGroup` does not mean "show the main window", it means "make
    /// another one"; calling it on every press is how one Bulava came to look like several.
    static func reveal(open: () -> Void) { reveal(in: NSApp, open: open) }

    static func reveal(in app: MainWindowHost, open: () -> Void) {
        // Unhidden FIRST: a hidden app's windows report themselves invisible, so looking before this
        // finds nothing and opens a second window behind the first.
        if app.isHidden { app.unhide(nil) }
        app.bringToFront()
        if let window = existing(in: app.windows) {
            openRequestedAt = nil
            // Un-minimising is bringing it back; ordering it to the front as well, while it is still
            // on its way out of the Dock, would be asking twice for the same thing.
            if window.isMiniaturized { window.deminiaturize(nil) } else { window.makeKeyAndOrderFront(nil) }
            return
        }
        if let asked = openRequestedAt, Date().timeIntervalSince(asked) < 2 { return }
        openRequestedAt = Date()
        open()
    }
}
