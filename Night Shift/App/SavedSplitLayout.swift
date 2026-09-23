import Foundation

nonisolated enum SavedSplitLayout {
    /// Where AppKit files the main window's frame and its sidebar split. The main window is a
    /// `Window(id: "main")` scene, whose window autosaves under its id.
    static let navigationFramesKey = "NSSplitView Subview Frames main, SidebarNavigationSplitView"
    static let mainWindowFrameKey = "NSWindow Frame main"

    /// The same two, as they were filed while the main window was a `WindowGroup` — through 1.8.2.
    static let legacyNavigationFramesKey =
        "NSSplitView Subview Frames main-AppWindow-1, SidebarNavigationSplitView"
    static let legacyMainWindowFrameKey = "NSWindow Frame main-AppWindow-1"

    /// Carry the size and split a person set up across the change of scene. Without it the first
    /// launch after updating opens the window at its default size, as though it had never been
    /// arranged. Only ever fills a key that is empty, and runs before the window is created.
    @discardableResult
    static func migrateFromWindowGroup(defaults: UserDefaults = .standard) -> Bool {
        guard !isTestHost else { return false }
        return carryOverFromWindowGroup(in: defaults)
    }

    @discardableResult
    static func carryOverFromWindowGroup(in defaults: UserDefaults) -> Bool {
        var moved = false
        for (old, new) in [(legacyMainWindowFrameKey, mainWindowFrameKey),
                           (legacyNavigationFramesKey, navigationFramesKey)] {
            guard let value = defaults.object(forKey: old) else { continue }
            if defaults.object(forKey: new) == nil {
                defaults.set(value, forKey: new)
                moved = true
            }
            defaults.removeObject(forKey: old)
        }
        return moved
    }

    @discardableResult
    static func repairIfNeeded(defaults: UserDefaults = .standard) -> Bool {

        guard !isTestHost else { return false }
        guard let splitFrames = defaults.stringArray(forKey: navigationFramesKey),
              let windowFrame = defaults.string(forKey: mainWindowFrameKey),
              needsRepair(splitFrames: splitFrames, windowFrame: windowFrame) else {
            return false
        }
        defaults.removeObject(forKey: navigationFramesKey)
        return true
    }

    static func needsRepair(splitFrames: [String], windowFrame: String) -> Bool {
        guard splitFrames.count >= 2,
              let windowWidth = windowFrame
                .split(whereSeparator: \.isWhitespace)
                .dropFirst(2)
                .first
                .flatMap({ Double($0) }),
              windowWidth > 0 else { return false }

        let widths = splitFrames.compactMap { frame -> Double? in
            let fields = frame.split(separator: ",", omittingEmptySubsequences: false)
            guard fields.count >= 3 else { return nil }
            return Double(fields[2].trimmingCharacters(in: .whitespaces))
        }
        guard widths.count == splitFrames.count else { return false }

        return abs(widths.reduce(0, +) - windowWidth) > 80
    }

    private static var isTestHost: Bool {
        let environment = ProcessInfo.processInfo.environment
        return environment["XCTestConfigurationFilePath"] != nil
            || environment["XCTestBundlePath"] != nil
            || environment["XCTestSessionIdentifier"] != nil
    }
}
