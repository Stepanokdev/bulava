import Foundation
import AppKit

/// Where Google Chrome is on this Mac, if it is.
nonisolated enum ChromeApp {
    static let bundleID = "com.google.Chrome"

    static func find() -> URL? {
        let candidates = [URL(fileURLWithPath: "/Applications/Google Chrome.app"),
                          FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications/Google Chrome.app")]
        if let found = candidates.first(where: { FileManager.default.fileExists(atPath: executable(of: $0).path) }) {
            return found
        }
        return NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
            .flatMap { FileManager.default.fileExists(atPath: executable(of: $0).path) ? $0 : nil }
    }

    static func executable(of app: URL) -> URL {
        app.appendingPathComponent("Contents/MacOS/Google Chrome")
    }

    /// What every launch of the account browser carries: its own profile, and none of Chrome's
    /// first-run questions.
    static func baseArguments(profile: URL) -> [String] {
        ["--user-data-dir=\(profile.path)", "--no-first-run", "--no-default-browser-check"]
    }

    /// The profile keeps a site's sign-in across a restart only when Chrome reopens where it left
    /// off: Apple's session cookie lives until the browser closes, and Chrome restores it only
    /// with "Continue where you left off" (`session.restore_on_startup = 1`). Set before Chrome
    /// first opens the profile, and again whenever it is found otherwise.
    static func prepare(profile: URL) {
        let defaults = profile.appendingPathComponent("Default", isDirectory: true)
        try? FileManager.default.createDirectory(at: defaults, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: profile.path)
        let file = defaults.appendingPathComponent("Preferences")
        var prefs = (try? Data(contentsOf: file)).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
        var session = prefs["session"] as? [String: Any] ?? [:]
        guard session["restore_on_startup"] as? Int != 1 else { return }
        session["restore_on_startup"] = 1
        prefs["session"] = session
        if let data = try? JSONSerialization.data(withJSONObject: prefs) { try? data.write(to: file, options: .atomic) }
    }
}

/// Something that carries CDP messages to a browser and back: the real Chrome on a pipe, or a
/// stand-in in tests.
nonisolated protocol CDPTransport: AnyObject, Sendable {
    /// One message to the browser.
    func send(_ message: Data)
    /// Every message from the browser, and the end of it.
    func listen(onMessage: @escaping @Sendable (Data) -> Void, onExit: @escaping @Sendable () -> Void)
    var isRunning: Bool { get }
    /// Asks the browser to close, and makes sure it has.
    func terminate()
}

/// Chrome speaking DevTools on a pipe: `--remote-debugging-pipe` reads commands from descriptor 3
/// and writes answers to descriptor 4, NUL after each. No port is opened, so no other program on
/// this Mac can reach the browser — only Bulava, which holds the pipe.
///
/// Foundation's `Process` hands a child its standard streams only; the two extra descriptors need
/// `posix_spawn` and its file actions.
nonisolated final class ChromePipe: CDPTransport, @unchecked Sendable {
    let pid: pid_t
    private let toChrome: FileHandle
    private let fromChrome: FileHandle
    private let lock = NSLock()
    private var exited = false

    private init(pid: pid_t, toChrome: Int32, fromChrome: Int32) {
        self.pid = pid
        self.toChrome = FileHandle(fileDescriptor: toChrome, closeOnDealloc: true)
        self.fromChrome = FileHandle(fileDescriptor: fromChrome, closeOnDealloc: true)
    }

    enum LaunchError: Error, Equatable { case pipe, spawn(Int32) }

    static func launch(executable: URL, arguments: [String]) throws -> ChromePipe {
        var commands: [Int32] = [0, 0], answers: [Int32] = [0, 0]
        guard pipe(&commands) == 0 else { throw LaunchError.pipe }
        guard pipe(&answers) == 0 else { close(commands[0]); close(commands[1]); throw LaunchError.pipe }
        // The parent's ends must not leak into Chrome, nor into anything else Bulava starts.
        _ = fcntl(commands[1], F_SETFD, FD_CLOEXEC)
        _ = fcntl(answers[0], F_SETFD, FD_CLOEXEC)

        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_addopen(&actions, 1, "/dev/null", O_WRONLY, 0)
        posix_spawn_file_actions_addopen(&actions, 2, "/dev/null", O_WRONLY, 0)
        posix_spawn_file_actions_adddup2(&actions, commands[0], 3)
        posix_spawn_file_actions_adddup2(&actions, answers[1], 4)

        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        // Everything not named above is closed in Chrome: Bulava's sockets and files stay Bulava's.
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_CLOEXEC_DEFAULT))

        let argv = [executable.path] + arguments
        var cArgs: [UnsafeMutablePointer<CChar>?] = argv.map { strdup($0) } + [nil]
        defer { for p in cArgs { free(p) } }
        var pid: pid_t = 0
        let status = posix_spawn(&pid, executable.path, &actions, &attributes, &cArgs, environ)
        close(commands[0]); close(answers[1])
        guard status == 0 else {
            close(commands[1]); close(answers[0])
            throw LaunchError.spawn(status)
        }
        return ChromePipe(pid: pid, toChrome: commands[1], fromChrome: answers[0])
    }

    var isRunning: Bool { lock.withLock { !exited } }

    func send(_ message: Data) {
        guard isRunning else { return }
        var framed = message
        framed.append(0)
        do { try toChrome.write(contentsOf: framed) } catch { }
    }

    func listen(onMessage: @escaping @Sendable (Data) -> Void, onExit: @escaping @Sendable () -> Void) {
        let reader = fromChrome
        let pid = self.pid
        Thread.detachNewThread { [weak self] in
            var pending = Data()
            while true {
                let chunk = reader.availableData
                if chunk.isEmpty { break }
                pending.append(chunk)
                while let nul = pending.firstIndex(of: 0) {
                    let message = pending[pending.startIndex..<nul]
                    onMessage(Data(message))
                    pending.removeSubrange(pending.startIndex...nul)
                }
            }
            var status: Int32 = 0
            _ = waitpid(pid, &status, 0)
            self?.lock.withLock { self?.exited = true }
            onExit()
        }
    }

    /// `Browser.close` first — Chrome then writes its session out, which is what keeps a sign-in
    /// that lives only as long as the browser — then SIGTERM, then SIGKILL, a few seconds apart.
    func terminate() {
        guard isRunning else { return }
        send(Data(#"{"id":2147483000,"method":"Browser.close"}"#.utf8))
        let pid = self.pid
        DispatchQueue.global().asyncAfter(deadline: .now() + 4) { [weak self] in
            guard self?.isRunning == true else { return }
            kill(pid, SIGTERM)
            DispatchQueue.global().asyncAfter(deadline: .now() + 3) { [weak self] in
                if self?.isRunning == true { kill(pid, SIGKILL) }
            }
        }
    }

    /// Waits up to `seconds` for Chrome to be gone.
    func waitForExit(seconds: Double) -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while isRunning, Date() < deadline { usleep(50_000) }
        return !isRunning
    }
}
