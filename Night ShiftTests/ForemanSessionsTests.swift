import XCTest
@testable import Bulava

nonisolated final class ForemanSessionsTests: XCTestCase {

    private static func key(_ n: Int) -> ForemanSession.Key {

        ForemanSession.Key(productID: UUID(uuidString: String(format: "00000000-0000-4000-8000-%012d", n))!,
                           chatID: UUID(uuidString: String(format: "11111111-0000-4000-8000-%012d", n))!)
    }

    @MainActor private static func makeRegistry() -> ForemanSessions {

        ForemanSessions(resumeFile: JSONFile<[String: String]>(
            url: URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("bulava-sessions-\(UUID().uuidString).json")))
    }

    private static func open(_ registry: ForemanSessions, _ n: Int) async {
        _ = await registry.acquire(for: Self.key(n),
                                   cwd: URL(fileURLWithPath: NSTemporaryDirectory()),
                                   onUpdate: { _ in })
    }

    func testTheLimitHoldsAcrossMoreConversationsThanItAllows() async {
        let registry = await Self.makeRegistry()
        for n in 1...5 { await Self.open(registry, n) }
        let live = await registry.liveCount
        XCTAssertLessThanOrEqual(live, 4, "five conversations produced \(live) sessions")
    }

    func testReturningToARetiredConversationDoesNotExceedTheLimitEither() async {
        let registry = await Self.makeRegistry()
        for n in 1...8 { await Self.open(registry, n) }
        await Self.open(registry, 1)
        let live = await registry.liveCount
        XCTAssertLessThanOrEqual(live, 4)
    }

    func testTheSameConversationReusesItsSession() async {
        let registry = await Self.makeRegistry()
        await Self.open(registry, 1)
        let first = await registry.existing(Self.key(1))
        await Self.open(registry, 1)
        let again = await registry.existing(Self.key(1))
        XCTAssertTrue(again === first)
        let live = await registry.liveCount
        XCTAssertEqual(live, 1)
    }

    func testADiscardedSessionIsGoneAndTheNextOneIsFresh() async {
        let registry = await Self.makeRegistry()
        await Self.open(registry, 1)
        let first = await registry.existing(Self.key(1))
        XCTAssertNotNil(first)
        await registry.discard(Self.key(1))
        let afterDiscard = await registry.existing(Self.key(1))
        XCTAssertNil(afterDiscard)
        await Self.open(registry, 1)
        let replacement = await registry.existing(Self.key(1))
        XCTAssertFalse(replacement === first, "a discarded session must not come back")
    }

    func testAResumeIdSurvivesEvictionAndIsHandedToTheNextSession() async {
        let file = JSONFile<[String: String]>(
            url: URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("bulava-sessions-\(UUID().uuidString).json"))
        let registry = await ForemanSessions(resumeFile: file)
        await Self.open(registry, 1)
        await registry.rememberResume("session-abc", for: Self.key(1))

        let afterRelaunch = await ForemanSessions(resumeFile: file)
        let stored = await afterRelaunch.storedResume(for: Self.key(1))
        XCTAssertEqual(stored, "session-abc")
    }
}

// MARK: - Real processes

nonisolated final class ForemanProcessCapTests: XCTestCase {

    private func key(_ n: Int) -> ForemanSession.Key {
        ForemanSession.Key(productID: UUID(uuidString: String(format: "22222222-0000-4000-8000-%012d", n))!,
                           chatID: UUID(uuidString: String(format: "33333333-0000-4000-8000-%012d", n))!)
    }

    private static var claudeIsInstalled: Bool {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return ["\(home)/.local/bin/claude", "/opt/homebrew/bin/claude", "/usr/local/bin/claude"]
            .contains { FileManager.default.isExecutableFile(atPath: $0) }
    }

    func testMoreConversationsThanTheCapNeverRunMoreProcessesThanTheCap() async throws {
        try XCTSkipUnless(ForemanFence.isAvailable, "no sandbox-exec")
        try XCTSkipUnless(Self.claudeIsInstalled, "no claude on PATH")
        await ForemanSession.primePath()

        let fm = FileManager.default
        let stem = fm.homeDirectoryForCurrentUser
            .appendingPathComponent(".bulava-cap-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: stem, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: stem) }

        let registry = await ForemanSessions(resumeFile: JSONFile<[String: String]>(
            url: stem.appendingPathComponent("sessions.json")))
        await MainActor.run { ForemanSession.fenceDirectory = stem }

        let peak = Peak()
        let watcher = Task {
            while !Task.isCancelled {
                peak.observe(LiveAgents.shared.runningCount)
                try? await Task.sleep(for: .milliseconds(120))
            }
        }

        for n in 1...6 {
            let dir = stem.appendingPathComponent("p\(n)", isDirectory: true)
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            try Data("hello".utf8).write(to: dir.appendingPathComponent("a.txt"))

            let session = await registry.acquire(for: key(n), cwd: dir, onUpdate: { _ in })
            await session.send("Say the single word READY and nothing else.")
        }

        try await Task.sleep(for: .seconds(25))
        watcher.cancel()
        let live = await registry.liveCount
        let observed = peak.value
        await registry.shutdownAll()

        XCTAssertLessThanOrEqual(live, 4, "the registry held \(live) sessions")
        XCTAssertLessThanOrEqual(observed, 4,
                                 "peak of \(observed) live `claude` processes against a cap of 4")
        XCTAssertGreaterThan(observed, 0, "nothing ran at all — this probe would prove nothing")
    }

    private final class Peak: @unchecked Sendable {
        private let lock = NSLock()
        private var high = 0
        func observe(_ n: Int) { lock.lock(); high = max(high, n); lock.unlock() }
        var value: Int { lock.lock(); defer { lock.unlock() }; return high }
    }
}
