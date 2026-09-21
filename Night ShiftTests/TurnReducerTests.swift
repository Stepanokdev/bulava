import XCTest
@testable import Bulava

nonisolated final class TurnReducerTests: XCTestCase {

    private func replay(_ lines: [String]) -> TurnReducer {
        var reducer = TurnReducer()
        for line in lines {
            for event in AgentEvent.decode(line: line) { reducer.accept(event) }
        }
        return reducer
    }

    // MARK: - The whole turn

    func testARealSessionFoldsIntoTheBlocksItActuallyContained() {
        let reducer = replay(AgentStreamFixture.turnLines)

        XCTAssertTrue(reducer.isFinished, "only `result` ends a turn, and this fixture has one")
        XCTAssertFalse(reducer.failed)

        let blocks = reducer.renderable
        let prose = blocks.filter { $0.kind == .markdown }
        let tools = blocks.filter { $0.kind == .activity }

        XCTAssertEqual(prose.count, 2, "an opening sentence and a closing one — not four")
        XCTAssertEqual(tools.count, 2, "the refused Read and the Glob that ran")
    }

    func testStreamedProseIsReplacedByTheAuthoritativeMessageNotAppendedToIt() {
        let reducer = replay(AgentStreamFixture.turnLines)
        for block in reducer.renderable where block.kind == .markdown {

            let opening = String(block.text.prefix(24))
            let rest = String(block.text.dropFirst(4))
            XCTAssertFalse(rest.contains(opening),
                           "prose was written twice: \(block.text.prefix(120))")
        }
    }

    func testProseFromTwoAssistantMessagesGetsTwoDistinctBlocks() {
        let reducer = replay(AgentStreamFixture.turnLines)
        let ids = reducer.renderable.filter { $0.kind == .markdown }.map(\.id)
        XCTAssertEqual(Set(ids).count, ids.count, "prose block ids must be unique")

        let prefixes = Set(ids.map { $0.split(separator: "#").first.map(String.init) ?? "" })
        XCTAssertEqual(prefixes.count, 2, "the fixture has two assistant messages")
    }

    func testARefusedToolEndsAsFailedAndKeepsWhatItWasDoing() {
        let reducer = replay(AgentStreamFixture.turnLines)
        let failed = reducer.renderable.compactMap(\.activity).filter { $0.status == .failed }
        XCTAssertEqual(failed.count, 1, "exactly one tool was refused in this session")
        XCTAssertEqual(failed.first?.verbKey, "reads %@",
                       "the outcome is new; the verb came from the call and must survive it")
        XCTAssertNotNil(failed.first?.detail, "a failure with no reason is the screen this replaces")
    }

    func testTheSuccessfulToolEndsAsDone() {
        let reducer = replay(AgentStreamFixture.turnLines)
        let done = reducer.renderable.compactMap(\.activity).filter { $0.status == .done }
        XCTAssertEqual(done.count, 1)
        XCTAssertNil(done.first?.detail, "nothing went wrong, so there is nothing to explain")
    }

    func testMessageStopDoesNotEndTheTurn() {
        var reducer = TurnReducer()
        outer: for line in AgentStreamFixture.turnLines {
            for event in AgentEvent.decode(line: line) {
                if case .turnFinished = event { break outer }
                reducer.accept(event)
            }
        }
        XCTAssertFalse(reducer.isFinished,
                       "the fixture contains message_stop twice and neither may end the turn")
        XCTAssertEqual(reducer.renderable.filter { $0.kind == .markdown }.count, 2,
                       "both sentences arrived before `result` did")
    }

    func testTheSessionIsIdentifiedAndItsScopeIsObserved() {
        let reducer = replay(AgentStreamFixture.turnLines)
        XCTAssertNotNil(reducer.sessionID)
        XCTAssertTrue(reducer.hasExactly(tools: ["Read", "Glob"]),
                      "init reports what was GRANTED — got \(reducer.observedTools)")
        XCTAssertFalse(reducer.hasExactly(tools: ["Read", "Glob", "Bash"]),
                       "a scope the session does not have must not read as satisfied")
        XCTAssertTrue(reducer.observedMCPServers.isEmpty, "--strict-mcp-config drops every server")
    }

    // MARK: - Rules the fixture cannot show

    func testTheSameToolCallReportedManyTimesStaysOneBlock() {
        var reducer = TurnReducer()
        reducer.accept(.toolUse(id: "toolu_1", name: "Bash", verbKey: "runs %@", object: "night-shift start"))
        for _ in 0..<52 {
            reducer.accept(.toolResult(id: "toolu_1", isError: true, detail: "could not launch",
                                       output: nil))
        }
        XCTAssertEqual(reducer.renderable.count, 1, "one call is one block, however often it reports")
        XCTAssertEqual(reducer.renderable.first?.activity?.status, .failed)
    }

    func testACallStillRunningWhenTheTurnEndsIsNotLeftRunning() {
        var reducer = TurnReducer()
        reducer.accept(.toolUse(id: "toolu_x", name: "Bash", verbKey: "runs %@", object: "swift build"))
        reducer.accept(.turnFinished(subtype: "error_during_execution", sessionID: "s", isError: true))
        XCTAssertEqual(reducer.renderable.compactMap(\.activity).first?.status, .failed)
        XCTAssertTrue(reducer.failed)
        XCTAssertTrue(reducer.renderable.contains { $0.kind == .error },
                      "a turn that failed says so, rather than just stopping")
    }

    func testAnEmptyTextBlockNeverLeavesAGapInTheFeed() {
        var reducer = TurnReducer()
        reducer.accept(.messageStart(messageID: "m1"))
        reducer.accept(.textBlockStart(index: 0))
        reducer.accept(.toolUse(id: "t1", name: "Read", verbKey: "reads %@", object: "a.swift"))
        reducer.accept(.turnFinished(subtype: "success", sessionID: "s", isError: false))
        XCTAssertFalse(reducer.renderable.contains { $0.kind == .markdown })
    }

    func testProseArrivingWithNoPartialEventsStillKeysCleanly() {

        var reducer = TurnReducer()
        reducer.accept(.assistantText(messageID: "m1", text: "First."))
        reducer.accept(.assistantText(messageID: "m1", text: "Second."))
        reducer.accept(.assistantText(messageID: "m2", text: "Third."))
        let texts = reducer.renderable.filter { $0.kind == .markdown }.map(\.text)
        XCTAssertEqual(texts, ["First.", "Second.", "Third."])
    }

    func testUnknownEventsChangeNothing() {
        var reducer = TurnReducer()
        XCTAssertTrue(AgentEvent.decode(line: #"{"type":"telemetry","x":1}"#).isEmpty)
        XCTAssertTrue(AgentEvent.decode(line: "not json at all").isEmpty)
        XCTAssertTrue(reducer.renderable.isEmpty)
    }

    // MARK: - What the review caught

    func testAnAssistantMessageWithSeveralBlocksYieldsAllOfThem() {
        let line = #"""
        {"type":"assistant","message":{"id":"m9","content":[{"type":"text","text":"Looking."},{"type":"tool_use","id":"toolu_9","name":"Read","input":{"file_path":"/a/b.swift"}},{"type":"text","text":"Done."}]}}
        """#
        let events = AgentEvent.decode(line: line)
        XCTAssertEqual(events.count, 3, "three blocks, three events — got \(events)")

        var reducer = TurnReducer()
        for event in events { reducer.accept(event) }
        XCTAssertEqual(reducer.renderable.filter { $0.kind == .markdown }.count, 2)
        XCTAssertEqual(reducer.renderable.filter { $0.kind == .activity }.count, 1)
    }

    func testSeveralToolResultsInOneMessageAllLand() {
        let line = #"""
        {"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"a","is_error":false},{"type":"tool_result","tool_use_id":"b","is_error":true,"content":"boom"}]}}
        """#
        var reducer = TurnReducer()
        for event in AgentEvent.decode(line: line) { reducer.accept(event) }
        let byStatus = reducer.renderable.compactMap(\.activity)
        XCTAssertEqual(byStatus.count, 2)
        XCTAssertEqual(byStatus.first { $0.toolCallID == "b" }?.status, .failed)
    }

    func testAnUnrecognisedMCPShapeIsNotReadAsLockedDown() {
        let locked = #"{"type":"system","subtype":"init","session_id":"s","tools":["Read"],"mcp_servers":[]}"#
        let strange = #"{"type":"system","subtype":"init","session_id":"s","tools":["Read"],"mcp_servers":{"a":1}}"#

        var ok = TurnReducer()
        for event in AgentEvent.decode(line: locked) { ok.accept(event) }
        XCTAssertTrue(ok.hasExactly(tools: ["Read"]))

        var odd = TurnReducer()
        for event in AgentEvent.decode(line: strange) { odd.accept(event) }
        XCTAssertFalse(odd.hasExactly(tools: ["Read"]),
                       "an unreadable server list is unknown, and unknown is not empty")

        let silent = #"{"type":"system","subtype":"init","session_id":"s","tools":["Read"]}"#
        var quiet = TurnReducer()
        for event in AgentEvent.decode(line: silent) { quiet.accept(event) }
        XCTAssertFalse(quiet.hasExactly(tools: ["Read"]))
    }

    func testTwoIdenticalLinesInOneMessageAreBothKept() {
        var reducer = TurnReducer()
        reducer.accept(.assistantText(messageID: "m1", text: "Готово."))
        reducer.accept(.assistantText(messageID: "m1", text: "Готово."))
        XCTAssertEqual(reducer.renderable.filter { $0.kind == .markdown }.count, 2)
    }

    func testPlainTextFallbackIsTheProseAndOnlyTheProse() {
        let reducer = replay(AgentStreamFixture.turnLines)
        let plain = reducer.plainText
        XCTAssertFalse(plain.isEmpty)
        XCTAssertFalse(plain.contains("toolu_"), "tool ids are machinery, not something he reads")
    }
}

// MARK: - Framing

nonisolated final class NDJSONFramerTests: XCTestCase {

    func testAMultiByteCharacterSplitAcrossChunksSurvives() {
        var framer = NDJSONFramer()
        let line = Data(#"{"t":"Бригадир"}"#.utf8) + Data([UInt8(ascii: "\n")])

        let cut = 7
        XCTAssertTrue(framer.feed(line.prefix(cut)).isEmpty, "no newline yet, so nothing is a line")
        let out = framer.feed(line.suffix(from: cut))
        XCTAssertEqual(out, [#"{"t":"Бригадир"}"#])
    }

    func testSeveralLinesInOneChunkComeOutInOrder() {
        var framer = NDJSONFramer()
        let out = framer.feed(Data("{\"a\":1}\n{\"b\":2}\n{\"c\":3}\n".utf8))
        XCTAssertEqual(out, [#"{"a":1}"#, #"{"b":2}"#, #"{"c":3}"#])
    }

    func testAPartialTrailingLineIsHeldUntilItsNewlineArrives() {
        var framer = NDJSONFramer()
        XCTAssertEqual(framer.feed(Data("{\"a\":1}\n{\"b\"".utf8)), [#"{"a":1}"#])
        XCTAssertEqual(framer.feed(Data(":2}\n".utf8)), [#"{"b":2}"#])
    }

    func testBlankLinesAreNotEvents() {
        var framer = NDJSONFramer()
        XCTAssertEqual(framer.feed(Data("\n\n{\"a\":1}\n\n".utf8)), [#"{"a":1}"#])
    }

    func testFlushYieldsAnUnterminatedTail() {
        var framer = NDJSONFramer()
        _ = framer.feed(Data("{\"a\":1}".utf8))
        XCTAssertEqual(framer.flush(), [#"{"a":1}"#])
        XCTAssertTrue(framer.flush().isEmpty, "and only once")
    }

    func testTheRealCaptureFramesBackToItsOwnLines() {
        var framer = NDJSONFramer()
        var out: [String] = []
        let data = Data((AgentStreamFixture.raw + "\n").utf8)

        var i = data.startIndex
        while i < data.endIndex {
            let j = data.index(i, offsetBy: 97, limitedBy: data.endIndex) ?? data.endIndex
            out += framer.feed(data[i..<j])
            i = j
        }
        out += framer.flush()
        XCTAssertEqual(out.count, AgentStreamFixture.turnLines.count)
        XCTAssertEqual(out, AgentStreamFixture.turnLines)
    }
}

// MARK: - Superseding

nonisolated final class ForemanSupersedingTests: XCTestCase {

    func testTalkingIntentsSurviveANewerMessage() {
        for action in [ForemanIntent.Action.answer, .clarify, .unknown, .look,
                       .status, .done, .blocked, .review, .capacity, .activity] {
            XCTAssertTrue(AppModel.isConversational(action), "\(action) only talks")
        }
    }

    func testEveryConsequentialIntentIsStillSuperseded() {
        for action in [ForemanIntent.Action.createTask, .runQueue, .stopAll,
                       .dispatchReady, .approve, .relay, .watch] {
            XCTAssertFalse(AppModel.isConversational(action),
                           "\(action) changes something and must not fire late")
        }
    }
}

// MARK: - The worker's trail

nonisolated final class WorkerTrailTests: XCTestCase {

    private func aRealTranscript() throws -> URL {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/projects")
        let projects = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        for name in projects.sorted() {
            let sub = dir.appendingPathComponent(name)
            let files = ((try? FileManager.default.contentsOfDirectory(atPath: sub.path)) ?? [])
                .filter { $0.hasSuffix(".jsonl") }
                .map { sub.appendingPathComponent($0) }
            if let big = files.first(where: {
                ((try? FileManager.default.attributesOfItem(atPath: $0.path)[.size]) as? Int ?? 0) > 200_000
            }) { return big }
        }
        throw XCTSkip("no substantial transcript on this machine")
    }

    // MARK: - Reading one

    func testARealSessionYieldsItsToolCallsAsSteps() throws {
        let trail = WorkerTrail.read(transcript: try aRealTranscript())
        XCTAssertFalse(trail.isEmpty, "a substantial session produced no trail at all")
        for block in trail.blocks {
            XCTAssertEqual(block.kind, .activity)
            XCTAssertFalse(block.activity?.toolCallID.isEmpty ?? true)
        }
    }

    func testEachToolCallAppearsOnce() throws {
        let trail = WorkerTrail.read(transcript: try aRealTranscript())
        let ids = trail.blocks.compactMap { $0.activity?.toolCallID }
        XCTAssertEqual(Set(ids).count, ids.count)
    }

    func testNothingInAFinishedTrailIsStillRunning() throws {
        let trail = WorkerTrail.read(transcript: try aRealTranscript())
        try XCTSkipIf(trail.blocks.count < 5, "too few steps to say anything")
        XCTAssertTrue(trail.blocks.allSatisfy { $0.activity?.status != .running },
                      "a trail is read after the fact; nothing in it is still going")
    }

    // MARK: - Which session

    private func task(dispatched: Date, project: String, worktree: String? = nil,
                      session: String? = nil) -> BacklogTask {
        var t = BacklogTask(title: "probe")
        t.projectPath = project
        t.worktree = worktree
        t.boundSessionID = session
        t.dispatchedAt = dispatched
        return t
    }

    private func makeSessions() throws -> (dir: URL, root: String, old: URL, mine: URL, started: Date) {
        let root = "/tmp/bulava-trail-\(UUID().uuidString)"
        let dir = WorkerTrail.directory(for: root)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let started = Date()

        let old = dir.appendingPathComponent("11111111-1111-4111-8111-111111111111.jsonl")
        try Self.transcript(tool: "Read", object: "SomebodyElse.swift").write(to: old, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.modificationDate: started.addingTimeInterval(-14)],
                                              ofItemAtPath: old.path)

        let mine = dir.appendingPathComponent("22222222-2222-4222-8222-222222222222.jsonl")
        try Self.transcript(tool: "Read", object: "Mine.swift").write(to: mine, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.modificationDate: started.addingTimeInterval(60)],
                                              ofItemAtPath: mine.path)
        return (dir, root, old, mine, started)
    }

    private static func transcript(tool: String, object: String, calls: Int = 1) -> String {
        (0..<calls).map { i in
            let id = "toolu_\(i)_\(object)"
            let use = #"{"type":"assistant","message":{"id":"m\#(i)","content":[{"type":"tool_use","id":"\#(id)","name":"\#(tool)","input":{"file_path":"/x/\#(object)"}}]}}"#
            let result = #"{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"\#(id)","is_error":false}]}}"#
            return use + "\n" + result
        }.joined(separator: "\n") + "\n"
    }

    func testASessionThatEndedBeforeTheTaskStartedIsNotItsTrail() throws {
        let s = try makeSessions()
        defer { try? FileManager.default.removeItem(at: s.dir) }

        try FileManager.default.setAttributes([.modificationDate: s.started.addingTimeInterval(-1)],
                                              ofItemAtPath: s.mine.path)
        let chosen = WorkerTrail.transcript(for: task(dispatched: s.started, project: s.root))
        XCTAssertNil(chosen, "no session overlaps this run, so there is no trail — not somebody else's")
    }

    func testTheSessionThatOverlapsTheRunIsChosen() throws {
        let s = try makeSessions()
        defer { try? FileManager.default.removeItem(at: s.dir) }
        let chosen = WorkerTrail.transcript(for: task(dispatched: s.started, project: s.root))
        XCTAssertEqual(chosen?.lastPathComponent, s.mine.lastPathComponent)
    }

    func testABoundSessionIdWins() throws {
        let s = try makeSessions()
        defer { try? FileManager.default.removeItem(at: s.dir) }
        let bound = "11111111-1111-4111-8111-111111111111"
        let chosen = WorkerTrail.transcript(for: task(dispatched: s.started, project: s.root,
                                                     session: bound))
        XCTAssertEqual(chosen?.lastPathComponent, bound + ".jsonl")
    }

    func testASessionIdThatIsNotAFileFallsBackToTheWindow() throws {
        let s = try makeSessions()
        defer { try? FileManager.default.removeItem(at: s.dir) }
        let chosen = WorkerTrail.transcript(for: task(dispatched: s.started, project: s.root,
                                                     session: "night-presale-copilot-0ae8"))
        XCTAssertEqual(chosen?.lastPathComponent, s.mine.lastPathComponent)
    }

    func testAWorktreeRunIsFoundInTheWorktreesDirectory() throws {
        let s = try makeSessions()
        defer { try? FileManager.default.removeItem(at: s.dir) }
        let chosen = WorkerTrail.transcript(for: task(dispatched: s.started,
                                                     project: "/tmp/some-other-project",
                                                     worktree: s.root))
        XCTAssertEqual(chosen?.lastPathComponent, s.mine.lastPathComponent)
    }

    // MARK: - Two sessions at once

    func testTwoSessionsOverlappingTheRunProduceNoTrail() throws {
        let s = try makeSessions()
        defer { try? FileManager.default.removeItem(at: s.dir) }

        let his = s.dir.appendingPathComponent("33333333-3333-4333-8333-333333333333.jsonl")
        try Self.transcript(tool: "Edit", object: "HisOwnAfternoon.swift")
            .write(to: his, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.modificationDate: s.started.addingTimeInterval(600)],
                                              ofItemAtPath: his.path)

        XCTAssertNil(WorkerTrail.transcript(for: task(dispatched: s.started, project: s.root)),
                     "two sessions overlap this run — picking the newest is a guess, not an answer")
    }

    func testABoundIdResolvesTwoOverlappingSessions() throws {
        let s = try makeSessions()
        defer { try? FileManager.default.removeItem(at: s.dir) }
        let his = s.dir.appendingPathComponent("33333333-3333-4333-8333-333333333333.jsonl")
        try Self.transcript(tool: "Edit", object: "HisOwnAfternoon.swift")
            .write(to: his, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.modificationDate: s.started.addingTimeInterval(600)],
                                              ofItemAtPath: his.path)

        let mine = s.mine.deletingPathExtension().lastPathComponent
        let chosen = WorkerTrail.transcript(for: task(dispatched: s.started, project: s.root,
                                                     session: mine))
        XCTAssertEqual(chosen?.lastPathComponent, s.mine.lastPathComponent)
    }

    func testTheSameSessionSeenThroughTwoRootsIsNotAmbiguous() throws {
        let s = try makeSessions()
        defer { try? FileManager.default.removeItem(at: s.dir) }

        let alias = "/tmp/bulava-trail-alias-\(UUID().uuidString)"
        let aliasDir = WorkerTrail.directory(for: alias)
        try FileManager.default.createDirectory(at: aliasDir.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: aliasDir, withDestinationURL: s.dir)
        defer { try? FileManager.default.removeItem(at: aliasDir) }

        let chosen = WorkerTrail.transcript(for: task(dispatched: s.started, project: alias,
                                                     worktree: s.root))
        XCTAssertEqual(chosen?.lastPathComponent, s.mine.lastPathComponent,
                       "one file under two names is one session")
    }

    func testATaskThatWasNeverDispatchedHasNoTrail() throws {
        let s = try makeSessions()
        defer { try? FileManager.default.removeItem(at: s.dir) }
        var t = task(dispatched: s.started, project: s.root)
        t.dispatchedAt = nil
        XCTAssertNil(WorkerTrail.transcript(for: t))
    }

    // MARK: - Nothing is silently dropped

    func testTheOmittedCountIsExactOverTheWholeFile() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("bulava-omit-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let calls = WorkerTrail.stepCeiling + 37
        let url = dir.appendingPathComponent("s.jsonl")
        try Self.transcript(tool: "Read", object: "f.swift", calls: calls)
            .write(to: url, atomically: true, encoding: .utf8)

        let trail = WorkerTrail.read(transcript: url)
        XCTAssertEqual(trail.blocks.count, WorkerTrail.stepCeiling)
        XCTAssertEqual(trail.omitted, 37, "the count must be exact, not what fitted in a window")
    }

    func testAShortTrailOmitsNothing() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("bulava-omit2-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("s.jsonl")
        try Self.transcript(tool: "Read", object: "f.swift", calls: 5)
            .write(to: url, atomically: true, encoding: .utf8)

        let trail = WorkerTrail.read(transcript: url)
        XCTAssertEqual(trail.blocks.count, 5)
        XCTAssertEqual(trail.omitted, 0)
        XCTAssertEqual(AppModel.trailCaption(trail), String(localized: "What it did while you were away:"),
                       "with nothing omitted the caption says only what it is")
    }

    func testTheCaptionSaysSoWhenStepsWereDropped() throws {
        var trail = WorkerTrail.Trail(blocks: [], omitted: 12, lastSaid: nil, source: nil)
        trail.blocks = [.activity(BlockActivity(toolCallID: "t", verbKey: "reads %@", object: "a.swift"))]
        let caption = AppModel.trailCaption(trail)
        XCTAssertTrue(caption.contains("12"), "silently hiding what was dropped is the bug, not the fix")
    }

    func testAProjectWithNoTranscriptYieldsNothing() {
        var t = BacklogTask(title: "x")
        t.projectPath = "/tmp/definitely-not-a-project-\(UUID().uuidString)"
        t.dispatchedAt = Date()
        let trail = WorkerTrail.read(task: t)
        XCTAssertTrue(trail.isEmpty)
        XCTAssertNil(trail.source)
    }
}
