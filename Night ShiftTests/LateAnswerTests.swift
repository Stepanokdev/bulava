import XCTest
@testable import Bulava

/// An answer that comes after the run stopped waiting for it reaches the run anyway — including
/// one given in the very moment the deadline passes.
///
/// The engine's hook holds a question for the director up to its deadline, then takes the safe
/// default — or, for what only he may decide, leaves that part undone — and removes its question.
/// An answer given after that was written to `answer.json`, which nothing read, and so was one
/// written just before it, between the hook's last look and its deadline, while the app had already
/// said "sent". The hook now claims an answer by renaming it and leaves a receipt naming it; the
/// app waits for the receipt and otherwise takes its file back and sends the answer to the run's
/// chat as his message.
nonisolated final class LateAnswerTests: XCTestCase {

    private var state: URL!
    private var project: String!
    private var instanceDir: URL!

    override func setUp() async throws {
        let token = UUID().uuidString.lowercased()
        state = FileManager.default.temporaryDirectory.appendingPathComponent("bulava-late-answer-\(token)")
        project = state.appendingPathComponent("project").path
        try FileManager.default.createDirectory(atPath: project, withIntermediateDirectories: true)
        instanceDir = state.appendingPathComponent("instances/\(Slug.forPath(project))")
        try FileManager.default.createDirectory(at: instanceDir, withIntermediateDirectories: true)
        let files = ["project": project!, "session": "ns-late-\(token.prefix(12))", "run-id": "RUN-LATE", "started-at": ""]
        for (name, text) in files {
            try text.write(to: instanceDir.appendingPathComponent(name), atomically: true, encoding: .utf8)
        }
        try askAgain()
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: state)
    }

    /// The hook's question, as answer-question.sh leaves it while it waits.
    private func askAgain() throws {
        let ask: [String: Any] = [
            "asked_at": Date().timeIntervalSince1970, "headline": "Which export format?", "reason_code": "product_fork",
            "questions": [["question": "Which export format?", "options": ["CSV", "JSON"]]],
        ]
        try JSONSerialization.data(withJSONObject: ask).write(to: instanceDir.appendingPathComponent("ask-user.json"))
    }

    private var answerFile: URL { instanceDir.appendingPathComponent("answer.json") }
    private var askFile: URL { instanceDir.appendingPathComponent("ask-user.json") }

    /// What the hook does with an answer it sees in time (answer-question.sh): claim it by renaming,
    /// leave a receipt with its id, and end the question.
    private func hookTakesTheNextAnswer() -> Task<Void, Never> {
        let dir: URL = instanceDir
        return Task.detached {
            let fm = FileManager.default
            let file = dir.appendingPathComponent("answer.json")
            for _ in 0..<200 {
                let claimed = dir.appendingPathComponent("answer.json.taken.test")
                if fm.fileExists(atPath: file.path), (try? fm.moveItem(at: file, to: claimed)) != nil {
                    let obj = (try? Data(contentsOf: claimed)).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
                    let receipt = try? JSONSerialization.data(withJSONObject: ["id": obj?["id"] as? String ?? "", "taken_at": 1])
                    try? receipt?.write(to: dir.appendingPathComponent("answer-taken.json"))
                    try? fm.removeItem(at: claimed)
                    try? fm.removeItem(at: dir.appendingPathComponent("ask-user.json"))
                    return
                }
                try? await Task.sleep(for: .milliseconds(20))
            }
        }
    }

    /// The deadline passing while the answer is on its way: the hook gives up and removes its
    /// question, and never looks at the file again.
    private func deadlinePassesAsTheAnswerArrives() -> Task<Void, Never> {
        let dir: URL = instanceDir
        return Task.detached {
            let fm = FileManager.default
            for _ in 0..<200 {
                if fm.fileExists(atPath: dir.appendingPathComponent("answer.json").path) {
                    try? fm.removeItem(at: dir.appendingPathComponent("ask-user.json"))
                    return
                }
                try? await Task.sleep(for: .milliseconds(5))
            }
        }
    }

    @MainActor
    private func ready() async throws -> (AppModel, SupervisorInstance, Chat) {
        let appData = state.appendingPathComponent("app")
        try FileManager.default.createDirectory(at: appData, withIntermediateDirectories: true)
        setenv("BULAVA_STATE_DIR", appData.path, 1)
        let model = AppModel()
        await model.client.updatePaths(SupervisorPaths(stateDir: state))
        await model.client.setAnswerPickup(.milliseconds(600))
        await model.refresh()
        let inst = try XCTUnwrap(model.snapshot.instances.first { $0.pendingQuestion != nil }, "the hook's question is read")
        XCTAssertEqual(inst.pendingQuestion?.source, .hook)
        // The run's chat. Its product has no folder, so a message to it stops before any engine runs.
        let product = model.products.add(name: "Late")
        let chat = model.conversations.newChat(for: product.id)
        model.conversations.bindSession(ChatSessionBinding(primaryProjectID: nil, projectPath: project,
                                                           activeRunID: "RUN-LATE"), to: chat.id)
        return (model, inst, chat)
    }

    @MainActor
    private func lateMessage(in chat: Chat, of model: AppModel) async throws -> ConversationEntry? {
        for _ in 0..<80 {
            if let late = model.conversations.entries(inChat: chat.id).first(where: { $0.kind == .user }) { return late }
            try await Task.sleep(for: .milliseconds(25))
        }
        return nil
    }

    @MainActor
    func testAnAnswerTheHookTakesInTimeIsNotAlsoSentToTheChat() async throws {
        let (model, inst, chat) = try await ready()
        let hook = hookTakesTheNextAnswer()
        model.answerQuestion(inst, "CSV")
        await hook.value
        try await Task.sleep(for: .milliseconds(1200))    // past the app's wait for a receipt
        XCTAssertFalse(model.conversations.entries(inChat: chat.id).contains { $0.kind == .user },
                       "the answer the hook took is not also sent to the chat")
        let receipt = try JSONSerialization.jsonObject(
            with: Data(contentsOf: instanceDir.appendingPathComponent("answer-taken.json"))) as? [String: Any]
        XCTAssertNotNil(receipt?["id"] as? String, "the hook's receipt names the answer it took")
        try askAgain()
        let direct = hookTakesTheNextAnswer()
        let outcome = await model.client.answerUserQuestion(slug: inst.slug, answer: "JSON")
        await direct.value
        XCTAssertEqual(outcome, .taken)
    }

    @MainActor
    func testAnAnswerCaughtByTheDeadlineGoesToTheRunsChat() async throws {
        let (model, inst, chat) = try await ready()
        let deadline = deadlinePassesAsTheAnswerArrives()
        model.answerQuestion(inst, "JSON")
        await deadline.value
        let arrived = try await lateMessage(in: chat, of: model)
        let message = try XCTUnwrap(arrived, "the answer that lost the race with the deadline reaches the chat")
        XCTAssertTrue(message.text.contains("JSON"), message.text)
        XCTAssertTrue(message.text.contains("Which export format?"), "and says which question it answers")
        XCTAssertFalse(FileManager.default.fileExists(atPath: answerFile.path),
                       "the app took its file back: nothing waits there for a question that is over")
    }

    @MainActor
    func testAnAnswerAfterTheDeadlineGoesToTheRunsChat() async throws {
        let (model, inst, chat) = try await ready()
        try FileManager.default.removeItem(at: askFile)     // the hook already took its default
        model.answerQuestion(inst, "JSON")
        let arrived = try await lateMessage(in: chat, of: model)
        let message = try XCTUnwrap(arrived)
        XCTAssertTrue(message.text.contains("JSON"), message.text)
        XCTAssertFalse(FileManager.default.fileExists(atPath: answerFile.path), "nothing is written where nobody reads it")
    }

    @MainActor
    func testAnAnswerNobodyPicksUpIsTakenBackAndSentToTheChat() async throws {
        // The question is still on disk, but the hook that wrote it is gone and never looks again.
        let (model, inst, chat) = try await ready()
        model.answerQuestion(inst, "CSV")
        let arrived = try await lateMessage(in: chat, of: model)
        let message = try XCTUnwrap(arrived, "an answer nobody took is not lost")
        XCTAssertTrue(message.text.contains("CSV"), message.text)
        XCTAssertFalse(FileManager.default.fileExists(atPath: answerFile.path))
        try askAgain()   // keep the folder looking the same for the next test's reading
    }
}
