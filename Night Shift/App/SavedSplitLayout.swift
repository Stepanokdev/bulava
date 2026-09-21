import Foundation

nonisolated enum SavedSplitLayout {
    static let navigationFramesKey =
        "NSSplitView Subview Frames main-AppWindow-1, SidebarNavigationSplitView"
    static let mainWindowFrameKey = "NSWindow Frame main-AppWindow-1"

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
