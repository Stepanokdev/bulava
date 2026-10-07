import XCTest
import Network
@testable import Bulava

/// The door to Bulava's browser, against a browser that answers like Chrome and a client that
/// connects like chrome-devtools-mcp: who gets in, one run at a time, what a run leaves behind,
/// and what a run without the director cannot do there.
nonisolated final class BrowserBrokerTests: XCTestCase {

    /// Answers every command `{"id":N,"result":{}}` — an attach with a session id — and records
    /// what it was sent.
    final class FakeBrowser: CDPTransport, @unchecked Sendable {
        private let lock = NSLock()
        private var received: [[String: Any]] = []
        private var deliver: (@Sendable (Data) -> Void)?
        private var sessions = 0
        var isRunning: Bool { true }

        func send(_ message: Data) {
            guard let object = (try? JSONSerialization.jsonObject(with: message)) as? [String: Any],
                  let id = object["id"] as? Int else { return }
            let method = object["method"] as? String ?? ""
            let reply: String = lock.withLock {
                received.append(object)
                if method == "Target.attachToTarget" { sessions += 1; return #"{"id":\#(id),"result":{"sessionId":"S-\#(sessions)"}}"# }
                if method == "Target.getTargetInfo" {
                    let target = (object["params"] as? [String: Any])?["targetId"] as? String ?? "T1"
                    let url = target == "BANK" ? "https://online.bank.example/" : "https://console.example/"
                    return #"{"id":\#(id),"result":{"targetInfo":{"targetId":"\#(target)","type":"page","url":"\#(url)"}}}"#
                }
                return #"{"id":\#(id),"result":{}}"#
            }
            deliver?(Data(reply.utf8))
        }
        func listen(onMessage: @escaping @Sendable (Data) -> Void, onExit: @escaping @Sendable () -> Void) {
            lock.withLock { deliver = onMessage }
        }
        func terminate() {}
        func emit(_ event: String) { deliver?(Data(event.utf8)) }
        var commands: [[String: Any]] { lock.withLock { received } }
        func methods() -> [String] { commands.compactMap { $0["method"] as? String } }
    }

    private var broker: BrowserBroker!
    private var fake: FakeBrowser!
    private var port: UInt16 = 0
    private let attended = BrowserBroker.Run(token: String(repeating: "a", count: 48), slug: "chat-run", title: "Export fix", unattended: false)
    private let night = BrowserBroker.Run(token: String(repeating: "b", count: 48), slug: "night-run", title: "Nightly", unattended: true)

    override func setUp() async throws {
        broker = BrowserBroker()
        fake = FakeBrowser()
        let browser = fake!
        broker.makeTransport = { browser }
        broker.reconnectGrace = 0.2
        port = broker.start(preferredPort: 0)
        XCTAssertNotEqual(port, 0)
        broker.setRuns([attended, night])
    }

    override func tearDown() async throws {
        broker.stop()
    }

    // MARK: A client

    final class Client {
        let task: URLSessionWebSocketTask
        init(port: UInt16, token: String?, origin: String? = nil) {
            var request = URLRequest(url: URL(string: "ws://127.0.0.1:\(port)/devtools/browser/bulava")!)
            if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
            if let origin { request.setValue(origin, forHTTPHeaderField: "Origin") }
            task = URLSession(configuration: .ephemeral).webSocketTask(with: request)
            task.resume()
        }
        func send(_ object: [String: Any]) async throws {
            let data = try JSONSerialization.data(withJSONObject: object)
            try await task.send(.string(String(decoding: data, as: UTF8.self)))
        }
        func receive() async throws -> [String: Any] {
            let message = try await task.receive()
            let data: Data
            switch message {
            case .string(let text): data = Data(text.utf8)
            case .data(let raw): data = raw
            @unknown default: data = Data()
            }
            return (try JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
        }
        /// A command and its answer.
        func call(_ id: Int, _ method: String, _ params: [String: Any] = [:], session: String? = nil) async throws -> [String: Any] {
            var object: [String: Any] = ["id": id, "method": method, "params": params]
            if let session { object["sessionId"] = session }
            try await send(object)
            while true {
                let answer = try await receive()
                if answer["id"] as? Int == id { return answer }
            }
        }
        /// The HTTP status the door answered a refused handshake with.
        func refusedStatus() async -> Int? {
            do { _ = try await call(1, "Browser.getVersion"); return nil }
            catch { return (task.response as? HTTPURLResponse)?.statusCode }
        }
        func close() { task.cancel(with: .normalClosure, reason: nil) }
    }

    private func settle(_ seconds: Double = 0.35) async throws { try await Task.sleep(for: .seconds(seconds)) }

    // MARK: Who gets in

    func testOnlyARunWithItsOwnTokenGetsIn() async throws {
        let stranger = await Client(port: port, token: String(repeating: "z", count: 48)).refusedStatus()
        XCTAssertEqual(stranger, 401, "a token no live run holds")
        let bare = await Client(port: port, token: nil).refusedStatus()
        XCTAssertEqual(bare, 401, "no token at all")
        let page = await Client(port: port, token: attended.token, origin: "https://evil.example").refusedStatus()
        XCTAssertEqual(page, 403, "a web page knocking on the loopback, even with a token")
        let run = Client(port: port, token: attended.token)
        let answer = try await run.call(1, "Browser.getVersion")
        XCTAssertNotNil(answer["result"])
        XCTAssertEqual(broker.currentLease?.run.slug, "chat-run")
        run.close()
    }

    func testTheDoorListensOnThisMacOnly() throws {
        let lsof = Process()
        lsof.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
        lsof.arguments = ["-nP", "-a", "-p", "\(ProcessInfo.processInfo.processIdentifier)", "-iTCP:\(port)", "-sTCP:LISTEN"]
        let out = Pipe()
        lsof.standardOutput = out
        try lsof.run()
        lsof.waitUntilExit()
        let listening = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        XCTAssertTrue(listening.contains("127.0.0.1:\(port)"), "bound to the loopback: \(listening)")
        XCTAssertFalse(listening.contains("*:\(port)"), "and not to every address: \(listening)")
    }

    func testOneRunAtATimeAndTheNextGetsItWhenTheFirstLetsGo() async throws {
        let first = Client(port: port, token: attended.token)
        _ = try await first.call(1, "Browser.getVersion")
        let second = await Client(port: port, token: night.token).refusedStatus()
        XCTAssertEqual(second, 423, "busy, said at once — not queued behind a socket")
        XCTAssertTrue(broker.release(token: attended.token), "the holder lets go ($IDIR/browser release)")
        try await settle()
        let next = Client(port: port, token: night.token)
        _ = try await next.call(1, "Browser.getVersion")
        XCTAssertEqual(broker.currentLease?.run.slug, "night-run")
        next.close()
    }

    func testTheSameRunReconnectingKeepsItsLease() async throws {
        let first = Client(port: port, token: attended.token)
        _ = try await first.call(1, "Browser.getVersion")
        first.close()
        // chrome-devtools-mcp comes straight back; another run trying in between is turned away.
        let between = await Client(port: port, token: night.token).refusedStatus()
        XCTAssertEqual(between, 423)
        let again = Client(port: port, token: attended.token)
        _ = try await again.call(2, "Browser.getVersion")
        XCTAssertEqual(broker.currentLease?.run.slug, "chat-run")
        again.close()
        try await settle(0.6)
        XCTAssertNil(broker.currentLease, "and once it is really gone, the lease is free")
    }

    func testAnEndedRunAndAnIdleOneLoseIt() async throws {
        let run = Client(port: port, token: attended.token)
        _ = try await run.call(1, "Browser.getVersion")
        broker.setRuns([night])
        try await settle()
        XCTAssertNil(broker.currentLease, "the run ended: its lease with it")
        do { _ = try await run.call(2, "Browser.getVersion"); XCTFail("the socket of an ended run still works") } catch {}

        let idle = Client(port: port, token: night.token)
        _ = try await idle.call(1, "Browser.getVersion")
        broker.checkIdle(now: Date().addingTimeInterval(broker.idleLimit + 1))
        try await settle()
        XCTAssertNil(broker.currentLease, "a run that went quiet lets the next one in")
        idle.close()
    }

    func testHeSigningInTakesItFromEveryRun() async throws {
        let run = Client(port: port, token: attended.token)
        _ = try await run.call(1, "Browser.getVersion")
        broker.setUnavailable("signing in")
        XCTAssertNil(broker.currentLease)
        let refused = await Client(port: port, token: attended.token).refusedStatus()
        XCTAssertEqual(refused, 503)
        broker.setUnavailable(nil)
        let back = Client(port: port, token: attended.token)
        _ = try await back.call(1, "Browser.getVersion")
        back.close()
    }

    // MARK: What passes

    func testEachClientKeepsItsOwnIdsAndTheBrowserNeverSeesTwoAlike() async throws {
        let first = Client(port: port, token: attended.token)
        let a = try await first.call(1, "Browser.getVersion")
        XCTAssertEqual(a["id"] as? Int, 1)
        XCTAssertTrue(broker.release(token: attended.token))
        try await settle()
        let second = Client(port: port, token: night.token)
        let b = try await second.call(1, "Browser.getVersion")
        XCTAssertEqual(b["id"] as? Int, 1, "the second client hears its own id back")
        let ids = fake.commands.filter { $0["method"] as? String == "Browser.getVersion" }.compactMap { $0["id"] as? Int }
        XCTAssertEqual(ids.count, 2)
        XCTAssertEqual(Set(ids).count, 2, "upstream, the two are different commands")
        second.close()
    }

    func testWhatARunLeftAttachedIsDetachedBeforeTheNext() async throws {
        let run = Client(port: port, token: attended.token)
        let attach = try await run.call(1, "Target.attachToTarget", ["targetId": "T1", "flatten": true])
        XCTAssertEqual((attach["result"] as? [String: Any])?["sessionId"] as? String, "S-1")
        fake.emit(#"{"method":"Target.attachedToTarget","params":{"sessionId":"AUTO-1","targetInfo":{"targetId":"T2"},"waitingForDebugger":true}}"#)
        let event = try await run.receive()
        XCTAssertEqual(event["method"] as? String, "Target.attachedToTarget", "events reach the client")
        XCTAssertTrue(broker.release(token: attended.token))
        try await settle()
        let detached = fake.commands.filter { $0["method"] as? String == "Target.detachFromTarget" }
            .compactMap { ($0["params"] as? [String: Any])?["sessionId"] as? String }
        XCTAssertEqual(Set(detached), ["S-1", "AUTO-1"])
        XCTAssertTrue(fake.methods().contains("Target.setAutoAttach"), "and the browser stops attaching for nobody")
    }

    func testNoRunReadsCookiesOrClosesTheBrowser() async throws {
        let run = Client(port: port, token: attended.token)
        for method in ["Network.getAllCookies", "Storage.getCookies", "Browser.close"] {
            let answer = try await run.call(7, method)
            XCTAssertNotNil(answer["error"], method)
        }
        XCTAssertFalse(fake.methods().contains { BrowserBroker.forbidden.contains($0) }, "none of them reached the browser")
        run.close()
    }

    func testARunWithoutHimCannotOpenTheSitesHeKeeps() async throws {
        broker.setBlocked(["bank.example"])
        let run = Client(port: port, token: night.token)
        let navigate = try await run.call(1, "Page.navigate", ["url": "https://online.bank.example/accounts"], session: "S-x")
        XCTAssertNotNil(navigate["error"], "his bank, at night")
        XCTAssertEqual(navigate["sessionId"] as? String, "S-x", "answered on the session it was asked on")
        let open = try await run.call(2, "Target.createTarget", ["url": "https://bank.example/"])
        XCTAssertNotNil(open["error"])
        let lift = try await run.call(3, "Network.emulateNetworkConditionsByRule", ["offline": false, "matchedNetworkConditions": []], session: "S-x")
        XCTAssertNotNil(lift["error"], "the rule cannot be lifted by the run")
        let fine = try await run.call(4, "Page.navigate", ["url": "https://console.example/"], session: "S-x")
        XCTAssertNil(fine["error"], "everything else is open")

        let his = try await run.call(6, "Target.attachToTarget", ["targetId": "BANK", "flatten": true])
        XCTAssertNotNil(his["error"], "a tab already open on his bank is not the run's to attach to")
        XCTAssertFalse("\(his)".contains("bank"), "and the refusal does not say which site it is")
        _ = try await run.call(5, "Target.attachToTarget", ["targetId": "T1", "flatten": true])
        try await settle(0.2)
        let rule = try XCTUnwrap(fake.commands.first { $0["method"] as? String == "Network.emulateNetworkConditionsByRule" },
                                 "Bulava closes his sites on the page the run attached to")
        XCTAssertEqual(rule["sessionId"] as? String, "S-1")
        let patterns = ((rule["params"] as? [String: Any])?["matchedNetworkConditions"] as? [[String: Any]])?.compactMap { $0["urlPattern"] as? String }
        XCTAssertEqual(patterns, ["*://{*.}?bank.example/*"])
        XCTAssertFalse(fake.commands.contains { ($0["method"] as? String) == "Page.navigate"
            && (($0["params"] as? [String: Any])?["url"] as? String)?.contains("bank") == true })
        run.close()
    }

    func testAChatHeIsInMayOpenThemAll() async throws {
        broker.setBlocked(["bank.example"])
        let run = Client(port: port, token: attended.token)
        let navigate = try await run.call(1, "Page.navigate", ["url": "https://bank.example/"], session: "S-x")
        XCTAssertNil(navigate["error"])
        run.close()
    }

    // MARK: Parts

    func testAnAnswersIdIsReadAndReplacedWithoutReadingTheRest() {
        let answer = Data(#"{"id":4242,"result":{"data":"AAAA"}}"#.utf8)
        XCTAssertEqual(BrowserBroker.leadingID(answer), 4242)
        XCTAssertEqual(String(decoding: BrowserBroker.replacingLeadingID(answer, with: 7), as: UTF8.self), #"{"id":7,"result":{"data":"AAAA"}}"#)
        XCTAssertNil(BrowserBroker.leadingID(Data(#"{"method":"Page.loadEventFired","params":{}}"#.utf8)))
        XCTAssertNil(BrowserBroker.leadingID(Data(#"{"id":"x"}"#.utf8)))
    }

    func testASiteIsReadFromWhatHeTypes() {
        XCTAssertEqual(BrowserSite.make(from: "play.google.com/console")?.host, "play.google.com")
        XCTAssertEqual(BrowserSite.make(from: "https://www.example.com/login")?.host, "example.com")
        XCTAssertNil(BrowserSite.make(from: "not a site"))
        XCTAssertNil(BrowserSite.make(from: "localhost"))
        XCTAssertNil(BrowserSite.make(from: "ftp://example.com"))
        XCTAssertTrue(BrowserSite.covers(URL(string: "https://a.b.example.com/x")!, anyOf: ["example.com"]))
        XCTAssertFalse(BrowserSite.covers(URL(string: "https://notexample.com/")!, anyOf: ["example.com"]))
    }
}

/// The real thing: Google Chrome on a pipe, through the door, to a client. Skipped where Chrome is
/// not installed.
nonisolated final class AccountBrowserChromeTests: XCTestCase {

    func testChromeOnAPipeAnswersThroughTheDoorAndOpensNoPort() async throws {
        let chrome = try XCTUnwrap(ChromeApp.find(), "Google Chrome is not installed here")
        let profile = FileManager.default.temporaryDirectory.appendingPathComponent("bulava-browser-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: profile) }
        ChromeApp.prepare(profile: profile)
        let prefs = try JSONSerialization.jsonObject(with: Data(contentsOf: profile.appendingPathComponent("Default/Preferences"))) as? [String: Any]
        XCTAssertEqual((prefs?["session"] as? [String: Any])?["restore_on_startup"] as? Int, 1,
                       "the profile reopens where it left off, which keeps session-only sign-ins")

        let broker = BrowserBroker()
        let launched = LockedBox<ChromePipe?>(nil)
        broker.makeTransport = {
            let pipe = try ChromePipe.launch(executable: ChromeApp.executable(of: chrome),
                                             arguments: ChromeApp.baseArguments(profile: profile)
                                                + ["--remote-debugging-pipe", "--headless=new", "about:blank"])
            launched.set(pipe)
            return pipe
        }
        let port = broker.start(preferredPort: 0)
        defer { broker.stop() }
        let token = String(repeating: "c", count: 48)
        broker.setRuns([.init(token: token, slug: "real", title: "Real", unattended: false)])

        let client = BrowserBrokerTests.Client(port: port, token: token)
        let version = try await client.call(1, "Browser.getVersion")
        let product = (version["result"] as? [String: Any])?["product"] as? String
        XCTAssertTrue(product?.hasPrefix("HeadlessChrome") == true || product?.hasPrefix("Chrome") == true, "\(version)")
        let target = try await client.call(2, "Target.createTarget", ["url": "about:blank"])
        XCTAssertNotNil((target["result"] as? [String: Any])?["targetId"], "\(target)")

        let pipe = try XCTUnwrap(launched.get())
        let listening = Process()
        listening.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
        listening.arguments = ["-nP", "-a", "-p", "\(pipe.pid)", "-iTCP", "-sTCP:LISTEN"]
        let out = Pipe()
        listening.standardOutput = out
        try listening.run()
        listening.waitUntilExit()
        let ports = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        XCTAssertTrue(ports.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, "Chrome listens on no port: \(ports)")
        client.close()

        broker.setUnavailable("test over")
        XCTAssertTrue(pipe.waitForExit(seconds: 10), "Chrome closes when the browser is taken for signing in")
    }
}

nonisolated final class LockedBox<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value
    init(_ value: Value) { self.value = value }
    func set(_ new: Value) { lock.withLock { value = new } }
    func get() -> Value { lock.withLock { value } }
}

/// What an agent actually uses — chrome-devtools-mcp 1.10.1, the version the engine pins — through
/// Bulava's door to a real Chrome on a pipe: it connects with the run's token, works, and a second
/// run is turned away while the first has it; a run without him cannot open his sites. Skipped
/// where node or that package is not on this Mac.
nonisolated final class AccountBrowserMCPTests: XCTestCase {

    /// An MCP server over stdio, one JSON-RPC message per line.
    final class MCP: @unchecked Sendable {
        let process = Process()
        private let input = Pipe(), output = Pipe()
        private let lock = NSLock()
        private var answers: [Int: [String: Any]] = [:]
        private var nextID = 0

        init(node: URL, script: URL, arguments: [String]) throws {
            process.executableURL = node
            process.arguments = [script.path] + arguments + ["--no-usage-statistics", "--no-performance-crux"]
            process.standardInput = input
            process.standardOutput = output
            process.standardError = FileHandle.nullDevice
            try process.run()
            let reader = output.fileHandleForReading
            Thread.detachNewThread { [weak self] in
                var pending = Data()
                while true {
                    let chunk = reader.availableData
                    if chunk.isEmpty { break }
                    pending.append(chunk)
                    while let nl = pending.firstIndex(of: 10) {
                        let line = pending[pending.startIndex..<nl]
                        pending.removeSubrange(pending.startIndex...nl)
                        guard let object = (try? JSONSerialization.jsonObject(with: Data(line))) as? [String: Any],
                              let id = object["id"] as? Int else { continue }
                        self?.lock.withLock { self?.answers[id] = object }
                    }
                }
            }
        }

        private func write(_ object: [String: Any]) throws {
            var data = try JSONSerialization.data(withJSONObject: object)
            data.append(10)
            try input.fileHandleForWriting.write(contentsOf: data)
        }

        func request(_ method: String, _ params: [String: Any], timeout: Double = 45) async throws -> [String: Any] {
            let id = lock.withLock { nextID += 1; return nextID }
            try write(["jsonrpc": "2.0", "id": id, "method": method, "params": params])
            let deadline = Date().addingTimeInterval(timeout)
            while Date() < deadline {
                if let answer = lock.withLock({ answers.removeValue(forKey: id) }) { return answer }
                try await Task.sleep(for: .milliseconds(50))
            }
            throw NSError(domain: "mcp", code: 1, userInfo: [NSLocalizedDescriptionKey: "\(method) timed out"])
        }

        func start() async throws {
            _ = try await request("initialize", ["protocolVersion": "2025-06-18", "capabilities": [:] as [String: Any],
                                                 "clientInfo": ["name": "bulava-test", "version": "0"]])
            try write(["jsonrpc": "2.0", "method": "notifications/initialized"])
        }

        /// A tool's text, and whether it says it failed.
        func call(_ tool: String, _ arguments: [String: Any] = [:]) async throws -> (text: String, failed: Bool) {
            let answer = try await request("tools/call", ["name": tool, "arguments": arguments])
            if let error = answer["error"] { return ("\(error)", true) }
            let result = answer["result"] as? [String: Any] ?? [:]
            let text = (result["content"] as? [[String: Any]] ?? []).compactMap { $0["text"] as? String }.joined(separator: "\n")
            return (text, result["isError"] as? Bool ?? false)
        }

        func stop() { process.terminate() }
    }

    private static func node() -> URL? {
        let fm = FileManager.default
        var candidates = ["/opt/homebrew/bin/node", "/usr/local/bin/node"]
        let nvm = fm.homeDirectoryForCurrentUser.appendingPathComponent(".nvm/versions/node")
        if let versions = try? fm.contentsOfDirectory(atPath: nvm.path) {
            candidates += versions.sorted().reversed().map { nvm.appendingPathComponent("\($0)/bin/node").path }
        }
        return candidates.first { fm.isExecutableFile(atPath: $0) }.map(URL.init(fileURLWithPath:))
    }

    private static func mcpScript() -> URL? {
        let fm = FileManager.default
        let cache = fm.homeDirectoryForCurrentUser.appendingPathComponent(".npm/_npx")
        for hash in (try? fm.contentsOfDirectory(atPath: cache.path)) ?? [] {
            let package = cache.appendingPathComponent("\(hash)/node_modules/chrome-devtools-mcp")
            guard let data = try? Data(contentsOf: package.appendingPathComponent("package.json")),
                  let info = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  info["version"] as? String == "1.10.1" else { continue }
            let script = package.appendingPathComponent("build/src/bin/chrome-devtools-mcp.js")
            if fm.fileExists(atPath: script.path) { return script }
        }
        return nil
    }

    func testTheAgentsOwnClientWorksThroughTheDoorOneRunAtATime() async throws {
        guard let chrome = ChromeApp.find() else { throw XCTSkip("Google Chrome is not installed") }
        guard let node = Self.node(), let script = Self.mcpScript() else { throw XCTSkip("node or chrome-devtools-mcp 1.10.1 is not here") }
        let profile = FileManager.default.temporaryDirectory.appendingPathComponent("bulava-mcp-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: profile) }
        ChromeApp.prepare(profile: profile)
        let sites = try AccountBrowserProtectedTabTests.Sites()
        defer { sites.stop() }
        let broker = BrowserBroker()
        broker.makeTransport = {
            try ChromePipe.launch(executable: ChromeApp.executable(of: chrome),
                                  arguments: ChromeApp.baseArguments(profile: profile)
                                    + ["--remote-debugging-pipe", "--headless=new", "--host-resolver-rules=MAP *.test 127.0.0.1", "about:blank"])
        }
        let port = broker.start(preferredPort: 0)
        defer { broker.setUnavailable("test over"); broker.stop() }
        let chat = BrowserBroker.Run(token: String(repeating: "d", count: 48), slug: "chat", title: "Export fix", unattended: false)
        let night = BrowserBroker.Run(token: String(repeating: "e", count: 48), slug: "night", title: "Nightly", unattended: true)
        broker.setRuns([chat, night])
        broker.setBlocked(["bank.example", "bank.test"])
        func client(_ run: BrowserBroker.Run) throws -> MCP {
            try MCP(node: node, script: script, arguments: [
                "--wsEndpoint", "ws://127.0.0.1:\(port)/devtools/browser/bulava",
                "--wsHeaders", #"{"Authorization":"Bearer \#(run.token)"}"#, "--redactNetworkHeaders"])
        }

        let first = try client(chat)
        defer { first.stop() }
        try await first.start()
        let opened = try await first.call("new_page", ["url": "data:text/html,<title>Bulava</title><h1>Signed in as the director</h1>"])
        XCTAssertFalse(opened.failed, opened.text)
        // 1.10.1 routes page tools by id: the page "new_page" opened is the selected one.
        let listed = try await first.call("list_pages")
        let selected = try XCTUnwrap(listed.text.split(separator: "\n").first { $0.contains("[selected]") }, listed.text)
        let pageID = try XCTUnwrap(Int(selected.prefix { $0.isNumber }), listed.text)
        let snapshot = try await first.call("take_snapshot", ["pageId": pageID])
        XCTAssertTrue(snapshot.text.contains("Signed in as the director"), snapshot.text)
        XCTAssertEqual(broker.currentLease?.run.slug, "chat")
        // He leaves his bank open in a tab of its own.
        let bankOpened = try await first.call("new_page", ["url": "http://bank.test:\(sites.port)/accounts"])
        XCTAssertFalse(bankOpened.failed, bankOpened.text)

        let second = try client(night)
        defer { second.stop() }
        try await second.start()
        let refused = try await second.call("list_pages")
        XCTAssertTrue(refused.text.contains("423"), "another run is turned away while the first has it: \(refused.text)")

        first.stop()
        XCTAssertTrue(broker.release(token: chat.token) || broker.currentLease == nil)
        try await Task.sleep(for: .seconds(1))
        let pages = try await second.call("list_pages")
        XCTAssertFalse(pages.failed, "the next run gets it once the first is gone: \(pages.text)")
        XCTAssertEqual(broker.currentLease?.run.slug, "night")
        XCTAssertFalse(pages.text.contains("bank.test"), "his open bank tab is not among the run's pages: \(pages.text)")
        XCTAssertTrue(pages.text.contains("Signed in as the director") || pages.text.contains("data:"),
                      "the tabs it may use are: \(pages.text)")
        let bank = try await second.call("new_page", ["url": "https://bank.example/"])
        XCTAssertTrue(bank.text.contains("kept for the director"), "a run without him cannot open his bank — Bulava's refusal, not a lookup failure: \(bank.text)")
    }
}

/// His own tab, left open in Bulava's browser, and the browser then lent to a run working without
/// him: the run cannot list it, attach to it, show, close or read it, nor reach the site's storage
/// or pages from a tab it does have; and a site he closes while the run has the browser is taken
/// from it at once. Real Chrome, a local "bank" and "console" served on the loopback.
nonisolated final class AccountBrowserProtectedTabTests: XCTestCase {

    /// Two sites on the loopback, told apart by the Host header.
    final class Sites: @unchecked Sendable {
        let listener: NWListener
        private(set) var port: UInt16 = 0
        static let secret = "SECRET-BALANCE-4242"

        init() throws {
            let parameters = NWParameters.tcp
            parameters.requiredInterfaceType = .loopback
            listener = try NWListener(using: parameters, on: .any)
            let queue = DispatchQueue(label: "sites")
            listener.newConnectionHandler = { connection in
                connection.start(queue: queue)
                connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { data, _, _, _ in
                    let request = String(decoding: data ?? Data(), as: UTF8.self).lowercased()
                    let body = request.contains("host: bank.test")
                        ? "<!doctype html><title>Bank</title><h1>\(Sites.secret)</h1><script>localStorage.setItem('session','\(Sites.secret)')</script>"
                        : "<!doctype html><title>Console</title><h1>Console page</h1>"
                    let response = "HTTP/1.1 200 OK\r\nContent-Type: text/html\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
                    connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in connection.cancel() })
                }
            }
            let ready = DispatchSemaphore(value: 0)
            listener.stateUpdateHandler = { if case .ready = $0 { ready.signal() } }
            listener.start(queue: queue)
            _ = ready.wait(timeout: .now() + 3)
            port = listener.port?.rawValue ?? 0
        }
        func stop() { listener.cancel() }
    }

    /// A client that reads everything the door says, answers and events alike.
    final class Recorder: @unchecked Sendable {
        let task: URLSessionWebSocketTask
        private let lock = NSLock()
        private var messages: [[String: Any]] = []
        private var reader: Task<Void, Never>?

        init(port: UInt16, token: String) {
            var request = URLRequest(url: URL(string: "ws://127.0.0.1:\(port)/devtools/browser/bulava")!)
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            task = URLSession(configuration: .ephemeral).webSocketTask(with: request)
            task.resume()
            reader = Task { [weak self] in
                while let self {
                    guard let message = try? await self.task.receive() else { return }
                    var data = Data()
                    if case .string(let text) = message { data = Data(text.utf8) }
                    if case .data(let raw) = message { data = raw }
                    if let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
                        self.lock.withLock { self.messages.append(object) }
                    }
                }
            }
        }

        func call(_ id: Int, _ method: String, _ params: [String: Any] = [:], session: String? = nil) async throws -> [String: Any] {
            var object: [String: Any] = ["id": id, "method": method, "params": params]
            if let session { object["sessionId"] = session }
            let data = try JSONSerialization.data(withJSONObject: object)
            try await task.send(.string(String(decoding: data, as: UTF8.self)))
            for _ in 0..<200 {
                if let answer = lock.withLock({ messages.first { $0["id"] as? Int == id } }) { return answer }
                try await Task.sleep(for: .milliseconds(50))
            }
            throw NSError(domain: "cdp", code: 1, userInfo: [NSLocalizedDescriptionKey: "\(method) unanswered"])
        }

        var events: [[String: Any]] { lock.withLock { messages.filter { $0["id"] == nil } } }
        /// Everything heard, as text, to look for what must never be there.
        var transcript: String {
            lock.withLock { messages.compactMap { (try? JSONSerialization.data(withJSONObject: $0)).map { String(decoding: $0, as: UTF8.self) } }.joined(separator: "\n") }
        }
        func close() { reader?.cancel(); task.cancel(with: .normalClosure, reason: nil) }
    }

    private static func failed(_ answer: [String: Any]) -> Bool { answer["error"] != nil }
    private static func text(_ answer: [String: Any]) -> String {
        ((((answer["result"] as? [String: Any])?["result"]) as? [String: Any])?["value"] as? String) ?? ""
    }

    func testHisOpenTabCannotBeSeenReadOrTouchedByARunWithoutHim() async throws {
        guard let chrome = ChromeApp.find() else { throw XCTSkip("Google Chrome is not installed") }
        let sites = try Sites()
        defer { sites.stop() }
        let port = sites.port
        let profile = FileManager.default.temporaryDirectory.appendingPathComponent("bulava-protected-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: profile) }
        let broker = BrowserBroker()
        broker.reconnectGrace = 0.2
        broker.makeTransport = {
            try ChromePipe.launch(executable: ChromeApp.executable(of: chrome),
                                  arguments: ChromeApp.baseArguments(profile: profile)
                                    + ["--remote-debugging-pipe", "--headless=new", "--host-resolver-rules=MAP *.test 127.0.0.1", "about:blank"])
        }
        let door = broker.start(preferredPort: 0)
        defer { broker.setUnavailable("test over"); broker.stop() }
        let chat = BrowserBroker.Run(token: String(repeating: "g", count: 48), slug: "chat", title: "With him", unattended: false)
        let night = BrowserBroker.Run(token: String(repeating: "h", count: 48), slug: "night", title: "Nightly", unattended: true)
        broker.setRuns([chat, night])
        let bankURL = "http://bank.test:\(port)/accounts"
        let consoleURL = "http://console.test:\(port)/"

        // He, in a chat: opens his bank and a console, and the bank's page is really there.
        let him = Recorder(port: door, token: chat.token)
        let created = try await him.call(1, "Target.createTarget", ["url": bankURL])
        let bank = try XCTUnwrap((created["result"] as? [String: Any])?["targetId"] as? String)
        _ = try await him.call(2, "Target.createTarget", ["url": consoleURL])
        let attachedToBank = try await him.call(3, "Target.attachToTarget", ["targetId": bank, "flatten": true])
        let bankSession = try XCTUnwrap((attachedToBank["result"] as? [String: Any])?["sessionId"] as? String)
        var seen = ""
        for attempt in 0..<40 where !seen.contains(Sites.secret) {
            seen = Self.text(try await him.call(10 + attempt, "Runtime.evaluate", ["expression": "document.body ? document.body.innerText : ''", "returnByValue": true], session: bankSession))
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTAssertTrue(seen.contains(Sites.secret), "with him there, his bank is readable: \(seen)")
        him.close()
        XCTAssertTrue(broker.release(token: chat.token))
        try await Task.sleep(for: .milliseconds(400))

        // The browser goes to a run without him; the bank tab stays open.
        broker.setBlocked(["bank.test"])
        let run = Recorder(port: door, token: night.token)
        let list = try await run.call(1, "Target.getTargets")
        let urls = ((list["result"] as? [String: Any])?["targetInfos"] as? [[String: Any]] ?? []).compactMap { $0["url"] as? String }
        XCTAssertTrue(urls.contains { $0.hasPrefix(consoleURL) }, "the console is the run's: \(urls)")
        XCTAssertFalse(urls.contains { $0.contains("bank.test") }, "his bank is not in the run's list: \(urls)")

        for (n, method) in ["Target.attachToTarget", "Target.activateTarget", "Target.closeTarget", "Target.getTargetInfo",
                            "Target.exposeDevToolsProtocol", "Browser.getWindowForTarget"].enumerated() {
            let answer = try await run.call(100 + n, method, ["targetId": bank, "flatten": true])
            XCTAssertTrue(Self.failed(answer), "\(method) on his tab: \(answer)")
        }
        let relayed = try await run.call(110, "Target.sendMessageToTarget", ["targetId": bank, "message": "{}"])
        XCTAssertTrue(Self.failed(relayed))

        _ = try await run.call(120, "Target.setDiscoverTargets", ["discover": true])
        _ = try await run.call(121, "Target.setAutoAttach", ["autoAttach": true, "waitForDebuggerOnStart": false, "flatten": true])
        try await Task.sleep(for: .seconds(1.5))
        let attachedEvents = run.events.filter { $0["method"] as? String == "Target.attachedToTarget" }
        let consoleSession = try XCTUnwrap(attachedEvents.compactMap { event -> String? in
            let params = event["params"] as? [String: Any]
            let url = (params?["targetInfo"] as? [String: Any])?["url"] as? String ?? ""
            return url.hasPrefix(consoleURL) ? params?["sessionId"] as? String : nil
        }.first, "the browser attaches the run to its console")
        XCTAssertFalse(run.transcript.contains("bank.test"),
                       "nothing about his bank reaches the run, not even its address: \(run.transcript.split(separator: "\n").filter { $0.contains("bank.test") })")

        // From the console tab: his bank's storage, a way there, a request to it.
        let storage = try await run.call(130, "DOMStorage.getDOMStorageItems",
                                         ["storageId": ["securityOrigin": "http://bank.test:\(port)", "isLocalStorage": true]], session: consoleSession)
        XCTAssertTrue(Self.failed(storage), "his bank's storage, read from another tab: \(storage)")
        let there = try await run.call(131, "Page.navigate", ["url": bankURL], session: consoleSession)
        XCTAssertTrue(Self.failed(there))
        let fetched = try await run.call(132, "Runtime.evaluate", ["expression": "fetch('\(bankURL)').then(r => r.text()).catch(e => 'blocked: ' + e)",
                                                                  "awaitPromise": true, "returnByValue": true], session: consoleSession)
        XCTAssertFalse(Self.text(fetched).contains(Sites.secret), "the bank does not answer the run: \(fetched)")
        XCTAssertFalse(run.transcript.contains(Sites.secret), "his bank's contents never reached the run")

        // He closes the console to such runs while this one has it: the tab is taken from it.
        broker.setBlocked(["bank.test", "console.test"])
        var taken = false
        for _ in 0..<40 where !taken {
            taken = run.events.contains { $0["method"] as? String == "Target.detachedFromTarget"
                && ($0["params"] as? [String: Any])?["sessionId"] as? String == consoleSession }
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTAssertTrue(taken, "a site he closes mid-lease is taken from the run at once")
        let after = try await run.call(140, "Runtime.evaluate", ["expression": "1"], session: consoleSession)
        XCTAssertTrue(Self.failed(after), "nothing more can be done in the tab taken from it")
        run.close()
        XCTAssertTrue(broker.release(token: night.token))
        try await Task.sleep(for: .milliseconds(400))

        // His tab was never closed: back with him, it is still there.
        let back = Recorder(port: door, token: chat.token)
        let again = try await back.call(1, "Target.getTargets")
        let still = ((again["result"] as? [String: Any])?["targetInfos"] as? [[String: Any]] ?? []).compactMap { $0["url"] as? String }
        XCTAssertTrue(still.contains { $0.contains("bank.test") }, "his bank tab is where he left it: \(still)")
        back.close()
    }
}
