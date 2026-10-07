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

        func ask(_ op: String, _ who: String = token) throws -> [String: Any] {
            let request = state.appendingPathComponent("req-\(UUID().uuidString).json")
            try JSONSerialization.data(withJSONObject: ["op": op, "token": who]).write(to: request)
            return browser.serve(request)
        }
        XCTAssertEqual(try ask("status")["state"] as? String, "free")
        XCTAssertEqual(try ask("release")["released"] as? Bool, false, "nothing held, nothing released")
        XCTAssertEqual(try ask("dance")["ok"] as? Bool, false)

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

        browser.setEnabled(false)
        let off = try JSONSerialization.jsonObject(with: Data(contentsOf: supervisor.appendingPathComponent("browser/service.json"))) as? [String: Any]
        XCTAssertEqual(off?["enabled"] as? Bool, false, "switched off: the engine gives runs what it gave before")
        unsetenv("BULAVA_STATE_DIR")
    }
}
