import Foundation
import AppKit
import Observation

/// Bulava's own browser: Google Chrome on a profile of Bulava's, where he signs in to the sites runs
/// need, once, and which runs then use without a single "Allow remote debugging?".
///
/// It has two modes, never both at once, because they are one profile:
/// - **signing in** — plain Chrome, no debugging at all, so a site sees an ordinary browser (Google
///   refuses sign-in to one that is being driven). He opens it from Settings, signs in, quits it.
/// - **working** — the same profile with DevTools on a pipe only Bulava holds, lent to one run at a
///   time through `BrowserBroker`. Started when a run first needs it, kept open afterwards: some
///   sign-ins live only as long as the browser does.
///
/// A run that needs no sign-in gets a throwaway headless browser of its own instead (the engine's
/// `browser` server), so runs never wait on each other for that.
///
/// The engine learns all this from `browser/service.json` in its state folder: whether the browser
/// is on, the door's port, and which sites are closed to runs without him. Each run has a token of
/// its own in `browser.json` in its folder; Bulava reads those to know who is asking.
@MainActor
@Observable
final class AccountBrowser {
    enum Mode: Equatable { case idle, working, signingIn }

    @ObservationIgnored weak var model: AppModel?
    @ObservationIgnored let broker = BrowserBroker()
    @ObservationIgnored private let folder: URL
    @ObservationIgnored private var stateDir: URL?
    @ObservationIgnored private var timer: Task<Void, Never>?
    @ObservationIgnored private var signInProcess: Process?
    @ObservationIgnored private var inFlight: Set<String> = []

    private(set) var enabled = false
    private(set) var chrome: URL?
    private(set) var sites: [BrowserSite] = []
    private(set) var lease: BrowserBroker.Lease?
    private(set) var mode: Mode = .idle
    private(set) var port: UInt16 = 0
    /// The site being signed in to, while he is.
    private(set) var signingIn: BrowserSite?

    static let preferredPort: UInt16 = 47_293

    init(folder: URL = AppSupport.file("browser")) {
        self.folder = folder
        sites = (try? Data(contentsOf: folder.appendingPathComponent("sites.json")))
            .flatMap { try? JSONDecoder().decode([BrowserSite].self, from: $0) } ?? []
    }

    var profile: URL { folder.appendingPathComponent("profile", isDirectory: true) }
    var serviceFile: URL? { stateDir?.appendingPathComponent("browser/service.json") }
    private var requests: URL? { stateDir?.appendingPathComponent("browser-requests", isDirectory: true) }

    // MARK: Life

    func attach(_ model: AppModel, enabled: Bool, stateDir: URL?) {
        self.model = model
        self.stateDir = stateDir
        chrome = ChromeApp.find()
        let profile = self.profile
        let chrome = self.chrome
        broker.makeTransport = {
            guard let chrome else { throw ChromePipe.LaunchError.spawn(ENOENT) }
            ChromeApp.prepare(profile: profile)
            return try ChromePipe.launch(executable: ChromeApp.executable(of: chrome),
                                         arguments: ChromeApp.baseArguments(profile: profile) + ["--remote-debugging-pipe"])
        }
        broker.onChange = { [weak self] lease in
            Task { @MainActor in self?.leaseChanged(lease) }
        }
        if let requests { try? FileManager.default.createDirectory(at: requests, withIntermediateDirectories: true) }
        setEnabled(enabled)
        timer = Task { [weak self] in
            var ticks = 0
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(500))
                guard let self else { return }
                self.drain()
                ticks += 1
                if ticks % 4 == 0 { self.refreshRuns() }
                if ticks % 10 == 0 { self.announce() }
            }
        }
    }

    func detach() {
        timer?.cancel()
        timer = nil
        broker.stop()
        if let serviceFile { try? FileManager.default.removeItem(at: serviceFile) }
    }

    func setEnabled(_ on: Bool) {
        enabled = on && chrome != nil
        if enabled {
            if port == 0 { port = broker.start(preferredPort: Self.preferredPort) }
            broker.setUnavailable(mode == .signingIn ? Self.signingInReason : nil)
            broker.setBlocked(blockedHosts)
            refreshRuns()
        } else {
            broker.stop()
            port = 0
            lease = nil
        }
        announce()
    }

    private func leaseChanged(_ lease: BrowserBroker.Lease?) {
        self.lease = lease
        if mode != .signingIn { mode = broker.browserRunning ? .working : .idle }
    }

    // MARK: Sites

    /// Adds a site and opens it for signing in. Nil when the address names no site.
    func addSite(_ typed: String) -> BrowserSite? {
        guard let site = BrowserSite.make(from: typed) else { return nil }
        if let known = sites.first(where: { $0.host == site.host }) { return known }
        sites.append(site)
        saveSites()
        return site
    }

    func removeSite(_ id: UUID) {
        sites.removeAll { $0.id == id }
        saveSites()
    }

    func setWithoutMe(_ id: UUID, _ on: Bool) {
        guard let i = sites.firstIndex(where: { $0.id == id }) else { return }
        sites[i].withoutMe = on
        saveSites()
    }

    /// Hosts a run without him may not open: every site he did not open to such runs.
    var blockedHosts: [String] { sites.filter { !$0.withoutMe }.map(\.host) }

    private func saveSites() {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(sites) {
            try? data.write(to: folder.appendingPathComponent("sites.json"), options: .atomic)
        }
        broker.setBlocked(blockedHosts)
        announce()
    }

    // MARK: Signing in

    static var signingInReason: String { String(localized: "He is signing in to a site in Bulava's browser right now.") }

    /// Plain Chrome on Bulava's profile, at `site`, for him to sign in. Whoever was using the
    /// browser loses it — the profile cannot be open twice — so the caller asks him first.
    func signIn(_ site: BrowserSite?) async {
        guard enabled, let chrome, mode != .signingIn else { return }
        mode = .signingIn
        signingIn = site
        let broker = self.broker
        let reason = Self.signingInReason
        await Task.detached { broker.setUnavailable(reason) }.value
        lease = nil
        ChromeApp.prepare(profile: profile)
        let process = Process()
        process.executableURL = ChromeApp.executable(of: chrome)
        process.arguments = ChromeApp.baseArguments(profile: profile) + [site?.url ?? "about:blank"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        process.terminationHandler = { [weak self] _ in
            Task { @MainActor in self?.signInEnded() }
        }
        do {
            try process.run()
            signInProcess = process
        } catch {
            signInEnded()
            model?.toast = ToastMessage(text: String(localized: "Bulava could not open its browser."), kind: .error,
                                        detail: error.localizedDescription)
        }
        announce()
    }

    /// He is done: Chrome is asked to quit the way ⌘Q would, so it keeps what he signed in to.
    func finishSigningIn() {
        guard let process = signInProcess, process.isRunning else { signInEnded(); return }
        if let app = NSRunningApplication(processIdentifier: process.processIdentifier) { app.terminate() }
        else { process.terminate() }
    }

    private func signInEnded() {
        guard mode == .signingIn else { return }
        if let site = signingIn, let i = sites.firstIndex(where: { $0.id == site.id }) {
            sites[i].signedInAt = Date()
            saveSites()
        }
        signInProcess = nil
        signingIn = nil
        mode = .idle
        if enabled { broker.setUnavailable(nil) }
        announce()
    }

    /// He takes the browser back from the run that has it.
    func endLease() {
        broker.endCurrentLease()
    }

    // MARK: Runs

    /// The runs that may use the browser now: live ones whose folder holds a token.
    func refreshRuns() {
        guard enabled, let model, let stateDir else { return }
        let paths = SupervisorPaths(stateDir: stateDir)
        var runs: [BrowserBroker.Run] = []
        // A finished run (its `done` is written) has nothing left to do in the browser.
        for instance in model.snapshot.instances where instance.finishedAt == nil {
            let file = paths.instanceDir(slug: instance.slug).appendingPathComponent("browser.json")
            guard let data = try? Data(contentsOf: file),
                  let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  let token = object["token"] as? String, token.count >= 32 else { continue }
            let chat = model.conversations.chats.first { chat in
                chat.session.flatMap { model.matchingInstance(for: $0) }?.slug == instance.slug
            }
            let title = chat?.title ?? URL(fileURLWithPath: instance.projectPath).lastPathComponent
            runs.append(.init(token: token, slug: instance.slug, title: title,
                              unattended: object["unattended"] as? Bool ?? false))
        }
        broker.setRuns(runs)
        if mode != .signingIn { mode = broker.browserRunning ? .working : .idle }
    }

    /// What the engine reads when it starts a run.
    func announce() {
        guard let serviceFile else { return }
        try? FileManager.default.createDirectory(at: serviceFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        let payload: [String: Any] = [
            "pid": ProcessInfo.processInfo.processIdentifier,
            "enabled": enabled && port != 0,
            "port": Int(port),
            "blocked": blockedHosts,
            "sites": sites.map { ["host": $0.host, "withoutMe": $0.withoutMe] },
        ]
        if let data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]) {
            try? data.write(to: serviceFile, options: .atomic)
        }
    }

    // MARK: `$IDIR/browser`

    private func drain() {
        guard let requests, let names = try? FileManager.default.contentsOfDirectory(atPath: requests.path) else { return }
        for name in names.sorted() where name.hasSuffix(".json") {
            let id = String(name.dropLast(5))
            let done = requests.appendingPathComponent("\(id).done")
            guard !inFlight.contains(id), !FileManager.default.fileExists(atPath: done.path) else { continue }
            inFlight.insert(id)
            let answer = serve(requests.appendingPathComponent(name))
            if let data = try? JSONSerialization.data(withJSONObject: answer) { try? data.write(to: done, options: .atomic) }
            inFlight.remove(id)
        }
    }

    /// `{"op": "status" | "release", "token"}` from a run.
    func serve(_ request: URL) -> [String: Any] {
        guard let data = try? Data(contentsOf: request),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let op = object["op"] as? String, let token = object["token"] as? String else {
            return ["ok": false, "error": "unreadable request"]
        }
        refreshRuns()
        let held = broker.currentLease
        switch op {
        case "release":
            return ["ok": true, "released": broker.release(token: token)]
        case "status":
            var answer: [String: Any] = ["ok": true, "enabled": enabled,
                                         "sites": sites.map { ["host": $0.host, "withoutMe": $0.withoutMe] }]
            if !enabled {
                answer["state"] = "off"
            } else if mode == .signingIn {
                answer["state"] = "unavailable"
                answer["reason"] = Self.signingInReason
            } else if let held {
                answer["state"] = held.run.token == token ? "yours" : "busy"
                answer["holder"] = held.run.title
                answer["since"] = Int(held.since.timeIntervalSince1970)
            } else {
                answer["state"] = "free"
            }
            return answer
        default:
            return ["ok": false, "error": "unknown op \(op)"]
        }
    }
}
