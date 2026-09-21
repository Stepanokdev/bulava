import Foundation

nonisolated final class CodexChatRunner: @unchecked Sendable {

    struct Outcome: Sendable {

        var threadID: String?
        var blocks: [ConversationBlock]
        var failure: String?
        var usage: CodexUsage?
        var exitCode: Int32
    }

    static func send(prompt: String,
                     threadID: String?,
                     cwd: URL,
                     effort: String,
                     model: String = "",
                     path: String,
                     register: ((CodexChatRunner) -> Void)? = nil,
                     onProgress: (@Sendable ([ConversationBlock]) -> Void)? = nil) async -> Outcome {
        let runner = CodexChatRunner(prompt: prompt, threadID: threadID, cwd: cwd,
                                     effort: effort, model: model, path: path,
                                     onProgress: onProgress)

        register?(runner)
        return await runner.run()
    }

    // MARK: - Instance

    private let prompt: String
    private let threadID: String?
    private let cwd: URL
    private let effort: String
    private let model: String
    private let path: String
    private let onProgress: (@Sendable ([ConversationBlock]) -> Void)?

    private var retained: CodexChatRunner?

    private var process: Process?
    private let cancelled = FlagBox()

    private var framer = NDJSONFramer()
    private var reducer = CodexTurnReducer()
    private var lastEmit = Date.distantPast
    private let lock = NSLock()

    private static let emitInterval: TimeInterval = 0.12

    private static let turnBudget: Duration = .seconds(30 * 60)

    private init(prompt: String, threadID: String?, cwd: URL, effort: String, model: String,
                 path: String, onProgress: (@Sendable ([ConversationBlock]) -> Void)?) {
        self.prompt = prompt
        self.threadID = threadID
        self.cwd = cwd
        self.effort = effort
        self.model = model
        self.path = path
        self.onProgress = onProgress
    }

    static func arguments(threadID: String?, effort: String, prompt: String,
                          model: String = "") -> [String] {
        var args = ["exec", "--sandbox", "workspace-write", "--skip-git-repo-check",
                    "-c", "approval_policy=\"never\""]
        // An effort is ALWAYS named. Sending no flag does not mean "let the CLI be sensible" —
        // it means "use ~/.codex/config.toml", and that file is set to xhigh here. Every message
        // in the app was therefore running at the deepest setting while the menu said Automatic.
        let level = effort.isEmpty ? CodexEffortChoice.conversationDefault.rawValue : effort
        args += ["-c", "model_reasoning_effort=\"\(level)\""]
        // Empty means the CLI's own default, which is the honest reading of "Automatic" for a
        // model: there is no model Bulava should substitute for the one he configured.
        if let model = CodexModelCatalog.safeSlug(model) {
            args += ["-m", model]
        }
        if let threadID, !threadID.isEmpty {
            args += ["resume", threadID, "--json", prompt]
        } else {
            args += ["--json", prompt]
        }
        return args
    }

    private func run() async -> Outcome {
        retained = self
        defer { retained = nil }

        let process = Process()
        self.process = process
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["codex"] + Self.arguments(threadID: threadID, effort: effort,
                                                       prompt: prompt, model: model)
        process.currentDirectoryURL = cwd
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = path
        process.environment = env

        let out = Pipe()
        let err = Pipe()
        process.standardOutput = out
        process.standardError = err
        process.standardInput = FileHandle.nullDevice

        out.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            self?.consume(data)
        }

        let stderrBox = DataBox()
        err.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            stderrBox.append(data)
        }

        let code: Int32
        let timedOut = FlagBox()
        do {
            try process.run()

            let killer = Task {
                try? await Task.sleep(for: Self.turnBudget)
                guard !Task.isCancelled, process.isRunning else { return }
                timedOut.raise()
                process.terminate()
            }
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                process.terminationHandler = { _ in continuation.resume() }
            }
            killer.cancel()
            code = process.terminationStatus
        } catch {
            return Outcome(threadID: threadID, blocks: [],
                           failure: String(localized: "Codex could not be started."),
                           usage: nil, exitCode: -1)
        }

        out.fileHandleForReading.readabilityHandler = nil
        err.fileHandleForReading.readabilityHandler = nil

        consume(out.fileHandleForReading.readDataToEndOfFile())
        flushFramer()

        let stderrText = stderrBox.text()

        var blocks = reducer.blocks
        var failure = reducer.failure
        let thread = reducer.threadID
        let usage = reducer.usage
        let finished = reducer.isFinished

        if !finished && failure == nil {
            let detail = stderrText.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
                .last(where: { !$0.isEmpty })
            failure = cancelled.isRaised
                ? String(localized: "Stopped. The thread is intact — carry on when you want.")
                : timedOut.isRaised
                ? String(localized: "Codex ran past half an hour on one message and was stopped. The thread is intact — ask again.")
                : (detail?.isEmpty == false
                   ? detail
                   : String(format: String(localized: "Codex stopped without answering (exit %lld)."), Int(code)))
            blocks.append(.error(id: "codex-failure", failure ?? ""))
        }

        onProgress?(blocks)

        return Outcome(threadID: thread ?? threadID, blocks: blocks, failure: failure,
                       usage: usage, exitCode: code)
    }

    func cancel() {
        cancelled.raise()
        guard let process, process.isRunning else { return }
        let pid = process.processIdentifier
        Self.signalTree(pid, SIGTERM)
        process.terminate()
        DispatchQueue.global().asyncAfter(deadline: .now() + 2) {
            guard process.isRunning else { return }
            Self.signalTree(pid, SIGKILL)
            kill(pid, SIGKILL)
        }
    }

    private static func signalTree(_ pid: pid_t, _ signal: Int32) {
        let pgrep = Process()
        pgrep.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        pgrep.arguments = ["-P", String(pid)]
        let pipe = Pipe()
        pgrep.standardOutput = pipe
        pgrep.standardError = FileHandle.nullDevice
        guard (try? pgrep.run()) != nil else { return }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        pgrep.waitUntilExit()
        for line in (String(data: data, encoding: .utf8) ?? "").split(separator: "\n") {
            if let child = pid_t(line.trimmingCharacters(in: .whitespaces)) {
                signalTree(child, signal)
                kill(child, signal)
            }
        }
    }

    private func consume(_ data: Data) {
        guard !data.isEmpty else { return }
        lock.lock()
        let lines = framer.feed(data)
        var changed = false
        for line in lines {
            for event in CodexEvent.decode(line: line) where reducer.accept(event) { changed = true }
        }
        let due = Date().timeIntervalSince(lastEmit) >= Self.emitInterval
        let snapshot = reducer.blocks
        if changed && due { lastEmit = Date() }
        lock.unlock()

        if changed && due { onProgress?(snapshot) }
    }

    private func flushFramer() {
        for line in framer.feed(Data()) {
            for event in CodexEvent.decode(line: line) { _ = reducer.accept(event) }
        }
    }
}

private nonisolated final class FlagBox: @unchecked Sendable {
    private var value = false
    private let lock = NSLock()
    func raise() { lock.lock(); value = true; lock.unlock() }
    var isRaised: Bool { lock.lock(); defer { lock.unlock() }; return value }
}

private nonisolated final class DataBox: @unchecked Sendable {
    private var data = Data()
    private let lock = NSLock()
    func append(_ more: Data) { lock.lock(); data.append(more); lock.unlock() }
    func text() -> String { lock.lock(); defer { lock.unlock() }; return String(data: data, encoding: .utf8) ?? "" }
}
