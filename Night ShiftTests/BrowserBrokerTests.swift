import XCTest
import Network
@testable import Bulava

/// The door to Bulava's browser, against a browser that answers like Chrome and a client that
/// connects like chrome-devtools-mcp: who gets in, several runs at once, what a run leaves behind,
/// and what a run without the director cannot do there. What each run sees of the others' tabs is
/// proved against a real Chrome further down.
nonisolated final class BrowserBrokerTests: XCTestCase {

    /// Answers like Chrome does for what the door asks of it — a browser session, a new tab, an
    /// attach — echoing the session a command came on, and records what it was sent.
    final class FakeBrowser: CDPTransport, @unchecked Sendable {
        private let lock = NSLock()
        private var received: [[String: Any]] = []
        private var deliver: (@Sendable (Data) -> Void)?
        private var counter = 0
        private(set) var browserSessions: [String] = []
        private(set) var created: [String] = []
        var isRunning: Bool { true }

        func send(_ message: Data) {
            guard let object = (try? JSONSerialization.jsonObject(with: message)) as? [String: Any],
                  let id = object["id"] as? Int else { return }
            let method = object["method"] as? String ?? ""
            let session = object["sessionId"] as? String
            let result: [String: Any] = lock.withLock {
                received.append(object)
                counter += 1
                switch method {
                case "Target.attachToBrowserTarget":
                    let made = "BS-\(counter)"; browserSessions.append(made); return ["sessionId": made]
                case "Target.createTarget":
                    let made = "T-\(counter)"; created.append(made); return ["targetId": made]
                case "Target.attachToTarget": return ["sessionId": "S-\(counter)"]
                case "Target.getTargets":
                    return ["targetInfos": created.map { ["targetId": $0, "type": "page", "url": "about:blank"] }]
                case "Browser.getVersion": return ["product": "Chrome/Fake"]
                default: return [:]
                }
            }
            var reply: [String: Any] = ["id": id, "result": result]
            if let session { reply["sessionId"] = session }
            if let data = try? JSONSerialization.data(withJSONObject: reply) { deliver?(data) }
        }
        func listen(onMessage: @escaping @Sendable (Data) -> Void, onExit: @escaping @Sendable () -> Void) {
            lock.withLock { deliver = onMessage }
        }
        func terminate() {}
        func emit(_ event: [String: Any]) {
            if let data = try? JSONSerialization.data(withJSONObject: event) { deliver?(data) }
        }
        /// Bulava's watcher hears a tab change address — the first browser session is the watcher's.
        func navigated(_ target: String, to url: String) {
            guard let watcher = lock.withLock({ browserSessions.first }) else { return }
            emit(["method": "Target.targetInfoChanged", "sessionId": watcher,
                  "params": ["targetInfo": ["targetId": target, "type": "page", "url": url]]])
        }
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
        XCTAssertNil(answer["sessionId"], "a command the run sent at its root is answered at its root")
        XCTAssertEqual(broker.leases.map(\.run.slug), ["chat-run"])
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

    /// 13 Oct: a second chat that needed App Store Connect was turned away (`423`) while another
    /// chat held the browser. Now both are in, at once, each on a browser session of its own.
    func testTwoRunsUseItAtOnceEachOnItsOwnSession() async throws {
        let first = Client(port: port, token: attended.token)
        _ = try await first.call(1, "Browser.getVersion")
        let second = Client(port: port, token: night.token)
        let answer = try await second.call(1, "Browser.getVersion")
        XCTAssertNotNil(answer["result"], "the second run is not turned away")
        XCTAssertEqual(Set(broker.leases.map(\.run.slug)), ["chat-run", "night-run"])
        let rooted = fake.commands.filter { $0["method"] as? String == "Browser.getVersion" }.compactMap { $0["sessionId"] as? String }
        XCTAssertEqual(rooted.count, 2)
        XCTAssertEqual(Set(rooted).count, 2, "each run's root commands go on its own browser session")
        let ids = fake.commands.filter { $0["method"] as? String == "Browser.getVersion" }.compactMap { $0["id"] as? Int }
        XCTAssertEqual(Set(ids).count, 2, "upstream, the two are different commands, though both clients said id 1")
        first.close(); second.close()
    }

    func testEachRunStartsWithABlankTabOfItsOwn() async throws {
        let run = Client(port: port, token: attended.token)
        _ = try await run.call(1, "Browser.getVersion")
        try await settle(0.2)
        XCTAssertEqual(broker.tabs(of: attended.token).count, 1, "chrome-devtools-mcp has a page to work in from the start")
        let list = try await run.call(2, "Target.getTargets")
        let ids = ((list["result"] as? [String: Any])?["targetInfos"] as? [[String: Any]] ?? []).compactMap { $0["targetId"] as? String }
        XCTAssertEqual(ids, broker.tabs(of: attended.token), "and lists only its own")
        run.close()
    }

    func testARunCannotNameAnotherRunsTabOrSession() async throws {
        let first = Client(port: port, token: attended.token)
        _ = try await first.call(1, "Browser.getVersion")
        let second = Client(port: port, token: night.token)
        _ = try await second.call(1, "Browser.getVersion")
        try await settle(0.2)
        let theirs = try XCTUnwrap(broker.tabs(of: attended.token).first)
        for (n, method) in ["Target.attachToTarget", "Target.closeTarget", "Target.activateTarget", "Target.getTargetInfo"].enumerated() {
            let answer = try await second.call(10 + n, method, ["targetId": theirs, "flatten": true])
            XCTAssertNotNil(answer["error"], "\(method) on another run's tab")
        }
        let mine = try await first.call(2, "Target.attachToTarget", ["targetId": theirs, "flatten": true])
        let session = try XCTUnwrap((mine["result"] as? [String: Any])?["sessionId"] as? String)
        let foreign = try await second.call(20, "Runtime.evaluate", ["expression": "1"], session: session)
        XCTAssertNotNil(foreign["error"], "a session of another run's is not this run's to use")
        let own = try await first.call(3, "Runtime.evaluate", ["expression": "1"], session: session)
        XCTAssertNil(own["error"], "its own session is")
        XCTAssertFalse(fake.commands.contains { $0["method"] as? String == "Target.closeTarget"
            && ($0["params"] as? [String: Any])?["targetId"] as? String == theirs }, "nothing of another run's reached the browser")
        first.close(); second.close()
    }

    func testTheSameRunReconnectingKeepsItsTabs() async throws {
        let first = Client(port: port, token: attended.token)
        _ = try await first.call(1, "Browser.getVersion")
        try await settle(0.2)
        let tabs = broker.tabs(of: attended.token)
        first.close()
        // chrome-devtools-mcp comes straight back, within the grace.
        let again = Client(port: port, token: attended.token)
        _ = try await again.call(2, "Browser.getVersion")
        try await settle(0.4)
        XCTAssertEqual(broker.tabs(of: attended.token), tabs, "its tabs are still its own")
        XCTAssertFalse(fake.methods().contains("Target.closeTarget"), "and nothing was closed")
        again.close()
        try await settle(0.6)
        XCTAssertTrue(broker.leases.isEmpty, "once it is really gone, it is not using the browser")
        let closed = fake.commands.filter { $0["method"] as? String == "Target.closeTarget" }
            .compactMap { ($0["params"] as? [String: Any])?["targetId"] as? String }
        XCTAssertEqual(Set(closed), Set(tabs), "and the tabs it opened are closed")
    }

    func testReleaseClosesOnlyThatRunsTabs() async throws {
        let first = Client(port: port, token: attended.token)
        _ = try await first.call(1, "Browser.getVersion")
        let second = Client(port: port, token: night.token)
        _ = try await second.call(1, "Browser.getVersion")
        try await settle(0.2)
        let mine = broker.tabs(of: attended.token), theirs = broker.tabs(of: night.token)
        XCTAssertTrue(broker.release(token: attended.token), "$IDIR/browser release")
        try await settle(0.2)
        let closed = Set(fake.commands.filter { $0["method"] as? String == "Target.closeTarget" }
            .compactMap { ($0["params"] as? [String: Any])?["targetId"] as? String })
        XCTAssertEqual(closed, Set(mine))
        XCTAssertTrue(closed.isDisjoint(with: theirs), "the other run's tabs are left alone")
        let still = try await second.call(2, "Browser.getVersion")
        XCTAssertNotNil(still["result"], "and the other run goes on")
        XCTAssertFalse(broker.release(token: attended.token), "nothing left to release")
        second.close()
    }

    func testAnEndedRunLosesItAndAnUnusedBrowserIsQuit() async throws {
        let run = Client(port: port, token: attended.token)
        _ = try await run.call(1, "Browser.getVersion")
        broker.setRuns([night])
        try await settle()
        XCTAssertTrue(broker.leases.isEmpty, "the run ended: it is no longer using the browser")
        do { _ = try await run.call(2, "Browser.getVersion"); XCTFail("the socket of an ended run still works") } catch {}
        XCTAssertTrue(broker.browserRunning)
        broker.checkIdle(now: Date().addingTimeInterval(broker.idleLimit - 10))
        XCTAssertTrue(broker.browserRunning, "not yet")
        broker.checkIdle(now: Date().addingTimeInterval(broker.idleLimit + 1))
        XCTAssertFalse(broker.browserRunning, "nobody used it for a while: it is quit, not left open")
    }

    func testHeSigningInTakesItFromEveryRun() async throws {
        let run = Client(port: port, token: attended.token)
        _ = try await run.call(1, "Browser.getVersion")
        let other = Client(port: port, token: night.token)
        _ = try await other.call(1, "Browser.getVersion")
        broker.setUnavailable("signing in")
        XCTAssertTrue(broker.leases.isEmpty)
        let refused = await Client(port: port, token: attended.token).refusedStatus()
        XCTAssertEqual(refused, 503)
        broker.setUnavailable(nil)
        let back = Client(port: port, token: attended.token)
        _ = try await back.call(1, "Browser.getVersion")
        back.close()
    }

    // MARK: What passes

    func testNoRunReadsCookiesClosesTheBrowserOrTakesItWhole() async throws {
        let run = Client(port: port, token: attended.token)
        for method in ["Network.getAllCookies", "Storage.getCookies", "Browser.close", "Network.clearBrowserCookies",
                       "Target.attachToBrowserTarget", "Target.sendMessageToTarget"] {
            let answer = try await run.call(7, method)
            XCTAssertNotNil(answer["error"], method)
        }
        let forwarded = fake.commands.filter { $0["method"] as? String == "Target.attachToBrowserTarget" }.count
        XCTAssertEqual(forwarded, 2, "only Bulava's own: its watcher and this run's session")
        XCTAssertFalse(fake.methods().contains { BrowserBroker.forbidden.contains($0) && $0 != "Target.attachToBrowserTarget" },
                       "none of them reached the browser")
        run.close()
    }

    /// Google refuses to sign in to a browser an agent drives, whatever is typed into it. A run's tab
    /// that reaches Google's sign-in is told to Bulava, with the page the sign-in was for and the run
    /// whose tab it is — once per tab — so he signs in where nobody drives.
    func testGooglesSignInInARunsTabIsHandedToHim() async throws {
        final class Heard: @unchecked Sendable {
            let lock = NSLock()
            var calls: [(URL, String)] = []
        }
        let heard = Heard()
        broker.onSignInNeeded = { url, run in heard.lock.withLock { heard.calls.append((url, run.slug)) } }
        let run = Client(port: port, token: attended.token)
        _ = try await run.call(1, "Browser.getVersion")
        let other = Client(port: port, token: night.token)
        _ = try await other.call(1, "Browser.getVersion")
        try await settle(0.2)
        let tab = try XCTUnwrap(broker.tabs(of: attended.token).first)
        let signIn = "https://accounts.google.com/v3/signin/identifier?continue=https%3A%2F%2Fsearch.google.com%2Fsearch-console&flowName=GlifWebSignIn"
        fake.navigated(tab, to: signIn)
        fake.navigated(tab, to: signIn)
        fake.navigated(tab, to: "https://console.example/dashboard")
        fake.navigated("NOBODYS", to: signIn)
        try await settle(0.2)
        let calls = heard.lock.withLock { heard.calls }
        XCTAssertEqual(calls.map(\.0.absoluteString), ["https://search.google.com/search-console"],
                       "where the sign-in was for, once; nothing for an ordinary page or a tab no run has")
        XCTAssertEqual(calls.first?.1, attended.slug, "with the run whose tab it is")

        let theirs = try XCTUnwrap(broker.tabs(of: night.token).first)
        fake.navigated(theirs, to: signIn)
        try await settle(0.2)
        XCTAssertEqual(heard.lock.withLock { heard.calls.last?.1 }, night.slug, "another run's own tab is asked about for it")
        run.close(); other.close()
    }

    func testWhichPagesOnlyHeCanSignInOn() {
        let rejected = URL(string: "https://accounts.google.com/v3/signin/rejected?continue=https%3A%2F%2Fsearch.google.com%2Fsearch-console&dsh=S1")!
        XCTAssertEqual(BrowserBroker.signInOnlyHeCanDo(rejected)?.absoluteString, "https://search.google.com/search-console")
        XCTAssertEqual(BrowserBroker.signInOnlyHeCanDo(URL(string: "https://accounts.google.com/o/oauth2/v2/auth?client_id=x")!)?.absoluteString,
                       "https://accounts.google.com/", "a sign-in for another site: Google's own page")
        XCTAssertEqual(BrowserBroker.signInOnlyHeCanDo(URL(string: "https://accounts.google.com/signin?continue=javascript:alert(1)")!)?.absoluteString,
                       "https://accounts.google.com/", "nothing but a web page is opened for him")
        XCTAssertNil(BrowserBroker.signInOnlyHeCanDo(URL(string: "https://search.google.com/search-console")!))
        XCTAssertNil(BrowserBroker.signInOnlyHeCanDo(URL(string: "http://accounts.google.com/")!))
        XCTAssertNil(BrowserBroker.signInOnlyHeCanDo(URL(string: "https://accounts.google.com.evil.example/signin")!))
    }

    func testARunWithoutHimCannotOpenTheSitesHeKeeps() async throws {
        broker.setBlocked(["bank.example"])
        let run = Client(port: port, token: night.token)
        _ = try await run.call(0, "Browser.getVersion")
        try await settle(0.2)
        let tab = try XCTUnwrap(broker.tabs(of: night.token).first)
        let attach = try await run.call(1, "Target.attachToTarget", ["targetId": tab, "flatten": true])
        let session = try XCTUnwrap((attach["result"] as? [String: Any])?["sessionId"] as? String)
        let navigate = try await run.call(2, "Page.navigate", ["url": "https://online.bank.example/accounts"], session: session)
        XCTAssertNotNil(navigate["error"], "his bank, at night")
        XCTAssertEqual(navigate["sessionId"] as? String, session, "answered on the session it was asked on")
        let open = try await run.call(3, "Target.createTarget", ["url": "https://bank.example/"])
        XCTAssertNotNil(open["error"])
        let lift = try await run.call(4, "Network.emulateNetworkConditionsByRule", ["offline": false, "matchedNetworkConditions": []], session: session)
        XCTAssertNotNil(lift["error"], "the rule cannot be lifted by the run")
        let fine = try await run.call(5, "Page.navigate", ["url": "https://console.example/"], session: session)
        XCTAssertNil(fine["error"], "everything else is open")
        XCTAssertFalse(fake.commands.contains { ($0["method"] as? String) == "Page.navigate"
            && (($0["params"] as? [String: Any])?["url"] as? String)?.contains("bank") == true })
        run.close()
    }

    func testAChatHeIsInMayOpenThemAll() async throws {
        broker.setBlocked(["bank.example"])
        let run = Client(port: port, token: attended.token)
        let open = try await run.call(1, "Target.createTarget", ["url": "https://bank.example/"])
        XCTAssertNil(open["error"])
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

    /// Why he cannot sign in to Google in the window a run drives, and what Bulava does about it,
    /// against a real Chrome on a pipe: the page says it is driven (`navigator.webdriver`), which is
    /// what Google refuses; and a run's tab that opens Google's sign-in is handed to him at once.
    func testARealDrivenChromeSaysSoAndItsGoogleSignInIsHandedToHim() async throws {
        let chrome = try XCTUnwrap(ChromeApp.find(), "Google Chrome is not installed here")
        let profile = FileManager.default.temporaryDirectory.appendingPathComponent("bulava-browser-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: profile) }
        ChromeApp.prepare(profile: profile)
        let broker = BrowserBroker()
        broker.makeTransport = {
            try ChromePipe.launch(executable: ChromeApp.executable(of: chrome),
                                  arguments: ChromeApp.baseArguments(profile: profile) + ["--remote-debugging-pipe", "--headless=new", "about:blank"])
        }
        let handed = LockedBox<URL?>(nil)
        broker.onSignInNeeded = { url, _ in handed.set(url) }
        let port = broker.start(preferredPort: 0)
        defer { broker.stop(); broker.setUnavailable("test over") }
        let token = String(repeating: "d", count: 48)
        broker.setRuns([.init(token: token, slug: "real", title: "Real", unattended: false)])

        let client = BrowserBrokerTests.Client(port: port, token: token)
        _ = try await client.call(1, "Target.setDiscoverTargets", ["discover": true])
        let blank = try await client.call(2, "Target.createTarget", ["url": "about:blank"])
        let blankID = try XCTUnwrap((blank["result"] as? [String: Any])?["targetId"] as? String)
        let attached = try await client.call(3, "Target.attachToTarget", ["targetId": blankID, "flatten": true])
        let session = try XCTUnwrap((attached["result"] as? [String: Any])?["sessionId"] as? String)
        let driven = try await client.call(4, "Runtime.evaluate", ["expression": "navigator.webdriver", "returnByValue": true], session: session)
        let value = ((driven["result"] as? [String: Any])?["result"] as? [String: Any])?["value"] as? Bool
        XCTAssertEqual(value, true, "a browser on a DevTools pipe tells every page it is driven — Google reads that")

        _ = try await client.call(5, "Target.createTarget",
                                  ["url": "https://accounts.google.com/ServiceLogin?continue=https%3A%2F%2Fsearch.google.com%2Fsearch-console"])
        for _ in 0..<50 where handed.get() == nil { try await Task.sleep(for: .milliseconds(100)) }
        XCTAssertEqual(handed.get()?.absoluteString, "https://search.google.com/search-console",
                       "the sign-in is handed to him, for the page it was for")
        client.close()
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
/// Bulava's door to a real Chrome on a pipe: two runs connect with their tokens and work at the same
/// time, each in its own tabs; a run without him cannot open his sites. Skipped where node or that
/// package is not on this Mac.
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

    /// Two chats at once, each with the agent's own client, through Bulava's door to one real Chrome:
    /// both work at the same time, each sees only its own pages, and the sign-ins they share are the
    /// browser's. 13 Oct the second chat was turned away for as long as the first held the browser.
    func testTwoAgentsUseTheBrowserAtOnceEachInItsOwnTabs() async throws {
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
        let second = try client(night)
        defer { second.stop() }
        try await first.start()
        try await second.start()

        // Both at once.
        async let a = first.call("new_page", ["url": "data:text/html,<title>First</title><h1>FIRST-CHAT-PAGE</h1>"])
        async let b = second.call("new_page", ["url": "http://console.test:\(sites.port)/"])
        let (openedA, openedB) = try await (a, b)
        XCTAssertFalse(openedA.failed, openedA.text)
        XCTAssertFalse(openedB.failed, "the second run is not turned away: \(openedB.text)")
        XCTAssertEqual(Set(broker.leases.map(\.run.slug)), ["chat", "night"])

        let listedA = try await first.call("list_pages")
        let listedB = try await second.call("list_pages")
        XCTAssertTrue(listedA.text.contains("FIRST-CHAT-PAGE") || listedA.text.contains("data:text/html"), listedA.text)
        XCTAssertFalse(listedA.text.contains("console.test"), "the first run does not see the second's page: \(listedA.text)")
        XCTAssertTrue(listedB.text.contains("console.test"), listedB.text)
        XCTAssertFalse(listedB.text.contains("FIRST-CHAT-PAGE") || listedB.text.contains("data:text/html"),
                       "nor the second the first's: \(listedB.text)")

        let selected = try XCTUnwrap(listedA.text.split(separator: "\n").first { $0.contains("[selected]") }, listedA.text)
        let pageID = try XCTUnwrap(Int(selected.prefix { $0.isNumber }), listedA.text)
        let snapshot = try await first.call("take_snapshot", ["pageId": pageID])
        XCTAssertTrue(snapshot.text.contains("FIRST-CHAT-PAGE"), "the first run works in its page meanwhile: \(snapshot.text)")

        // A run without him cannot open his bank — Bulava's refusal, not a lookup failure.
        let bank = try await second.call("new_page", ["url": "https://bank.example/"])
        XCTAssertTrue(bank.text.contains("kept for the director"), bank.text)

        // The first lets go: its pages close, the second goes on untouched.
        first.stop()
        XCTAssertTrue(broker.release(token: chat.token) || !broker.isUsing(token: chat.token))
        try await Task.sleep(for: .seconds(1))
        XCTAssertTrue(broker.tabs(of: chat.token).isEmpty, "what the first run opened is gone with it")
        let after = try await second.call("list_pages")
        XCTAssertFalse(after.failed, after.text)
        XCTAssertTrue(after.text.contains("console.test"), "the second run's page is where it was: \(after.text)")
    }
}

/// His own tab, open in Bulava's browser in a chat he is in, while a run working without him uses the
/// same browser at the same time: the run cannot list it, attach to it, show, close or read it, nor
/// reach the site's storage or pages from a tab it does have; and a site he closes while the run is
/// at it is taken from it at once. Real Chrome, a local "bank" and "console" served on the loopback.
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
                    // A page that sends a browser nobody signed in with to the site's sign-in.
                    if request.hasPrefix("get /private") {
                        let moved = "HTTP/1.1 302 Found\r\nLocation: /login?next=/private\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
                        connection.send(content: Data(moved.utf8), completion: .contentProcessed { _ in connection.cancel() })
                        return
                    }
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

        // He, in a chat: opens his bank, and the bank's page is really there.
        let him = Recorder(port: door, token: chat.token)
        let created = try await him.call(1, "Target.createTarget", ["url": bankURL])
        let bank = try XCTUnwrap((created["result"] as? [String: Any])?["targetId"] as? String, "\(created)")
        let attachedToBank = try await him.call(3, "Target.attachToTarget", ["targetId": bank, "flatten": true])
        let bankSession = try XCTUnwrap((attachedToBank["result"] as? [String: Any])?["sessionId"] as? String)
        var seen = ""
        for attempt in 0..<40 where !seen.contains(Sites.secret) {
            seen = Self.text(try await him.call(10 + attempt, "Runtime.evaluate", ["expression": "document.body ? document.body.innerText : ''", "returnByValue": true], session: bankSession))
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTAssertTrue(seen.contains(Sites.secret), "with him there, his bank is readable: \(seen)")

        // A run without him comes in at the same time; his bank tab stays open, his chat stays in.
        broker.setBlocked(["bank.test"])
        let run = Recorder(port: door, token: night.token)
        let list = try await run.call(1, "Target.getTargets")
        let infos = (list["result"] as? [String: Any])?["targetInfos"] as? [[String: Any]] ?? []
        XCTAssertFalse(infos.contains { ($0["targetId"] as? String) == bank }, "his bank is not in the run's list: \(infos)")
        XCTAssertEqual(Set(broker.leases.map(\.run.slug)), ["chat", "night"], "both are in at once")

        for (n, method) in ["Target.attachToTarget", "Target.activateTarget", "Target.closeTarget", "Target.getTargetInfo",
                            "Target.exposeDevToolsProtocol", "Browser.getWindowForTarget"].enumerated() {
            let answer = try await run.call(100 + n, method, ["targetId": bank, "flatten": true])
            XCTAssertTrue(Self.failed(answer), "\(method) on his tab: \(answer)")
        }
        let relayed = try await run.call(110, "Target.sendMessageToTarget", ["targetId": bank, "message": "{}"])
        XCTAssertTrue(Self.failed(relayed))
        let onHisSession = try await run.call(111, "Runtime.evaluate", ["expression": "document.body.innerText"], session: bankSession)
        XCTAssertTrue(Self.failed(onHisSession), "nor through his session")

        // What Puppeteer asks for when it connects: the browser attaches the run to its own tabs only.
        _ = try await run.call(120, "Target.setDiscoverTargets", ["discover": true, "filter": [["type": "tab", "exclude": true], [:]]])
        _ = try await run.call(121, "Target.setAutoAttach", ["autoAttach": true, "waitForDebuggerOnStart": false, "flatten": true,
                                                             "filter": [["type": "page", "exclude": true], [:]]])
        let console = try await run.call(122, "Target.createTarget", ["url": consoleURL])
        let consoleTarget = try XCTUnwrap((console["result"] as? [String: Any])?["targetId"] as? String, "\(console)")
        let consoleAttach = try await run.call(123, "Target.attachToTarget", ["targetId": consoleTarget, "flatten": true])
        let consoleSession = try XCTUnwrap((consoleAttach["result"] as? [String: Any])?["sessionId"] as? String, "\(consoleAttach)")
        try await Task.sleep(for: .seconds(1.5))
        XCTAssertFalse(run.transcript.contains("bank.test"),
                       "nothing about his bank reaches the run, not even its address: \(run.transcript.split(separator: "\n").filter { $0.contains("bank.test") })")
        XCTAssertFalse(run.transcript.contains(bank), "nor its id")

        // From its console tab: his bank's storage, a way there, a request to it.
        let storage = try await run.call(130, "DOMStorage.getDOMStorageItems",
                                         ["storageId": ["securityOrigin": "http://bank.test:\(port)", "isLocalStorage": true]], session: consoleSession)
        XCTAssertTrue(Self.failed(storage), "his bank's storage, read from another tab: \(storage)")
        let there = try await run.call(131, "Page.navigate", ["url": bankURL], session: consoleSession)
        XCTAssertTrue(Self.failed(there))
        let fetched = try await run.call(132, "Runtime.evaluate", ["expression": "fetch('\(bankURL)').then(r => r.text()).catch(e => 'blocked: ' + e)",
                                                                  "awaitPromise": true, "returnByValue": true], session: consoleSession)
        XCTAssertFalse(Self.text(fetched).contains(Sites.secret), "the bank does not answer the run: \(fetched)")
        XCTAssertFalse(run.transcript.contains(Sites.secret), "his bank's contents never reached the run")

        // He closes the console to such runs while this one is at it: the tab is taken from it.
        broker.setBlocked(["bank.test", "console.test"])
        var taken = false
        for _ in 0..<40 where !taken {
            taken = run.events.contains { $0["method"] as? String == "Target.detachedFromTarget"
                && ($0["params"] as? [String: Any])?["sessionId"] as? String == consoleSession }
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTAssertTrue(taken, "a site he closes mid-work is taken from the run at once")
        let after = try await run.call(140, "Runtime.evaluate", ["expression": "1"], session: consoleSession)
        XCTAssertTrue(Self.failed(after), "nothing more can be done in the tab taken from it")
        run.close()
        XCTAssertTrue(broker.release(token: night.token))
        try await Task.sleep(for: .milliseconds(400))

        // His tab was never closed, and his chat never lost the browser.
        let again = try await him.call(200, "Target.getTargets")
        let still = ((again["result"] as? [String: Any])?["targetInfos"] as? [[String: Any]] ?? []).compactMap { $0["url"] as? String }
        XCTAssertTrue(still.contains { $0.contains("bank.test") }, "his bank tab is where he left it: \(still)")
        let stillReadable = Self.text(try await him.call(201, "Runtime.evaluate", ["expression": "document.body.innerText", "returnByValue": true], session: bankSession))
        XCTAssertTrue(stillReadable.contains(Sites.secret), "and his session in it still works: \(stillReadable)")
        him.close()
    }
}

/// Bulava's own look at a site, to keep his sign-in alive and see when it has run out: opened in a
/// tab no run sees, in a browser with no window when no run is using it, and closed again.
nonisolated final class AccountBrowserSignInCheckTests: XCTestCase {

    /// A browser that takes commands and never answers, and can be made to die.
    final class SilentBrowser: CDPTransport, @unchecked Sendable {
        private let lock = NSLock()
        private var exit: (@Sendable () -> Void)?
        private var alive = true
        var isRunning: Bool { lock.withLock { alive } }
        func send(_ message: Data) {}
        func listen(onMessage: @escaping @Sendable (Data) -> Void, onExit: @escaping @Sendable () -> Void) {
            lock.withLock { exit = onExit }
        }
        func terminate() { die() }
        func die() {
            let gone: (@Sendable () -> Void)? = lock.withLock { guard alive else { return nil }; alive = false; return exit }
            gone?()
        }
    }

    private func visitAnswered(_ broker: BrowserBroker, settle: TimeInterval = 0.1, meanwhile: () -> Void) async -> (answered: Bool, url: URL?) {
        let box = LockedBox<(Bool, URL?)>((false, nil))
        broker.visit(URL(string: "https://console.example/")!, settle: settle) { url in box.set((true, url)) }
        meanwhile()
        for _ in 0..<60 where !box.get().0 { try? await Task.sleep(for: .milliseconds(50)) }
        return box.get()
    }

    /// The visit used to wait for ever when Chrome went before answering, and the sign-in check with
    /// it — and every check after it, since one was still "running".
    func testAVisitIsAnsweredWhenTheBrowserDiesStopsOrNeverAnswers() async throws {
        let broker = BrowserBroker()
        broker.visitTimeout = 0.3
        let silent = LockedBox<SilentBrowser?>(nil)
        broker.makeQuietTransport = { let made = SilentBrowser(); silent.set(made); return made }
        broker.start(preferredPort: 0)
        defer { broker.stop() }

        let died = await visitAnswered(broker) { usleep(100_000); silent.get()?.die() }
        XCTAssertTrue(died.answered, "Chrome gone before it answered: the visit is answered")
        XCTAssertNil(died.url)

        let stopped = await visitAnswered(broker) { usleep(100_000); broker.setUnavailable("he is signing in") }
        XCTAssertTrue(stopped.answered, "the browser taken for signing in: the visit is answered")
        broker.setUnavailable(nil)

        let silentOne = await visitAnswered(broker) {}
        XCTAssertTrue(silentOne.answered, "a browser that never answers: the visit is answered after its time")
        XCTAssertNil(silentOne.url)
    }

    @MainActor
    func testTheSignInCheckEndsWhenTheBrowserGoesMidVisit() async throws {
        guard ChromeApp.find() != nil else { throw XCTSkip("Google Chrome is not installed") }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("bulava-check-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let browser = AccountBrowser(folder: folder)
        _ = browser.addSite("console.example")
        let model = AppModel()
        browser.attach(model, enabled: true, stateDir: nil)
        defer { browser.detach() }
        let silent = LockedBox<SilentBrowser?>(nil)
        browser.broker.makeQuietTransport = { let made = SilentBrowser(); silent.set(made); return made }
        browser.noteSignedIn(try XCTUnwrap(browser.sites.first?.id))

        let check = Task { await browser.checkSignIns(force: true) }
        for _ in 0..<40 where silent.get() == nil { try await Task.sleep(for: .milliseconds(50)) }
        XCTAssertTrue(browser.checkingSignIns)
        silent.get()?.die()
        _ = await check.value
        XCTAssertFalse(browser.checkingSignIns, "the check ended; the next one can run")
        XCTAssertNil(browser.sites.first?.checkedAt, "and nothing was concluded from a visit that never happened")
    }

    func testWhatASignedOutPageLooksLike() {
        func out(_ opened: String, _ landed: String) -> Bool {
            BrowserSite.asksToSignIn(opened: URL(string: opened)!, landed: URL(string: landed)!)
        }
        XCTAssertTrue(out("https://play.google.com/console", "https://accounts.google.com/v3/signin/identifier?continue=x"))
        XCTAssertTrue(out("https://appstoreconnect.apple.com/", "https://idmsa.apple.com/IDMSWebAuth/signin"))
        XCTAssertTrue(out("https://analytics.stepanok.com/websites", "https://analytics.stepanok.com/login"))
        XCTAssertFalse(out("https://analytics.stepanok.com/websites", "https://analytics.stepanok.com/websites"))
        XCTAssertFalse(out("https://play.google.com/console", "https://play.google.com/console/u/0/developers/123/app-list"))
        XCTAssertFalse(out("https://example.com/login", "https://example.com/login"), "a page he chose that is itself a sign-in is not news")
    }

    func testAVisitSaysWhereThePageLandedAndNoRunSeesIt() async throws {
        guard let chrome = ChromeApp.find() else { throw XCTSkip("Google Chrome is not installed") }
        let sites = try AccountBrowserProtectedTabTests.Sites()
        defer { sites.stop() }
        let profile = FileManager.default.temporaryDirectory.appendingPathComponent("bulava-visit-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: profile) }
        let broker = BrowserBroker()
        let quiet = LockedBox(false)
        let launch: @Sendable (Bool) throws -> CDPTransport = { headless in
            if headless { quiet.set(true) }
            return try ChromePipe.launch(executable: ChromeApp.executable(of: chrome),
                                         arguments: ChromeApp.baseArguments(profile: profile)
                                            + ["--remote-debugging-pipe", "--headless=new", "--host-resolver-rules=MAP *.test 127.0.0.1", "about:blank"])
        }
        broker.makeTransport = { try launch(false) }
        broker.makeQuietTransport = { try launch(true) }
        let door = broker.start(preferredPort: 0)
        defer { broker.setUnavailable("test over"); broker.stop() }

        func visit(_ address: String) async -> URL? {
            await withCheckedContinuation { done in broker.visit(URL(string: address)!, settle: 2) { done.resume(returning: $0) } }
        }
        let signedOut = await visit("http://console.test:\(sites.port)/private")
        XCTAssertTrue(quiet.get(), "with no run using it, the browser opens without a window")
        XCTAssertEqual(signedOut?.path, "/login", "where a signed-out browser is sent: \(String(describing: signedOut))")
        XCTAssertTrue(BrowserSite.asksToSignIn(opened: URL(string: "http://console.test:\(sites.port)/private")!, landed: signedOut!))

        let token = String(repeating: "k", count: 48)
        broker.setRuns([.init(token: token, slug: "run", title: "Run", unattended: false)])
        let run = AccountBrowserProtectedTabTests.Recorder(port: door, token: token)
        _ = try await run.call(1, "Target.setDiscoverTargets", ["discover": true])
        let fine = await visit("http://console.test:\(sites.port)/")
        XCTAssertEqual(fine?.host, "console.test")
        let list = try await run.call(2, "Target.getTargets")
        let urls = ((list["result"] as? [String: Any])?["targetInfos"] as? [[String: Any]] ?? []).compactMap { $0["url"] as? String }
        XCTAssertFalse(urls.contains { $0.contains("console.test") }, "Bulava's own tab is no run's: \(urls)")
        XCTAssertFalse(run.transcript.contains("console.test"), "nothing about it reached the run")
        run.close()
        broker.quitIfUnused()
    }
}
