import Foundation

// MARK: - Process

private nonisolated enum AgentOutput: Sendable {
    case line(String)
    case ended(code: Int32, stderr: String)
}

nonisolated final class LiveAgents: @unchecked Sendable {
    static let shared = LiveAgents()
    private let lock = NSLock()
    private var processes: [ObjectIdentifier: Process] = [:]

    var runningCount: Int {
        lock.lock(); defer { lock.unlock() }
        return processes.values.filter(\.isRunning).count
    }

    func register(_ process: Process, for owner: AnyObject) {
        lock.lock(); processes[ObjectIdentifier(owner)] = process; lock.unlock()
    }

    func forget(_ owner: AnyObject) {
        lock.lock(); processes[ObjectIdentifier(owner)] = nil; lock.unlock()
    }

    func terminateAll() {
        lock.lock()
        let all = Array(processes.values)
        processes.removeAll()
        lock.unlock()
        for process in all where process.isRunning { process.terminate() }
    }
}

private nonisolated final class AgentProcess: @unchecked Sendable {
    private let process = Process()
    private let inPipe = Pipe()
    private let outPipe = Pipe()
    private let errPipe = Pipe()
    private let lock = NSLock()
    private var framer = NDJSONFramer()
    private var selfRetain: AgentProcess?
    private var finished = false

    private var errorTail = Data()
    private static let errorTailLimit = 8 * 1024

    let output: AsyncStream<AgentOutput>
    private let emit: AsyncStream<AgentOutput>.Continuation

    private let writeQueue = DispatchQueue(label: "bulava.foreman.stdin")

    var isRunning: Bool { process.isRunning }

    init() {
        var continuation: AsyncStream<AgentOutput>.Continuation!

        output = AsyncStream(bufferingPolicy: .unbounded) { continuation = $0 }
        emit = continuation
    }

    func start(arguments: [String], cwd: URL, fence: URL, path: String) -> Bool {
        selfRetain = self

        process.executableURL = URL(fileURLWithPath: "/bin/zsh")

        process.arguments = ["-lc", "exec /usr/bin/sandbox-exec -f \"$1\" claude \"${@:2}\"",
                             "ns", fence.path] + arguments
        process.currentDirectoryURL = cwd
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = path

        env.removeValue(forKey: "ANTHROPIC_API_KEY")
        env.removeValue(forKey: "ANTHROPIC_AUTH_TOKEN")
        process.environment = env
        process.standardInput = inPipe
        process.standardOutput = outPipe
        process.standardError = errPipe

        outPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            guard let self else { return }

            self.lock.lock()
            let data = handle.availableData
            if !data.isEmpty {
                for line in self.framer.feed(data) { self.emit.yield(.line(line)) }
            }
            self.lock.unlock()
        }
        errPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard let self, !data.isEmpty else { return }
            self.lock.lock()
            self.errorTail.append(data)
            if self.errorTail.count > Self.errorTailLimit {
                self.errorTail = Data(self.errorTail.suffix(Self.errorTailLimit))
            }
            self.lock.unlock()
        }
        process.terminationHandler = { [weak self] proc in
            self?.finish(code: proc.terminationStatus)
        }

        do {
            try process.run()
            LiveAgents.shared.register(process, for: self)
            return true
        } catch {
            finish(code: -1, reason: "failed to launch: \(error.localizedDescription)")
            return false
        }
    }

    func write(line: String) {
        let data = Data((line + "\n").utf8)
        let handle = inPipe.fileHandleForWriting
        writeQueue.async { [weak self] in
            guard self?.process.isRunning == true else { return }

            try? handle.write(contentsOf: data)
        }
    }

    func stop() {
        writeQueue.async { [weak self] in
            try? self?.inPipe.fileHandleForWriting.close()
        }
        if process.isRunning { process.terminate() }
    }

    func stopAndWait(grace: TimeInterval = 3) async {
        stop()
        let deadline = Date().addingTimeInterval(grace)
        while process.isRunning, Date() < deadline {
            try? await Task.sleep(for: .milliseconds(50))
        }
        if process.isRunning {
            kill(process.processIdentifier, SIGKILL)
            while process.isRunning, Date() < deadline.addingTimeInterval(1) {
                try? await Task.sleep(for: .milliseconds(50))
            }
        }
    }

    private func finish(code: Int32, reason: String? = nil) {
        lock.lock()
        if finished { lock.unlock(); return }
        finished = true
        lock.unlock()

        outPipe.fileHandleForReading.readabilityHandler = nil
        errPipe.fileHandleForReading.readabilityHandler = nil

        let restOut = ((try? outPipe.fileHandleForReading.readToEnd()) ?? nil) ?? Data()

        lock.lock()
        for line in framer.feed(restOut) { emit.yield(.line(line)) }
        for line in framer.flush() { emit.yield(.line(line)) }
        let stderrText = reason ?? String(decoding: errorTail, as: UTF8.self)
        emit.yield(.ended(code: code, stderr: stderrText.trimmedTail))
        emit.finish()
        lock.unlock()

        LiveAgents.shared.forget(self)
        process.terminationHandler = nil
        selfRetain = nil
    }
}

// MARK: - Session

actor ForemanSession {

    nonisolated struct Key: Hashable, Sendable, Codable {
        let productID: UUID
        let chatID: UUID
    }

    nonisolated enum Update: Sendable {

        case turn(blocks: [ConversationBlock])

        case finished(blocks: [ConversationBlock], plainText: String, failed: Bool)

        case scopeViolation(observed: [String], mcpServers: [String])

        case unavailable(reason: String)
    }

    nonisolated static let readOnlyTools = ["Read", "Grep", "Glob"]

    let key: Key
    private let cwd: URL
    private let tools: [String]
    private let onUpdate: @Sendable (Update) -> Void

    private var agent: AgentProcess?

    private var generation = 0
    private var consumer: Task<Void, Never>?
    private var reducer = TurnReducer()
    private var turnInFlight = false

    private var outbox: [String] = []

    private(set) var resumeID: String?

    private var consecutiveFailures = 0
    private var lastEmit = Date.distantPast
    private var shuttingDown = false

    private var lastSentText: String?

    private var watchdog: Task<Void, Never>?

    private var lastHeard = Date.distantPast

    private static let silenceBudget: TimeInterval = 5 * 60

    var isBusy: Bool { turnInFlight }

    private static let emitInterval: TimeInterval = 0.12

    init(key: Key, cwd: URL, tools: [String] = ForemanSession.readOnlyTools,
         resumeID: String? = nil,
         onUpdate: @escaping @Sendable (Update) -> Void) {
        self.key = key
        self.cwd = cwd
        self.tools = tools
        self.resumeID = resumeID
        self.onUpdate = onUpdate
    }

    // MARK: Sending

    func send(_ text: String) {
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty, !shuttingDown else { return }
        if turnInFlight {
            outbox.append(clean)
            return
        }
        deliver(clean)
    }

    private func deliver(_ text: String) {
        guard let agent = liveAgent() else {
            onUpdate(.unavailable(reason: String(localized: "The foreman could not be started.")))
            return
        }
        reducer = TurnReducer()
        turnInFlight = true
        lastSentText = text
        lastEmit = .distantPast
        lastHeard = Date()
        agent.write(line: Self.userMessage(text))
        startWatchdog()
    }

    private func startWatchdog() {
        watchdog?.cancel()
        watchdog = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(Self.pollSeconds))
                guard let self, await self.checkSilence() else { return }
            }
        }
    }

    private static let pollSeconds: Double = 20

    private func checkSilence() -> Bool {
        guard turnInFlight, !shuttingDown else { return false }

        if !reducer.renderable.isEmpty { onUpdate(.turn(blocks: reducer.renderable)) }
        guard Date().timeIntervalSince(lastHeard) > Self.silenceBudget else { return true }
        generation += 1
        consumer?.cancel(); consumer = nil
        let dying = agent; agent = nil
        completeTurn(failedReason: String(localized: "He went quiet and stopped answering."))
        Task { await dying?.stopAndWait() }
        return false
    }

    nonisolated static func userMessage(_ text: String) -> String {
        let payload: [String: Any] = [
            "type": "user",
            "message": ["role": "user", "content": [["type": "text", "text": text]]],
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: payload),
              let line = String(data: data, encoding: .utf8) else {
            return #"{"type":"user","message":{"role":"user","content":[{"type":"text","text":""}]}}"#
        }
        return line
    }

    // MARK: Lifecycle

    private func liveAgent() -> AgentProcess? {
        if let agent, agent.isRunning { return agent }
        return launch()
    }

    private func launch() -> AgentProcess? {
        generation += 1
        let mine = generation
        let process = AgentProcess()

        var arguments = ["-p",
                         "--input-format", "stream-json",
                         "--output-format", "stream-json",
                         "--verbose",
                         "--include-partial-messages",
                         "--strict-mcp-config"]
        arguments += ["--tools"] + tools

        if let resumeID { arguments += ["--resume", resumeID] }

        guard ForemanFence.isAvailable,
              let fence = ForemanFence.writeProfile(root: cwd.path, into: Self.fenceDirectory),
              process.start(arguments: arguments, cwd: cwd, fence: fence, path: Self.cachedPath)
        else { return nil }
        agent = process

        consumer = Task { [weak self] in
            for await item in process.output {
                guard let self else { return }
                switch item {
                case .line(let line):   await self.handle(line: line, generation: mine)
                case .ended(let code, let stderr): await self.handleExit(code: code, stderr: stderr,
                                                                        generation: mine)
                }
            }
        }
        return process
    }

    private nonisolated(unsafe) static var cachedPath: String = ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin"

    static func primePath() async {
        cachedPath = await ShellEnvironment.shared.path()
    }

    nonisolated(unsafe) static var fenceDirectory: URL = AppSupport.root

    // MARK: Receiving

    private func handle(line: String, generation mine: Int) async {
        guard mine == generation else { return }
        lastHeard = Date()

        for event in AgentEvent.decode(line: line) {

            if case .initialized = event {
                reducer.accept(event)
                guard reducer.hasExactly(tools: Set(tools)) else {
                    let observed = reducer.observedTools
                    let mcp = reducer.observedMCPServers

                    await shutdown(silent: true)
                    onUpdate(.scopeViolation(observed: observed, mcpServers: mcp))
                    return
                }
                resumeID = reducer.sessionID
                continue
            }

            let changed = reducer.accept(event)

            if reducer.isFinished {
                completeTurn()
                return
            }
            guard changed else { continue }
            let now = Date()
            guard now.timeIntervalSince(lastEmit) >= Self.emitInterval else { continue }
            lastEmit = now
            onUpdate(.turn(blocks: reducer.renderable))
        }
    }

    private func completeTurn(failedReason: String? = nil) {
        guard turnInFlight else { return }
        turnInFlight = false
        watchdog?.cancel()
        watchdog = nil

        var blocks = reducer.renderable
        if let failedReason {
            blocks.upsert(.error(id: "session-died", failedReason))

            for i in blocks.indices where blocks[i].activity?.status == .running {
                blocks[i].activity?.status = .failed
            }
        }
        let failed = reducer.failed || failedReason != nil
        onUpdate(.finished(blocks: blocks, plainText: reducer.plainText, failed: failed))

        if !failed { consecutiveFailures = 0 }
        if !outbox.isEmpty, !shuttingDown {
            let next = outbox.removeFirst()
            deliver(next)
        }
    }

    private func handleExit(code: Int32, stderr: String, generation mine: Int) async {
        guard mine == generation else { return }
        agent = nil
        guard !shuttingDown else { return }
        guard turnInFlight else { return }

        consecutiveFailures += 1
        let detail = stderr.isEmpty ? String(localized: "it stopped without saying why") : stderr

        if consecutiveFailures == 1, let text = lastSentText {
            turnInFlight = false
            deliver(text)
            return
        }
        completeTurn(failedReason: String(format: String(localized: "The foreman's session ended (%@)."),
                                          String(detail.prefix(200))))
    }

    func shutdown(silent: Bool = false) async {
        shuttingDown = true
        outbox.removeAll()
        generation += 1
        consumer?.cancel()
        consumer = nil
        watchdog?.cancel()
        watchdog = nil
        let dying = agent
        agent = nil
        if silent {
            turnInFlight = false
        } else if turnInFlight {
            completeTurn(failedReason: String(localized: "The session was stopped."))
        }

        await dying?.stopAndWait()
    }

    func cancelTurn() async {
        guard turnInFlight else { return }
        generation += 1
        consumer?.cancel()
        consumer = nil
        watchdog?.cancel()
        watchdog = nil
        let dying = agent
        agent = nil
        completeTurn(failedReason: String(localized: "Stopped."))
        await dying?.stopAndWait()
    }
}

// MARK: - Registry

@MainActor
final class ForemanSessions {
    private var sessions: [ForemanSession.Key: ForemanSession] = [:]

    private var order: [ForemanSession.Key] = []
    private let limit = 4

    private let resumeFile: JSONFile<[String: String]>
    private var resumeIDs: [String: String]

    init(resumeFile: JSONFile<[String: String]> =
            JSONFile<[String: String]>(url: AppSupport.file("foreman-sessions.json"))) {
        self.resumeFile = resumeFile
        resumeIDs = resumeFile.load() ?? [:]
    }

    func storedResume(for key: ForemanSession.Key) -> String? { resumeIDs[Self.token(key)] }

    func acquire(for key: ForemanSession.Key, cwd: URL,
                 onUpdate: @escaping @Sendable (ForemanSession.Update) -> Void) async -> ForemanSession {
        touch(key)
        if let existing = sessions[key] { return existing }
        await makeRoom(for: key)
        let session = ForemanSession(key: key, cwd: cwd,
                                     resumeID: resumeIDs[Self.token(key)], onUpdate: onUpdate)
        sessions[key] = session
        return session
    }

    var liveCount: Int { sessions.count }

    func existing(_ key: ForemanSession.Key) -> ForemanSession? { sessions[key] }

    func discard(_ key: ForemanSession.Key) {
        order.removeAll { $0 == key }
        if let session = sessions.removeValue(forKey: key) {
            Task { await session.shutdown() }
        }
    }

    func rememberResume(_ id: String?, for key: ForemanSession.Key) {
        guard let id, !id.isEmpty, resumeIDs[Self.token(key)] != id else { return }
        resumeIDs[Self.token(key)] = id
        resumeFile.save(resumeIDs)
    }

    private static func token(_ key: ForemanSession.Key) -> String {
        key.productID.uuidString + "/" + key.chatID.uuidString
    }

    private func touch(_ key: ForemanSession.Key) {
        order.removeAll { $0 == key }
        order.append(key)
    }

    private static let waitForSlot: TimeInterval = 120

    private func makeRoom(for key: ForemanSession.Key) async {
        let deadline = Date().addingTimeInterval(Self.waitForSlot)

        while sessions.count >= limit {
            let candidates = order.filter { $0 != key && sessions[$0] != nil }
            guard !candidates.isEmpty else { return }

            var retired = false
            for candidate in candidates {
                guard let session = sessions[candidate] else { continue }
                if await session.isBusy { continue }
                await retire(candidate, session)
                retired = true
                break
            }
            if retired { continue }

            if Date() < deadline {
                try? await Task.sleep(for: .milliseconds(250))
                continue
            }

            if let oldest = candidates.first, let session = sessions[oldest] {
                await retire(oldest, session)
            }
            return
        }
    }

    private func retire(_ key: ForemanSession.Key, _ session: ForemanSession) async {
        sessions[key] = nil
        order.removeAll { $0 == key }
        await session.shutdown()
    }

    func shutdownAll() {
        LiveAgents.shared.terminateAll()
        let all = Array(sessions.values)
        sessions.removeAll()
        order.removeAll()
        for session in all { Task { await session.shutdown() } }
    }
}
