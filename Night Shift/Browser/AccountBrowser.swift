import Foundation
import AppKit
import Observation

/// Bulava's own browser: Google Chrome on a profile of Bulava's, where he signs in to the sites runs
/// need, once, and which runs then use without a single "Allow remote debugging?".
///
/// It has two modes, never both at once, because they are one profile:
/// - **signing in** — plain Chrome, no debugging at all, so a site sees an ordinary browser (Google
///   refuses sign-in to one that is being driven). He opens it from Settings, signs in, quits it —
///   or from where Bulava asks him to, when a run reached a sign-in (`askToSignIn`).
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

    /// A sign-in a run reached that only he can do, in Chrome with nobody driving it.
    struct SignInRequest: Equatable, Sendable {
        var url: URL
        /// The run that waits for it.
        var runSlug: String
        var runTitle: String
        var runToken: String
        /// Seen by Bulava in the run's tab, rather than asked for by the run: it belongs to that
        /// run's lease of the browser, and goes when the lease does.
        var automatic: Bool
        var at: Date

        var site: String { url.host ?? url.absoluteString }
    }

    @ObservationIgnored weak var model: AppModel?
    @ObservationIgnored let broker = BrowserBroker()
    @ObservationIgnored private let folder: URL
    @ObservationIgnored private var stateDir: URL?
    @ObservationIgnored private var timer: Task<Void, Never>?
    /// Waiting for him: a site to sign in to that a run reached. Shown in Bulava, in what waits for
    /// him on the Mac and the phone, and in Settings until he signs in or dismisses it.
    private(set) var signInRequest: SignInRequest?
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
        broker.onSignInNeeded = { [weak self] url, run in
            Task { @MainActor in self?.signInSeen(at: url, by: run) }
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
        // A sign-in Bulava saw in a run's tab waits only while that run has the browser.
        if let waiting = signInRequest, waiting.automatic, lease?.run.token != waiting.runToken { dismissSignInRequest() }
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

    /// Plain Chrome on Bulava's profile, at `address` or else `site`, for him to sign in. Whoever was
    /// using the browser loses it — the profile cannot be open twice — so the caller asks him first,
    /// unless it was that run's own sign-in he was asked for.
    func signIn(_ site: BrowserSite?, at address: URL? = nil) async {
        guard enabled, let chrome, mode != .signingIn else { return }
        mode = .signingIn
        signingIn = site
        signInRequest = nil
        model?.resolveToast(key: Self.signInToastKey)
        let broker = self.broker
        let reason = Self.signingInReason
        await Task.detached { broker.setUnavailable(reason) }.value
        lease = nil
        ChromeApp.prepare(profile: profile)
        let process = Process()
        process.executableURL = ChromeApp.executable(of: chrome)
        process.arguments = ChromeApp.baseArguments(profile: profile) + [address?.absoluteString ?? site?.url ?? "about:blank"]
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

    static let signInToastKey = "browser-sign-in"

    /// A run's browser is at a sign-in only he can do: Google's, seen by Bulava, or any site a run
    /// asked about (`$IDIR/browser sign-in`). Typed into the run's own window it fails — Google
    /// refuses a driven browser, whatever is typed — so he is asked to sign in in the window this
    /// opens instead: Bulava's profile, nobody driving. The run then goes on with his sign-in. One
    /// request at a time; the same site again is the same request.
    func askToSignIn(at url: URL, for run: BrowserBroker.Run, automatic: Bool = false) {
        // Only for a run that may use the browser now: one that ended asks him for nothing.
        guard enabled, mode != .signingIn, let host = url.host, !host.isEmpty,
              broker.run(token: run.token) != nil else { return }
        // The same run at the same site is the same request; another run there is its own.
        if let waiting = signInRequest, waiting.url.host == host, waiting.runToken == run.token { return }
        let request = SignInRequest(url: url, runSlug: run.slug, runTitle: run.title, runToken: run.token,
                                    automatic: automatic, at: Date())
        signInRequest = request
        model?.toast = ToastMessage(
            title: String(format: String(localized: "%@ needs you to sign in"), request.site),
            text: Self.signInWhy(google: url.host?.hasSuffix("google.com") == true),
            kind: .info, key: Self.signInToastKey,
            actions: [
                ToastAction(title: String(localized: "Sign in")) { [weak self] in
                    Task { await self?.signIn(nil, at: url) }
                },
                ToastAction(title: String(localized: "Later"), primary: false) {},
            ])
        model?.mobileLink.scheduleRefresh()
    }

    /// Bulava saw a run's tab reach Google's sign-in. By the time this is read the run may have let
    /// go of the browser, or ended: then nobody waits, and he is asked for nothing.
    func signInSeen(at url: URL, by run: BrowserBroker.Run) {
        guard broker.currentLease?.run.token == run.token else { return }
        askToSignIn(at: url, for: run, automatic: true)
    }

    /// Why he signs in in another window, in his words.
    static func signInWhy(google: Bool) -> String {
        google
            ? String(localized: "Google does not let anyone sign in to a browser an agent is driving. Sign in in the window that opens: the same browser of Bulava's, with nobody driving it. The run goes on with your sign-in.")
            : String(localized: "Sign in in the window that opens: the same browser of Bulava's, with nobody driving it. The run goes on with your sign-in.")
    }

    /// He does not want to sign in now.
    func dismissSignInRequest() {
        signInRequest = nil
        model?.resolveToast(key: Self.signInToastKey)
        model?.mobileLink.scheduleRefresh()
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
        // A sign-in asked for by a run that has ended waits for nobody any more.
        if let slug = signInRequest?.runSlug, !runs.contains(where: { $0.slug == slug }) { dismissSignInRequest() }
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

    /// `{"op": "status" | "release" | "signIn", "token", "url"?}` from a run.
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
        case "signIn":
            guard enabled else { return ["ok": false, "error": "Bulava's browser is off."] }
            guard let raw = object["url"] as? String, let url = URL(string: raw),
                  ["https", "http"].contains(url.scheme?.lowercased() ?? ""), url.host != nil else {
                return ["ok": false, "error": "sign-in needs the address of the site's page, http(s)://…"]
            }
            // Only a run that may use the browser now asks him for anything.
            guard let run = broker.run(token: token) else {
                return ["ok": false, "error": "this run may not use Bulava's browser now"]
            }
            if mode == .signingIn { return ["ok": true, "asked": false, "reason": Self.signingInReason] }
            askToSignIn(at: url, for: run)
            let asked = signInRequest?.url.host == url.host
            return asked ? ["ok": true, "asked": true] : ["ok": true, "asked": false, "reason": "Bulava did not ask him."]
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
