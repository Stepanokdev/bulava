import Foundation
import CryptoKit

enum Slug {

    /// Remembered for a few seconds. Resolving symlinks asks the disk (`lstat` per component), and
    /// the sidebar compares every chat with every run on every redraw: the same few dozen paths,
    /// hundreds of times a second. That kept Bulava at 37–49 % of a core while nothing at all was
    /// happening (22.10). A folder that becomes a symlink is seen again within `lifetime`.
    nonisolated static func canonicalPath(_ path: String) -> String {
        CanonicalPaths.shared.value(for: path) { path in
            let url = URL(fileURLWithPath: path)
            let resolved = url.resolvingSymlinksInPath().path
            var p = resolved.isEmpty ? url.standardizedFileURL.path : resolved
            if p.count > 1 && p.hasSuffix("/") { p.removeLast() }
            return p
        }
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

nonisolated final class CanonicalPaths: @unchecked Sendable {
    static let shared = CanonicalPaths()
    private static let lifetime: TimeInterval = 5
    private static let capacity = 2000

    private let lock = NSLock()
    private var memo: [String: (value: String, at: TimeInterval)] = [:]

    func value(for path: String, resolve: (String) -> String) -> String {
        let now = ProcessInfo.processInfo.systemUptime
        lock.lock()
        if let hit = memo[path], now - hit.at < Self.lifetime {
            lock.unlock()
            return hit.value
        }
        lock.unlock()

        let value = resolve(path)

        lock.lock(); defer { lock.unlock() }
        if memo.count >= Self.capacity { memo.removeAll(keepingCapacity: true) }
        memo[path] = (value, now)
        return value
    }

    func forget() {
        lock.lock(); memo.removeAll(); lock.unlock()
    }
}
