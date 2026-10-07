import AppKit
import OSLog

nonisolated enum SingleInstance {

    static let log = Logger(subsystem: "app.bulava", category: "lifecycle")

    /// Whether this launch should step aside for a copy that is already running.
    ///
    /// One Bulava at a time, and until now always the one that was there FIRST. That made the old
    /// copy win every time: an update installed and opened, and the new build quit itself in favour
    /// of whatever was already running — a Debug build left over in Xcode's DerivedData, a
    /// version from the day before. The director went on looking at the old app, and asked where
    /// the buttons were that the new one had. So a newer build now takes the place: it asks the
    /// older copy to quit, the ordinary way, and carries on once it has. A copy of the same build
    /// or a newer one still keeps its place, as before.
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

        let myBuild = build(of: Bundle.main)
        let older = others.filter { isOlder(build(of: $0), than: myBuild) }
        if older.count == others.count {
            log.notice("an older Bulava is running (\(older.map { "\($0.processIdentifier)" }.joined(separator: ","), privacy: .public)) — asking it to quit and taking its place")
            older.forEach { $0.terminate() }
            let deadline = Date().addingTimeInterval(takeoverWait)
            while Date() < deadline, older.contains(where: { !$0.isTerminated }) {
                RunLoop.current.run(until: Date().addingTimeInterval(0.1))
            }
            if older.allSatisfy(\.isTerminated) { return false }
            log.notice("the older Bulava did not quit — leaving it in place")
        }

        log.notice("another Bulava is already running (pid \(first.processIdentifier, privacy: .public)) — activating it and quitting")
        first.activate(options: [])
        return true
    }

    /// Long enough for an ordinary quit, short enough that a copy stuck on a dialog does not hold
    /// the new launch hostage.
    static let takeoverWait: TimeInterval = 10

    static func build(of app: NSRunningApplication) -> String? {
        guard let url = app.bundleURL, let bundle = Bundle(url: url) else { return nil }
        return build(of: bundle)
    }

    static func build(of bundle: Bundle) -> String? {
        let built = bundle.executableURL
            .flatMap { try? $0.resourceValues(forKeys: [.contentModificationDateKey]) }?
            .contentModificationDate
        return effectiveBuild(bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String, builtAt: built)
    }

    /// A build's number is the minute it was built: a release's from `release.sh`, any other
    /// build's from `scripts/stamp-build-number.sh`. One without such a number — a Debug build from
    /// before the stamp, still «1» — is dated by when its executable was written, in the same form.
    ///
    /// Compared as it was, «1» was older than every release: 4 Oct, an installed 1.10 that was
    /// opened quit a Debug build with newer code in the middle of an automation's run, then wrote the
    /// conversations back without the fields it did not know.
    static func effectiveBuild(_ version: String?, builtAt: Date?) -> String? {
        if let version, version.count == 12, version.allSatisfy({ $0.isASCII && $0.isNumber }) { return version }
        guard let builtAt else { return nil }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = .current
        f.dateFormat = "yyyyMMddHHmm"
        return f.string(from: builtAt)
    }

    /// Build numbers are timestamps to the minute and only ever rise. Anything unreadable is not
    /// «older»: a copy whose build cannot be told is left alone, as every copy used to be.
    static func isOlder(_ theirs: String?, than mine: String?) -> Bool {
        guard let theirs, let mine, !theirs.isEmpty, !mine.isEmpty else { return false }
        return theirs.compare(mine, options: .numeric) == .orderedAscending
    }
}
