import Foundation
import Observation
import OSLog

/// Everything shared with the phone over the home Wi-Fi, in one place: the links (`ShareStore`),
/// the server that answers them (`ShareServer`), and the requests agents send through
/// `$IDIR/phone-link` (served like `UIControlService`'s: a JSON file in a watched folder, a `.done`
/// file with the answer, a `service.json` saying Bulava is alive).
///
/// One server for every project and every link, started the first time something is shared and
/// kept while the setting is on; addresses on the usual port survive restarts, so a link in a chat
/// from last week still opens as long as its file is there.
@MainActor
@Observable
final class ShareCenter {
    let store: ShareStore
    @ObservationIgnored let server = ShareServer()
    private(set) var enabled = true

    @ObservationIgnored weak var model: AppModel?
    @ObservationIgnored private var requests: URL?
    @ObservationIgnored private var timer: Task<Void, Never>?
    @ObservationIgnored private var inFlight: Set<String> = []
    @ObservationIgnored private let log = Logger(subsystem: "com.stepanok.bulava", category: "share")

    /// The app's own, for views that open a link without a model at hand (`MarkdownProse.route`).
    static weak var current: ShareCenter?

    init(store: ShareStore = ShareStore()) {
        self.store = store
        server.snapshot.set(store.links)
    }

    /// Hooked up at launch: the agents' request folder is watched, and the server starts if there
    /// is anything to serve.
    func attach(_ model: AppModel, enabled: Bool, stateDir: URL?) {
        self.model = model
        requests = stateDir?.appendingPathComponent("share-requests", isDirectory: true)
        store.dropMissing()
        setEnabled(enabled)
        guard let requests else { return }
        try? FileManager.default.createDirectory(at: requests, withIntermediateDirectories: true)
        announce()
        timer = Task { [weak self] in
            var ticks = 0
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(400))
                await self?.drain()
                ticks += 1
                if ticks % 12 == 0 { self?.announce() }
            }
        }
    }

    func detach() {
        timer?.cancel()
        timer = nil
        server.stop()
        if let requests { try? FileManager.default.removeItem(at: requests.appendingPathComponent("service.json")) }
    }

    func setEnabled(_ on: Bool) {
        enabled = on
        if on, !store.links.isEmpty { server.start() } else if !on { server.stop() }
        announce()
    }

    // MARK: Sharing

    /// Shares a path from inside `roots`, and waits until the server can answer it.
    func share(_ path: URL, within roots: [URL], title: String? = nil, project: URL? = nil) async -> Result<ShareLink, ShareRefusal> {
        guard enabled else {
            return .failure(ShareRefusal(message: String(localized: "Links to the phone are switched off in Bulava's settings.")))
        }
        let result = store.register(path, within: roots, title: title, project: project)
        guard case .success = result else { return result }
        server.snapshot.set(store.links)
        server.start()
        for _ in 0..<40 where server.port == nil {
            if case .failed(let why) = server.state { return .failure(ShareRefusal(message: why)) }
            try? await Task.sleep(for: .milliseconds(50))
        }
        guard server.port != nil else {
            return .failure(ShareRefusal(message: String(localized: "Bulava could not open a port for links to the phone.")))
        }
        return result
    }

    func revoke(_ token: String) {
        store.revoke(token)
        server.snapshot.set(store.links)
    }

    func revokeAll() {
        store.revokeAll()
        server.snapshot.set(store.links)
    }

    /// Where a link opens: this Mac's Bonjour name first — it survives a new address from the
    /// router — then each address it has on the local network now.
    func urls(for link: ShareLink) -> [URL] {
        guard let port = server.port else { return [] }
        var hosts: [String] = []
        if let name = ShareAddresses.localHostName() { hosts.append(name) }
        hosts += ShareAddresses.lanAddresses()
        return hosts.compactMap { url(for: link, host: $0, port: port) }
    }

    /// The address for one host: the phone's own way to this Mac, when it asks over the link.
    func url(for link: ShareLink, host: String, port: UInt16? = nil) -> URL? {
        guard let port = port ?? server.port else { return nil }
        return URL(string: "http://\(ShareAddresses.authority(host, port: port))\(link.path)")
    }

    /// What the Mac itself opens it at.
    func localURL(for link: ShareLink) -> URL? { url(for: link, host: "127.0.0.1") }

    /// The link a page open on this Mac belongs to, if it is one of ours.
    func link(forPage url: URL) -> ShareLink? {
        guard url.scheme == "http", let host = url.host, ["127.0.0.1", "localhost"].contains(host),
              url.port.map(UInt16.init) == server.port else { return nil }
        let parts = url.path.split(separator: "/")
        guard parts.count >= 2, parts[0] == "s" else { return nil }
        return store.link(token: String(parts[1]))
    }

    // MARK: Agents' requests (`$IDIR/phone-link`)

    func announce() {
        guard let requests else { return }
        let payload: [String: Any] = ["pid": ProcessInfo.processInfo.processIdentifier,
                                      "since": Int(Date().timeIntervalSince1970), "enabled": enabled]
        if let data = try? JSONSerialization.data(withJSONObject: payload) {
            try? data.write(to: requests.appendingPathComponent("service.json"), options: .atomic)
        }
    }

    private func drain() async {
        guard let requests, let names = try? FileManager.default.contentsOfDirectory(atPath: requests.path) else { return }
        for name in names.sorted() where name.hasSuffix(".json") && name != "service.json" {
            let id = String(name.dropLast(5))
            let done = requests.appendingPathComponent("\(id).done")
            guard !inFlight.contains(id), !FileManager.default.fileExists(atPath: done.path) else { continue }
            inFlight.insert(id)
            let answer = await serve(requests.appendingPathComponent(name))
            if let data = try? JSONSerialization.data(withJSONObject: answer) { try? data.write(to: done, options: .atomic) }
            inFlight.remove(id)
        }
    }

    /// One request: `{"path", "project", "title"?}`. The project must be one Bulava knows — a
    /// project folder or the folder of a run it is watching — and the path must be inside it.
    func serve(_ request: URL) async -> [String: Any] {
        guard let data = try? Data(contentsOf: request),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let path = obj["path"] as? String, let project = obj["project"] as? String else {
            return ["ok": false, "error": String(localized: "The request is not readable.")]
        }
        let folder = URL(fileURLWithPath: project).resolvingSymlinksInPath().standardizedFileURL
        guard knownProject(folder) else {
            return ["ok": false, "error": String(localized: "That project folder is not one Bulava knows.")]
        }
        let target = URL(fileURLWithPath: path, relativeTo: folder).standardizedFileURL
        switch await share(target, within: [folder], title: obj["title"] as? String, project: folder) {
        case .failure(let refusal):
            return ["ok": false, "error": refusal.message]
        case .success(let link):
            log.info("shared \(link.entry, privacy: .public) from \(folder.lastPathComponent, privacy: .public)")
            return ["ok": true, "token": link.token, "scope": link.scope.rawValue,
                    "urls": urls(for: link).map(\.absoluteString)]
        }
    }

    private func knownProject(_ folder: URL) -> Bool {
        guard let model else { return false }
        let path = Slug.canonicalPath(folder.path)
        if model.projects.projects.contains(where: { Slug.canonicalPath($0.path) == path }) { return true }
        return model.snapshot.instances.contains { Slug.canonicalPath($0.projectPath) == path }
    }
}
