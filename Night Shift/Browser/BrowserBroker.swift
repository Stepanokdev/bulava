import Foundation
import Network

/// The one door to the account browser: a WebSocket on this Mac's loopback that a run's
/// chrome-devtools-mcp connects to, and behind it the pipe to Chrome only Bulava holds.
///
/// Every run that may use it has a token of its own (the engine writes it into the run's folder
/// and its MCP config). The door is open to one run at a time — the lease — because two runs on one
/// browser see and steer each other's tabs. Another run asking meanwhile is told so at once
/// (`423`), never queued behind a socket. A lease ends when its run lets go, ends, goes quiet for
/// `idleLimit`, or the director takes the browser to sign in somewhere.
///
/// A lease ending is more than a closed socket: chrome-devtools-mcp reconnects by itself, so the
/// old holder is turned away at the next handshake unless the lease is free again, and what it
/// left attached in Chrome — its sessions, its auto-attach — is undone before the next run comes.
///
/// It also keeps what the run's own client should not decide. A run working without the director
/// does not get the sites he keeps for himself (`blocked`): his tabs already open on them are not
/// in its lists or events, cannot be attached to, shown, closed or read — Bulava looks up what a tab
/// holds before passing on any command that names one, and lets go of a tab the browser attached
/// for the run on its own; no address of his sites passes in any command, storage included; every
/// page the run does have is closed to those sites at the network; and a site he closes while the
/// run has the browser is taken from it at once. No run reads cookies or closes the browser.
nonisolated final class BrowserBroker: @unchecked Sendable {

    struct Run: Sendable, Equatable {
        var token: String
        var slug: String
        /// What he would call it: the chat's name, or the project's.
        var title: String
        var unattended: Bool
    }

    struct Lease: Sendable, Equatable {
        var run: Run
        var since: Date
        var lastActivity: Date
    }

    let queue = DispatchQueue(label: "bulava.account-browser")
    var idleLimit: TimeInterval = 300
    /// How long a lease stays its run's after the socket closes: chrome-devtools-mcp reconnects at
    /// once, and another run should not slip in between.
    var reconnectGrace: TimeInterval = 5
    /// Starts the browser for work when a lease needs it.
    var makeTransport: (@Sendable () throws -> CDPTransport)?
    /// The lease changed, or the browser stopped. Called on `queue`.
    var onChange: (@Sendable (Lease?) -> Void)?
    /// A tab of the run's reached a sign-in only he can do here: Google refuses to sign in to a
    /// browser a program is driving — and this one is driven — so he has to, in Chrome with nobody
    /// at the wheel. The address to sign in at, and the run that holds the browser — only while one
    /// does: a page no run is driving asks him for nothing. Once per tab and address. Called on `queue`.
    var onSignInNeeded: (@Sendable (URL, Run) -> Void)?

    private var listener: NWListener?
    private var boundPort: UInt16 = 0
    private var runs: [String: Run] = [:]
    /// Sites a run without the director may not open, by host (a host covers its subdomains).
    private var blocked: [String] = []
    private var unavailable: String?
    private var transport: CDPTransport?
    private var peer: WebSocketPeer?
    private var lease: Lease?
    private var idleTimer: DispatchSourceTimer?

    private struct Pending { var peer: ObjectIdentifier; var id: Int; var method: String; var target: String?; var session: String? }
    private var nextID = 1
    private var pending: [Int: Pending] = [:]
    private var own: Set<Int> = []
    private var ownCallbacks: [Int: ([String: Any]?) -> Void] = [:]
    /// Sessions the run has, which tab each is, and the session it was attached under.
    private var sessions: Set<String> = []
    private var sessionTargets: [String: String] = [:]
    private var sessionParents: [String: String] = [:]
    /// Sessions the browser opened on his tabs that the run never hears of.
    private var hidden: Set<String> = []
    /// What each tab shows, as last heard.
    private var targetURLs: [String: String] = [:]
    /// Tabs and addresses already said to need him (`onSignInNeeded`) in this lease, so a page that
    /// reloads is not news again. A lease's own: the next run in the same tab is asked for afresh.
    private var signInsTold: Set<String> = []

    /// What no run may ask of the account browser.
    static let forbidden: Set<String> = [
        "Browser.close", "Browser.crash", "Browser.crashGpuProcess",
        "Storage.getCookies", "Network.getAllCookies", "Network.getCookies",
    ]
    /// What would lift the rule that keeps a run without the director off his own sites.
    static let guarding: Set<String> = [
        "Network.emulateNetworkConditionsByRule", "Network.emulateNetworkConditions",
        "Network.overrideNetworkState", "Fetch.enable", "Fetch.disable",
    ]

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
            endLease()
            transport?.terminate()
            transport = nil
        }
    }

    // MARK: What Bulava tells it

    /// The runs that may use the browser now, by token. A lease whose run is no longer among them ends.
    func setRuns(_ live: [Run]) {
        queue.async {
            self.runs = Dictionary(live.map { ($0.token, $0) }, uniquingKeysWith: { a, _ in a })
            if let held = self.lease, self.runs[held.run.token] == nil { self.endLease() }
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

    /// Nil when runs may have the browser; otherwise why not — he is signing in, it is off. Ends a
    /// lease and stops the working browser, so the profile is free for Chrome in its other mode.
    func setUnavailable(_ reason: String?) {
        let stopping: CDPTransport? = queue.sync {
            unavailable = reason
            guard reason != nil else { return nil }
            endLease()
            let running = transport
            transport = nil
            return running
        }
        // Waited for off the queue: the door keeps answering "unavailable" meanwhile.
        guard let stopping else { return }
        stopping.terminate()
        (stopping as? ChromePipe).map { _ = $0.waitForExit(seconds: 8) }
    }

    /// He took the browser back from whoever has it.
    func endCurrentLease() { queue.async { self.endLease() } }

    /// One run lets go (`$IDIR/browser release`). True when it held the lease.
    func release(token: String) -> Bool {
        queue.sync {
            guard lease?.run.token == token else { return false }
            endLease()
            return true
        }
    }

    var currentLease: Lease? { queue.sync { lease } }
    /// The run a token belongs to, while it may use the browser.
    func run(token: String) -> Run? { queue.sync { runs[token] } }
    var browserRunning: Bool { queue.sync { transport?.isRunning == true } }

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
        if let held = lease, held.run.token != token {
            return .init(status: 423, reason: "Bulava's browser is busy: \(held.run.title) has it.")
        }
        if transport?.isRunning != true {
            guard let make = makeTransport, let started = try? make() else {
                return .init(status: 503, reason: "Bulava could not start its browser.")
            }
            transport = started
            let made = ObjectIdentifier(started)
            started.listen(onMessage: { [weak self] data in
                self?.queue.async { self?.fromBrowser(data, transport: made) }
            }, onExit: { [weak self] in
                self?.queue.async { self?.browserExited(made) }
            })
        }
        // The same run coming back (chrome-devtools-mcp reconnects by itself): its old socket goes.
        if let old = self.peer, old !== peer { old.onClose = nil; old.close(); cleanUp() }
        self.peer = peer
        let now = Date()
        lease = Lease(run: run, since: lease?.since ?? now, lastActivity: now)
        peer.onMessage = { [weak self, weak peer] data in
            guard let self, let peer else { return }
            self.fromClient(data, peer: peer)
        }
        peer.onClose = { [weak self, weak peer] in
            guard let self, let peer, self.peer === peer else { return }
            self.peer = nil
            self.cleanUp()
            let token = run.token
            self.queue.asyncAfter(deadline: .now() + self.reconnectGrace) {
                if self.peer == nil, self.lease?.run.token == token { self.endLease() }
            }
        }
        onChange?(lease)
        return nil
    }

    // MARK: Relay

    /// A run without the director, with sites he keeps for himself: everything below checks it.
    private var guarded: Bool { lease?.run.unattended == true && !blocked.isEmpty }

    private func fromClient(_ data: Data, peer: WebSocketPeer) {
        guard let transport, transport.isRunning,
              let message = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let id = message["id"] as? Int, let method = message["method"] as? String else { return }
        lease?.lastActivity = Date()
        let session = message["sessionId"] as? String
        let params = message["params"] as? [String: Any]
        if let why = refusal(method: method, params: params, session: session) {
            return refuse(id, session: session, why, peer: peer)
        }
        // A command about one tab: what is in that tab now is looked up first, by Bulava itself,
        // and a tab on one of his sites is not the run's to attach to, show, close or read.
        if guarded, Self.addressesTarget.contains(method), let target = params?["targetId"] as? String {
            command("Target.getTargetInfo", ["targetId": target]) { [weak self, weak peer] answer in
                guard let self, let peer, self.peer === peer else { return }
                let info = (answer?["result"] as? [String: Any])?["targetInfo"] as? [String: Any]
                let url = info?["url"] as? String ?? ""
                self.targetURLs[target] = url
                if info == nil || self.isBlocked(url) {
                    // Said without its address: the run does not learn which of his tabs are open.
                    self.refuse(id, session: session, Self.notShown, peer: peer)
                } else {
                    self.forward(message, id: id, method: method, peer: peer)
                }
            }
            return
        }
        forward(message, id: id, method: method, peer: peer)
    }

    private func forward(_ message: [String: Any], id: Int, method: String, peer: WebSocketPeer) {
        guard let transport else { return }
        var message = message
        let upstream = nextID
        nextID += 1
        pending[upstream] = Pending(peer: ObjectIdentifier(peer), id: id, method: method,
                                    target: (message["params"] as? [String: Any])?["targetId"] as? String,
                                    session: message["sessionId"] as? String)
        message["id"] = upstream
        guard let out = try? JSONSerialization.data(withJSONObject: message) else { return }
        transport.send(out)
    }

    private func refuse(_ id: Int, session: String?, _ why: String, peer: WebSocketPeer) {
        var error: [String: Any] = ["id": id, "error": ["code": -32000, "message": why]]
        if let session { error["sessionId"] = session }
        if let reply = try? JSONSerialization.data(withJSONObject: error) { peer.send(reply) }
    }

    /// Commands that name a tab by its `targetId`.
    static let addressesTarget: Set<String> = [
        "Target.attachToTarget", "Target.activateTarget", "Target.closeTarget", "Target.getTargetInfo",
        "Target.exposeDevToolsProtocol", "Target.detachFromTarget", "Browser.getWindowForTarget",
    ]

    static let notShown = "No such tab for this run: tabs kept for the director are not shown to a run without him."

    static func kept(_ url: String) -> String {
        "\(URL(string: url)?.host ?? "This tab") is kept for the director: a run without him does not open, see or touch it."
    }

    /// Why a command is not passed on, or nil.
    private func refusal(method: String, params: [String: Any]?, session: String?) -> String? {
        if Self.forbidden.contains(method) { return "Bulava's browser does not allow \(method)." }
        if let session, hidden.contains(session) { return "No such session." }
        guard guarded else { return nil }
        if Self.guarding.contains(method) || method == "Target.sendMessageToTarget" {
            return "\(method) is not available to a run working without the director."
        }
        // Any address in what is asked — a page to open, an origin whose storage to read, a frame's
        // resource — on one of his sites.
        if let url = Self.addresses(in: params ?? [:]).first(where: isBlocked) {
            return Self.kept(url.absoluteString)
        }
        return nil
    }

    func isBlocked(_ url: URL) -> Bool { BrowserSite.covers(url, anyOf: blocked) }

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
    private func isBlocked(_ text: String) -> Bool { URL(string: text).map(isBlocked) ?? false }

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

    private func fromBrowser(_ data: Data, transport made: ObjectIdentifier) {
        guard let transport, ObjectIdentifier(transport) == made else { return }
        if let upstream = Self.leadingID(data) {
            answered(upstream, data: data, rewrite: { Self.replacingLeadingID(data, with: $0) })
            return
        }
        // Not in the usual shape: read it whole. An answer whose id is not first still goes back
        // under the client's own id.
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return }
        if let upstream = object["id"] as? Int {
            answered(upstream, data: data, rewrite: { id in
                var copy = object
                copy["id"] = id
                return (try? JSONSerialization.data(withJSONObject: copy)) ?? data
            })
            return
        }
        if event(object) { peer?.send(data) }
    }

    /// Reads an event; true when it is passed on to the run.
    private func event(_ object: [String: Any]) -> Bool {
        let method = object["method"] as? String ?? ""
        let params = object["params"] as? [String: Any] ?? [:]
        let parent = object["sessionId"] as? String
        // Whatever happens in a tab Bulava keeps from the run stays with Bulava.
        if let parent, hidden.contains(parent) { return false }
        let info = params["targetInfo"] as? [String: Any]
        let target = info?["targetId"] as? String
        let url = info?["url"] as? String
        if let target, let url { targetURLs[target] = url }
        if let run = lease?.run, let target, let url, (info?["type"] as? String ?? "page") == "page",
           let page = URL(string: url), let address = Self.signInOnlyHeCanDo(page),
           signInsTold.insert(target + " " + (address.host ?? "")).inserted {
            onSignInNeeded?(address, run)
        }
        switch method {
        case "Target.attachedToTarget":
            guard let session = params["sessionId"] as? String else { return true }
            if guarded, let url, isBlocked(url) {
                hide(session, parent: parent, waiting: params["waitingForDebugger"] as? Bool ?? false)
                return false
            }
            sessionTargets[session] = target
            if let parent { sessionParents[session] = parent }
            attached(session)
            return true
        case "Target.detachedFromTarget":
            guard let session = params["sessionId"] as? String else { return true }
            if hidden.remove(session) != nil { return false }
            forget(session)
            return true
        case "Target.targetCreated", "Target.targetInfoChanged":
            guard guarded, let url, isBlocked(url) else { return true }
            // A tab the run had that is now on one of his sites is taken from it.
            if let target {
                for (session, held) in sessionTargets where held == target { detach(session) }
            }
            return false
        case "Target.targetDestroyed":
            if let gone = params["targetId"] as? String { targetURLs[gone] = nil }
            return true
        default:
            return true
        }
    }

    private func answered(_ upstream: Int, data: Data, rewrite: (Int) -> Data) {
        if own.remove(upstream) != nil {
            if let then = ownCallbacks.removeValue(forKey: upstream) {
                then((try? JSONSerialization.jsonObject(with: data)) as? [String: Any])
            }
            return
        }
        guard let request = pending.removeValue(forKey: upstream) else { return }
        if request.method == "Target.attachToTarget",
           let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
           let session = (object["result"] as? [String: Any])?["sessionId"] as? String {
            sessionTargets[session] = request.target
            if let parent = request.session { sessionParents[session] = parent }
            attached(session)
        } else if request.method == "Target.getTargets",
                  var object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  var result = object["result"] as? [String: Any],
                  let infos = result["targetInfos"] as? [[String: Any]] {
            for info in infos {
                if let target = info["targetId"] as? String, let url = info["url"] as? String { targetURLs[target] = url }
            }
            if guarded {
                // His tabs are not in the run's list.
                result["targetInfos"] = infos.filter { !isBlocked(($0["url"] as? String) ?? "") }
                object["result"] = result
                object["id"] = request.id
                guard let peer, ObjectIdentifier(peer) == request.peer,
                      let filtered = try? JSONSerialization.data(withJSONObject: object) else { return }
                peer.send(filtered)
                return
            }
        }
        guard let peer, ObjectIdentifier(peer) == request.peer else { return }
        peer.send(rewrite(request.id))
    }

    /// A page the run is now attached to. For a run without the director, his own sites are
    /// closed on it before the run can do anything there.
    private func attached(_ session: String) {
        sessions.insert(session)
        applyRules(to: session)
    }

    private func applyRules(to session: String) {
        guard lease?.run.unattended == true else { return }
        let rules = blocked.map { ["urlPattern": BrowserSite.pattern(for: $0), "offline": true, "latency": 0, "downloadThroughput": -1, "uploadThroughput": -1] as [String: Any] }
        command("Network.emulateNetworkConditionsByRule",
                ["offline": !rules.isEmpty, "matchedNetworkConditions": rules], session: session)
    }

    /// A tab of his the browser attached for the run: it is let go at once, and nothing from it
    /// reaches the run.
    private func hide(_ session: String, parent: String?, waiting: Bool) {
        hidden.insert(session)
        if waiting { command("Runtime.runIfWaitingForDebugger", [:], session: session) }
        command("Target.detachFromTarget", ["sessionId": session], session: parent)
    }

    /// Takes a tab from the run: Chrome tells the run it is gone.
    private func detach(_ session: String) {
        command("Target.detachFromTarget", ["sessionId": session], session: sessionParents[session])
        forget(session)
    }

    private func forget(_ session: String) {
        sessions.remove(session)
        sessionTargets[session] = nil
        sessionParents[session] = nil
    }

    /// He changed which sites a run without him may use, while one has the browser: tabs now on a
    /// closed site are taken from it, and the rule on every tab it keeps is set again.
    private func blockedChanged() {
        guard lease?.run.unattended == true else { return }
        for session in sessions { applyRules(to: session) }
        guard guarded else { return }
        command("Target.getTargets", [:]) { [weak self] answer in
            guard let self else { return }
            let infos = (answer?["result"] as? [String: Any])?["targetInfos"] as? [[String: Any]] ?? []
            for info in infos {
                guard let target = info["targetId"] as? String, let url = info["url"] as? String else { continue }
                self.targetURLs[target] = url
                guard self.isBlocked(url) else { continue }
                for (session, held) in self.sessionTargets where held == target { self.detach(session) }
            }
        }
    }

    /// A command of Bulava's own; its answer is not passed on, but may be read.
    private func command(_ method: String, _ params: [String: Any], session: String? = nil,
                         then: (([String: Any]?) -> Void)? = nil) {
        guard let transport else { return }
        let id = nextID
        nextID += 1
        own.insert(id)
        if let then { ownCallbacks[id] = then }
        var message: [String: Any] = ["id": id, "method": method, "params": params]
        if let session { message["sessionId"] = session }
        if let data = try? JSONSerialization.data(withJSONObject: message) { transport.send(data) }
    }

    /// What the last holder left attached is detached, and the browser stops attaching anything
    /// for nobody.
    private func cleanUp() {
        for session in sessions { command("Target.detachFromTarget", ["sessionId": session], session: sessionParents[session]) }
        sessions.removeAll()
        sessionTargets.removeAll()
        sessionParents.removeAll()
        command("Target.setAutoAttach", ["autoAttach": false, "waitForDebuggerOnStart": false, "flatten": true])
        command("Target.setDiscoverTargets", ["discover": false])
        pending.removeAll()
    }

    private func endLease() {
        guard lease != nil || peer != nil else { return }
        if let peer { self.peer = nil; peer.onClose = nil; peer.close(code: 1001) }
        cleanUp()
        signInsTold.removeAll()
        lease = nil
        onChange?(nil)
    }

    private func browserExited(_ made: ObjectIdentifier) {
        guard let transport, ObjectIdentifier(transport) == made else { return }
        self.transport = nil
        sessions.removeAll()
        sessionTargets.removeAll()
        sessionParents.removeAll()
        hidden.removeAll()
        targetURLs.removeAll()
        signInsTold.removeAll()
        pending.removeAll()
        own.removeAll()
        ownCallbacks.removeAll()
        if let peer { self.peer = nil; peer.onClose = nil; peer.close(code: 1011) }
        lease = nil
        onChange?(nil)
    }

    private func startIdleWatch() {
        idleTimer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 15, repeating: 15)
        timer.setEventHandler { [weak self] in
            guard let self, let held = self.lease else { return }
            if Date().timeIntervalSince(held.lastActivity) > self.idleLimit { self.endLease() }
        }
        timer.resume()
        idleTimer = timer
    }

    /// Lets a test move the clock: a lease idle for longer than the limit ends now.
    func checkIdle(now: Date) {
        queue.sync {
            if let held = lease, now.timeIntervalSince(held.lastActivity) > idleLimit { endLease() }
        }
    }

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
