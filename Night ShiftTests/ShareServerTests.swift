import XCTest
@testable import Bulava

/// What is shared with the phone over the home Wi-Fi, and what never is.
///
/// A link is a key to a folder on this Mac, readable by anyone on the same Wi-Fi who has it. Pinned
/// here: only what is inside a known project folder is shared, never a whole project, never
/// anything hidden; a site brings its own folder (and finds its root-relative assets), a file is
/// shared alone; the server answers only to this Mac's own names, refuses every way of climbing
/// out of a share, renders notes as pages and serves video in ranges — and it does all of that on a
/// real socket.
nonisolated final class ShareServerTests: XCTestCase {

    private var dir: URL!
    private var project: URL!

    override func setUp() async throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("bulava-share-\(UUID().uuidString)")
            .resolvingSymlinksInPath()
        project = dir.appendingPathComponent("project")
        let fm = FileManager.default
        let site = project.appendingPathComponent("artifacts/site")
        try fm.createDirectory(at: site.appendingPathComponent("assets"), withIntermediateDirectories: true)
        try fm.createDirectory(at: project.appendingPathComponent(".git"), withIntermediateDirectories: true)
        try "<!doctype html><link rel=stylesheet href=\"/assets/app.css\"><h1>Site</h1>".write(
            to: site.appendingPathComponent("index.html"), atomically: true, encoding: .utf8)
        try "body{color:red}".write(to: site.appendingPathComponent("assets/app.css"), atomically: true, encoding: .utf8)
        try "SECRET=1".write(to: site.appendingPathComponent(".env"), atomically: true, encoding: .utf8)
        try "# План\n\n| a | b |\n|---|---|\n| 1 | 2 |".write(
            to: project.appendingPathComponent("artifacts/план нічний.md"), atomically: true, encoding: .utf8)
        try "<h1>root page</h1>".write(to: project.appendingPathComponent("index.html"), atomically: true, encoding: .utf8)
        try "code".write(to: project.appendingPathComponent("main.swift"), atomically: true, encoding: .utf8)
        try "0123456789".write(to: project.appendingPathComponent("artifacts/clip.mp4"), atomically: true, encoding: .utf8)
        try "x".write(to: project.appendingPathComponent(".git/config"), atomically: true, encoding: .utf8)
        try "outside".write(to: dir.appendingPathComponent("outside.txt"), atomically: true, encoding: .utf8)
        try fm.createSymbolicLink(at: site.appendingPathComponent("escape.txt"),
                                  withDestinationURL: dir.appendingPathComponent("outside.txt"))
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: dir)
    }

    // MARK: What may be shared

    func testOnlyWhatIsInsideAKnownProjectAndNotHiddenIsShared() throws {
        let roots = [project!]
        guard case .success(let site) = ShareRules.decide(project.appendingPathComponent("artifacts/site"), within: roots) else {
            return XCTFail("a site folder is shared")
        }
        XCTAssertEqual(site.scope, .site)
        XCTAssertEqual(site.entry, "index.html")
        guard case .success(let page) = ShareRules.decide(project.appendingPathComponent("artifacts/site/index.html"), within: roots) else {
            return XCTFail("a page is shared with its folder")
        }
        XCTAssertEqual(page.scope, .site)
        guard case .success(let rootPage) = ShareRules.decide(project.appendingPathComponent("index.html"), within: roots) else {
            return XCTFail("a page at the project's root is shared")
        }
        XCTAssertEqual(rootPage.scope, .file, "…alone: the repository beside it is never shared")
        guard case .success(let note) = ShareRules.decide(project.appendingPathComponent("artifacts/план нічний.md"), within: roots) else {
            return XCTFail("a note is shared")
        }
        XCTAssertEqual(note.scope, .file)

        let refused: [URL] = [
            project,                                                   // a whole project
            project.appendingPathComponent(".git/config"),            // hidden
            project.appendingPathComponent("artifacts/site/.env"),    // hidden
            dir.appendingPathComponent("outside.txt"),                // not in a project
            project.appendingPathComponent("artifacts/site/escape.txt"), // a symlink out
            project.appendingPathComponent("nope.md"),                // not there
        ]
        for url in refused {
            if case .success = ShareRules.decide(url, within: roots) { XCTFail("shared what must not be: \(url.path)") }
        }
    }

    @MainActor
    func testTheSameThingIsTheSameLinkAndRevokingEndsIt() throws {
        let store = ShareStore(file: dir.appendingPathComponent("links.json"))
        guard case .success(let first) = store.register(project.appendingPathComponent("artifacts/site"), within: [project]),
              case .success(let again) = store.register(project.appendingPathComponent("artifacts/site/index.html"), within: [project])
        else { return XCTFail("shared") }
        XCTAssertEqual(first.token, again.token, "one site, one link")
        XCTAssertGreaterThanOrEqual(first.token.count, 20, "a token nobody guesses")
        let mode = try FileManager.default.attributesOfItem(atPath: store.file.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(mode?.intValue, 0o600, "the keys are readable by this user only")
        let reread = ShareStore(file: store.file)
        XCTAssertEqual(reread.links, store.links, "links survive a restart")
        store.revoke(first.token)
        XCTAssertNil(store.link(token: first.token))
    }

    // MARK: What the server answers

    private func shares() throws -> (site: ShareLink, note: ShareLink, clip: ShareLink) {
        func link(_ path: String) throws -> ShareLink {
            guard case .success(let d) = ShareRules.decide(project.appendingPathComponent(path), within: [project]) else {
                throw NSError(domain: "share", code: 1)
            }
            return ShareLink(token: ShareRules.newToken(), root: d.root.path, entry: d.entry, scope: d.scope,
                             title: d.entry, project: project.path, createdAt: Date())
        }
        return (try link("artifacts/site"), try link("artifacts/план нічний.md"), try link("artifacts/clip.mp4"))
    }

    private let hosts = ShareHTTP.Hosts(names: ["127.0.0.1", "192.168.1.20", "mac.local", "localhost", "::1"], port: 47292)

    private func get(_ target: String, host: String = "192.168.1.20:47292", headers: [String: String] = [:],
                     method: String = "GET", links: [ShareLink]) -> ShareHTTP.Response {
        var all = ["host": host]
        for (k, v) in headers { all[k.lowercased()] = v }
        let request = ShareHTTP.Request(method: method, target: target, headers: all)
        return ShareHTTP.respond(request, hosts: hosts, link: { token in links.first { $0.token == token } })
    }

    private func text(_ r: ShareHTTP.Response) -> String {
        switch r.body {
        case .data(let d): return String(decoding: d, as: UTF8.self)
        case .file(let path, let offset, let length):
            let h = FileHandle(forReadingAtPath: path)!
            try? h.seek(toOffset: UInt64(offset))
            return String(decoding: (try? h.read(upToCount: Int(length))) ?? Data(), as: UTF8.self)
        case .none: return ""
        }
    }

    func testASiteOpensWithItsOwnAssetsAndRoutes() throws {
        let (site, _, _) = try shares()
        let links = [site]
        let open = get("/s/\(site.token)/", links: links)
        XCTAssertEqual(open.status, 302)
        XCTAssertEqual(open.header("Location"), "/s/\(site.token)/index.html")
        let page = get("/s/\(site.token)/index.html", links: links)
        XCTAssertEqual(page.status, 200)
        XCTAssertEqual(page.header("Content-Type"), "text/html; charset=utf-8")
        XCTAssertTrue(text(page).contains("<h1>Site</h1>"))
        XCTAssertEqual(page.header("Cache-Control"), "no-store")
        XCTAssertEqual(page.header("X-Content-Type-Options"), "nosniff")

        // `/assets/app.css` from that page: the build's root-relative path, found by its Referer.
        let asset = get("/assets/app.css", headers: ["Referer": "http://192.168.1.20:47292/s/\(site.token)/index.html"], links: links)
        XCTAssertEqual(asset.status, 200)
        XCTAssertEqual(asset.header("Content-Type"), "text/css; charset=utf-8")
        XCTAssertEqual(text(asset), "body{color:red}")
        XCTAssertEqual(get("/assets/app.css", links: links).status, 404, "without a page it came from, it is nobody's")
        XCTAssertEqual(get("/assets/app.css", headers: ["Referer": "http://evil.example/s/\(site.token)/"], links: links).status, 404,
                       "a page elsewhere cannot borrow a share by naming it")

        // A route the page draws itself.
        let route = get("/s/\(site.token)/settings/profile", headers: ["Accept": "text/html,*/*"], links: links)
        XCTAssertEqual(route.status, 200)
        XCTAssertTrue(text(route).contains("<h1>Site</h1>"))
        XCTAssertEqual(get("/s/\(site.token)/missing.js", headers: ["Accept": "*/*"], links: links).status, 404)
    }

    func testNoWayOutOfAShare() throws {
        let (site, note, _) = try shares()
        let links = [site, note]
        let attempts = [
            "/s/\(site.token)/../main.swift",
            "/s/\(site.token)/%2e%2e/main.swift",
            "/s/\(site.token)/assets/%2E%2E/%2E%2E/main.swift",
            "/s/\(site.token)/.env",
            "/s/\(site.token)/escape.txt",                // a symlink inside the share
            "/s/\(site.token)//etc/passwd",
            "/s/\(note.token)/../site/index.html",
            "/s/\(note.token)/clip.mp4",                 // a file share opens its one file only
            "/s/nosuchtoken/index.html",
            "/",
            "/etc/passwd",
        ]
        for target in attempts {
            let r = get(target, links: links)
            XCTAssertTrue([400, 404].contains(r.status), "\(target) → \(r.status)")
            XCTAssertFalse(text(r).contains("code") && !text(r).contains("<p>"), "\(target) leaked a file")
            XCTAssertFalse(text(r).contains("outside"), "\(target) leaked what the symlink points at")
            XCTAssertFalse(text(r).contains("SECRET"), "\(target) leaked a hidden file")
        }
        XCTAssertEqual(get("/s/\(site.token)/a%00b", links: links).status, 400, "a NUL in a path is not a path")
        XCTAssertEqual(get("/s/\(site.token)/index.html", method: "POST", links: links).status, 405)
    }

    func testOnlyThisMacsOwnNamesAreAnswered() throws {
        let (site, _, _) = try shares()
        let target = "/s/\(site.token)/index.html"
        XCTAssertEqual(get(target, host: "mac.local:47292", links: [site]).status, 200)
        XCTAssertEqual(get(target, host: "[::1]:47292", links: [site]).status, 200)
        XCTAssertEqual(get(target, host: "127.0.0.1:47292", links: [site]).status, 200)
        XCTAssertEqual(get(target, host: "evil.example:47292", links: [site]).status, 421, "a rebound name is refused")
        XCTAssertEqual(get(target, host: "192.168.1.20:8080", links: [site]).status, 421, "and so is another port")
        XCTAssertEqual(get(target, host: "", links: [site]).status, 421)
        XCTAssertNil(ShareHTTP.parse(Data("GET / HTTP/1.1\r\nHost: a\r\nHost: b".utf8)), "two Hosts is not a request")
    }

    func testANoteIsAPageAndAVideoComesInRanges() throws {
        let (_, note, clip) = try shares()
        let links = [note, clip]
        let page = get(note.path, links: links)
        XCTAssertEqual(page.status, 200)
        XCTAssertEqual(page.header("Content-Type"), "text/html; charset=utf-8")
        XCTAssertTrue(text(page).contains("<h1>План</h1>"))
        XCTAssertTrue(text(page).contains("<table>"))
        XCTAssertTrue(note.path.contains("%D0%BF%D0%BB%D0%B0%D0%BD%20"), "a Ukrainian name, encoded in the address: \(note.path)")
        let raw = get(note.path + "?raw=1", links: links)
        XCTAssertEqual(raw.header("Content-Type"), "text/plain; charset=utf-8")
        XCTAssertTrue(text(raw).hasPrefix("# План"))

        let part = get(clip.path, headers: ["Range": "bytes=2-5"], links: links)
        XCTAssertEqual(part.status, 206)
        XCTAssertEqual(part.header("Content-Range"), "bytes 2-5/10")
        XCTAssertEqual(text(part), "2345")
        XCTAssertEqual(part.header("Content-Type"), "video/mp4")
        XCTAssertEqual(get(clip.path, headers: ["Range": "bytes=50-60"], links: links).status, 416)
        XCTAssertEqual(text(get(clip.path, headers: ["Range": "bytes=-3"], links: links)), "789")
    }

    // MARK: An agent's request (`$IDIR/phone-link`)

    @MainActor
    func testAnAgentSharesFromItsOwnProjectAndNothingElse() async throws {
        setenv("BULAVA_STATE_DIR", dir.appendingPathComponent("app").path, 1)
        let model = AppModel()
        _ = model.projects.add(path: project.path)
        let center = ShareCenter(store: ShareStore(file: dir.appendingPathComponent("links.json")))
        center.server.preferredPort = 0
        center.model = model
        defer { center.server.stop() }

        func serve(_ body: [String: Any]) async throws -> [String: Any] {
            let request = dir.appendingPathComponent("request-\(UUID().uuidString).json")
            try JSONSerialization.data(withJSONObject: body).write(to: request)
            return await center.serve(request)
        }

        let shared = try await serve(["path": "artifacts/site", "project": project.path, "title": "Сайт"])
        XCTAssertEqual(shared["ok"] as? Bool, true, "\(shared)")
        let urls = try XCTUnwrap(shared["urls"] as? [String])
        XCTAssertFalse(urls.isEmpty)
        XCTAssertTrue(urls.allSatisfy { $0.hasPrefix("http://") && $0.hasSuffix("/index.html") }, "\(urls)")
        XCTAssertEqual(center.store.links.first?.title, "Сайт")

        let stranger = try await serve(["path": dir.appendingPathComponent("outside.txt").path, "project": dir.path])
        XCTAssertEqual(stranger["ok"] as? Bool, false, "a folder Bulava does not know is not a project to share from")
        let whole = try await serve(["path": ".", "project": project.path])
        XCTAssertEqual(whole["ok"] as? Bool, false)
        XCTAssertNotNil(whole["error"] as? String, "and the agent is told why")

        center.setEnabled(false)
        let off = try await serve(["path": "artifacts/site", "project": project.path])
        XCTAssertEqual(off["ok"] as? Bool, false, "switched off, nothing is shared")
    }

    // MARK: On a real socket

    @MainActor
    func testTheServerAnswersOverTheNetworkAndStopsWhenSwitchedOff() async throws {
        let (site, _, _) = try shares()
        let server = ShareServer()
        server.preferredPort = 0
        server.snapshot.set([site])
        server.start()
        for _ in 0..<60 where server.port == nil { try await Task.sleep(for: .milliseconds(50)) }
        let port = try XCTUnwrap(server.port, "the server is listening")
        let session = URLSession(configuration: .ephemeral)
        let (data, response) = try await session.data(from: URL(string: "http://127.0.0.1:\(port)/s/\(site.token)/index.html")!)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        XCTAssertTrue(String(decoding: data, as: UTF8.self).contains("<h1>Site</h1>"))
        let (_, missing) = try await session.data(from: URL(string: "http://127.0.0.1:\(port)/s/\(site.token)/.env")!)
        XCTAssertEqual((missing as? HTTPURLResponse)?.statusCode, 404)

        server.stop()
        try await Task.sleep(for: .milliseconds(200))
        do {
            _ = try await session.data(from: URL(string: "http://127.0.0.1:\(port)/s/\(site.token)/index.html")!)
            XCTFail("a server switched off answers nothing")
        } catch {}
    }
}
