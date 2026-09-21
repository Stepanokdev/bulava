import AppKit
import OSLog

nonisolated enum SingleInstance {

    static let log = Logger(subsystem: "app.bulava", category: "lifecycle")

    @MainActor static func shouldYield() -> Bool {
        let env = ProcessInfo.processInfo.environment

        if env["XCTestConfigurationFilePath"] != nil || env["XCTestSessionIdentifier"] != nil { return false }
        if let dir = env["BULAVA_STATE_DIR"], !dir.isEmpty { return false }
        if let inbox = env["BULAVA_TEST_INBOX"], !inbox.isEmpty { return false }
        guard let id = Bundle.main.bundleIdentifier else { return false }

        let mine = ProcessInfo.processInfo.processIdentifier
        let others = NSRunningApplication.runningApplications(withBundleIdentifier: id)
            .filter { $0.processIdentifier != mine && !$0.isTerminated }
        guard let first = others.first else { return false }

        log.notice("another Bulava is already running (pid \(first.processIdentifier, privacy: .public)) — activating it and quitting")
        first.activate(options: [])
        return true
    }
}
