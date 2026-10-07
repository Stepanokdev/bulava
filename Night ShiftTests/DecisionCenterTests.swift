import XCTest
@testable import Bulava

/// A report that asks the director to decide: what the agent may ask, and what becomes of his answer.
///
/// The answer is his message in the report's chat, the same as anything he types. It answers the
/// questions as they are now, never a version that changed under him; it never silently replaces an
/// answer another device sent meanwhile; and the same answer sent twice — a phone that never heard
/// the reply — is one message, not two.
nonisolated final class DecisionCenterTests: XCTestCase {

    private var state: URL!
    private var project: URL!
    private var report: URL!
    private var store: URL!

    override func setUp() async throws {
        let token = UUID().uuidString.lowercased()
        state = FileManager.default.temporaryDirectory.appendingPathComponent("bulava-decisions-\(token)")
        project = state.appendingPathComponent("project")
        let folder = project.appendingPathComponent("artifacts/plan")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        report = folder.appendingPathComponent("index.html")
        try "<h1>Plan</h1>".write(to: report, atomically: true, encoding: .utf8)
        try writeQuestions(Self.questions)
        store = state.appendingPathComponent("store")
        let instanceDir = state.appendingPathComponent("instances/\(Slug.forPath(project.path))")
        try FileManager.default.createDirectory(at: instanceDir, withIntermediateDirectories: true)
        let files = ["project": project.path, "session": "ns-decide-\(token.prefix(12))", "run-id": "RUN-DECIDE", "started-at": ""]
        for (name, text) in files {
            try text.write(to: instanceDir.appendingPathComponent(name), atomically: true, encoding: .utf8)
        }
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: state)
    }

    nonisolated(unsafe) private static let questions: [String: Any] = [
        "title": "What to build next",
        "items": [
            ["id": "leak", "title": "Close the password leak", "detail": "Workers inherit the browser.", "recommended": "Take it"],
            ["id": "browser", "title": "A browser of Bulava's own", "options": ["Now", "After the release", "Never"], "comment": true],
            ["id": "keychain", "title": "Keep logins in the Keychain", "comment": false],
        ],
    ]

    private func writeQuestions(_ obj: [String: Any]) throws {
        let data = try JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys])
        try data.write(to: report.deletingLastPathComponent().appendingPathComponent("decisions.json"))
    }

    @MainActor
    private func ready() async throws -> (AppModel, DecisionCenter, Chat) {
        let appData = state.appendingPathComponent("app")
        try FileManager.default.createDirectory(at: appData, withIntermediateDirectories: true)
        setenv("BULAVA_STATE_DIR", appData.path, 1)
        let model = AppModel()
        await model.client.updatePaths(SupervisorPaths(stateDir: state))
        await model.refresh()
        // A product with no folder: a message to its chat stops before any engine runs.
        let product = model.products.add(name: "Decide")
        let chat = model.conversations.newChat(for: product.id)
        model.conversations.bindSession(ChatSessionBinding(primaryProjectID: nil, projectPath: project.path,
                                                           activeRunID: "RUN-DECIDE"), to: chat.id)
        let center = DecisionCenter(folder: store)
        center.model = model
        return (model, center, chat)
    }

    @MainActor
    private func messages(in chat: Chat, of model: AppModel) -> [ConversationEntry] {
        model.conversations.entries(inChat: chat.id).filter { $0.kind == .user }
    }

    // MARK: The questions

    func testTheAgentsFileIsReadAndCheckedAndUnsoundOnesAreRefusedWithAReason() throws {
        let set = try XCTUnwrap(DecisionSet.load(besides: report))
        XCTAssertEqual(set.title, "What to build next")
        XCTAssertEqual(set.items.map(\.id), ["leak", "browser", "keychain"])
        XCTAssertEqual(set.items[0].options, DecisionSet.defaultOptions, "no options of its own: take it, later, no")
        XCTAssertEqual(set.items[0].recommended, DecisionSet.defaultOptions[0],
                       "advice named in English is found among the default options, whatever his language")
        XCTAssertFalse(set.items[2].comment)

        func refusal(_ items: [[String: Any]]) -> String? {
            let data = try? JSONSerialization.data(withJSONObject: ["items": items])
            if case .failure(let r) = DecisionSet.parse(data ?? Data()) { return r.message }
            return nil
        }
        XCTAssertNotNil(refusal([]), "nothing to decide")
        XCTAssertNotNil(refusal([["id": "a", "title": "A"], ["id": "a", "title": "B"]]), "one id twice")
        XCTAssertNotNil(refusal([["id": "a b", "title": "A"]]), "an id that is not a plain name")
        XCTAssertNotNil(refusal([["id": "a", "title": "A", "options": ["Only one"]]]), "a single option is not a choice")
        XCTAssertNotNil(refusal([["id": "a", "title": "A", "recommended": "Maybe"]]), "advice that is none of the options")
        XCTAssertNil(refusal([["id": "a", "title": "A"]]))
    }

    func testAChangedFileIsANewRevision() throws {
        let before = try XCTUnwrap(DecisionSet.load(besides: report)).revision
        var changed = Self.questions
        changed["title"] = "What to build next, again"
        try writeQuestions(changed)
        XCTAssertNotEqual(try XCTUnwrap(DecisionSet.load(besides: report)).revision, before)
    }

    // MARK: Answering

    @MainActor
    func testAnAnswerBecomesHisMessageInTheReportsChat() async throws {
        let (model, center, chat) = try await ready()
        center.publish(report, to: chat.id)
        XCTAssertTrue(model.conversations.chat(id: chat.id)?.session?.reportPaths.contains(report.path) == true,
                      "the report is the chat's report — on the Mac and on the phone")
        let set = try XCTUnwrap(DecisionSet.load(besides: report))
        let answers = DecisionAnswers(choices: ["leak": "Take it", "browser": "After the release"],
                                      comments: ["browser": "headless when no login is needed"],
                                      general: "Start with the leak.")
        let sent = center.submit(report: report, answers: answers, revision: set.revision, basedOn: nil,
                                 submissionID: UUID(), device: "mac")
        guard case .success(let submission) = sent else { return XCTFail("\(sent)") }
        let message = try XCTUnwrap(messages(in: chat, of: model).first)
        XCTAssertEqual(message.id, submission.id, "the message is the submission: found again by its id")
        XCTAssertTrue(message.text.contains("What to build next"))
        XCTAssertTrue(message.text.contains("1. Close the password leak — Take it"), message.text)
        XCTAssertTrue(message.text.contains("2. A browser of Bulava's own — After the release"), message.text)
        XCTAssertTrue(message.text.contains("headless when no login is needed"))
        XCTAssertTrue(message.text.contains("3. Keep logins in the Keychain — not decided"),
                      "what he left open is said to be open, so nothing is started on it")
        XCTAssertTrue(message.text.contains("Start with the leak."))
        XCTAssertEqual(center.record(for: report).latest?.id, submission.id)
        XCTAssertTrue(center.record(for: report).draft.isEmpty, "what was sent is no longer a draft")
    }

    @MainActor
    func testTheSameAnswerSentTwiceIsOneMessage() async throws {
        // The phone sent, the reply was lost on the way, the phone sends the same thing again.
        let (model, center, chat) = try await ready()
        center.publish(report, to: chat.id)
        let set = try XCTUnwrap(DecisionSet.load(besides: report))
        let id = UUID()
        let answers = DecisionAnswers(choices: ["leak": "Take it"])
        let first = center.submit(report: report, answers: answers, revision: set.revision, basedOn: nil,
                                  submissionID: id, device: "phone-1")
        let again = center.submit(report: report, answers: answers, revision: set.revision, basedOn: nil,
                                  submissionID: id, device: "phone-1")
        XCTAssertEqual(try first.get(), try again.get(), "the second send is answered with what the first recorded")
        XCTAssertEqual(messages(in: chat, of: model).count, 1, "and writes nothing new")
        XCTAssertEqual(center.record(for: report).submissions.count, 1)
    }

    @MainActor
    func testAnAnswerToQuestionsThatChangedMeanwhileIsRefused() async throws {
        let (model, center, chat) = try await ready()
        center.publish(report, to: chat.id)
        let seen = try XCTUnwrap(DecisionSet.load(besides: report)).revision
        var changed = Self.questions
        changed["items"] = [["id": "leak", "title": "Close the password leak, and rotate the keys"]]
        try writeQuestions(changed)
        let sent = center.submit(report: report, answers: DecisionAnswers(choices: ["leak": "Take it"]),
                                 revision: seen, basedOn: nil, submissionID: UUID(), device: "mac")
        XCTAssertEqual(sent.failure?.code, .stale)
        XCTAssertTrue(messages(in: chat, of: model).isEmpty, "an answer to questions he did not see is not sent")
    }

    @MainActor
    func testAnAnswerThatMissedAnotherDevicesAnswerIsRefusedThenSentAsACorrection() async throws {
        let (model, center, chat) = try await ready()
        center.publish(report, to: chat.id)
        let set = try XCTUnwrap(DecisionSet.load(besides: report))
        let fromPhone = try center.submit(report: report, answers: DecisionAnswers(choices: ["leak": "Take it"]),
                                          revision: set.revision, basedOn: nil, submissionID: UUID(), device: "phone-1").get()
        // The Mac had the report open since before the phone answered.
        let stale = center.submit(report: report, answers: DecisionAnswers(choices: ["leak": "No"]),
                                  revision: set.revision, basedOn: nil, submissionID: UUID(), device: "mac")
        XCTAssertEqual(stale.failure?.code, .conflict, "the phone's answer is shown first, not overwritten")
        XCTAssertEqual(messages(in: chat, of: model).count, 1)

        let corrected = try center.submit(report: report, answers: DecisionAnswers(choices: ["leak": "No"]),
                                          revision: set.revision, basedOn: fromPhone.id, submissionID: UUID(), device: "mac").get()
        let sent = messages(in: chat, of: model)
        XCTAssertEqual(sent.count, 2)
        XCTAssertEqual(sent.last?.id, corrected.id)
        XCTAssertTrue(sent.last?.text.contains("Corrected decisions") == true,
                      "the agent is told this one replaces the earlier answer: \(sent.last?.text ?? "")")
        XCTAssertEqual(center.record(for: report).latest?.basedOn, fromPhone.id)
    }

    /// The Mac's panel, as it works: it remembers the answer he had in front of him. One sent from
    /// the phone while the panel was open is shown, Send is off until he has seen it, and only then
    /// does his draft go — as a correction of that answer, not silently over it.
    @MainActor
    func testThePanelNeverTurnsHisDraftIntoACorrectionOfAnAnswerHeHasNotSeen() async throws {
        let (model, center, chat) = try await ready()
        center.publish(report, to: chat.id)
        let set = try XCTUnwrap(DecisionSet.load(besides: report))
        var review = DecisionReview()
        review.open(center.record(for: report))          // the panel opens; nothing sent yet
        let draft = DecisionAnswers(choices: ["leak": "No"], general: "from the Mac")
        XCTAssertTrue(review.canSend(draft, in: center.record(for: report)))

        // The phone answers while the panel is open.
        let phone = try center.submit(report: report, answers: DecisionAnswers(choices: ["leak": "Take it"]),
                                      revision: set.revision, basedOn: nil, submissionID: UUID(), device: "phone-1").get()
        XCTAssertEqual(review.unseen(in: center.record(for: report))?.id, phone.id, "the panel shows the phone's answer")
        XCTAssertFalse(review.canSend(draft, in: center.record(for: report)), "and Send is off until he has seen it")
        let refused = center.send(from: &review, report: report, answers: draft, revision: set.revision)
        XCTAssertEqual(refused.failure?.code, .conflict, "the panel's send is refused, not made a correction behind his back")
        XCTAssertEqual(messages(in: chat, of: model).count, 1)

        review.acknowledge(center.record(for: report))      // "Seen"
        XCTAssertEqual(review.corrected(in: center.record(for: report))?.id, phone.id)
        let sent = try center.send(from: &review, report: report, answers: draft, revision: set.revision).get()
        XCTAssertEqual(sent.basedOn, phone.id, "it corrects the answer he read")
        XCTAssertTrue(messages(in: chat, of: model).last?.text.contains("Corrected decisions") == true)
        XCTAssertNil(review.unseen(in: center.record(for: report)), "his own answer is one he has seen")
        XCTAssertEqual(review.corrected(in: center.record(for: report))?.id, sent.id, "the next one corrects his own")

        // A panel opened after an answer came sees it from the start.
        var later = DecisionReview()
        later.open(center.record(for: report))
        XCTAssertNil(later.unseen(in: center.record(for: report)))
        XCTAssertEqual(later.seen, sent.id)
    }

    @MainActor
    func testAChoiceTheReportDoesNotOfferIsRefused() async throws {
        let (model, center, chat) = try await ready()
        center.publish(report, to: chat.id)
        let set = try XCTUnwrap(DecisionSet.load(besides: report))
        for answers in [DecisionAnswers(choices: ["leak": "Delete everything"]),
                        DecisionAnswers(choices: ["nope": "Take it"]),
                        DecisionAnswers(comments: ["nope": "a comment on nothing"]),
                        DecisionAnswers()] {
            let sent = center.submit(report: report, answers: answers, revision: set.revision, basedOn: nil,
                                     submissionID: UUID(), device: "phone-1")
            XCTAssertNotNil(sent.failure, "\(answers)")
        }
        XCTAssertTrue(messages(in: chat, of: model).isEmpty)
    }

    @MainActor
    func testWhatIsTickedSurvivesAQuitAndWhatWasSentToo() async throws {
        let (_, center, chat) = try await ready()
        center.publish(report, to: chat.id)
        center.saveDraft(DecisionAnswers(choices: ["browser": "Now"], general: "half way"), for: report)
        let reopened = DecisionCenter(folder: store)
        XCTAssertEqual(reopened.record(for: report).draft.choices, ["browser": "Now"])
        XCTAssertEqual(reopened.record(for: report).draft.general, "half way")
        XCTAssertEqual(reopened.record(for: report).chatID, chat.id, "and which chat the report answers to")
    }

    // MARK: The agent's side (`$IDIR/decide`)

    @MainActor
    func testAnAgentPutsItsReportIntoTheChatOfItsRun() async throws {
        let (model, center, chat) = try await ready()
        func ask(_ obj: [String: Any]) throws -> [String: Any] {
            let request = state.appendingPathComponent("request-\(UUID().uuidString).json")
            try JSONSerialization.data(withJSONObject: obj).write(to: request)
            return center.serve(request)
        }
        let answer = try ask(["path": "artifacts/plan/index.html", "project": project.path])
        XCTAssertEqual(answer["ok"] as? Bool, true, "\(answer)")
        XCTAssertEqual(answer["chat"] as? String, chat.title)
        XCTAssertTrue(model.conversations.chat(id: chat.id)?.session?.reportPaths.contains(report.path) == true)

        let outside = try ask(["path": "../../etc/hosts", "project": project.path])
        XCTAssertEqual(outside["ok"] as? Bool, false, "nothing outside its project")

        try "notes".write(to: project.appendingPathComponent("notes.md"), atomically: true, encoding: .utf8)
        let bare = try ask(["path": "notes.md", "project": project.path])
        XCTAssertEqual(bare["ok"] as? Bool, false, "a report with no questions beside it is not a decision report")

        // A note works too: it is made into a page next to it.
        let folder = project.appendingPathComponent("artifacts/note")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try "# Options\n\n- one\n- two".write(to: folder.appendingPathComponent("plan.md"), atomically: true, encoding: .utf8)
        try JSONSerialization.data(withJSONObject: ["items": [["id": "a", "title": "Pick one"]]])
            .write(to: folder.appendingPathComponent("decisions.json"))
        let note = try ask(["path": "artifacts/note/plan.md", "project": project.path])
        XCTAssertEqual(note["ok"] as? Bool, true, "\(note)")
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.appendingPathComponent("plan.html").path))
    }
}

private extension Result {
    var failure: Failure? { if case .failure(let f) = self { return f } else { return nil } }
}
