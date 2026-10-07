import Foundation
import CryptoKit
import Security
import Shared

/// A WebSocket over TLS that trusts one key only: the one whose fingerprint the QR code carried.
///
/// The check happens inside the TLS handshake, before anything is sent, so a machine that merely
/// answers at the Mac's address never hears the pairing token or the credential.
final class PinnedSocket: NSObject, IosSocket, URLSessionWebSocketDelegate, @unchecked Sendable {
    private let pin: String
    private let listener: TransportListener
    private var session: URLSession!
    private var task: URLSessionWebSocketTask?
    private let lock = NSLock()
    private var finished = false
    private var closing = false

    init(url: String, pin: String, listener: TransportListener) {
        self.pin = pin
        self.listener = listener
        super.init()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 8
        configuration.waitsForConnectivity = false
        session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
        guard let target = URL(string: url) else {
            finish("bad url")
            return
        }
        let task = session.webSocketTask(with: target)
        task.maximumMessageSize = 4 * 1024 * 1024
        self.task = task
        task.resume()
    }

    // MARK: IosSocket

    func send(text: String) -> Bool {
        guard let task, !isFinished else { return false }
        task.send(.string(text)) { [weak self] error in
            if let error { self?.finish(error.localizedDescription) }
        }
        return true
    }

    func close() {
        lock.lock(); closing = true; lock.unlock()
        task?.cancel(with: .normalClosure, reason: nil)
        session.invalidateAndCancel()
        finish(nil)
    }

    // MARK: Receiving

    private func receive() {
        task?.receive { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(.string(let text)):
                self.listener.onText(text: text)
                self.receive()
            case .success(.data(let data)):
                self.listener.onText(text: String(decoding: data, as: UTF8.self))
                self.receive()
            case .success:
                self.receive()
            case .failure(let error):
                self.finish(error.localizedDescription)
            }
        }
    }

    private var isFinished: Bool {
        lock.lock(); defer { lock.unlock() }
        return finished
    }

    private func finish(_ failure: String?) {
        lock.lock()
        guard !finished else { lock.unlock(); return }
        finished = true
        let orderly = closing
        lock.unlock()
        listener.onClosed(failure: orderly ? nil : (failure ?? "closed"))
    }

    // MARK: URLSessionWebSocketDelegate

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask,
                    didOpenWithProtocol protocol: String?) {
        listener.onOpen()
        receive()
    }

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask,
                    didCloseWith closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        finish(closeCode == .normalClosure ? nil : "closed \(closeCode.rawValue)")
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        finish(error?.localizedDescription)
    }

    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let trust = challenge.protectionSpace.serverTrust,
              let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate],
              let leaf = chain.first,
              Self.fingerprint(of: leaf) == pin else {
            completionHandler(.cancelAuthenticationChallenge, nil)
            return
        }
        completionHandler(.useCredential, URLCredential(trust: trust))
    }

    /// SHA-256 of the certificate's SubjectPublicKeyInfo, base64url — what the Mac put in the QR code.
    static func fingerprint(of certificate: SecCertificate) -> String? {
        guard let key = SecCertificateCopyKey(certificate),
              let x963 = SecKeyCopyExternalRepresentation(key, nil) as Data?, x963.count == 65 else { return nil }
        // The fixed DER header of a P-256 SubjectPublicKeyInfo, followed by the uncompressed point.
        let header: [UInt8] = [0x30, 0x59, 0x30, 0x13, 0x06, 0x07, 0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x02, 0x01,
                               0x06, 0x08, 0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x03, 0x01, 0x07, 0x03, 0x42, 0x00]
        let digest = SHA256.hash(data: Data(header) + x963)
        return Data(digest).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
