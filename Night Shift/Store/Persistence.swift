import Foundation
import OSLog

nonisolated enum AppSupport {

    static var root: URL {
        if let override = ProcessInfo.processInfo.environment["BULAVA_STATE_DIR"],
           !override.isEmpty {
            let dir = URL(fileURLWithPath: override, isDirectory: true)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            return dir
        }
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        let dir = base.appendingPathComponent(AppChannel.current.supportFolderName, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static var attachments: URL {
        let d = root.appendingPathComponent("attachments", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    static func file(_ name: String) -> URL { root.appendingPathComponent(name) }
}

struct JSONFile<T: Codable> {
    let url: URL

    func load() -> T? {
        // A write still waiting in the background is the newest truth about this file. Reading
        // around it would hand back the state from before the last change.
        CoalescedWrites.shared.flush(url)
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder.iso.decode(T.self, from: data)
    }

    func save(_ value: T) {
        CoalescedWrites.shared.writeNow(url) { try? JSONEncoder.iso.encode(value) }
    }
}

extension JSONFile where T: Sendable {
    /// Save without making the caller wait: the value is encoded and written on a background
    /// queue, and several saves inside `delay` become one write of the last value.
    ///
    /// For files that change all the time and are large. The chat history is tens of megabytes,
    /// and encoding it on the main thread on every streamed change stalled scrolling and froze the
    /// window for seconds at a time.
    func saveSoon(_ value: T, delay: TimeInterval = 0.4) {
        CoalescedWrites.shared.schedule(url, delay: delay) {
            try? JSONEncoder.compact.encode(value)
        }
    }
}

/// The background half of `JSONFile.saveSoon`.
///
/// One pending job per file; a newer one replaces it. Each file has its own lock, held from the
/// moment a write takes its job until the bytes are on disk — so a reader's `flush` waits for a
/// write already in flight instead of reading the file from before it, and a write to the big
/// history never holds up a read of a small file beside it.
nonisolated final class CoalescedWrites: @unchecked Sendable {
    static let shared = CoalescedWrites()

    private let lock = NSLock()
    private var pending: [URL: @Sendable () -> Data?] = [:]
    private var fileLocks: [URL: NSLock] = [:]
    private let queue = DispatchQueue(label: "bulava.persistence", qos: .utility)

    private func fileLock(_ url: URL) -> NSLock {
        lock.lock(); defer { lock.unlock() }
        if let existing = fileLocks[url] { return existing }
        let made = NSLock()
        fileLocks[url] = made
        return made
    }

    func schedule(_ url: URL, delay: TimeInterval, encode: @escaping @Sendable () -> Data?) {
        lock.lock()
        let scheduled = pending[url] != nil
        pending[url] = encode
        lock.unlock()
        guard !scheduled else { return }
        queue.asyncAfter(deadline: .now() + delay) { [self] in flush(url) }
    }

    /// Writes the pending value for `url` now, if there is one, and returns once it is on disk —
    /// or once a write of it already under way has finished.
    func flush(_ url: URL) {
        let file = fileLock(url)
        file.lock(); defer { file.unlock() }
        lock.lock()
        let job = pending.removeValue(forKey: url)
        lock.unlock()
        guard let job else { return }
        if !write(job, to: url) { requeue(job, for: url) }
    }

    /// A synchronous save. It supersedes whatever was waiting, and holds the file's lock for the
    /// whole write so a background one cannot land an older value on top of it.
    func writeNow(_ url: URL, encode: () -> Data?) {
        let file = fileLock(url)
        file.lock(); defer { file.unlock() }
        lock.lock(); pending.removeValue(forKey: url); lock.unlock()
        guard let data = encode() else { return }
        do { try data.write(to: url, options: .atomic) } catch {
            Log.lifecycle.error("could not save \(url.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Everything still waiting, and everything being written — called when the app quits.
    /// Each file's lock is taken whether or not anything is pending for it, because a write that
    /// has already taken its job is no longer pending and the process must not end under it.
    func flushAll() {
        lock.lock()
        let urls = Set(pending.keys).union(fileLocks.keys)
        lock.unlock()
        for url in urls { flush(url) }
    }

    private func write(_ job: @Sendable () -> Data?, to url: URL) -> Bool {
        guard let data = job() else {
            // The same value will not encode any better a second time; only a failed write is
            // worth trying again.
            Log.lifecycle.error("could not encode \(url.lastPathComponent, privacy: .public)")
            return true
        }
        do {
            try data.write(to: url, options: .atomic)
            return true
        } catch {
            Log.lifecycle.error("could not save \(url.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    /// A write that failed is tried again later — unless something newer is already waiting,
    /// which will carry the same history and more.
    private func requeue(_ job: @escaping @Sendable () -> Data?, for url: URL) {
        lock.lock()
        let newer = pending[url] != nil
        if !newer { pending[url] = job }
        lock.unlock()
        guard !newer else { return }
        queue.asyncAfter(deadline: .now() + 2) { [self] in flush(url) }
    }
}

extension JSONDecoder {
    // `nonisolated(unsafe)`, as `Fmt.relative` already is: a coder configured once and only read
    // afterwards. Without it Swift 6.4 puts these on the main actor and nothing off it can decode.
    nonisolated(unsafe) static let iso: JSONDecoder = {
        let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601; return d
    }()
}
extension JSONEncoder {
    nonisolated(unsafe) static let iso: JSONEncoder = {
        let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return e
    }()

    /// For the big, frequently written files: no indentation and no key sorting, which together
    /// cost a large share of the encoding time and a third of the bytes.
    nonisolated(unsafe) static let compact: JSONEncoder = {
        let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601
        return e
    }()
}
