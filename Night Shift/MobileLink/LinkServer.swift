import Foundation
import Network
import OSLog
import SystemConfiguration

/// The listening half: TLS 1.3 and WebSocket on one port of this Mac's local network.
///
/// It accepts nothing from outside the local network. Two fences, because either alone leaks:
/// the listener refuses cellular and "other" interfaces — which is where VPN tunnels live — and a
/// connection whose peer address is not private, link-local or loopback is dropped before a byte
/// is read. Neither is authentication; the pairing credential is. They keep the door off the
/// internet, which is what "the same Wi-Fi only" promises.
@MainActor
final class LinkServer {
    enum State: Equatable {
        case stopped
        case starting
        case listening(port: UInt16)
        case failed(String)
    }

    private(set) var state: State = .stopped {
        didSet { if state != oldValue { onState?(state) } }
    }
    var onState: ((State) -> Void)?
    var onConnection: ((NWConnection, String) -> Void)?

    private var listener: NWListener?
    private let log = Logger(subsystem: "com.stepanok.bulava", category: "mobile-link")
    /// What the listener was last started with, so a busy usual port can be traded for a free one.
    private var startedWith: (identity: LinkIdentity, port: UInt16, serviceName: String, desktopID: String)?

    func start(identity: LinkIdentity, port: UInt16, serviceName: String, desktopID: String) {
        guard listener == nil else { return }
        startedWith = (identity, port, serviceName, desktopID)
        guard let secIdentity = identity.secIdentity(),
              let tlsIdentity = sec_identity_create(secIdentity) else {
            state = .failed(String(localized: "Bulava could not make its own certificate for the phone link."))
            return
        }
        state = .starting

        let tls = NWProtocolTLS.Options()
        sec_protocol_options_set_local_identity(tls.securityProtocolOptions, tlsIdentity)
        sec_protocol_options_set_min_tls_protocol_version(tls.securityProtocolOptions, .TLSv13)

        let tcp = NWProtocolTCP.Options()
        tcp.enableKeepalive = true
        tcp.keepaliveIdle = 20
        tcp.connectionTimeout = 10

        let parameters = NWParameters(tls: tls, tcp: tcp)
        let ws = NWProtocolWebSocket.Options()
        ws.autoReplyPing = true
        ws.maximumMessageSize = LinkProtocol.maximumFrame
        parameters.defaultProtocolStack.applicationProtocols.insert(ws, at: 0)
        parameters.prohibitedInterfaceTypes = [.cellular, .other]
        parameters.includePeerToPeer = false
        parameters.allowLocalEndpointReuse = true

        let made: NWListener
        do {
            made = try Self.listener(parameters, port: port)
        } catch {
            state = .failed(String(format: String(localized: "The phone link could not open a port: %@"),
                                   error.localizedDescription))
            return
        }
        var txt = NWTXTRecord()
        txt["id"] = desktopID
        txt["v"] = String(LinkProtocol.version)
        made.service = NWListener.Service(name: serviceName, type: LinkProtocol.bonjourType,
                                          domain: nil, txtRecord: txt)
        made.stateUpdateHandler = { [weak self] newState in
            MainActor.assumeIsolated { self?.listenerChanged(newState) }
        }
        made.newConnectionHandler = { [weak self] connection in
            MainActor.assumeIsolated { self?.accept(connection) }
        }
        listener = made
        made.start(queue: .main)
    }

    /// The usual port first, so a phone that remembers it finds this Mac without looking; any
    /// free one when something else holds it. The QR code and Bonjour both carry the one in use.
    private static func listener(_ parameters: NWParameters, port: UInt16) throws -> NWListener {
        if port != 0, let fixed = NWEndpoint.Port(rawValue: port),
           let listener = try? NWListener(using: parameters, on: fixed) {
            return listener
        }
        return try NWListener(using: parameters)
    }

    func stop() {
        listener?.cancel()
        listener = nil
        state = .stopped
    }

    private func listenerChanged(_ newState: NWListener.State) {
        switch newState {
        case .ready:
            state = .listening(port: listener?.port?.rawValue ?? 0)
            log.notice("phone link listening on \(self.listener?.port?.rawValue ?? 0, privacy: .public)")
        case .failed(let error):
            // Detached first: a failed listener still reports its cancellation, and that must not
            // be read as the state of the one that replaces it.
            listener?.stateUpdateHandler = nil
            listener?.newConnectionHandler = nil
            listener?.cancel()
            listener = nil
            // The usual port, taken by whatever bound it first — another Bulava on this Mac, or any
            // other program. A listener on a named port learns that only when it starts, never when
            // it is made, so the fallback in `listener(_:port:)` never saw it and the phone link
            // simply died: the QR code went on naming a port nobody here was listening on. Once,
            // on any free port; the code and Bonjour follow it (`refreshPairingIfPortMoved`).
            if case .posix(.EADDRINUSE) = error, let was = startedWith, was.port != 0 {
                log.notice("phone link: port \(was.port, privacy: .public) is taken — listening on a free one")
                start(identity: was.identity, port: 0, serviceName: was.serviceName, desktopID: was.desktopID)
                return
            }
            log.error("phone link failed: \(error.localizedDescription, privacy: .public)")
            state = .failed(error.localizedDescription)
        case .waiting(let error):
            state = .failed(error.localizedDescription)
        case .cancelled:
            if listener == nil { state = .stopped }
        default:
            break
        }
    }

    private func accept(_ connection: NWConnection) {
        guard let peer = Self.peerAddress(connection.endpoint), Self.isLocal(peer) else {
            log.notice("phone link refused a connection from outside the local network")
            connection.cancel()
            return
        }
        onConnection?(connection, peer)
    }

    // MARK: Who may knock

    nonisolated static func peerAddress(_ endpoint: NWEndpoint) -> String? {
        guard case .hostPort(let host, _) = endpoint else { return nil }
        switch host {
        case .ipv4(let a): return "\(a)"
        case .ipv6(let a): return "\(a)"
        case .name(let n, _): return n
        @unknown default: return nil
        }
    }

    /// Private IPv4 (RFC 1918), link-local, loopback, IPv6 unique-local and link-local.
    ///
    /// Carrier-grade NAT space (100.64/10) is deliberately NOT local: it is where VPN overlays such
    /// as Tailscale hand out addresses, and accepting it would reopen the door the interface fence
    /// just closed.
    nonisolated static func isLocal(_ address: String) -> Bool {
        var text = address
        if let percent = text.firstIndex(of: "%") { text = String(text[..<percent]) }
        if let v4 = IPv4Address(text) {
            let b = [UInt8](v4.rawValue)
            switch (b[0], b[1]) {
            case (10, _), (127, _): return true
            case (172, 16...31): return true
            case (192, 168): return true
            case (169, 254): return true
            default: return false
            }
        }
        if let v6 = IPv6Address(text) {
            let b = [UInt8](v6.rawValue)
            if v6 == .loopback { return true }
            if b[0] & 0xFE == 0xFC { return true }                 // fc00::/7
            if b[0] == 0xFE && b[1] & 0xC0 == 0x80 { return true } // fe80::/10
            if b[0..<10].allSatisfy({ $0 == 0 }) && b[10] == 0xFF && b[11] == 0xFF {
                return isLocal("\(b[12]).\(b[13]).\(b[14]).\(b[15])") // v4-mapped
            }
            return false
        }
        return false
    }

    /// Addresses a phone on the same network can reach this Mac at, best first: the Wi-Fi and
    /// Ethernet ones, then the Bonjour name, which survives a new address from the router.
    nonisolated static func hostCandidates() -> [String] {
        var out: [String] = []
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return out }
        defer { freeifaddrs(ifaddr) }
        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let ptr = cursor {
            defer { cursor = ptr.pointee.ifa_next }
            let flags = Int32(ptr.pointee.ifa_flags)
            guard flags & IFF_UP != 0, flags & IFF_LOOPBACK == 0,
                  let sa = ptr.pointee.ifa_addr, sa.pointee.sa_family == UInt8(AF_INET) else { continue }
            let name = String(cString: ptr.pointee.ifa_name)
            guard name.hasPrefix("en") else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(sa, socklen_t(sa.pointee.sa_len), &host, socklen_t(host.count),
                              nil, 0, NI_NUMERICHOST) == 0 else { continue }
            let address = String(decoding: host.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
            if isLocal(address), !out.contains(address) { out.append(address) }
        }
        if let local = localHostName() { out.append(local) }
        return out
    }

    /// The Bonjour name, as Sharing settings has it. Read from the configuration store rather than
    /// `ProcessInfo.hostName`, which can block on a DNS lookup.
    nonisolated static func localHostName() -> String? {
        guard let name = SCDynamicStoreCopyLocalHostName(nil) as String?, !name.isEmpty else { return nil }
        return name + ".local"
    }
}
