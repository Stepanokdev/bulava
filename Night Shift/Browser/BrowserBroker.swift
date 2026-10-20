import Foundation
import Network

/// The one door to the account browser: a WebSocket on this Mac's loopback that a run's
/// chrome-devtools-mcp connects to, and behind it the pipe to Chrome only Bulava holds.
///
/// Every run that may use it has a token of its own (the engine writes it into the run's folder and
/// its MCP config). Several runs use it AT ONCE, each in tabs of its own. It used to be lent to one
/// run at a time, and a second chat that needed a console was turned away (`423`) for as long as the
/// first one held it — 13 Oct the owner: «Видимо когда хоть кто-то из агентов использует браузер,
/// ты уже не можешь». Now:
///
/// - **One browser, one profile, one set of sign-ins.** Every tab is in Chrome's default context,
///   so whatever he signed in to works for every run.
/// - **Each run sees only its own tabs.** Each client gets a browser session of its own on the pipe
///   (`Target.attachToBrowserTarget`), so Chrome keeps each client's discovery and auto-attach apart
///   by itself. Bulava decides only who owns what: a tab is the run's that opened it
///   (`Target.createTarget`), a popup is its opener's run's, and nothing else — his own tabs, another
///   run's — is listed to it, attached for it, or reachable by any command it sends.
/// - **What it opened goes when it does.** A run that lets go, ends, or stays away longer than the
///   grace after its socket closes has its tabs closed. A browser nobody has used for `idleLimit` is
///   quit — the way ⌘Q would, so a sign-in that lives only as long as the browser is written out.
///
/// To know which page is in which tab — Chrome's tab and page targets share no id, and Puppeteer
/// attaches to the tab first and to its page inside it — Bulava keeps a session of its own that
/// watches every tab and the page in it. Nothing from that session reaches any run.
///
/// It also keeps what the run's own client should not decide. A run working without the director
/// does not get the sites he keeps for himself (`blocked`): no address of his sites passes in any
/// command, storage included; every page the run has is closed to those sites at the network; and a
/// tab of the run's that reaches one of them is taken from it. No run reads cookies or closes the
/// browser. This keeps runs out of each other's way; it is not a wall between them — they share a
/// profile, as they share the sign-ins.
nonisolated final class BrowserBroker: @unchecked Sendable {

    struct Run: Sendable, Equatable {
        var token: String
        var slug: String
        /// What he would call it: the chat's name, or the project's.
        var title: String
        var unattended: Bool
    }

    /// A run using the browser now.
    struct Lease: Sendable, Equatable {
        var run: Run
        var since: Date
        var lastActivity: Date
    }

    let queue = DispatchQueue(label: "bulava.account-browser")
    /// How long the browser stays open with no run using it.
    var idleLimit: TimeInterval = 300
    /// How long a run keeps its tabs after its socket closes: chrome-devtools-mcp reconnects at once.
    var reconnectGrace: TimeInterval = 5
    /// How long a tab nobody has claimed yet waits for its owner before it is treated as nobody's.
    var claimWait: TimeInterval = 5
    /// Starts the browser for work when a run needs it.
    var makeTransport: (@Sendable () throws -> CDPTransport)?
    /// Starts it with no window, for Bulava's own errands when no run is using it (`visit`).
    var makeQuietTransport: (@Sendable () throws -> CDPTransport)?
    /// Who is using the browser changed, or the browser stopped. Called on `queue`.
    var onChange: (@Sendable ([Lease]) -> Void)?
    /// A tab of a run's reached a sign-in only he can do here: Google refuses to sign in to a
    /// browser a program is driving — and this one is driven — so he has to, in Chrome with nobody
    /// at the wheel. The address to sign in at, and the run whose tab it is. Once per tab and address
    /// for each run. Called on `queue`.
    var onSignInNeeded: (@Sendable (URL, Run) -> Void)?

    private var listener: NWListener?
    private var boundPort: UInt16 = 0
    private var runs: [String: Run] = [:]
    /// Sites a run without the director may not open, by host (a host covers its subdomains).
    private var blocked: [String] = []
    private var unavailable: String?
    private var transport: CDPTransport?
    private var idleTimer: DispatchSourceTimer?
    /// When the last run stopped using the browser; nil while one is.
    private var unusedSince: Date?

    /// One run's connection, by its token.
    private final class Client {
        let run: Run
        var peer: WebSocketPeer?
        /// Bumped by every new socket, so an old socket's ending cannot end the new one's run.
        var generation = 0
        /// Its own browser session on the pipe; until it is known, what the client sends waits.
        var browserSession: String?
        var waiting: [Data] = []
        var since: Date
        var lastActivity: Date
        /// Browser contexts it made (`new_page` with an isolated context).
        var contexts: Set<String> = []
        var signInsTold: Set<String> = []
        init(run: Run, now: Date) { self.run = run; since = now; lastActivity = now }
    }
    private var clients: [String: Client] = [:]

    /// A tab or page, and the run it belongs to.
    private var owner: [String: String] = [:]
    private var tabPage: [String: String] = [:]
    private var pageTab: [String: String] = [:]
    private var targetURLs: [String: String] = [:]
    private var targetTypes: [String: String] = [:]
    private var openers: [String: String] = [:]

    /// Every session a client has, whose it is, which target it is on, and its parent session.
    private var sessionOwner: [String: String] = [:]
    private var sessionTarget: [String: String] = [:]
    private var sessionParent: [String: String] = [:]
    /// Client browser sessions → token.
    private var browserSessions: [String: String] = [:]
    /// Sessions Bulava took away or never gave: what comes from them goes nowhere.
    private var hidden: Set<String> = []
    /// Sessions being taken from their run: nothing more may be sent on them, and the run still hears
    /// Chrome say they are gone.
    private var taken: Set<String> = []

    /// Bulava's own session that watches every tab and the page in it.
    private var observer: String?
    private var observerSessions: [String: String] = [:]   // tab session → tab id

    /// A tab the browser attached for a client before Bulava knew whose it is: the attach and
    /// everything after it, kept until it is known.
    private struct Held { var token: String; var session: String; var target: String; var messages: [[String: Any]]; var since: Date }
    private var held: [String: Held] = [:]                  // by session
    /// Discovery events about a target nobody has claimed yet, per client.
    private var heldDiscovery: [String: [(token: String, event: [String: Any])]] = [:]

    private struct Pending {
        var token: String
        var generation: Int
        var id: Int
        var method: String
        /// Sent on the client's browser session in its place: the answer goes back without it.
        var rooted: Bool
        var target: String?
    }
    private var nextID = 1
    private var pending: [Int: Pending] = [:]
    /// `Target.createTarget` calls still unanswered: a new tab may be one of them.
    private var creating = 0
    private var own: Set<Int> = []
    private var ownCallbacks: [Int: ([String: Any]?) -> Void] = [:]

    /// What no run may ask of the account browser.
    static let forbidden: Set<String> = [
        "Browser.close", "Browser.crash", "Browser.crashGpuProcess",
        "Storage.getCookies", "Network.getAllCookies", "Network.getCookies",
        "Network.clearBrowserCookies", "Storage.clearCookies",
        // A session on the whole browser, or a message into a target past Bulava: either would see
        // every run's tabs.
        "Target.attachToBrowserTarget", "Target.sendMessageToTarget", "Target.exposeDevToolsProtocol",
    ]
    /// What would lift the rule that keeps a run without the director off his own sites.
    static let guarding: Set<String> = [
        "Network.emulateNetworkConditionsByRule", "Network.emulateNetworkConditions",
        "Network.overrideNetworkState", "Fetch.enable", "Fetch.disable",
    ]
    /// Commands that name a tab by its `targetId`.
    static let addressesTarget: Set<String> = [
        "Target.attachToTarget", "Target.activateTarget", "Target.closeTarget", "Target.getTargetInfo",
        "Target.detachFromTarget", "Browser.getWindowForTarget", "Target.autoAttachRelated",
    ]

    static let notShown = "No such tab for this run: each run sees only the tabs it opened."

    static func kept(_ url: String) -> String {
        "\(URL(string: url)?.host ?? "This tab") is kept for the director: a run without him does not open, see or touch it."
    }

    // MARK: Door

    var port: UInt16 { queue.sync { boundPort } }

    /// Opens the door on the loopback. Waits for it to be listening, briefly.
    @discardableResult
    func start(preferredPort: UInt16) -> UInt16 {
        let ready = DispatchSemaphore(value: 0)
        queue.async { self.listen(on: preferredPort, ready: ready) }
        _ = ready.wait(timeout: .now() + 3)
        return port
    }

    private func listen(on port: UInt16, ready: DispatchSemaphore) {
        // Bound to 127.0.0.1 itself: limiting the interface type alone still listened on every
        // address, and the door has nothing to say to the network.
        let parameters = NWParameters.tcp
        parameters.requiredInterfaceType = .loopback
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: NWEndpoint.Port(rawValue: port) ?? .any)
        parameters.allowLocalEndpointReuse = true
        guard let made = try? NWListener(using: parameters) else {
            if port != 0 { listen(on: 0, ready: ready) } else { ready.signal() }
            return
        }
        listener = made
        made.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
        made.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                self.boundPort = made.port?.rawValue ?? port
                ready.signal()
            case .failed:
                made.cancel()
                self.listener = nil
                if port != 0 { self.listen(on: 0, ready: ready) } else { ready.signal() }
            default:
                break
            }
        }
        made.start(queue: queue)
        startIdleWatch()
    }

    func stop() {
        queue.sync {
            listener?.cancel()
            listener = nil
            boundPort = 0
            idleTimer?.cancel()
            idleTimer = nil
            endEveryone()
            transport?.terminate()
            transport = nil
            forgetBrowser()
        }
    }

    // MARK: What Bulava tells it

    /// The runs that may use the browser now, by token. A run no longer among them loses its tabs.
    func setRuns(_ live: [Run]) {
        queue.async {
            self.runs = Dictionary(live.map { ($0.token, $0) }, uniquingKeysWith: { a, _ in a })
            for token in Array(self.clients.keys) where self.runs[token] == nil { self.end(token, closingTabs: true) }
        }
    }

    /// Sites closed to a run without the director, by host.
    func setBlocked(_ hosts: [String]) {
        queue.async {
            guard self.blocked != hosts else { return }
            self.blocked = hosts
            self.blockedChanged()
        }
    }

    /// Nil when runs may use the browser; otherwise why not — he is signing in, it is off. Every run
    /// is let go and the working browser stopped, so the profile is free for Chrome in its other mode.
    func setUnavailable(_ reason: String?) {
        let stopping: CDPTransport? = queue.sync {
            unavailable = reason
            guard reason != nil else { return nil }
            endEveryone()
            let running = transport
            transport = nil
            forgetBrowser()
            return running
        }
        // Waited for off the queue: the door keeps answering "unavailable" meanwhile.
        guard let stopping else { return }
        stopping.terminate()
        (stopping as? ChromePipe).map { _ = $0.waitForExit(seconds: 8) }
    }

    /// He took the browser back from every run using it.
    func endCurrentLease() { queue.async { self.endEveryone() } }

    /// One run lets go (`$IDIR/browser release`): its socket closes and the tabs it opened go. True
    /// when it was using the browser.
    func release(token: String) -> Bool {
        queue.sync {
            guard clients[token] != nil else { return false }
            end(token, closingTabs: true)
            return true
        }
    }

    /// The runs using the browser now, longest first.
    var leases: [Lease] { queue.sync { currentLeases() } }
    /// The run a token belongs to, while it may use the browser.
    func run(token: String) -> Run? { queue.sync { runs[token] } }
    /// Whether this run is using the browser now.
    func isUsing(token: String) -> Bool { queue.sync { clients[token] != nil } }
    var browserRunning: Bool { queue.sync { transport?.isRunning == true } }
    /// The tabs a run has open now. For tests and the status line.
    func tabs(of token: String) -> [String] {
        queue.sync { owner.filter { $0.value == token && targetTypes[$0.key] != "tab" }.map(\.key).sorted() }
    }

    private func currentLeases() -> [Lease] {
        clients.values.map { Lease(run: $0.run, since: $0.since, lastActivity: $0.lastActivity) }
            .sorted { $0.since < $1.since }
    }

    // MARK: Handshake

    private func accept(_ connection: NWConnection) {
        // The loopback only — the listener is bound there, and this says so again.
        if case .hostPort(let host, _) = connection.endpoint {
            let local: Bool = switch host {
            case .ipv4(let address): address.isLoopback
            case .ipv6(let address): address.isLoopback || address.asIPv4?.isLoopback == true
            case .name(let name, _): name == "localhost"
            @unknown default: false
            }
            guard local else { connection.cancel(); return }
        }
        let peer = WebSocketPeer(connection, queue: queue)
        peer.start { [weak self, weak peer] request in
            guard let self, let peer else { return WebSocketPeer.Refusal(status: 500, reason: "") }
            return self.decide(request, peer: peer)
        }
    }

    /// Who gets in. Runs on `queue`.
    private func decide(_ request: WebSocketPeer.Request, peer: WebSocketPeer) -> WebSocketPeer.Refusal? {
        // A web page can open a WebSocket to the loopback too; it always says where it came from,
        // and a run's client never does.
        if request.headers["origin"] != nil {
            return .init(status: 403, reason: "Not from a web page.")
        }
        let bearer = request.headers["authorization"].flatMap { value -> String? in
            let parts = value.split(separator: " ", maxSplits: 1)
            return parts.count == 2 && parts[0].lowercased() == "bearer" ? String(parts[1]) : nil
        }
        guard let token = bearer, let run = runs[token] else {
            return .init(status: 401, reason: "This run has no access to Bulava's browser.")
        }
        if let unavailable { return .init(status: 503, reason: unavailable) }
        if transport?.isRunning != true {
            guard startBrowser(quietly: false) else {
                return .init(status: 503, reason: "Bulava could not start its browser.")
            }
        }
        let now = Date()
        let client: Client
        if let existing = clients[token] {
            // The same run coming back (chrome-devtools-mcp reconnects by itself): its tabs are kept,
            // its old socket and the session that socket had go.
            client = existing
            if let old = client.peer, old !== peer { old.onClose = nil; old.close() }
            if let session = client.browserSession { dropBrowserSession(session) }
        } else {
            client = Client(run: run, now: now)
            clients[token] = client
        }
        client.generation += 1
        client.peer = peer
        client.browserSession = nil
        client.waiting = []
        client.lastActivity = now
        unusedSince = nil
        let generation = client.generation
        peer.onMessage = { [weak self, weak peer] data in
            guard let self, let peer else { return }
            self.fromClient(data, token: token, peer: peer)
        }
        peer.onClose = { [weak self] in
            guard let self, let client = self.clients[token], client.generation == generation else { return }
            client.peer = nil
            if let session = client.browserSession { self.dropBrowserSession(session) }
            client.browserSession = nil
            client.waiting = []
            self.queue.asyncAfter(deadline: .now() + self.reconnectGrace) {
                guard let again = self.clients[token], again.generation == generation, again.peer == nil else { return }
                self.end(token, closingTabs: true)
            }
        }
        command("Target.attachToBrowserTarget", [:]) { [weak self] answer in
            guard let self, let client = self.clients[token], client.generation == generation,
                  let session = (answer?["result"] as? [String: Any])?["sessionId"] as? String else { return }
            client.browserSession = session
            self.browserSessions[session] = token
            let waiting = client.waiting
            client.waiting = []
            for data in waiting { self.fromClient(data, token: token, peer: peer) }
        }
        // A run that has no tab yet gets a blank one: chrome-devtools-mcp has nothing to work in
        // until a page is selected, and it would otherwise see none at all.
        if !owner.values.contains(token) { openBlankTab(for: token) }
        onChange?(currentLeases())
        return nil
    }

    private func startBrowser(quietly: Bool) -> Bool {
        guard let make = (quietly ? makeQuietTransport : nil) ?? makeTransport, let started = try? make() else { return false }
        transport = started
        let made = ObjectIdentifier(started)
        started.listen(onMessage: { [weak self] data in
            self?.queue.async { self?.fromBrowser(data, transport: made) }
        }, onExit: { [weak self] in
            self?.queue.async { self?.browserExited(made) }
        })
        watch()
        if clients.isEmpty { unusedSince = Date() }
        return true
    }

    // MARK: Bulava's own errands

    /// Opens `url` in a tab of Bulava's own — no run sees it — waits for the page to settle, and says
    /// where it ended up; then closes the tab. Nil when the browser is not available. Used to see
    /// whether he is still signed in to a site, which also keeps a sign-in that lasts while it is used.
    func visit(_ url: URL, settle: TimeInterval = 8, then: @escaping @Sendable (URL?) -> Void) {
        queue.async {
            guard self.unavailable == nil else { return then(nil) }
            if self.transport?.isRunning != true, !self.startBrowser(quietly: true) { return then(nil) }
            // Answered exactly once, whatever happens: the page settles, the browser stops or dies,
            // or nothing answers in time. A visit left unanswered held the sign-in check open for
            // ever, and with it every check after it.
            let id = UUID()
            self.visits[id] = then
            self.queue.asyncAfter(deadline: .now() + settle + self.visitTimeout) { self.finishVisit(id, nil) }
            self.command("Target.createTarget", ["url": url.absoluteString, "background": true]) { [weak self] answer in
                guard let self else { return then(nil) }
                guard let target = (answer?["result"] as? [String: Any])?["targetId"] as? String else {
                    return self.finishVisit(id, nil)
                }
                self.queue.asyncAfter(deadline: .now() + settle) {
                    guard self.visits[id] != nil else { return }
                    let landed = self.targetURLs[target].flatMap(URL.init(string:))
                    self.command("Target.closeTarget", ["targetId": target])
                    self.finishVisit(id, landed)
                }
            }
        }
    }

    /// How long a visit may take beyond its settling time before it is answered with nothing.
    var visitTimeout: TimeInterval = 15
    private var visits: [UUID: @Sendable (URL?) -> Void] = [:]

    private func finishVisit(_ id: UUID, _ landed: URL?) {
        visits.removeValue(forKey: id)?(landed)
    }

    /// Quits the browser now if no run is using it — after Bulava's own errands, rather than leaving
    /// it open for `idleLimit`.
    func quitIfUnused() {
        queue.async {
            guard self.clients.isEmpty, let running = self.transport else { return }
            self.transport = nil
            self.forgetBrowser()
            self.unusedSince = nil
            running.terminate()
            self.onChange?([])
        }
    }

    private func openBlankTab(for token: String) {
        creating += 1
        command("Target.createTarget", ["url": "about:blank", "background": true]) { [weak self] answer in
            guard let self else { return }
            self.creating -= 1
            if let target = (answer?["result"] as? [String: Any])?["targetId"] as? String {
                if self.clients[token] != nil { self.claim(target, for: token) }
                else { self.command("Target.closeTarget", ["targetId": target]) }
            }
            self.resolveHeld()
        }
    }

    // MARK: From a run

    private func fromClient(_ data: Data, token: String, peer: WebSocketPeer) {
        guard let client = clients[token], client.peer === peer, let transport, transport.isRunning else { return }
        guard let browserSession = client.browserSession else { client.waiting.append(data); return }
        guard let message = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let id = message["id"] as? Int, let method = message["method"] as? String else { return }
        client.lastActivity = Date()
        let session = message["sessionId"] as? String
        let params = message["params"] as? [String: Any] ?? [:]
        if let why = refusal(method: method, params: params, session: session, client: client) {
            return refuse(id, session: session, why, peer: peer)
        }
        var out = message
        let rooted = session == nil
        if rooted { out["sessionId"] = browserSession }
        if method == "Target.createTarget" {
            creating += 1
            // Into the default context unless the run made one of its own: that is where the
            // sign-ins are.
            if var p = out["params"] as? [String: Any], let context = p["browserContextId"] as? String,
               !client.contexts.contains(context) {
                p["browserContextId"] = nil
                out["params"] = p
            }
        }
        let upstream = nextID
        nextID += 1
        pending[upstream] = Pending(token: token, generation: client.generation, id: id, method: method,
                                    rooted: rooted, target: params["targetId"] as? String)
        out["id"] = upstream
        guard let bytes = try? JSONSerialization.data(withJSONObject: out) else { return }
        transport.send(bytes)
    }

    private func refuse(_ id: Int, session: String?, _ why: String, peer: WebSocketPeer) {
        var error: [String: Any] = ["id": id, "error": ["code": -32000, "message": why]]
        if let session { error["sessionId"] = session }
        if let reply = try? JSONSerialization.data(withJSONObject: error) { peer.send(reply) }
    }

    /// A run without the director, with sites he keeps for himself: everything below checks it.
    private func guarded(_ client: Client) -> Bool { client.run.unattended && !blocked.isEmpty }

    /// Why a command is not passed on, or nil.
    private func refusal(method: String, params: [String: Any], session: String?, client: Client) -> String? {
        let token = client.run.token
        if Self.forbidden.contains(method) { return "Bulava's browser does not allow \(method)." }
        if let session, sessionOwner[session] != token || hidden.contains(session) || taken.contains(session) {
            return "No such session."
        }
        if Self.addressesTarget.contains(method) || method == "Target.createTarget" {
            if let target = params["targetId"] as? String, !owns(target, token) { return Self.notShown }
        }
        if method == "Target.detachFromTarget", let target = params["sessionId"] as? String, sessionOwner[target] != token {
            return "No such session."
        }
        if method == "Target.disposeBrowserContext", let context = params["browserContextId"] as? String,
           !client.contexts.contains(context) {
            return "Not this run's context."
        }
        guard guarded(client) else { return nil }
        if Self.guarding.contains(method) {
            return "\(method) is not available to a run working without the director."
        }
        // Any address in what is asked — a page to open, an origin whose storage to read, a frame's
        // resource — on one of his sites.
        if let url = Self.addresses(in: params).first(where: isBlocked) {
            return Self.kept(url.absoluteString)
        }
        return nil
    }

    private func owns(_ target: String, _ token: String) -> Bool {
        if owner[target] == token { return true }
        if let page = tabPage[target], owner[page] == token { return true }
        if let tab = pageTab[target], owner[tab] == token { return true }
        return false
    }

    func isBlocked(_ url: URL) -> Bool { BrowserSite.covers(url, anyOf: blocked) }
    private func isBlocked(_ text: String) -> Bool { URL(string: text).map(isBlocked) ?? false }

    /// Where he has to sign in himself when a driven tab is at `url`, or nil when it is not such a
    /// page. Google's sign-in — every page on accounts.google.com, the "Couldn't sign you in" one
    /// included — refuses a browser a program controls (`navigator.webdriver` is true under
    /// `--remote-debugging-pipe`), whatever is typed into it. The page the sign-in was for
    /// (`continue`) is where he goes, when it names one on the web; Google asks him to sign in there.
    static func signInOnlyHeCanDo(_ url: URL) -> URL? {
        guard url.scheme?.lowercased() == "https", url.host?.lowercased() == "accounts.google.com" else { return nil }
        let after = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?
            .first { $0.name == "continue" }?.value.flatMap(URL.init(string:))
        if let after, after.scheme?.lowercased() == "https", after.host != nil { return after }
        return URL(string: "https://accounts.google.com/")
    }

    /// Every string in a command's parameters that reads as a web address or an origin.
    static func addresses(in value: Any) -> [URL] {
        switch value {
        case let text as String:
            guard text.count < 4096, let url = URL(string: text), let scheme = url.scheme?.lowercased(),
                  ["http", "https", "ws", "wss"].contains(scheme), url.host != nil else { return [] }
            return [url]
        case let list as [Any]: return list.flatMap { addresses(in: $0) }
        case let object as [String: Any]: return object.values.flatMap { addresses(in: $0) }
        default: return []
        }
    }

    // MARK: From the browser

    private func fromBrowser(_ data: Data, transport made: ObjectIdentifier) {
        guard let transport, ObjectIdentifier(transport) == made else { return }
        // An answer to a run's command on one of its pages: only its id changes on the way back, so
        // a screenshot's megabytes are not parsed and written again to change it.
        if let upstream = Self.leadingID(data), own.contains(upstream) == false,
           let request = pending[upstream], !request.rooted, !Self.special(request.method) {
            pending[upstream] = nil
            deliver(Self.replacingLeadingID(data, with: request.id), to: request)
            return
        }
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return }
        if let upstream = object["id"] as? Int { answered(upstream, object) ; return }
        event(object, raw: data)
    }

    /// Answers Bulava reads before passing on.
    private static func special(_ method: String) -> Bool {
        method.hasPrefix("Target.") || method == "Browser.getWindowForTarget"
    }

    private func deliver(_ data: Data, to request: Pending) {
        guard let client = clients[request.token], client.generation == request.generation, let peer = client.peer else { return }
        peer.send(data)
    }

    private func answered(_ upstream: Int, _ object: [String: Any]) {
        if own.remove(upstream) != nil {
            ownCallbacks.removeValue(forKey: upstream)?(object)
            return
        }
        guard let request = pending.removeValue(forKey: upstream) else { return }
        var reply = object
        reply["id"] = request.id
        if request.rooted { reply["sessionId"] = nil }
        var result = reply["result"] as? [String: Any]
        switch request.method {
        case "Target.createTarget":
            creating -= 1
            if let target = result?["targetId"] as? String { claim(target, for: request.token) }
            resolveHeld()
        case "Target.attachToTarget":
            if let session = result?["sessionId"] as? String, let target = request.target {
                give(session, to: request.token, target: target, parent: nil)
            }
        case "Target.getTargets":
            if let infos = result?["targetInfos"] as? [[String: Any]] {
                for info in infos { remember(info) }
                result?["targetInfos"] = infos.filter { info in
                    (info["targetId"] as? String).map { owns($0, request.token) } ?? false
                }
                reply["result"] = result
            }
        case "Target.createBrowserContext":
            if let context = result?["browserContextId"] as? String { clients[request.token]?.contexts.insert(context) }
        case "Target.getBrowserContexts":
            let mine = clients[request.token]?.contexts ?? []
            if let ids = result?["browserContextIds"] as? [String] {
                result?["browserContextIds"] = ids.filter { mine.contains($0) }
                reply["result"] = result
            }
        default:
            break
        }
        guard let data = try? JSONSerialization.data(withJSONObject: reply) else { return }
        deliver(data, to: request)
    }

    private func event(_ object: [String: Any], raw: Data) {
        let method = object["method"] as? String ?? ""
        let params = object["params"] as? [String: Any] ?? [:]
        guard let session = object["sessionId"] as? String else { return }   // the pipe's own root: nobody's

        // Bulava's watcher, and the tabs it watches.
        if session == observer { return observed(method, params) }
        if let tab = observerSessions[session] { return observedInTab(tab, method, params) }

        // A run's browser session: what it hears at its root.
        if let token = browserSessions[session] { return atRoot(token, method, params, object) }

        if hidden.contains(session) {
            if method == "Target.detachedFromTarget" { hidden.remove(session) }
            return
        }
        // Held until it is known whose this tab is.
        if var waiting = held[session] {
            waiting.messages.append(object)
            held[session] = waiting
            return
        }
        guard let token = sessionOwner[session] else { return }
        switch method {
        case "Target.attachedToTarget":
            if let child = params["sessionId"] as? String {
                let info = params["targetInfo"] as? [String: Any] ?? [:]
                remember(info)
                give(child, to: token, target: info["targetId"] as? String, parent: session)
            }
        case "Target.detachedFromTarget":
            if let child = params["sessionId"] as? String { forget(child); taken.remove(child) }
        default:
            break
        }
        send(object, to: token)
    }

    /// A message to a run, as Chrome wrote it.
    private func send(_ object: [String: Any], to token: String) {
        guard let peer = clients[token]?.peer, let data = try? JSONSerialization.data(withJSONObject: object) else { return }
        peer.send(data)
    }

    /// An event at a run's root: everything about a target it does not own stays here.
    private func atRoot(_ token: String, _ method: String, _ params: [String: Any], _ object: [String: Any]) {
        var plain = object
        plain["sessionId"] = nil
        switch method {
        case "Target.attachedToTarget":
            guard let child = params["sessionId"] as? String, let info = params["targetInfo"] as? [String: Any],
                  let target = info["targetId"] as? String else { return }
            remember(info)
            switch whose(target) {
            case .some(let who) where who == token:
                give(child, to: token, target: target, parent: nil)
                send(plain, to: token)
            case .some:
                letGo(child, waiting: params["waitingForDebugger"] as? Bool ?? false, under: token)
            case .none:
                held[child] = Held(token: token, session: child, target: target, messages: [plain], since: Date())
            }
        case "Target.detachedFromTarget":
            guard let child = params["sessionId"] as? String else { return }
            if held.removeValue(forKey: child) != nil { return }
            if hidden.remove(child) != nil { return }
            guard sessionOwner[child] == token else { return }
            forget(child)
            taken.remove(child)
            send(plain, to: token)
        case "Target.targetCreated", "Target.targetInfoChanged", "Target.targetDestroyed":
            let info = params["targetInfo"] as? [String: Any]
            if let info { remember(info) }
            guard let target = (info?["targetId"] as? String) ?? (params["targetId"] as? String) else { return }
            switch whose(target) {
            case .some(let who) where who == token: send(plain, to: token)
            case .some: break
            case .none:
                if method == "Target.targetDestroyed" { heldDiscovery[target] = nil; return }
                heldDiscovery[target, default: []].append((token, plain))
            }
        default:
            send(plain, to: token)
        }
    }

    /// Whose a target is: a run's token, "" for nobody's, or nil while it cannot be told yet.
    private func whose(_ target: String) -> String?? {
        if let who = owner[target] { return .some(who) }
        if let page = tabPage[target] {
            if let who = owner[page] { owner[target] = who; return .some(who) }
            if let opener = openers[page], let who = owner[opener] ?? pageTab[opener].flatMap({ owner[$0] }) {
                claim(page, for: who)
                return .some(who)
            }
            return creating > 0 ? .none : .some("")
        }
        if let tab = pageTab[target], let who = owner[tab] { return .some(who) }
        switch targetTypes[target] {
        case "tab":
            return .none                             // its page is not known yet
        case "page":
            if let opener = openers[target], let who = owner[opener] ?? pageTab[opener].flatMap({ owner[$0] }) {
                claim(target, for: who)
                return .some(who)
            }
            return creating > 0 ? .none : .some("")
        default:
            return .some("")                         // workers, extensions, the browser's own UI
        }
    }

    /// A tab the browser attached for a run that is not that run's: let it run, and let go of it.
    private func letGo(_ child: String, waiting: Bool, under token: String, maybeLater target: String? = nil) {
        guard let browserSession = clients[token]?.browserSession else { return }
        hidden.insert(child)
        // Let go only because nobody knew yet whose it was: if it turns out to be this run's, it is
        // attached again (`claim`).
        if let target, targetTypes[target] == "tab" { hiddenTabs.insert(target) }
        if waiting { command("Runtime.runIfWaitingForDebugger", [:], session: child) }
        command("Target.detachFromTarget", ["sessionId": child], session: browserSession)
    }

    /// Tabs held for an owner are handed over, or let go, as soon as it is known whose they are —
    /// or once they have waited long enough to be nobody's.
    private func resolveHeld(now: Date = Date()) {
        for (session, waiting) in held {
            let answer = whose(waiting.target)
            let late = now.timeIntervalSince(waiting.since) > claimWait
            switch answer {
            case .some(let who) where who == waiting.token:
                held[session] = nil
                give(session, to: waiting.token, target: waiting.target, parent: nil)
                for message in waiting.messages { send(message, to: waiting.token) }
            case .some:
                held[session] = nil
                letGo(session, waiting: true, under: waiting.token)
            case .none where late:
                held[session] = nil
                letGo(session, waiting: true, under: waiting.token, maybeLater: waiting.target)
            case .none:
                break
            }
        }
        for (target, events) in heldDiscovery {
            switch whose(target) {
            case .some(let who):
                heldDiscovery[target] = nil
                for (token, event) in events where token == who { send(event, to: token) }
            case .none:
                break
            }
        }
    }

    /// A target is now this run's. If the browser already attached it for the run and it was let
    /// go while nobody knew whose it was, it is attached again.
    private func claim(_ target: String, for token: String) {
        owner[target] = token
        if let tab = pageTab[target] { owner[tab] = token }
        if let page = tabPage[target] { owner[page] = token }
        guard let client = clients[token], let browserSession = client.browserSession else { return }
        let tab = pageTab[target] ?? target
        let attached = sessionTarget.contains { $0.value == tab && sessionOwner[$0.key] == token }
            || held.values.contains { $0.target == tab && $0.token == token }
        // Only a tab that was let go needs attaching again; a new one is attached by the browser.
        if !attached, targetTypes[tab] == "tab", hiddenTabs.contains(tab) {
            hiddenTabs.remove(tab)
            command("Target.attachToTarget", ["targetId": tab, "flatten": true], session: browserSession)
        }
    }
    private var hiddenTabs: Set<String> = []

    private func give(_ session: String, to token: String, target: String?, parent: String?) {
        sessionOwner[session] = token
        if let target { sessionTarget[session] = target }
        if let parent { sessionParent[session] = parent }
        // A page of a run without him: his sites are closed on it before it can do anything there.
        if let target, targetTypes[target] == "page", clients[token]?.run.unattended == true { applyRules(to: session) }
    }

    private func forget(_ session: String) {
        sessionOwner[session] = nil
        sessionTarget[session] = nil
        sessionParent[session] = nil
        for (child, parent) in sessionParent where parent == session { forget(child) }
    }

    private func remember(_ info: [String: Any]) {
        guard let target = info["targetId"] as? String else { return }
        if let type = info["type"] as? String { targetTypes[target] = type }
        if let url = info["url"] as? String {
            targetURLs[target] = url
            noticeSignIn(target, url)
            takeIfKept(target, url)
        }
        if let opener = info["openerId"] as? String { openers[target] = opener }
    }

    // MARK: Bulava's watcher

    private func watch() {
        command("Target.attachToBrowserTarget", [:]) { [weak self] answer in
            guard let self, let session = (answer?["result"] as? [String: Any])?["sessionId"] as? String else { return }
            self.observer = session
            self.command("Target.setDiscoverTargets", ["discover": true], session: session)
            self.command("Target.setAutoAttach", ["autoAttach": true, "waitForDebuggerOnStart": false, "flatten": true,
                                                  "filter": [["type": "tab"], ["exclude": true]]], session: session)
        }
    }

    private func observed(_ method: String, _ params: [String: Any]) {
        switch method {
        case "Target.attachedToTarget":
            guard let session = params["sessionId"] as? String,
                  let info = params["targetInfo"] as? [String: Any], let tab = info["targetId"] as? String else { return }
            remember(info)
            observerSessions[session] = tab
            command("Target.setAutoAttach", ["autoAttach": true, "waitForDebuggerOnStart": false, "flatten": true,
                                            "filter": [["type": "page"], ["exclude": true]]], session: session)
        case "Target.detachedFromTarget":
            if let session = params["sessionId"] as? String, let tab = observerSessions.removeValue(forKey: session) {
                gone(tab)
            }
        case "Target.targetCreated", "Target.targetInfoChanged":
            if let info = params["targetInfo"] as? [String: Any] { remember(info) }
            resolveHeld()
        case "Target.targetDestroyed":
            if let target = params["targetId"] as? String { gone(target) }
        default:
            break
        }
    }

    private func observedInTab(_ tab: String, _ method: String, _ params: [String: Any]) {
        guard method == "Target.attachedToTarget", let info = params["targetInfo"] as? [String: Any],
              let page = info["targetId"] as? String else { return }
        remember(info)
        tabPage[tab] = page
        pageTab[page] = tab
        if let who = owner[page] { owner[tab] = who } else if let who = owner[tab] { owner[page] = who }
        resolveHeld()
    }

    private func gone(_ target: String) {
        if let page = tabPage.removeValue(forKey: target) { pageTab[page] = nil; owner[page] = nil; targetURLs[page] = nil }
        if let tab = pageTab.removeValue(forKey: target) { tabPage[tab] = nil }
        owner[target] = nil
        targetURLs[target] = nil
        targetTypes[target] = nil
        openers[target] = nil
        hiddenTabs.remove(target)
        heldDiscovery[target] = nil
    }

    // MARK: His sites, and his sign-ins

    private func noticeSignIn(_ target: String, _ url: String) {
        guard let who = owner[target] ?? pageTab[target].flatMap({ owner[$0] }), let client = clients[who],
              targetTypes[target] != "tab", let page = URL(string: url),
              let address = Self.signInOnlyHeCanDo(page),
              client.signInsTold.insert(target + " " + (address.host ?? "")).inserted else { return }
        onSignInNeeded?(address, client.run)
    }

    /// A tab of a run without him that is now on one of his sites is taken from it.
    private func takeIfKept(_ target: String, _ url: String) {
        guard let who = owner[target], let client = clients[who], guarded(client), isBlocked(url) else { return }
        let tab = pageTab[target] ?? target
        for (session, on) in sessionTarget where (on == target || on == tab) && sessionOwner[session] == who {
            detach(session)
        }
        owner[target] = nil
        owner[tab] = nil
        if let page = tabPage[tab] { owner[page] = nil }
    }

    private func applyRules(to session: String) {
        let rules = blocked.map { ["urlPattern": BrowserSite.pattern(for: $0), "offline": true, "latency": 0, "downloadThroughput": -1, "uploadThroughput": -1] as [String: Any] }
        command("Network.emulateNetworkConditionsByRule",
                ["offline": !rules.isEmpty, "matchedNetworkConditions": rules], session: session)
    }

    /// Takes a tab from the run: Chrome tells the run it is gone, and until then nothing more passes.
    private func detach(_ session: String) {
        guard !taken.contains(session) else { return }
        let parent = sessionParent[session] ?? sessionOwner[session].flatMap { clients[$0]?.browserSession }
        taken.insert(session)
        command("Target.detachFromTarget", ["sessionId": session], session: parent)
    }

    /// He changed which sites a run without him may use: the rule on every page such a run has is set
    /// again, and its tabs now on a closed site are taken from it.
    private func blockedChanged() {
        for (session, token) in sessionOwner where clients[token]?.run.unattended == true {
            if let target = sessionTarget[session], targetTypes[target] == "page" { applyRules(to: session) }
        }
        for (target, url) in targetURLs { takeIfKept(target, url) }
    }

    // MARK: Ending

    /// A run stops using the browser: its socket closes, its session goes, and — when it is not
    /// coming back — the tabs it opened are closed.
    private func end(_ token: String, closingTabs: Bool) {
        guard let client = clients.removeValue(forKey: token) else { return }
        if let peer = client.peer { client.peer = nil; peer.onClose = nil; peer.close(code: 1001) }
        if let session = client.browserSession { dropBrowserSession(session) }
        held = held.filter { $0.value.token != token }
        for (target, events) in heldDiscovery { heldDiscovery[target] = events.filter { $0.token != token } }
        if closingTabs {
            let mine = Set(owner.filter { $0.value == token }.map(\.key))
            // A page closes its tab; a tab whose page is not known yet is closed by itself.
            var closing: Set<String> = []
            for target in mine {
                if targetTypes[target] == "tab" { closing.insert(tabPage[target] ?? target) }
                else if let tab = pageTab[target], mine.contains(tab) { closing.insert(target) }
                else { closing.insert(target) }
            }
            for target in closing { command("Target.closeTarget", ["targetId": target]) }
            for target in mine { owner[target] = nil }
        }
        if clients.isEmpty { unusedSince = Date() }
        onChange?(currentLeases())
    }

    /// Chrome detaches everything a browser session had when the session goes; Bulava forgets it too.
    private func dropBrowserSession(_ session: String) {
        let token = browserSessions.removeValue(forKey: session)
        command("Target.detachFromTarget", ["sessionId": session])
        guard let token else { return }
        for (child, who) in sessionOwner where who == token { forget(child) }
        held = held.filter { $0.value.token != token }
    }

    private func endEveryone() {
        for token in Array(clients.keys) { end(token, closingTabs: false) }
    }

    private func forgetBrowser() {
        // The browser is gone: every visit still waiting for it is answered now, with nothing.
        for id in Array(visits.keys) { finishVisit(id, nil) }
        owner.removeAll(); tabPage.removeAll(); pageTab.removeAll(); targetURLs.removeAll(); targetTypes.removeAll()
        openers.removeAll(); sessionOwner.removeAll(); sessionTarget.removeAll(); sessionParent.removeAll()
        browserSessions.removeAll(); hidden.removeAll(); taken.removeAll(); observer = nil; observerSessions.removeAll()
        held.removeAll(); heldDiscovery.removeAll(); pending.removeAll(); own.removeAll(); ownCallbacks.removeAll()
        hiddenTabs.removeAll(); creating = 0
    }

    private func browserExited(_ made: ObjectIdentifier) {
        guard let transport, ObjectIdentifier(transport) == made else { return }
        self.transport = nil
        // Every run's socket is closed, so its client knows at once and reconnects — to a browser
        // started afresh — rather than going on with tabs that are no longer there ("Target closed").
        for client in clients.values {
            if let peer = client.peer { client.peer = nil; peer.onClose = nil; peer.close(code: 1011) }
        }
        clients.removeAll()
        forgetBrowser()
        unusedSince = Date()
        onChange?([])
    }

    /// A command of Bulava's own; its answer is not passed on, but may be read.
    private func command(_ method: String, _ params: [String: Any], session: String? = nil,
                         then: (([String: Any]?) -> Void)? = nil) {
        guard let transport else { then?(nil); return }
        let id = nextID
        nextID += 1
        own.insert(id)
        if let then { ownCallbacks[id] = then }
        var message: [String: Any] = ["id": id, "method": method, "params": params]
        if let session { message["sessionId"] = session }
        if let data = try? JSONSerialization.data(withJSONObject: message) { transport.send(data) }
    }

    // MARK: Time

    private func startIdleWatch() {
        idleTimer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 1, repeating: 1)
        timer.setEventHandler { [weak self] in self?.tick(now: Date()) }
        timer.resume()
        idleTimer = timer
    }

    private func tick(now: Date) {
        if !held.isEmpty || !heldDiscovery.isEmpty { resolveHeld(now: now) }
        // Quit when nobody has used it for a while: a browser left open for nobody is what he saw
        // after the work was done.
        if clients.isEmpty, let since = unusedSince, now.timeIntervalSince(since) > idleLimit, let running = transport {
            transport = nil
            forgetBrowser()
            unusedSince = nil
            running.terminate()
            onChange?([])
        }
    }

    /// Lets a test move the clock.
    func checkIdle(now: Date) { queue.sync { tick(now: now) } }

    // MARK: Ids

    /// Chrome writes an answer as `{"id":N,…}`; only that number changes on the way back, so a
    /// screenshot's megabytes are not parsed and written again to change it.
    static func leadingID(_ data: Data) -> Int? {
        let prefix = Array(data.prefix(24))
        let head: [UInt8] = Array(#"{"id":"#.utf8)
        guard prefix.count > head.count, Array(prefix[0..<head.count]) == head else { return nil }
        var value = 0, i = head.count, digits = 0
        while i < prefix.count, let d = prefix[i] >= 48 && prefix[i] <= 57 ? Int(prefix[i] - 48) : nil {
            value = value * 10 + d; i += 1; digits += 1
        }
        guard digits > 0, i < prefix.count, prefix[i] == UInt8(ascii: ",") || prefix[i] == UInt8(ascii: "}") else { return nil }
        return value
    }

    static func replacingLeadingID(_ data: Data, with id: Int) -> Data {
        let head = Data(#"{"id":"#.utf8)
        var digits = head.count
        while digits < data.count, data[data.startIndex + digits] >= 48, data[data.startIndex + digits] <= 57 { digits += 1 }
        return head + Data(String(id).utf8) + data.dropFirst(digits)
    }
}
