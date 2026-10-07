import Foundation
import Network
import CryptoKit

/// One WebSocket connection, the server's end (RFC 6455), on a plain TCP connection.
///
/// Network's own WebSocket protocol was not usable here: its server hook sees a request's headers
/// but not which connection they came on, and the account browser has to know exactly that — the
/// token in the request is what says which run is asking. So the handshake is read here, by hand,
/// and the frames after it too. Text and binary messages, fragmentation, ping and close are all a
/// CDP client ever sends.
nonisolated final class WebSocketPeer: @unchecked Sendable {

    struct Request: Sendable {
        var method: String
        var path: String
        /// Lower-cased names.
        var headers: [String: String]
    }

    /// Why a handshake was refused, said to the client as an HTTP answer.
    struct Refusal: Sendable, Equatable {
        var status: Int
        var reason: String
    }

    static let maximumMessage = 64 * 1024 * 1024
    private static let guid = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"

    let connection: NWConnection
    private let queue: DispatchQueue
    private var buffer: [UInt8] = []
    private var fragments: [UInt8] = []
    private var fragmenting = false
    private(set) var isOpen = false
    private var ended = false
    /// The peer keeps itself until its connection is over: everything else holds it weakly, and a
    /// handshake still being read has nobody else to hold it.
    private var keepAlive: WebSocketPeer?

    /// A whole message from the client. Called on `queue`.
    var onMessage: ((Data) -> Void)?
    /// The connection is over, whoever ended it. Called once, on `queue`.
    var onClose: (() -> Void)?

    init(_ connection: NWConnection, queue: DispatchQueue) {
        self.connection = connection
        self.queue = queue
    }

    /// Reads the upgrade request and asks `decide` about it: nil accepts it, a refusal answers it
    /// with that status and closes.
    func start(deciding decide: @escaping (Request) -> Refusal?) {
        keepAlive = self
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed, .cancelled: self?.finish()
            default: break
            }
        }
        connection.start(queue: queue)
        readHandshake(decide)
    }

    // MARK: Handshake

    private func readHandshake(_ decide: @escaping (Request) -> Refusal?) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16 * 1024) { [weak self] data, _, complete, error in
            guard let self else { return }
            if let data { self.buffer += data }
            if let end = Self.headEnd(self.buffer) {
                let head = Array(self.buffer[..<end])
                self.buffer.removeFirst(end + 4)
                self.answer(head, decide)
            } else if error != nil || complete || self.buffer.count > 16 * 1024 {
                self.finish()
            } else {
                self.readHandshake(decide)
            }
        }
    }

    private static func headEnd(_ bytes: [UInt8]) -> Int? {
        guard bytes.count >= 4 else { return nil }
        for i in 0...(bytes.count - 4) where bytes[i] == 13 && bytes[i + 1] == 10 && bytes[i + 2] == 13 && bytes[i + 3] == 10 {
            return i
        }
        return nil
    }

    static func parse(_ head: [UInt8]) -> Request? {
        guard let text = String(bytes: head, encoding: .utf8) else { return nil }
        var lines = text.components(separatedBy: "\r\n")
        let start = lines.removeFirst().split(separator: " ")
        guard start.count == 3 else { return nil }
        var headers: [String: String] = [:]
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { continue }
            headers[line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()] =
                line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        return Request(method: String(start[0]), path: String(start[1]), headers: headers)
    }

    private func answer(_ head: [UInt8], _ decide: (Request) -> Refusal?) {
        guard let request = Self.parse(head), request.method == "GET",
              request.headers["upgrade"]?.lowercased() == "websocket",
              request.headers["connection"]?.lowercased().contains("upgrade") == true,
              request.headers["sec-websocket-version"] == "13",
              let key = request.headers["sec-websocket-key"], !key.isEmpty else {
            return refuse(Refusal(status: 400, reason: "A WebSocket upgrade is expected here."))
        }
        if let refusal = decide(request) { return refuse(refusal) }
        let accept = Data(Insecure.SHA1.hash(data: Data((key + Self.guid).utf8))).base64EncodedString()
        let response = "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n"
            + "Sec-WebSocket-Accept: \(accept)\r\n\r\n"
        isOpen = true
        connection.send(content: Data(response.utf8), completion: .contentProcessed { [weak self] error in
            guard let self else { return }
            if error != nil { self.finish(); return }
            self.parseFrames()
            self.readFrames()
        })
    }

    private func refuse(_ refusal: Refusal) {
        let body = Data(refusal.reason.utf8)
        let status = HTTPURLResponse.localizedString(forStatusCode: refusal.status).capitalized
        let head = "HTTP/1.1 \(refusal.status) \(status)\r\nContent-Type: text/plain; charset=utf-8\r\n"
            + "Content-Length: \(body.count)\r\nConnection: close\r\n\r\n"
        connection.send(content: Data(head.utf8) + body, isComplete: true, completion: .contentProcessed { [weak self] _ in
            self?.finish()
        })
    }

    // MARK: Frames

    private func readFrames() {
        guard !ended else { return }
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { [weak self] data, _, complete, error in
            guard let self else { return }
            if let data { self.buffer += data }
            self.parseFrames()
            if error != nil || complete { self.finish(); return }
            self.readFrames()
        }
    }

    private func parseFrames() {
        while !ended, buffer.count >= 2 {
            let b0 = buffer[0], b1 = buffer[1]
            let fin = b0 & 0x80 != 0, opcode = b0 & 0x0F
            guard b1 & 0x80 != 0 else { return close(code: 1002) }       // a client always masks
            var length = UInt64(b1 & 0x7F), offset = 2
            if length == 126 {
                guard buffer.count >= 4 else { return }
                length = UInt64(buffer[2]) << 8 | UInt64(buffer[3]); offset = 4
            } else if length == 127 {
                guard buffer.count >= 10 else { return }
                length = buffer[2..<10].reduce(0) { $0 << 8 | UInt64($1) }; offset = 10
            }
            guard length <= UInt64(Self.maximumMessage) else { return close(code: 1009) }
            let total = offset + 4 + Int(length)
            guard buffer.count >= total else { return }
            let mask = Array(buffer[offset..<offset + 4])
            var payload = Array(buffer[(offset + 4)..<total])
            for i in payload.indices { payload[i] ^= mask[i & 3] }
            buffer.removeFirst(total)
            switch opcode {
            case 0x1, 0x2:
                if fin { onMessage?(Data(payload)) } else { fragments = payload; fragmenting = true }
            case 0x0:
                guard fragmenting else { return close(code: 1002) }
                fragments += payload
                guard fragments.count <= Self.maximumMessage else { return close(code: 1009) }
                if fin { fragmenting = false; let whole = fragments; fragments = []; onMessage?(Data(whole)) }
            case 0x8:
                return close(code: 1000)
            case 0x9:
                write(opcode: 0xA, Data(payload))
            case 0xA:
                break
            default:
                return close(code: 1002)
            }
        }
    }

    // MARK: Sending

    func send(_ message: Data) { write(opcode: 0x1, message) }

    private func write(opcode: UInt8, _ payload: Data) {
        guard isOpen, !ended else { return }
        var head: [UInt8] = [0x80 | opcode]
        let n = payload.count
        if n < 126 {
            head.append(UInt8(n))
        } else if n <= 0xFFFF {
            head += [126, UInt8(n >> 8), UInt8(n & 0xFF)]
        } else {
            head.append(127)
            for shift in stride(from: 56, through: 0, by: -8) { head.append(UInt8((UInt64(n) >> UInt64(shift)) & 0xFF)) }
        }
        connection.send(content: Data(head) + payload, completion: .contentProcessed { [weak self] error in
            if error != nil { self?.finish() }
        })
    }

    /// Ends the connection with a close frame, as the protocol asks.
    func close(code: UInt16 = 1000) {
        guard !ended else { return }
        if isOpen {
            let frame = Data([0x88, 0x02, UInt8(code >> 8), UInt8(code & 0xFF)])
            connection.send(content: frame, isComplete: true, completion: .contentProcessed { [weak self] _ in self?.finish() })
        } else {
            finish()
        }
    }

    private func finish() {
        guard !ended else { return }
        ended = true
        isOpen = false
        connection.cancel()
        let done = onClose
        onClose = nil
        onMessage = nil
        done?()
        keepAlive = nil
    }
}
