import Foundation

/// Which Bulava this is: the one he works in, or the one being built.
///
/// Both used to be the same app to the system and to each other — one bundle id, one data folder,
/// one engine run straight from the repository, one tmux server, one keychain item. Where each was
/// launched from separated nothing. On 4 Oct the older one quit the newer, rewrote the
/// conversations without the fields it did not know, and an automation's follow-up landed in his
/// own folder. Being careful about which copy to open cannot fix that; being different apps can.
///
/// So the build carries its channel in its Info.plist (`BulavaChannel`, from the `BULAVA_CHANNEL`
/// build setting: Debug is `dev`, Release is `production`), and everything that is his — data,
/// supervisor state, work copies, the engine, the updater, the phone, the login item, the signing
/// key — is chosen by it. A build that says nothing is production: that is what every release
/// before this one was.
nonisolated enum AppChannel: String, Sendable {
    case production
    case dev

    static let current: AppChannel = from(infoValue: Bundle.main.object(forInfoDictionaryKey: "BulavaChannel") as? String)

    static func from(infoValue: String?) -> AppChannel {
        infoValue?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "dev" ? .dev : .production
    }

    var isDev: Bool { self == .dev }

    /// The app's own data under Application Support.
    var supportFolderName: String { isDev ? "NightShift-Dev" : "NightShift" }

    /// The engine's state: runs, queues, reports, worker settings.
    func defaultSupervisorStateDir(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        home.appendingPathComponent(isDev ? ".claude/supervisor-dev" : ".claude/supervisor", isDirectory: true)
    }

    /// Where the copies its runs work in live. Separate per channel because each sweeps the copies
    /// it has no record of — the other channel's would look exactly like that.
    func developerFolder(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        home.appendingPathComponent(isDev ? "Library/Developer/Bulava-Dev" : "Library/Developer/Bulava",
                                    isDirectory: true)
    }

    /// A tmux server of its own for Dev, found through `TMUX_TMPDIR`. The same project in both
    /// channels has the same session name, and the engine treats a session of that name as its
    /// run — a Dev start would have attached to his.
    func tmuxDir(stateDir: URL) -> URL? {
        isDev ? stateDir.appendingPathComponent("tmux", isDirectory: true) : nil
    }

    /// The keychain item that holds the key decisions are signed with. A key read by a build that
    /// did not create it raises a keychain prompt; Dev has its own and never asks for his.
    var signingKeyService: String { isDev ? "app.bulava.decisions.dev" : "app.bulava.decisions" }

    /// Sparkle, the phone link and the login item are his app's. A Dev build updating itself from
    /// the public feed, answering his phone, or registering itself to start at login would each
    /// reach into the production app's place.
    var ownsUpdates: Bool { !isDev }
    var ownsPhoneLink: Bool { !isDev }
    var ownsLoginItem: Bool { !isDev }

    /// Called before anything reads a path: the engine's scripts, the tmux server the engine
    /// starts and the hooks inside every worker take their state folder and their tmux socket from
    /// the environment they inherit, so Dev sets both on its own process once. A value already set
    /// — a test fixture, a person's own override — is left alone.
    static func prepareProcessEnvironment(_ channel: AppChannel = current,
                                          setenv: (String, String) -> Void = { Foundation.setenv($0, $1, 1) },
                                          environment: [String: String] = ProcessInfo.processInfo.environment) {
        guard channel.isDev else { return }
        let state: URL
        if let set = environment["SUPERVISOR_STATE_DIR"], !set.isEmpty {
            state = URL(fileURLWithPath: set, isDirectory: true)
        } else {
            state = channel.defaultSupervisorStateDir()
            setenv("SUPERVISOR_STATE_DIR", state.path)
        }
        if (environment["TMUX_TMPDIR"] ?? "").isEmpty, let tmux = channel.tmuxDir(stateDir: state) {
            try? FileManager.default.createDirectory(at: tmux, withIntermediateDirectories: true)
            setenv("TMUX_TMPDIR", tmux.path)
        }
        setenv("BULAVA_CHANNEL", channel.rawValue)
    }
}
