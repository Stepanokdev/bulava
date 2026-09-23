import AppKit

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
}
