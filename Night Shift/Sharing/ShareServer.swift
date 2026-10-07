import Foundation
import Network
import OSLog
import SystemConfiguration

/// What the connections read while they work off the main thread: the links and the names this Mac
/// answers to. Swapped whole whenever either changes.
nonisolated final class ShareSnapshot: @unchecked Sendable {
    private let lock = NSLock()
    private var links: [String: ShareLink] = [:]
    private var names: Set<String> = []
    private var namesAt = Date.distantPast
    private var open = 0

    func set(_ list: [ShareLink]) {
        lock.lock(); defer { lock.unlock() }
        links = Dictionary(list.map { ($0.token, $0) }, uniquingKeysWith: { a, _ in a })
    }

    func link(_ token: String) -> ShareLink? {
        lock.lock(); defer { lock.unlock() }
        return links[token]
    }

    /// This Mac's own names, read again at most every half minute: an address that changed with the
    /// network is answered to within that.
    func hostNames() -> Set<String> {
        lock.lock(); defer { lock.unlock() }
        if Date().timeIntervalSince(namesAt) > 30 {
            names = ShareAddresses.ownNames()
            namesAt = Date()
        }
        return names
    }

    func admit(limit: Int) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard open < limit else { return false }
        open += 1
        return true
    }

    func release() {
        lock.lock(); defer { lock.unlock() }
        open = max(0, open - 1)
    }
}

/// Whether a connection has said what it wants yet: past the head's deadline, one that has not is
/// cancelled.
nonisolated final class HeadDeadline: @unchecked Sendable {
    private let lock = NSLock()
    private var met = false
    func meet() { lock.lock(); met = true; lock.unlock() }
    var isMet: Bool { lock.lock(); defer { lock.unlock() }; return met }
}

/// Where this Mac can be reached on the local network.
nonisolated enum ShareAddresses {

    /// `Name.local`, the name Bonjour gives this Mac: it stays the same when the router hands out a
    /// new address.
    static func localHostName() -> String? {
        guard let name = SCDynamicStoreCopyLocalHostName(nil) as String?, !name.isEmpty else { return nil }
        return name + ".local"
    }

    /// Private addresses on the interfaces a phone on the same Wi-Fi can reach: never a tunnel, and
    /// IPv4 first.
    static func lanAddresses() -> [String] {
        var out: [String] = []
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return [] }
        defer { freeifaddrs(ifaddr) }
        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let current = cursor {
            defer { cursor = current.pointee.ifa_next }
            let flags = Int32(current.pointee.ifa_flags)
            guard flags & IFF_UP != 0, flags & IFF_LOOPBACK == 0, let addr = current.pointee.ifa_addr else { continue }
            let name = String(cString: current.pointee.ifa_name)
            guard name.hasPrefix("en") || name.hasPrefix("bridge") else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            let family = addr.pointee.sa_family
            guard family == UInt8(AF_INET) || family == UInt8(AF_INET6) else { continue }
            let length = socklen_t(family == UInt8(AF_INET) ? MemoryLayout<sockaddr_in>.size : MemoryLayout<sockaddr_in6>.size)
            guard getnameinfo(addr, length, &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 else { continue }
            var text = String(cString: host)
            if let percent = text.firstIndex(of: "%") { text = String(text[..<percent]) }
            guard LinkServer.isLocal(text) else { continue }
            out.append(text)
        }
        return out.sorted { a, b in (a.contains(":") ? 1 : 0, a) < (b.contains(":") ? 1 : 0, b) }
    }

    static func ownNames() -> Set<String> {
        var names: Set<String> = ["localhost", "127.0.0.1", "::1"]
        names.formUnion(lanAddresses().map { $0.lowercased() })
        if let local = localHostName() { names.insert(local.lowercased()) }
        return names
    }

    /// `host:port` for a URL, with IPv6 in brackets.
    static func authority(_ host: String, port: UInt16) -> String {
        host.contains(":") ? "[\(host)]:\(port)" : "\(host):\(port)"
    }
}

/// The one server that shows the phone what was shared: a plain HTTP server on the home Wi-Fi,
/// reading only, serving only the links in `ShareStore` (rules in `ShareHTTP`).
///
/// Fenced like the phone link (`LinkServer`): no cellular, no tunnel interfaces, and a peer that is
/// not on a private or link-local network is dropped before a byte is read. The token in a link is
/// what lets a request in; the fence is what keeps that request on this side of the router.
@MainActor
final class ShareServer {
    enum State: Equatable {
        case stopped
        case starting
        case listening(port: UInt16)
        case failed(String)
    }

    private(set) var state: State = .stopped
    let snapshot = ShareSnapshot()
    /// The usual port, so an address once given keeps working after a restart. Tests pass 0.
    var preferredPort: UInt16 = 47292
    /// How many requests may be in flight at once, and how long one may take to say what it wants.
    nonisolated static let connectionLimit = 48
    nonisolated static let headLimit = 16 * 1024
    nonisolated static let headTimeout: TimeInterval = 10

    private var listener: NWListener?
    private let queue = DispatchQueue(label: "com.stepanok.bulava.share", qos: .userInitiated, attributes: .concurrent)
    private let log = Logger(subsystem: "com.stepanok.bulava", category: "share")

    var port: UInt16? {
        if case .listening(let port) = state { return port }
        return nil
    }

    func start() { start(on: preferredPort) }

    private func start(on port: UInt16) {
        guard listener == nil else { return }
        state = .starting
        let tcp = NWProtocolTCP.Options()
        tcp.connectionTimeout = 10
        let parameters = NWParameters(tls: nil, tcp: tcp)
        parameters.prohibitedInterfaceTypes = [.cellular, .other]
        parameters.includePeerToPeer = false
        parameters.allowLocalEndpointReuse = true
        let endpoint = NWEndpoint.Port(rawValue: port) ?? .any
        guard let made = try? NWListener(using: parameters, on: endpoint) else {
            if port != 0 { start(on: 0) } else { state = .failed(String(localized: "Bulava could not open a port for links to the phone.")) }
            return
        }
        listener = made
        let snapshot = self.snapshot
        made.newConnectionHandler = { connection in Self.accept(connection, snapshot: snapshot) }
        made.stateUpdateHandler = { [weak self] update in
            Task { @MainActor in self?.listenerChanged(update, port: port) }
        }
        made.start(queue: queue)
    }

    private func listenerChanged(_ update: NWListener.State, port: UInt16) {
        switch update {
        case .ready:
            state = .listening(port: listener?.port?.rawValue ?? port)
        case .failed(let error):
            listener?.cancel()
            listener = nil
            // The usual port is taken by something else: any free one, the addresses say which.
            if port != 0, case .posix(let code) = error, code == .EADDRINUSE {
                start(on: 0)
            } else {
                log.error("share server failed: \(error.localizedDescription, privacy: .public)")
                state = .failed(error.localizedDescription)
            }
        case .cancelled:
            if listener == nil { state = .stopped }
        default:
            break
        }
    }

    func stop() {
        listener?.cancel()
        listener = nil
        state = .stopped
    }

    // MARK: One connection

    nonisolated private static func accept(_ connection: NWConnection, snapshot: ShareSnapshot) {
        guard let peer = LinkServer.peerAddress(connection.endpoint), LinkServer.isLocal(peer),
              snapshot.admit(limit: connectionLimit) else {
            connection.cancel()
            return
        }
        let queue = DispatchQueue(label: "com.stepanok.bulava.share.connection")
        let deadline = HeadDeadline()
        // A request that has not said what it wants in time is let go.
        queue.asyncAfter(deadline: .now() + headTimeout) { if !deadline.isMet { connection.cancel() } }
        connection.stateUpdateHandler = { state in
            switch state {
            case .failed, .cancelled:
                deadline.meet()
                snapshot.release()
                connection.stateUpdateHandler = nil
            default:
                break
            }
        }
        connection.start(queue: queue)
        readHead(connection, so: Data(), snapshot: snapshot, deadline: deadline)
    }

    nonisolated private static func readHead(_ connection: NWConnection, so far: Data, snapshot: ShareSnapshot,
                                             deadline: HeadDeadline) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { data, _, complete, error in
            var head = far
            if let data { head.append(data) }
            if let end = head.range(of: Data("\r\n\r\n".utf8)) {
                deadline.meet()
                answer(connection, head: head[..<end.lowerBound], snapshot: snapshot)
                return
            }
            guard error == nil, !complete, head.count < headLimit else {
                connection.cancel()
                return
            }
            readHead(connection, so: head, snapshot: snapshot, deadline: deadline)
        }
    }

    nonisolated private static func answer(_ connection: NWConnection, head: Data, snapshot: ShareSnapshot) {
        let port = connection.currentPath?.localEndpoint.flatMap { endpoint -> UInt16? in
            if case .hostPort(_, let port) = endpoint { return port.rawValue }
            return nil
        } ?? 0
        let response: ShareHTTP.Response
        if let request = ShareHTTP.parse(head) {
            response = ShareHTTP.respond(request, hosts: ShareHTTP.Hosts(names: snapshot.hostNames(), port: port),
                                         link: { snapshot.link($0) })
        } else {
            response = ShareHTTP.page(400, String(localized: "That address is not a valid one."))
        }
        send(response, on: connection)
    }

    nonisolated private static func send(_ response: ShareHTTP.Response, on connection: NWConnection) {
        var head = "HTTP/1.1 \(response.status) \(reason(response.status))\r\n"
        for (name, value) in response.headers {
            // Nothing a header carries may end it early.
            let clean = value.replacingOccurrences(of: "\r", with: "").replacingOccurrences(of: "\n", with: "")
            head += "\(name): \(clean)\r\n"
        }
        head += "\r\n"
        switch response.body {
        case .none:
            connection.send(content: Data(head.utf8), contentContext: .finalMessage, isComplete: true,
                            completion: .contentProcessed { _ in connection.cancel() })
        case .data(let data):
            connection.send(content: Data(head.utf8) + data, contentContext: .finalMessage, isComplete: true,
                            completion: .contentProcessed { _ in connection.cancel() })
        case .file(let path, let offset, let length):
            guard let handle = FileHandle(forReadingAtPath: path) else { connection.cancel(); return }
            try? handle.seek(toOffset: UInt64(offset))
            connection.send(content: Data(head.utf8), completion: .contentProcessed { error in
                guard error == nil else { try? handle.close(); connection.cancel(); return }
                stream(handle, left: length, on: connection)
            })
        }
    }

    /// A file in pieces, each sent when the last one is through: a video does not sit in memory.
    nonisolated private static func stream(_ handle: FileHandle, left: Int64, on connection: NWConnection) {
        guard left > 0 else {
            try? handle.close()
            connection.send(content: nil, contentContext: .finalMessage, isComplete: true,
                            completion: .contentProcessed { _ in connection.cancel() })
            return
        }
        let chunk = (try? handle.read(upToCount: Int(min(left, 256 * 1024)))) ?? Data()
        guard !chunk.isEmpty else { try? handle.close(); connection.cancel(); return }
        connection.send(content: chunk, completion: .contentProcessed { error in
            guard error == nil else { try? handle.close(); connection.cancel(); return }
            stream(handle, left: left - Int64(chunk.count), on: connection)
        })
    }

    nonisolated private static func reason(_ status: Int) -> String {
        switch status {
        case 200: "OK"
        case 206: "Partial Content"
        case 302: "Found"
        case 400: "Bad Request"
        case 404: "Not Found"
        case 405: "Method Not Allowed"
        case 416: "Range Not Satisfiable"
        case 421: "Misdirected Request"
        default: "Status"
        }
    }
}
