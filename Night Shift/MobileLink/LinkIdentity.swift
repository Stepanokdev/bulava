import Foundation
import CryptoKit
import Security

/// Who this Mac is to a phone: one P-256 key and a self-signed certificate over it.
///
/// The phone learns the certificate's key fingerprint from the pairing QR code and from then on
/// talks to nothing else — which is what makes a coffee-shop Wi-Fi a place where Bulava can still be
/// paired without anyone in the middle reading along. The certificate is only a wrapper TLS insists
/// on; no authority vouches for it, and none has to.
///
/// Nothing here touches the Keychain. The test host is ad-hoc signed under another identity, and
/// reading a keychain item the real app created raises a prompt nobody answers — the whole suite
/// stalls on it. The key sits in a file only this user can read, beside the rest of Bulava's state,
/// and the TLS identity is assembled in memory from it (`SecIdentityCreate`).
nonisolated struct LinkIdentity: Sendable {
    let privateKey: P256.Signing.PrivateKey
    let certificateDER: Data

    /// SHA-256 of the certificate's SubjectPublicKeyInfo, base64url. What the QR code carries and
    /// what the phone compares against on every connection.
    var pin: String { Self.base64url(Data(SHA256.hash(data: Self.spki(privateKey.publicKey)))) }

    /// Loads the identity kept at `url`, or makes one and keeps it there. A file that exists but
    /// does not parse is replaced: every phone paired to it will have to pair again, which is the
    /// honest outcome for a key that is gone.
    static func loadOrCreate(at url: URL, commonName: String) -> LinkIdentity? {
        if let data = try? Data(contentsOf: url),
           let stored = try? JSONDecoder().decode(Stored.self, from: data),
           let keyData = Data(base64Encoded: stored.privateKey),
           let key = try? P256.Signing.PrivateKey(rawRepresentation: keyData),
           let cert = Data(base64Encoded: stored.certificate) {
            return LinkIdentity(privateKey: key, certificateDER: cert)
        }
        let key = P256.Signing.PrivateKey()
        guard let cert = try? Self.selfSignedCertificate(key: key, commonName: commonName) else { return nil }
        let identity = LinkIdentity(privateKey: key, certificateDER: cert)
        let stored = Stored(privateKey: key.rawRepresentation.base64EncodedString(),
                            certificate: cert.base64EncodedString())
        guard let data = try? JSONEncoder().encode(stored) else { return nil }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        guard FileManager.default.createFile(atPath: url.path, contents: data,
                                             attributes: [.posixPermissions: 0o600]) else { return nil }
        return identity
    }

    private struct Stored: Codable {
        var privateKey: String
        var certificate: String
    }

    /// The identity Network.framework's TLS wants, built without a keychain.
    func secIdentity() -> SecIdentity? {
        guard let certificate = SecCertificateCreateWithData(nil, certificateDER as CFData) else { return nil }
        let attributes: [CFString: Any] = [
            kSecAttrKeyType: kSecAttrKeyTypeECSECPrimeRandom,
            kSecAttrKeyClass: kSecAttrKeyClassPrivate,
            kSecAttrKeySizeInBits: 256,
        ]
        // SecKey wants the X9.63 form: the public point followed by the private scalar.
        let x963 = privateKey.publicKey.x963Representation + privateKey.rawRepresentation
        var error: Unmanaged<CFError>?
        guard let key = SecKeyCreateWithData(x963 as CFData, attributes as CFDictionary, &error) else {
            return nil
        }
        return SecIdentityCreate(nil, certificate, key)
    }

    // MARK: - Encoding

    static func base64url(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    /// SubjectPublicKeyInfo for a P-256 key: the algorithm pair and the uncompressed point.
    /// Android reads exactly these bytes as `PublicKey.encoded`, which is why the pin is over them.
    static func spki(_ key: P256.Signing.PublicKey) -> Data {
        DER.sequence([
            DER.sequence([DER.oid(DER.idEcPublicKey), DER.oid(DER.prime256v1)]),
            DER.bitString(key.x963Representation),
        ])
    }

    /// A minimal X.509 v3 certificate, signed by its own key. No extensions: nothing on either side
    /// judges it by anything but the key it carries.
    static func selfSignedCertificate(key: P256.Signing.PrivateKey, commonName: String,
                                      now: Date = Date()) throws -> Data {
        let name = DER.sequence([
            DER.set([DER.sequence([DER.oid(DER.commonName), DER.utf8String(commonName)])]),
        ])
        var serial = [UInt8](repeating: 0, count: 16)
        _ = SecRandomCopyBytes(kSecRandomDefault, serial.count, &serial)
        serial[0] &= 0x7F  // a positive INTEGER
        let algorithm = DER.sequence([DER.oid(DER.ecdsaWithSHA256)])
        let notBefore = now.addingTimeInterval(-86_400)
        let notAfter = Calendar(identifier: .gregorian).date(byAdding: .year, value: 20, to: now) ?? now
        let tbs = DER.sequence([
            DER.explicit(0, DER.integer(Data([2]))),       // v3
            DER.integer(Data(serial)),
            algorithm,
            name,
            DER.sequence([DER.generalizedTime(notBefore), DER.generalizedTime(notAfter)]),
            name,
            spki(key.publicKey),
        ])
        let signature = try key.signature(for: tbs)
        return DER.sequence([tbs, algorithm, DER.bitString(signature.derRepresentation)])
    }
}

/// Just enough DER to write one certificate.
nonisolated enum DER {
    static let idEcPublicKey: [UInt64] = [1, 2, 840, 10045, 2, 1]
    static let prime256v1: [UInt64] = [1, 2, 840, 10045, 3, 1, 7]
    static let ecdsaWithSHA256: [UInt64] = [1, 2, 840, 10045, 4, 3, 2]
    static let commonName: [UInt64] = [2, 5, 4, 3]

    static func tlv(_ tag: UInt8, _ body: Data) -> Data {
        var out = Data([tag])
        let n = body.count
        if n < 0x80 {
            out.append(UInt8(n))
        } else {
            var bytes: [UInt8] = []
            var v = n
            while v > 0 { bytes.insert(UInt8(v & 0xFF), at: 0); v >>= 8 }
            out.append(0x80 | UInt8(bytes.count))
            out.append(contentsOf: bytes)
        }
        out.append(body)
        return out
    }

    static func sequence(_ items: [Data]) -> Data { tlv(0x30, items.reduce(Data(), +)) }
    static func set(_ items: [Data]) -> Data { tlv(0x31, items.reduce(Data(), +)) }
    static func explicit(_ n: UInt8, _ inner: Data) -> Data { tlv(0xA0 | n, inner) }
    static func bitString(_ bytes: Data) -> Data { tlv(0x03, Data([0]) + bytes) }
    static func utf8String(_ s: String) -> Data { tlv(0x0C, Data(s.utf8)) }

    static func integer(_ bytes: Data) -> Data {
        var b = Data(bytes.drop { $0 == 0 })
        if b.isEmpty { b = Data([0]) }
        if b.first! & 0x80 != 0 { b.insert(0, at: 0) }
        return tlv(0x02, b)
    }

    static func oid(_ arcs: [UInt64]) -> Data {
        var body = Data([UInt8(arcs[0] * 40 + arcs[1])])
        for arc in arcs.dropFirst(2) {
            var chunk: [UInt8] = [UInt8(arc & 0x7F)]
            var v = arc >> 7
            while v > 0 { chunk.insert(UInt8(v & 0x7F) | 0x80, at: 0); v >>= 7 }
            body.append(contentsOf: chunk)
        }
        return tlv(0x06, body)
    }

    static func generalizedTime(_ date: Date) -> Data {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyyMMddHHmmss'Z'"
        return tlv(0x18, Data(f.string(from: date).utf8))
    }
}
