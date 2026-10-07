import XCTest
@testable import Bulava

/// The run view draws only what the engine's journal says. These are the journal's own lines, in
/// the order `pipeline.sh`, `pipeline-deliver.sh`, `worker-outcome.sh` and the review gate write them.
nonisolated final class RunTimelineTests: XCTestCase {
    private let mid = "6F1C2A40-0000-4000-8000-000000000001"

    private var peerDoc: PipelineDocument {
        let json = """
        {"schema":"bulava.pipeline/1","id":"adaptive-peer","name":"Claude + Codex","builtin":true,"executes":"adaptive-peer",
         "nodes":[{"id":"chat","module":"bulava/trigger.chat@1"},{"id":"context","module":"bulava/prep.context@1"},
                  {"id":"peer-claude","module":"bulava/prep.position@1","params":{"engine":"claude"}},
                  {"id":"peer-codex","module":"bulava/prep.position@1","params":{"engine":"codex"}},
                  {"id":"align","module":"bulava/prep.align@1"},{"id":"compose","module":"bulava/prep.compose@1"},
                  {"id":"deliver","module":"bulava/agent.claude@1"},{"id":"scope","module":"bulava/gate.scope@1"},
                  {"id":"verify","module":"bulava/gate.verify@1"},{"id":"review","module":"bulava/gate.review@1"},
                  {"id":"skills","module":"bulava/skill.require@1"},
                  {"id":"report","module":"bulava/out.report@1"},{"id":"merge","module":"bulava/out.merge@1"}],
         "edges":[{"from":"chat.task","to":"context.task"},{"from":"review.fail","to":"deliver.feedback","loop":{"max":3}}],
         "future_key":{"kept":true}}
        """
        return try! JSONDecoder().decode(PipelineDocument.self, from: Data(json.utf8))
    }

    private func line(_ stage: String, _ state: String, _ extra: String = "", note: String? = nil, ms: Int = 0, message: String? = nil) -> String {
        let n = note.map { ",\"note\":\"\($0)\"" } ?? ""
        let x = extra.isEmpty ? "" : "," + extra
        return "{\"v\":1,\"ms\":\(1_790_000_000_000 + ms),\"message_id\":\"\(message ?? mid)\",\"pipeline\":\"adaptive-peer\",\"stage\":\"\(stage)\",\"state\":\"\(state)\"\(n)\(x)}"
    }

    private let stagesList = "\"stages\":[{\"id\":\"context\",\"node\":\"context\"},{\"id\":\"peer-claude\",\"node\":\"peer-claude\",\"group\":\"peers\",\"optional\":true},{\"id\":\"peer-codex\",\"node\":\"peer-codex\",\"group\":\"peers\",\"optional\":true},{\"id\":\"align\",\"node\":\"align\"},{\"id\":\"compose\",\"node\":\"compose\"},{\"id\":\"deliver\",\"node\":\"deliver\"}],\"snapshot\":\"/tmp/art\""

    private func reduce(_ lines: [String]) -> RunGraph {
        let events = RunEvent.parse(lines: lines.joined(separator: "\n").split(separator: "\n"))
        return RunReducer.reduce(events: events, messageID: mid, document: peerDoc)
    }

    private var preparation: [String] {
        [line("pipeline", "running", stagesList),
         line("context", "running", "\"node\":\"context\""),
         line("context", "done", "\"node\":\"context\""),
         line("peer-claude", "running", "\"node\":\"peer-claude\""),
         line("peer-codex", "running", "\"node\":\"peer-codex\""),
         line("peer-claude", "done", "\"node\":\"peer-claude\""),
         line("peer-codex", "unavailable", "\"node\":\"peer-codex\"", note: "Codex limit"),
         line("align", "running", "\"node\":\"align\""),
         line("align", "done", "\"node\":\"align\""),
         line("compose", "running", "\"node\":\"compose\""),
         line("compose", "done", "\"node\":\"compose\""),
         line("deliver", "running", "\"node\":\"deliver\""),
         line("deliver", "delivered", "\"node_role\":\"agent\""),
         line("deliver", "done", "\"node\":\"deliver\""),
         line("pipeline", "done")]
    }

    func testDocumentKeepsKeysThisBuildDoesNotKnow() throws {
        let data = try JSONEncoder().encode(peerDoc)
        let back = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        XCTAssertEqual((back?["future_key"] as? [String: Any])?["kept"] as? Bool, true)
        XCTAssertEqual(peerDoc.revision, 1, "a description without a revision is at its first one")
        XCTAssertEqual(peerDoc.description, "")
    }

    func testPreparationEndsWithTheWorkerWorking() {
        let g = reduce(preparation)
        XCTAssertEqual(g.status("chat").state, .done)
        XCTAssertEqual(g.status("context").state, .done)
        XCTAssertEqual(g.status("peer-claude").state, .done)
        XCTAssertEqual(g.status("peer-codex").state, .unavailable)
        XCTAssertEqual(g.status("peer-codex").note, "Codex limit")
        XCTAssertEqual(g.status("deliver").state, .running,
                       "the hand-over finishing is not the work finishing")
        XCTAssertEqual(g.status("review").state, .queued)
        XCTAssertEqual(g.overall, .working)
        XCTAssertTrue(g.isLive)
        XCTAssertEqual(g.snapshot, "/tmp/art")
    }

    func testAPassedRunAcceptsTheWorkAndLeavesTheMergeToYou() {
        let g = reduce(preparation + [
            line("outcome", "declared", "\"result\":\"succeeded_changes\""),
            line("gate", "running"),
            line("gate.scope", "done"),
            line("gate.verify", "running"),
            line("gate.verify", "done"),
            line("gate.review", "running", "\"round\":1,\"max\":3"),
            line("gate.review", "verified"),
            line("run", "passed", "\"disposition\":\"passed\""),
        ])
        XCTAssertEqual(g.status("deliver").state, .done)
        XCTAssertEqual(g.status("scope").state, .done)
        XCTAssertEqual(g.status("verify").state, .done)
        XCTAssertEqual(g.status("review").state, .verified)
        XCTAssertEqual(g.status("report").state, .done)
        XCTAssertEqual(g.status("merge").state, .waiting)
        XCTAssertEqual(g.overall, .finished("passed"))
        XCTAssertFalse(g.isLive)
    }

    /// The journal of the run that raised the question: round 2 of the review began, the reviewer
    /// answered BLOCKED, and the engine parked the run — with no line closing the review. The chat
    /// then said "work stopped" and "Codex review · working" at once. A run that has ended has no
    /// step still working.
    func testAReviewLeftOpenWhenTheRunWasParkedIsNotStillWorking() {
        let g = reduce(preparation + [
            line("outcome", "declared", "\"result\":\"succeeded_changes\""),
            line("gate", "running"),
            line("gate.scope", "done"),
            line("gate.verify", "running"),
            line("gate.verify", "done"),
            line("gate.review", "running", "\"round\":2,\"max\":3"),
            line("run", "needs-user", "\"disposition\":\"needs-user\""),
        ])
        XCTAssertEqual(g.status("review").state, .waiting, "the review is not still running")
        XCTAssertFalse(g.nodes.values.contains { $0.state.isActive }, "nothing is drawn as working")
        XCTAssertFalse(g.isLive)
        if case .waitingForYou = g.overall {} else { XCTFail("\(g.overall)") }
    }

    /// …and a newer engine closes it itself, with the reason, which reaches the chat's line.
    func testTheReasonAReviewStoppedForIsCarried() {
        let why = "Codex stopped the review: production access is needed"
        let g = reduce(preparation + [
            line("gate", "running"),
            line("gate.review", "running", "\"round\":2,\"max\":3"),
            line("gate.review", "waiting", note: why),
            line("run", "needs-user", "\"disposition\":\"needs-user\"", note: why),
        ])
        XCTAssertEqual(g.status("review").state, .waiting)
        XCTAssertEqual(g.status("review").note, why)
        XCTAssertEqual(g.overall, .waitingForYou(why))
    }

    /// Accepted work closes anything left open as done, not as waiting.
    func testAPassedRunClosesAStepLeftOpen() {
        let g = reduce(preparation + [
            line("gate", "running"),
            line("gate.verify", "running"),
            line("run", "passed", "\"disposition\":\"passed\""),
        ])
        XCTAssertEqual(g.status("verify").state, .done)
        XCTAssertEqual(g.overall, .finished("passed"))
    }

    func testASentBackRunRestartsTheWorkerAndClearsTheGatesAfterIt() {
        let g = reduce(preparation + [
            line("gate", "running"),
            line("gate.scope", "done"),
            line("gate.verify", "running"),
            line("gate.verify", "done"),
            line("gate.review", "running", "\"round\":1,\"max\":3"),
            line("gate.review", "retrying", "\"round\":1,\"max\":3,\"findings\":2"),
        ])
        XCTAssertEqual(g.status("deliver").state, .running)
        XCTAssertNil(g.status("deliver").round, "the review's round is not the worker's")
        XCTAssertEqual(g.status("review").state, .retrying)
        XCTAssertEqual(g.status("review").round, 1)
        XCTAssertEqual(g.status("review").max, 3)
        XCTAssertEqual(g.status("review").findings, 2)
        XCTAssertEqual(g.status("scope").state, .queued, "the next check runs every gate anew")
        XCTAssertEqual(g.status("verify").state, .queued)
        XCTAssertEqual(g.overall, .returned(round: 1, max: 3))

        let second = reduce(preparation + [
            line("gate", "running"),
            line("gate.review", "running", "\"round\":1,\"max\":3"),
            line("gate.review", "retrying", "\"round\":1,\"max\":3,\"findings\":2", note: "sent back"),
            line("gate", "running"),
            line("gate.review", "running", "\"round\":2,\"max\":3"),
        ])
        XCTAssertEqual(second.status("deliver").state, .done)
        XCTAssertEqual(second.status("review").state, .running)
        XCTAssertEqual(second.status("review").round, 2)
        XCTAssertNil(second.status("review").findings, "the findings belonged to the round that ended")
        XCTAssertEqual(second.overall, .checking)
        XCTAssertNil(second.status("review").note, "a note from the round before does not describe this one")
    }

    func testAMissingSkillReturnsOnceThenAsks() {
        let first = reduce(preparation + [
            line("gate", "running"),
            line("gate.skill", "failed", "\"attempt\":1,\"max\":1"),
        ])
        XCTAssertEqual(first.status("skills").state, .failed)
        XCTAssertEqual(first.status("deliver").state, .running)
        XCTAssertEqual(first.overall, .returned(round: 1, max: 1))

        let then = reduce(preparation + [
            line("gate", "running"),
            line("gate.skill", "failed", "\"attempt\":2", note: "decision"),
        ])
        XCTAssertEqual(then.overall, .waitingForYou("decision"))
    }

    func testAQuestionFromTheWorkerWaitsForYou() {
        let g = reduce(preparation + [line("outcome", "declared", "\"result\":\"needs_input\"", note: "which key?")])
        XCTAssertEqual(g.status("deliver").state, .waiting)
        XCTAssertEqual(g.overall, .waitingForYou("which key?"))
        XCTAssertFalse(g.isLive)
    }

    func testWithdrawnMessageCancelsWhatWasRunning() {
        let g = reduce([
            line("pipeline", "running", stagesList),
            line("context", "running", "\"node\":\"context\""),
            line("pipeline", "cancelled"),
        ])
        XCTAssertEqual(g.status("context").state, .cancelled)
        XCTAssertEqual(g.overall, .cancelled)
    }

    func testOtherMessagesAndBrokenLinesAreIgnored() {
        let lines = [line("pipeline", "running", stagesList),
                     line("context", "running", "\"node\":\"context\"", message: "OTHER"),
                     "{\"v\":1,\"stage\":\"context\"",
                     "not json"]
        let events = RunEvent.parse(lines: lines.joined(separator: "\n").split(separator: "\n"))
        XCTAssertEqual(events.count, 2)
        let g = RunReducer.reduce(events: events, messageID: mid, document: peerDoc)
        XCTAssertEqual(g.status("context").state, .queued)
        XCTAssertEqual(RunReducer.latestMessage(in: events, among: [mid, "OTHER"]), "OTHER")
    }

    func testTailDropsTheCutFirstLine() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("run-events-\(UUID().uuidString).jsonl")
        defer { try? FileManager.default.removeItem(at: url) }
        let body = (0..<50).map { line("context", "running", "\"node\":\"context\"", ms: $0) }.joined(separator: "\n") + "\n"
        try body.write(to: url, atomically: true, encoding: .utf8)
        let text = try XCTUnwrap(SupervisorClient.tail(of: url, bytes: 400))
        let events = RunEvent.parse(lines: text.split(separator: "\n"))
        XCTAssertFalse(events.isEmpty)
        XCTAssertTrue(text.hasPrefix("{"), "a fragment of a line is not an event")
        XCTAssertEqual(events.last?.ms, 1_790_000_000_049)
    }
}
