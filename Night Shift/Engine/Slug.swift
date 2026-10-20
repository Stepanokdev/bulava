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

    /// The slug exactly as the engine's `slug_for` makes it: from the path as the kernel spells it.
    /// Foundation's resolving turns `/private/var/…` into `/var/…` and the engine's `pwd -P` does not,
    /// so under `/var`, `/tmp` and `/etc` the two differ — and a name that is signed for the engine to
    /// check has to be the engine's own.
    nonisolated static func forEngine(_ path: String) -> String {
        var real = ClaudeFolderTrust.realPath(path)
        if real.count > 1 && real.hasSuffix("/") { real.removeLast() }
        let hex = Insecure.SHA1.hash(data: Data(real.utf8)).map { String(format: "%02x", $0) }.joined()
        return "\(sanitizedBasename(real))-\(hex.prefix(12))"
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
