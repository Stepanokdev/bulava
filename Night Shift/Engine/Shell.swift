import Foundation

nonisolated enum CommandEnd: Sendable, Equatable {
    case exited

    case wentQuiet(idle: TimeInterval)

    case hitCeiling(after: TimeInterval)
    case neverStarted
}

struct CommandResult: Sendable {
    let stdout: String
    let stderr: String
    let exitCode: Int32
    let launched: Bool
    var endedBy: CommandEnd = .exited

    var ok: Bool { launched && exitCode == 0 }
    var combined: String {
        if stderr.isEmpty { return stdout }
        if stdout.isEmpty { return stderr }
        return stdout + "\n" + stderr
    }
}

actor ShellEnvironment {
    static let shared = ShellEnvironment()
    private var cached: String?

    func path() -> String {
        if let cached { return cached }
        let resolved = Self.probe()
        cached = resolved
        return resolved
    }

    nonisolated private static func probe() -> String {
        let fallback = fallbackPath()
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/zsh")

        p.arguments = ["-lc", "printf %s \"$PATH\""]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = fallback
        p.environment = env

        let sema = DispatchSemaphore(value: 0)
        p.terminationHandler = { _ in sema.signal() }
        do { try p.run() } catch { return fallback }

        if sema.wait(timeout: .now() + 3) == .timedOut {
            p.terminate()
            return fallback
        }
        let data = (try? out.fileHandleForReading.readToEnd()) ?? Data()
        let probed = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return probed.contains("/") ? merge(probed, fallback) : fallback
    }

    nonisolated private static func fallbackPath() -> String {
        let home = NSHomeDirectory()
        var dirs = [
            "\(home)/.local/bin",
            "/opt/homebrew/bin", "/opt/homebrew/sbin",
            "/usr/local/bin",
            "/usr/bin", "/bin", "/usr/sbin", "/sbin",
        ]

        let nvm = "\(home)/.nvm/versions/node"
        if let versions = try? FileManager.default.contentsOfDirectory(atPath: nvm) {
            for v in versions.sorted().reversed() { dirs.append("\(nvm)/\(v)/bin") }
        }
        return dirs.joined(separator: ":")
    }

    nonisolated private static func merge(_ a: String, _ b: String) -> String {
        var seen = Set<String>(); var out = [String]()
        for part in a.split(separator: ":") + b.split(separator: ":") {
            let s = String(part)
            if !s.isEmpty, !seen.contains(s) { seen.insert(s); out.append(s) }
        }
        return out.joined(separator: ":")
    }
}

private nonisolated final class OutputCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var out = Data()
    private var err = Data()
    private var finished = false

    func appendOut(_ d: Data) { lock.lock(); out.append(d); lock.unlock() }
    func appendErr(_ d: Data) { lock.lock(); err.append(d); lock.unlock() }

    func take(extraOut: Data, extraErr: Data) -> (String, String)? {
        lock.lock(); defer { lock.unlock() }
        if finished { return nil }
        finished = true
        out.append(extraOut); err.append(extraErr)

        return (String(decoding: out, as: UTF8.self),
                String(decoding: err, as: UTF8.self))
    }
}

private nonisolated final class ProcessRunner: @unchecked Sendable {
    private let process = Process()
    private let outPipe = Pipe()
    private let errPipe = Pipe()
    private let collector = OutputCollector()
    private let completion: (CommandResult) -> Void
    private let lock = NSLock()
    private var emitted = false
    private var selfRetain: ProcessRunner?
    private var timeoutItem: DispatchWorkItem?
    private var idleItem: DispatchWorkItem?
    private var idleBudget: TimeInterval?
    private var endedBy: CommandEnd = .exited
    private var onChunk: (@Sendable (String) -> Void)?

    init(completion: @escaping (CommandResult) -> Void) { self.completion = completion }

    func terminateIfRunning() { if process.isRunning { process.terminate() } }
    func cancelTimeout() {
        lock.lock(); let idle = idleItem; idleItem = nil; lock.unlock()
        timeoutItem?.cancel(); idle?.cancel()
    }

    private func bumpIdle() {
        guard let budget = idleBudget else { return }
        let item = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.lock.lock(); self.endedBy = .wentQuiet(idle: budget); self.lock.unlock()
            self.terminateIfRunning()
        }
        lock.lock(); let previous = idleItem; idleItem = item; lock.unlock()
        previous?.cancel()
        DispatchQueue.global().asyncAfter(deadline: .now() + budget, execute: item)
    }

    func start(script: String, args: [String], cwd: URL?, path: String,
               extraEnv: [String: String], timeout: TimeInterval,
               idle: TimeInterval? = nil,
               onChunk: (@Sendable (String) -> Void)? = nil) {
        idleBudget = idle
        self.onChunk = onChunk
        selfRetain = self

        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-c", script, "ns"] + args
        if let cwd { process.currentDirectoryURL = cwd }
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = path
        for (k, v) in extraEnv { env[k] = v }
        process.environment = env
        process.standardOutput = outPipe
        process.standardError = errPipe

        let collector = self.collector
        outPipe.fileHandleForReading.readabilityHandler = { [weak self] h in
            let d = h.availableData
            guard !d.isEmpty else { return }
            collector.appendOut(d)
            self?.bumpIdle()
            if let onChunk = self?.onChunk { onChunk(String(decoding: d, as: UTF8.self)) }
        }
        errPipe.fileHandleForReading.readabilityHandler = { [weak self] h in
            let d = h.availableData
            guard !d.isEmpty else { return }
            collector.appendErr(d)
            self?.bumpIdle()
        }

        let item = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.lock.lock(); self.endedBy = .hitCeiling(after: timeout); self.lock.unlock()
            self.terminateIfRunning()
        }
        timeoutItem = item
        bumpIdle()
        process.terminationHandler = { [weak self] proc in
            self?.cancelTimeout()
            self?.finish(code: proc.terminationStatus, launched: true)
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: item)

        do {
            try process.run()
        } catch {
            cancelTimeout()
            emit(CommandResult(stdout: "", stderr: "failed to launch: \(error.localizedDescription)",
                               exitCode: -1, launched: false, endedBy: .neverStarted))
        }
    }

    private func finish(code: Int32, launched: Bool) {

        outPipe.fileHandleForReading.readabilityHandler = nil
        errPipe.fileHandleForReading.readabilityHandler = nil
        let restOut = ((try? outPipe.fileHandleForReading.readToEnd()) ?? nil) ?? Data()
        let restErr = ((try? errPipe.fileHandleForReading.readToEnd()) ?? nil) ?? Data()
        guard let (o, e) = collector.take(extraOut: restOut, extraErr: restErr) else { return }
        lock.lock(); let how = endedBy; lock.unlock()
        emit(CommandResult(stdout: o.trimmedTail, stderr: e.trimmedTail,
                           exitCode: code, launched: launched, endedBy: how))
    }

    private func emit(_ r: CommandResult) {
        lock.lock()
        if emitted { lock.unlock(); return }
        emitted = true
        lock.unlock()
        completion(r)

        outPipe.fileHandleForReading.readabilityHandler = nil
        errPipe.fileHandleForReading.readabilityHandler = nil
        process.terminationHandler = nil
        onChunk = nil
        selfRetain = nil
    }
}

enum Shell {

    private static let isolatedProcessTreeWrapper = #"""
    leader=""
    cleanup_group() {
      [ -n "$leader" ] || return 0
      /bin/kill -TERM -"$leader" 2>/dev/null || true
      for _ in 1 2 3 4 5 6 7 8 9 10; do
        /bin/kill -0 -"$leader" 2>/dev/null || return 0
        /bin/sleep 0.02
      done
      /bin/kill -KILL -"$leader" 2>/dev/null || true
    }
    trap 'cleanup_group; exit 143' TERM INT HUP
    trap cleanup_group EXIT
    /usr/bin/perl -MPOSIX -e 'POSIX::setsid(); exec @ARGV' /bin/zsh -c "$1" ns "${@:2}" &
    leader=$!
    wait "$leader"
    exit_code=$?
    cleanup_group
    trap - EXIT TERM INT HUP
    exit "$exit_code"
    """#

    @discardableResult
    static func run(_ script: String,
                    args: [String] = [],
                    cwd: URL? = nil,
                    extraEnv: [String: String] = [:],
                    timeout: TimeInterval = 60,
                    idle: TimeInterval? = nil,
                    isolatingProcessTree: Bool = false,
                    onChunk: (@Sendable (String) -> Void)? = nil) async -> CommandResult {
        let path = await ShellEnvironment.shared.path()
        return await withCheckedContinuation { (cont: CheckedContinuation<CommandResult, Never>) in
            let runner = ProcessRunner { result in cont.resume(returning: result) }
            let launchedScript = isolatingProcessTree ? isolatedProcessTreeWrapper : script
            let launchedArgs = isolatingProcessTree ? [script] + args : args
            runner.start(script: launchedScript, args: launchedArgs, cwd: cwd, path: path,
                         extraEnv: extraEnv, timeout: timeout, idle: idle, onChunk: onChunk)
        }
    }
}

extension String {

    nonisolated var trimmedTail: String {
        var s = self[...]
        while let last = s.last, last == "\n" || last == "\r" { s = s.dropLast() }
        return String(s)
    }
}
