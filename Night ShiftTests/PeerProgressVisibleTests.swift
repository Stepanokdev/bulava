import XCTest
@testable import Bulava

/// A message being prepared used to look identical whether it had just arrived, had been read for
/// two minutes, or was behind a pipeline that had died: one sentence, "Claude and Codex are reading
/// this first", for all of it. A user asked whether a simple question had hung. It had not — the
/// screen had nothing else to say, and that is the defect.
///
/// The other half of the same complaint: Codex reads every message and the reader never sees a word
/// of it. Claude's reading becomes the answer; Codex's went into a file under the instance.
nonisolated final class PeerProgressVisibleTests: XCTestCase {

    // MARK: - The header counts

    func testWhileBothAreReadingItSaysSoAndCounts() {
        let peers = PeerReading(claudeSince: Date(timeIntervalSinceNow: -75),
                                codexSince: Date(timeIntervalSinceNow: -70))
        XCTAssertTrue(peers.label.contains("1:1"), "a minute and a bit, visibly: \(peers.label)")
    }

    func testWhenOneHasFinishedTheOtherIsNamed() {
        let onlyCodex = PeerReading(claudeSince: nil, codexSince: Date(timeIntervalSinceNow: -20))
        XCTAssertTrue(onlyCodex.label.contains("Codex"), onlyCodex.label)
        XCTAssertTrue(onlyCodex.label.contains("0:2"), "and how long it has been: \(onlyCodex.label)")

        let onlyClaude = PeerReading(claudeSince: Date(timeIntervalSinceNow: -20), codexSince: nil)
        XCTAssertFalse(onlyClaude.label.contains("Codex"),
                       "Codex has finished — saying it is still reading is the old lie")
    }

    func testAPeerWithNoWindowIsNamedRatherThanCounted() {
        let peers = PeerReading(claudeSince: Date(timeIntervalSinceNow: -5), codexSince: nil,
                                codexOut: true)
        XCTAssertTrue(peers.label.contains("Codex"), peers.label)
        XCTAssertFalse(peers.withCodex)
    }

    /// Preparation has begun, but neither position has started yet — the message is still being
    /// assembled for them. There is nothing to count, and the old sentence is the true one.
    func testBeforeEitherStartsTheOldSentenceStands() {
        let peers = PeerReading(claudeSince: nil, codexSince: nil)
        XCTAssertFalse(peers.label.contains("·"), peers.label)
    }

    // MARK: - Read off the disk the engine writes to

    private func instanceDir() throws -> (state: URL, instance: URL) {
        let state = FileManager.default.temporaryDirectory
            .appendingPathComponent("bulava-peer-progress-\(UUID().uuidString)")
        let slug = Slug.forPath("/tmp/peer-progress-project")
        let instance = state.appendingPathComponent("instances/\(slug)")
        try FileManager.default.createDirectory(at: instance, withIntermediateDirectories: true)
        try "/tmp/peer-progress-project".write(to: instance.appendingPathComponent("project"),
                                               atomically: true, encoding: .utf8)
        try "night-\(slug)".write(to: instance.appendingPathComponent("session"),
                                  atomically: true, encoding: .utf8)
        try "started".write(to: instance.appendingPathComponent("started-at"),
                            atomically: true, encoding: .utf8)
        return (state, instance)
    }

    func testAPeerThatIsRunningIsReadFromWhatTheEngineWrote() async throws {
        let (state, instance) = try instanceDir()
        defer { try? FileManager.default.removeItem(at: state) }

        let partial = instance.appendingPathComponent(".peer-codex.partial")
        try "half an opinion so far".write(to: partial, atomically: true, encoding: .utf8)
        let started = Int(Date(timeIntervalSinceNow: -42).timeIntervalSince1970)
        try #"{"started_at":\#(started),"partial":"\#(partial.path)"}"#
            .write(to: instance.appendingPathComponent("peer-codex.running"),
                   atomically: true, encoding: .utf8)

        let snapshot = await SupervisorClient(paths: SupervisorPaths(stateDir: state)).snapshot()
        let found = try XCTUnwrap(snapshot.instances.first)
        let codex = try XCTUnwrap(found.peerCodex, "the chat cannot count what it cannot see")
        XCTAssertEqual(Int(codex.startedAt.timeIntervalSince1970), started)
        XCTAssertGreaterThan(codex.bytes, 0, "how much of the position has arrived")
        XCTAssertNil(found.peerClaude, "only one of them is reading")
    }

    /// The file is removed when the peer finishes, and a stale one from a killed pipeline is
    /// cleared when the next preparation starts — so its presence is the whole signal.
    func testWithNoRunningFileNobodyIsReading() async throws {
        let (state, _) = try instanceDir()
        defer { try? FileManager.default.removeItem(at: state) }
        let snapshot = await SupervisorClient(paths: SupervisorPaths(stateDir: state)).snapshot()
        let found = try XCTUnwrap(snapshot.instances.first)
        XCTAssertNil(found.peerCodex)
        XCTAssertNil(found.peerClaude)
    }

    func testCodexsOwnReadingReachesTheThread() async throws {
        let (state, instance) = try instanceDir()
        defer { try? FileManager.default.removeItem(at: state) }

        try """
        ## READING
        Це продовження поточної задачі.

        ## RISK
        Публікація зараз поширить дефект на встановлені копії.
        """.write(to: instance.appendingPathComponent("peer-codex.latest.md"),
                  atomically: true, encoding: .utf8)

        let snapshot = await SupervisorClient(paths: SupervisorPaths(stateDir: state)).snapshot()
        let found = try XCTUnwrap(snapshot.instances.first)
        let positions = found.codexArtifacts.filter { $0.kind == .position }
        XCTAssertEqual(positions.count, 1, "the reader sees Codex's reading exactly once")
        XCTAssertTrue(positions[0].text.contains("Публікація зараз"),
                      "and it is what Codex actually wrote")
    }

    func testAnEmptyPositionIsNotACard() async throws {
        let (state, instance) = try instanceDir()
        defer { try? FileManager.default.removeItem(at: state) }
        try "   \n".write(to: instance.appendingPathComponent("peer-codex.latest.md"),
                          atomically: true, encoding: .utf8)
        let snapshot = await SupervisorClient(paths: SupervisorPaths(stateDir: state)).snapshot()
        let found = try XCTUnwrap(snapshot.instances.first)
        XCTAssertTrue(found.codexArtifacts.filter { $0.kind == .position }.isEmpty)
    }
}
