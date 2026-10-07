import XCTest
@testable import Bulava

/// Bulava's browser as the app keeps it: the sites he signed in to and which of them a run without
/// him may use, what the engine is told, and what a run hears from `$IDIR/browser`.
nonisolated final class AccountBrowserTests: XCTestCase {

    private var state: URL!

    override func setUp() async throws {
        state = FileManager.default.temporaryDirectory.appendingPathComponent("bulava-account-browser-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: state, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: state)
    }

    @MainActor
    func testASiteIsKeptForHimUntilHeOpensItToRunsWithoutHim() throws {
        let folder = state.appendingPathComponent("browser")
        let browser = AccountBrowser(folder: folder)
        let bank = try XCTUnwrap(browser.addSite("https://www.bank.example/login"))
        let console = try XCTUnwrap(browser.addSite("play.google.com/console"))
        XCTAssertNil(browser.addSite("not a site"))
        XCTAssertEqual(browser.addSite("bank.example")?.id, bank.id, "the same site is not added twice")
        XCTAssertEqual(Set(browser.blockedHosts), ["bank.example", "play.google.com"], "a new site is his until he says otherwise")
        browser.setWithoutMe(console.id, true)
        XCTAssertEqual(browser.blockedHosts, ["bank.example"])

        let reopened = AccountBrowser(folder: folder)
        XCTAssertEqual(reopened.sites.map(\.host), ["bank.example", "play.google.com"], "kept across a restart")
        XCTAssertEqual(reopened.blockedHosts, ["bank.example"])
        reopened.removeSite(bank.id)
        XCTAssertTrue(AccountBrowser(folder: folder).blockedHosts.isEmpty)
    }

    @MainActor
    func testTheEngineIsToldWhereTheDoorIsAndARunHearsWhoHasIt() async throws {
        guard ChromeApp.find() != nil else { throw XCTSkip("Google Chrome is not installed") }
        let supervisor = state.appendingPathComponent("supervisor")
        let project = state.appendingPathComponent("project")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let instance = supervisor.appendingPathComponent("instances/\(Slug.forPath(project.path))")
        try FileManager.default.createDirectory(at: instance, withIntermediateDirectories: true)
        for (name, text) in ["project": project.path, "session": "ns-browser", "run-id": "RUN-B", "started-at": ""] {
            try text.write(to: instance.appendingPathComponent(name), atomically: true, encoding: .utf8)
        }
        let token = String(repeating: "f", count: 48)
        try #"{"token":"\#(token)","unattended":false}"#.write(to: instance.appendingPathComponent("browser.json"), atomically: true, encoding: .utf8)

        setenv("BULAVA_STATE_DIR", state.appendingPathComponent("app").path, 1)
        let model = AppModel()
        await model.client.updatePaths(SupervisorPaths(stateDir: supervisor))
        await model.refresh()
        let browser = AccountBrowser(folder: state.appendingPathComponent("browser"))
        _ = browser.addSite("bank.example")
        browser.attach(model, enabled: true, stateDir: supervisor)
        defer { browser.detach() }

        let service = try JSONSerialization.jsonObject(with: Data(contentsOf: supervisor.appendingPathComponent("browser/service.json"))) as? [String: Any]
        XCTAssertEqual(service?["enabled"] as? Bool, true)
        XCTAssertEqual(service?["pid"] as? Int32, ProcessInfo.processInfo.processIdentifier)
        XCTAssertEqual(service?["port"] as? Int, Int(browser.port))
        XCTAssertEqual(service?["blocked"] as? [String], ["bank.example"], "the engine closes his sites to runs without him")

        func ask(_ op: String, _ who: String = token, url: String? = nil) throws -> [String: Any] {
            let request = state.appendingPathComponent("req-\(UUID().uuidString).json")
            var object = ["op": op, "token": who]
            if let url { object["url"] = url }
            try JSONSerialization.data(withJSONObject: object).write(to: request)
            return browser.serve(request)
        }
        XCTAssertEqual(try ask("status")["state"] as? String, "free")
        XCTAssertEqual(try ask("release")["released"] as? Bool, false, "nothing held, nothing released")
        XCTAssertEqual(try ask("dance")["ok"] as? Bool, false)

        // A run reached a sign-in: he is asked to sign in himself, where nobody drives the browser.
        XCTAssertEqual(try ask("signIn", url: "search console")["ok"] as? Bool, false, "an address, or nothing")
        let toastsBefore = model.toasts
        let stranger = try ask("signIn", String(repeating: "0", count: 48), url: "https://search.google.com/search-console")
        XCTAssertEqual(stranger["ok"] as? Bool, false, "a token of no run asks him for nothing")
        XCTAssertNil(browser.signInRequest)
        XCTAssertEqual(model.toasts, toastsBefore, "and nothing is shown for it")
        XCTAssertEqual(try ask("signIn", url: "https://search.google.com/search-console")["asked"] as? Bool, true)
        XCTAssertEqual(browser.signInRequest?.site, "search.google.com")
        XCTAssertEqual(browser.signInRequest?.runSlug, Slug.forPath(project.path), "for the run that asked")
        XCTAssertEqual(model.toasts.last?.key, AccountBrowser.signInToastKey, "said in Bulava, with the way to do it")
        let first = browser.signInRequest?.at
        _ = try ask("signIn", url: "https://search.google.com/search-console/performance")
        XCTAssertEqual(browser.signInRequest?.at, first, "the same site again is the same request")
        browser.dismissSignInRequest()
        XCTAssertNil(browser.signInRequest)
        XCTAssertFalse(model.toasts.contains { $0.key == AccountBrowser.signInToastKey })

        // The run takes it, the way chrome-devtools-mcp would.
        try await Task.sleep(for: .milliseconds(200))
        let client = BrowserBrokerTests.Client(port: browser.port, token: token)
        let fake = BrowserBrokerTests.FakeBrowser()
        browser.broker.makeTransport = { fake }
        _ = try await client.call(1, "Browser.getVersion")
        XCTAssertEqual(try ask("status")["state"] as? String, "yours")
        let other = try ask("status", String(repeating: "0", count: 48))
        XCTAssertEqual(other["state"] as? String, "busy")
        XCTAssertEqual(other["holder"] as? String, "project", "named by its chat, or by its project when it has none")
        XCTAssertEqual(try ask("release")["released"] as? Bool, true)
        client.close()

        // Bulava saw a sign-in in a tab of the run's, but by the time it is read the run has let go
        // of the browser — or has ended: nobody waits, so he is asked for nothing.
        let run = BrowserBroker.Run(token: token, slug: Slug.forPath(project.path), title: "project", unattended: false)
        let google = URL(string: "https://search.google.com/search-console")!
        let shown = model.toasts
        browser.signInSeen(at: google, by: run)
        XCTAssertNil(browser.signInRequest, "the run let go of the browser")
        browser.askToSignIn(at: google, for: BrowserBroker.Run(token: String(repeating: "9", count: 48), slug: "gone",
                                                               title: "Gone", unattended: false))
        XCTAssertNil(browser.signInRequest, "a run that has ended")
        XCTAssertEqual(model.toasts, shown, "and nothing is shown for either")

        browser.setEnabled(false)
        let off = try JSONSerialization.jsonObject(with: Data(contentsOf: supervisor.appendingPathComponent("browser/service.json"))) as? [String: Any]
        XCTAssertEqual(off?["enabled"] as? Bool, false, "switched off: the engine gives runs what it gave before")
        unsetenv("BULAVA_STATE_DIR")
    }

    /// A sign-in Bulava saw in a run's tab belongs to that run's lease of the browser. Run A reaches
    /// Google's sign-in: he is asked, in A's chat on the phone. A lets go of the browser: the request
    /// goes. Run B then reaches the same sign-in in the same tab: he is asked again, for B, in B's chat.
    @MainActor
    func testAnAutomaticSignInGoesWithItsLeaseAndTheNextRunIsAskedForItself() async throws {
        guard ChromeApp.find() != nil else { throw XCTSkip("Google Chrome is not installed") }
        let supervisor = state.appendingPathComponent("supervisor")
        func run(_ name: String, _ token: String) throws -> URL {
            let project = state.appendingPathComponent(name)
            try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
            let instance = supervisor.appendingPathComponent("instances/\(Slug.forPath(project.path))")
            try FileManager.default.createDirectory(at: instance, withIntermediateDirectories: true)
            for (file, text) in ["project": project.path, "session": "ns-\(name)", "run-id": "RUN-\(name)", "started-at": ""] {
                try text.write(to: instance.appendingPathComponent(file), atomically: true, encoding: .utf8)
            }
            try #"{"token":"\#(token)","unattended":false}"#.write(to: instance.appendingPathComponent("browser.json"), atomically: true, encoding: .utf8)
            return project
        }
        let tokenA = String(repeating: "a", count: 48), tokenB = String(repeating: "b", count: 48)
        let projectA = try run("alpha", tokenA), projectB = try run("beta", tokenB)

        setenv("BULAVA_STATE_DIR", state.appendingPathComponent("app").path, 1)
        defer { unsetenv("BULAVA_STATE_DIR") }
        let model = AppModel()
        await model.client.updatePaths(SupervisorPaths(stateDir: supervisor))
        await model.refresh()
        let product = model.products.add(name: "Ledger")
        let chatA = model.conversations.newChat(for: product.id)
        model.conversations.bindSession(ChatSessionBinding(primaryProjectID: nil, projectPath: projectA.path, activeRunID: "RUN-alpha"), to: chatA.id)
        let chatB = model.conversations.newChat(for: product.id)
        model.conversations.bindSession(ChatSessionBinding(primaryProjectID: nil, projectPath: projectB.path, activeRunID: "RUN-beta"), to: chatB.id)

        let browser = model.browser
        browser.attach(model, enabled: true, stateDir: supervisor)
        defer { browser.detach() }
        let fake = BrowserBrokerTests.FakeBrowser()
        browser.broker.makeTransport = { fake }
        browser.refreshRuns()
        try await Task.sleep(for: .milliseconds(200))

        func waiting() -> [String] {
            LinkProjection.build(model, desktop: LinkDesktop(id: "mac", name: "Mac", version: "1", language: "en"), openChats: [])
                .home.attention.map(\.id).filter { $0.hasPrefix("signin:") }
        }
        func settle() async throws { try await Task.sleep(for: .milliseconds(400)) }
        let signIn = #"{"method":"Target.targetInfoChanged","params":{"targetInfo":{"targetId":"G1","type":"page","url":"https://accounts.google.com/v3/signin/identifier?continue=https%3A%2F%2Fsearch.google.com%2Fsearch-console"}}}"#

        let a = BrowserBrokerTests.Client(port: browser.port, token: tokenA)
        _ = try await a.call(1, "Browser.getVersion")
        fake.emit(signIn)
        try await settle()
        XCTAssertEqual(browser.signInRequest?.runSlug, Slug.forPath(projectA.path))
        XCTAssertEqual(waiting(), ["signin:\(chatA.id.uuidString):search.google.com"], "asked, in A's chat")

        XCTAssertTrue(browser.broker.release(token: tokenA))
        a.close()
        try await settle()
        XCTAssertNil(browser.signInRequest, "A let go of the browser: nobody waits for that sign-in")
        XCTAssertEqual(waiting(), [])
        XCTAssertFalse(model.toasts.contains { $0.key == AccountBrowser.signInToastKey })

        let b = BrowserBrokerTests.Client(port: browser.port, token: tokenB)
        _ = try await b.call(1, "Browser.getVersion")
        fake.emit(signIn)
        try await settle()
        XCTAssertEqual(browser.signInRequest?.runSlug, Slug.forPath(projectB.path), "the same tab and site, now B's")
        XCTAssertEqual(waiting(), ["signin:\(chatB.id.uuidString):search.google.com"], "asked again, in B's chat")
        b.close()
    }
}
