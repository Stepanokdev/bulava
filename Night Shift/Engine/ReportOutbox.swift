import Foundation

/// Reports waiting to go to us, kept on disk until they have.
///
/// An offline Mac, a server restart, a quit in the middle of sending — none of them lose a report,
/// and none of them let the queue grow without end: past `capacity` the oldest go. Turning the
/// setting off empties it on the spot; nothing queued while it was on is sent later.
///
/// Where they go: `https://bulava-push.stepanok.com/v1/reports`, beside the phone's push relay.
/// `BulavaReportsURL` in the app's defaults (or `BULAVA_REPORTS_URL`) points elsewhere, and `off`
/// turns sending off whatever the setting says. A test host never reaches the real server.
actor ReportOutbox {

    static let shared = ReportOutbox(file: AppSupport.root.appendingPathComponent("report-outbox.json"))

    static let capacity = 50
    static let defaultsKey = "BulavaReportsURL"
    static let defaultEndpoint = URL(string: "https://bulava-push.stepanok.com/v1/reports")!

    private let file: URL
    private var pending: [IncidentReport]
    private var sending = false
    /// Bumped by `purge`. A send that was in flight when reporting was turned off finds it changed
    /// when it comes back, and stops there: nothing more goes, and nothing is written back.
    private var generation = 0
    /// Replaced in tests, so a send can be observed without a network.
    var transport: @Sendable (URLRequest) async -> Int = ReportOutbox.urlSessionTransport

    init(file: URL) {
        self.file = file
        if let data = try? Data(contentsOf: file),
           let saved = try? JSONDecoder().decode([IncidentReport].self, from: data) {
            pending = saved
        } else {
            pending = []
        }
    }

    nonisolated static var endpoint: URL? {
        let raw = ProcessInfo.processInfo.environment["BULAVA_REPORTS_URL"]
            ?? UserDefaults.standard.string(forKey: defaultsKey)
        guard let raw else { return isTestHost ? nil : defaultEndpoint }
        guard raw.lowercased() != "off", let url = URL(string: raw),
              url.scheme == "https" || url.host == "127.0.0.1" else { return nil }
        return url
    }

    private nonisolated static var isTestHost: Bool {
        let env = ProcessInfo.processInfo.environment
        return env["XCTestConfigurationFilePath"] != nil || env["XCTestBundlePath"] != nil
            || env["XCTestSessionIdentifier"] != nil
    }

    var queued: [IncidentReport] { pending }

    func setTransport(_ t: @escaping @Sendable (URLRequest) async -> Int) { transport = t }

    func enqueue(_ report: IncidentReport) {
        // The same incident at the same outcome is one report, however many times it was posted.
        pending.removeAll { Self.key($0) == Self.key(report) }
        pending.append(report)
        if pending.count > Self.capacity { pending.removeFirst(pending.count - Self.capacity) }
        save()
    }

    /// Everything still waiting is dropped — the setting was turned off.
    func purge() {
        generation += 1
        pending.removeAll()
        try? FileManager.default.removeItem(at: file)
    }

    private static func key(_ r: IncidentReport) -> String { r.id + "|" + r.outcome }

    /// Sends what is waiting, oldest first. Stops at the first failure of the network or the
    /// server and leaves the rest for next time; a report the server refuses outright (it does not
    /// recognise the shape) is dropped, since sending it again cannot change the answer.
    ///
    /// The queue can change while a report is on the wire — this is an actor, and the send is a
    /// suspension point: another report can arrive and push the oldest out, or reporting can be
    /// turned off and the queue emptied. So what comes back removes the report that was SENT, by
    /// its identity, never "whatever is first now"; and a purge in the meantime ends the flush.
    @discardableResult
    func flush(to endpoint: URL? = ReportOutbox.endpoint) async -> Int {
        guard let endpoint, !sending, !pending.isEmpty else { return 0 }
        sending = true
        defer { sending = false }
        let started = generation
        var tried: Set<String> = []
        var sent = 0
        while generation == started,
              let report = pending.first(where: { !tried.contains(Self.key($0)) }) {
            let key = Self.key(report)
            tried.insert(key)
            var request = URLRequest(url: endpoint, timeoutInterval: 20)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try? JSONEncoder().encode(report)
            let status = await transport(request)
            guard generation == started else { return sent }
            switch status {
            case 200..<300:
                pending.removeAll { Self.key($0) == key }
                sent += 1
            case 400, 413, 415, 422:
                pending.removeAll { Self.key($0) == key }
            default:
                save()
                return sent
            }
        }
        if generation == started { save() }
        return sent
    }

    private func save() {
        if pending.isEmpty { try? FileManager.default.removeItem(at: file); return }
        guard let data = try? JSONEncoder().encode(pending) else { return }
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        try? data.write(to: file, options: .atomic)
    }

    /// Ephemeral: no cookies, no cache, nothing about the request kept on this Mac.
    static let urlSessionTransport: @Sendable (URLRequest) async -> Int = { request in
        let session = URLSession(configuration: .ephemeral)
        defer { session.finishTasksAndInvalidate() }
        guard let (_, response) = try? await session.data(for: request) else { return -1 }
        return (response as? HTTPURLResponse)?.statusCode ?? -1
    }
}
