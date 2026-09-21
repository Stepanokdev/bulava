import Foundation
import CryptoKit

nonisolated struct Finding: Identifiable, Sendable, Equatable {
    var cls: String
    var text: String
    var cwd: String?
    var timestamp: String?

    var id: String {
        let digest = SHA256.hash(data: Data((cls + "\u{1}" + text).utf8))
        return String(digest.map { String(format: "%02x", $0) }.joined().prefix(16))
    }
}
