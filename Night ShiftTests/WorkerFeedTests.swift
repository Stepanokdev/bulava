import XCTest
@testable import Bulava

nonisolated final class WorkerFeedTests: XCTestCase {

    private var dir: URL!

    override func setUp() async throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("bulava-feed-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: dir)
    }

    // MARK: - Fixture

    @MainActor private func store(_ name: String = "conversations") -> ConversationStore {
        ConversationStore(fileURL: dir.appendingPathComponent("\(name).json"),
                          chatsURL: dir.appendingPathComponent("\(name)-chats.json"))
    }

    @MainActor private func transcript(_ name: String = "session.jsonl") -> URL {
        let url = dir.appendingPathComponent(name)
        FileManager.default.createFile(atPath: url.path, contents: nil)
        return url
    }

    @MainActor private func append(_ lines: [String], to url: URL) {
        guard let handle = try? FileHandle(forWritingTo: url) else { return XCTFail("no fixture") }
        defer { try? handle.close() }
        try? handle.seekToEnd()
        try? handle.write(contentsOf: Data((lines.joined(separator: "\n") + "\n").utf8))
    }

    private func said(_ id: String, _ text: String) -> String {
        #"{"type":"assistant","message":{"id":"\#(id)","content":[{"type":"text","text":"\#(text)"}]}}"#
    }

    private func used(_ id: String, _ tool: String, _ file: String) -> String {
        #"{"type":"assistant","message":{"id":"m-\#(id)","content":[{"type":"tool_use","id":"\#(id)","name":"\#(tool)","input":{"file_path":"\#(file)"}}]}}"#
    }

    private func finished(_ id: String) -> String {
        #"{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"\#(id)","is_error":false}]}}"#
    }

    @MainActor private func feed(_ store: ConversationStore, _ url: URL,
                      task: UUID = UUID(), product: UUID = UUID()) -> WorkerFeed {
        WorkerFeed(taskID: task, productID: product, chatID: nil, transcript: url, store: store)
    }

    // MARK: - What it shows

    @MainActor func testTheWorkersWordsAndStepsBecomeOneTurn() async {
        let url = transcript()
        append([said("m1", "Дивлюсь, як пишеться CSV."),
                used("t1", "Read", "/x/ExportService.swift"),
                finished("t1")], to: url)

        let s = store()
        await feed(s, url).drain()

        XCTAssertEqual(s.entries.count, 1, "one run is one turn, not one turn per line")
        let blocks = s.entries[0].blocks
        XCTAssertEqual(blocks.filter { $0.kind == .markdown }.map(\.text), ["Дивлюсь, як пишеться CSV."])
        XCTAssertEqual(blocks.compactMap { $0.activity }.map(\.status), [.done])
    }

    @MainActor func testItContinuesWhereItLeftOff() async {
        let url = transcript()
        let s = store()
        let f = feed(s, url)

        append([said("m1", "Перше.")], to: url)
        await f.drain()
        append([said("m2", "Друге.")], to: url)
        await f.drain()

        XCTAssertEqual(s.entries.count, 1)
        XCTAssertEqual(s.entries[0].blocks.filter { $0.kind == .markdown }.map(\.text),
                       ["Перше.", "Друге."])
    }

    @MainActor func testAGapIsCaughtUpInFullAndArrivesAtTheSameThread() async {
        let url = transcript()

        let live = store()
        let watching = feed(live, url)
        append([said("m1", "Почав.")], to: url)
        await watching.drain()

        for i in 2...40 { append([said("m\(i)", "Крок \(i).")], to: url) }

        await watching.drain()
        let caughtUp = live.entries[0].blocks.filter { $0.kind == .markdown }.map(\.text)
        XCTAssertEqual(caughtUp.count, 40, "everything written while it was away is folded in")
        XCTAssertEqual(caughtUp.first, "Почав.")
        XCTAssertEqual(caughtUp.last, "Крок 40.")

        let cold = store("cold")
        let fresh = feed(cold, url)
        await fresh.drain()
        XCTAssertEqual(cold.entries[0].blocks.filter { $0.kind == .markdown }.map(\.text), caughtUp,
                       "a cold rebuild and an incremental read agree — which is what makes it safe "
                       + "to relaunch into the middle of a night")
        XCTAssertEqual(cold.entries.count, 1, "and it is one turn, not one per launch")
    }

    @MainActor func testARestartContinuesTheSameTurnRatherThanWritingASecondOne() async {
        let url = transcript()
        let s = store()
        let task = UUID(), product = UUID()

        append([said("m1", "Перше.")], to: url)
        await feed(s, url, task: task, product: product).drain()

        append([said("m2", "Друге.")], to: url)
        await feed(s, url, task: task, product: product).drain()

        XCTAssertEqual(s.entries.count, 1, "the night was written twice")
        XCTAssertEqual(s.entries[0].blocks.filter { $0.kind == .markdown }.count, 2)
    }

    @MainActor func testTwoDifferentRunsAreTwoTurns() async {
        let s = store()
        let a = transcript("a.jsonl"), b = transcript("b.jsonl")
        append([said("m1", "A")], to: a)
        append([said("m1", "B")], to: b)
        await feed(s, a).drain()
        await feed(s, b).drain()
        XCTAssertEqual(s.entries.count, 2)
    }

    // MARK: - What it hides

    @MainActor func testTheSessionsOwnBookkeepingNeverAppears() async {
        let url = transcript()
        append([#"{"type":"system","subtype":"init","session_id":"s","tools":["Read"]}"#,
                used("t1", "Read", "/x/A.swift"),
                #"{"type":"result","subtype":"success","is_error":false,"session_id":"s"}"#],
               to: url)

        let s = store()
        await feed(s, url).drain()

        let activity = s.entries.first?.blocks.compactMap { $0.activity }.first
        XCTAssertEqual(activity?.status, .running,
                       "a mid-session result must not retire a step that never reported back")
        XCTAssertTrue(s.entries[0].blocks.allSatisfy { $0.kind != .error })
    }

    @MainActor func testAFileThatShrankIsReadFromTheBeginning() async {
        let url = transcript()
        let s = store()
        let f = feed(s, url)

        append([said("m1", "Довга перша сесія."), used("t1", "Read", "/x/A.swift"), finished("t1")], to: url)
        await f.drain()

        try? Data((said("m9", "Нова.") + "\n").utf8).write(to: url)
        await f.drain()

        XCTAssertEqual(s.entries[0].blocks.filter { $0.kind == .markdown }.map(\.text), ["Нова."])
    }

    @MainActor func testAnEmptyTranscriptProducesNoTurn() async {
        let s = store()
        await feed(s, transcript()).drain()
        XCTAssertTrue(s.entries.isEmpty)
    }
}

// MARK: - What the app says when there is nothing to show

nonisolated final class NoTrailReasonTests: XCTestCase {

    @MainActor private func model() -> AppModel {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("bulava-notrail-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        setenv("BULAVA_STATE_DIR", dir.path, 1)
        return AppModel()
    }

    private func empty(_ miss: WorkerTrail.Miss) -> WorkerTrail.Trail {
        WorkerTrail.Trail(blocks: [], omitted: 0, lastSaid: nil, source: nil, miss: miss)
    }

    @MainActor func testARunThatNeverWroteAnythingSaysSoAndOffersTheFix() async {
        var task = BacklogTask(title: "Map Alerts")
        task.dispatchedAt = Date()
        let text = model().noTrailReason(empty(.noRecord), task: task)
        XCTAssertTrue(text.contains(Fmt.clock(task.dispatchedAt!)), "it must say when the run started")
        XCTAssertFalse(text.localizedCaseInsensitiveContains("cannot find"),
                       "«I cannot find the log» describes the app, not the run")
    }

    @MainActor func testSeveralOverlappingSessionsKeepTheirOwnAnswer() async {
        var task = BacklogTask(title: "Map Alerts")
        task.dispatchedAt = Date()
        let text = model().noTrailReason(empty(.ambiguous), task: task)
        XCTAssertNotEqual(text, model().noTrailReason(empty(.noRecord), task: task),
                          "«I cannot tell which session» and «it never started» have different fixes")
    }

    @MainActor func testATaskThatWasNeverRunFallsBackToThePlainAnswer() async {
        let text = model().noTrailReason(empty(.noRecord), task: BacklogTask(title: "Map Alerts"))
        XCTAssertFalse(text.contains("00:00"))
    }
}

// MARK: - One night, one telling

nonisolated final class TrailAndFeedDoNotOverlapTests: XCTestCase {

    private let productID = UUID()
    private let taskID = UUID()
    private var project = ""
    private var sessionDir: URL!

    @MainActor
    private func seededModel() throws -> AppModel {
        let state = FileManager.default.temporaryDirectory
            .appendingPathComponent("bulava-overlap-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: state, withIntermediateDirectories: true)
        project = state.appendingPathComponent("project").path
        try FileManager.default.createDirectory(atPath: project, withIntermediateDirectories: true)

        let session = "77777777-7777-4777-8777-777777777777"
        sessionDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/projects")
            .appendingPathComponent(WorkerActivity.transcriptDirName(for: project))
        try FileManager.default.createDirectory(at: sessionDir, withIntermediateDirectories: true)
        let transcript = sessionDir.appendingPathComponent(session + ".jsonl")
        try #"""
        {"type":"assistant","message":{"id":"m1","content":[{"type":"text","text":"Дивлюсь."}]}}
        {"type":"assistant","message":{"id":"m2","content":[{"type":"tool_use","id":"t1","name":"Read","input":{"file_path":"/x/A.swift"}}]}}

        """#.write(to: transcript, atomically: true, encoding: .utf8)

        let now = ISO8601DateFormatter().string(from: Date().addingTimeInterval(-600))
        try """
        [{"id":"\(productID)","name":"Overlap","summary":"","resources":[],
          "pinned":false,"addedAt":"\(now)","brief":"","decisions":[]}]
        """.write(to: state.appendingPathComponent("products.json"), atomically: true, encoding: .utf8)
        try """
        [{"id":"\(taskID)","title":"Робота","detail":"","projectPath":"\(project)",
          "productID":"\(productID)","type":"feature","priority":2,"state":"blocked",
          "createdAt":"\(now)","updatedAt":"\(now)","dispatchedAt":"\(now)",
          "boundSessionID":"\(session)","boundRunID":"run-overlap"}]
        """.write(to: state.appendingPathComponent("backlog.json"), atomically: true, encoding: .utf8)
        setenv("BULAVA_STATE_DIR", state.path, 1)
        return AppModel()
    }

    override func tearDown() async throws {
        if let sessionDir { try? FileManager.default.removeItem(at: sessionDir) }
    }

    @MainActor
    func testOnceTheRunHasWrittenItsOwnTurnTheTrailIsNotOfferedAgain() async throws {
        let model = try seededModel()
        let task = try XCTUnwrap(model.backlog.task(id: taskID))

        XCTAssertFalse(model.hasLiveTrail(for: task))
        XCTAssertTrue(TaskPresentation.cardActions(for: task, model: model).contains { $0.id == "trail" })

        let transcript = try XCTUnwrap(WorkerTrail.transcript(for: task))
        let feed = WorkerFeed(taskID: taskID, productID: productID, chatID: nil,
                              transcript: transcript, store: model.conversations)
        await feed.drain()

        XCTAssertTrue(model.hasLiveTrail(for: task), "the feed's turn was not recognised as the trail")
        XCTAssertFalse(TaskPresentation.cardActions(for: task, model: model).contains { $0.id == "trail" },
                       "the card offers to post a second copy of what is already above it")

        let before = model.conversations.entries.count
        model.showWorkerTrail(task: task)
        XCTAssertEqual(model.conversations.entries.count, before,
                       "the same night was written into the thread twice")
    }
}

// MARK: - A long night, on the main thread

nonisolated final class WorkerFeedCostTests: XCTestCase {

    private func biggestTranscript() throws -> URL {
        let root = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/projects")
        var best: (URL, Int)?
        for dir in (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? [] {
            let sub = root.appendingPathComponent(dir)
            for name in (try? FileManager.default.contentsOfDirectory(atPath: sub.path)) ?? []
            where name.hasSuffix(".jsonl") {
                let url = sub.appendingPathComponent(name)
                let size = ((try? FileManager.default.attributesOfItem(atPath: url.path)[.size]) as? Int) ?? 0
                if size > (best?.1 ?? 0) { best = (url, size) }
            }
        }
        guard let best, best.1 > 1_000_000 else { throw XCTSkip("no substantial transcript here") }
        return best.0
    }

    func testALongNightIsFoldedWithoutFreezingTheWindow() async throws {
        let url = try biggestTranscript()
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("bulava-cost-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let pings = Pings()
        let pinger = Task.detached(priority: .high) {
            while !Task.isCancelled {
                await pings.tick()
                try? await Task.sleep(for: .milliseconds(10))
            }
        }

        let store = await ConversationStore(fileURL: dir.appendingPathComponent("c.json"),
                                            chatsURL: dir.appendingPathComponent("chats.json"))
        let feed = await WorkerFeed(taskID: UUID(), productID: UUID(), chatID: nil,
                                    transcript: url, store: store)
        let started = Date()
        await feed.drain()
        let took = Date().timeIntervalSince(started)
        pinger.cancel()

        let landed = await pings.count

        XCTAssertGreaterThan(landed, 10,
                             "the main actor answered \(landed) pings while folding for \(String(format: "%.1f", took))s — the window was frozen")
        let entries = await store.entries.count
        XCTAssertGreaterThan(entries, 0, "a 10MB night produced no turn at all")
    }

    @MainActor private final class Pings {
        private(set) var count = 0
        func tick() { count += 1 }
    }
}

extension WorkerFeedTests {

    @MainActor func testTheLastLineIsReadOnceTheRunIsOver() async {
        let url = transcript()
        let s = store()
        let f = feed(s, url)

        try? Data(said("m1", "Готово, зупиняюсь.").utf8).write(to: url)
        await f.drain()
        XCTAssertTrue(s.entries.isEmpty, "a half-written line must not be shown while the run is live")

        f.stop()
        XCTAssertEqual(s.entries.first?.blocks.filter { $0.kind == .markdown }.map(\.text),
                       ["Готово, зупиняюсь."],
                       "the run's last sentence was dropped")
    }
}
