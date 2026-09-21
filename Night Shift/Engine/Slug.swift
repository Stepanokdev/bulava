import Foundation
import CryptoKit

enum Slug {

    nonisolated static func canonicalPath(_ path: String) -> String {
        let url = URL(fileURLWithPath: path)
        let resolved = url.resolvingSymlinksInPath().path
        var p = resolved.isEmpty ? url.standardizedFileURL.path : resolved
        if p.count > 1 && p.hasSuffix("/") { p.removeLast() }
        return p
    }

    nonisolated static func forPath(_ path: String) -> String {
        let canonical = canonicalPath(path)
        let base = sanitizedBasename(canonical)
        let digest = Insecure.SHA1.hash(data: Data(canonical.utf8))
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        let hash = String(hex.prefix(12))
        return "\(base)-\(hash)"
    }

    nonisolated private static func sanitizedBasename(_ canonical: String) -> String {
        let name = (canonical as NSString).lastPathComponent
        var out = ""
        var lastWasDash = false
        for ch in name {
            if ch.isASCII && (ch.isLetter || ch.isNumber) {
                out.append(ch); lastWasDash = false
            } else if !lastWasDash {
                out.append("-"); lastWasDash = true
            }
        }
        while out.hasPrefix("-") { out.removeFirst() }
        while out.hasSuffix("-") { out.removeLast() }
        return out.isEmpty ? "proj" : out
    }
}
