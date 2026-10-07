import XCTest
@testable import Bulava

/// A run in one of his chats seeing and making the product's automations through Bulava
/// (`$IDIR/automation`): made at once and said in that chat, never by an automation's own run, never
/// twice under one name, and only when the words for "when" mean one schedule.
nonisolated final class AutomationDoorTests: XCTestCase {

    private var state: URL!
    private var project: URL!

    override func setUp() async throws {
        let token = UUID().uuidString.lowercased()
        state = FileManager.default.temporaryDirectory.appendingPathComponent("bulava-door-\(token)")
        project = state.appendingPathComponent("Ledger")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let instance = state.appendingPathComponent("instances/\(Slug.forPath(project.path))")
        try FileManager.default.createDirectory(at: instance, withIntermediateDirectories: true)
        for (name, text) in ["project": project.path, "session": "ns-door-\(token.prefix(12))", "run-id": "RUN-DOOR", "started-at": ""] {
            try text.write(to: instance.appendingPathComponent(name), atomically: true, encoding: .utf8)
        }
        setenv("BULAVA_STATE_DIR", state.appendingPathComponent("app").path, 1)
    }

    override func tearDown() async throws {
        unsetenv("BULAVA_STATE_DIR")
        try? FileManager.default.removeItem(at: state)
    }

    @MainActor
    private func ready() async throws -> (AppModel, AutomationDoor, Product, Project, Chat) {
        let model = AppModel()
        await model.client.updatePaths(SupervisorPaths(stateDir: state))
        await model.refresh()
        let folder = model.projects.add(path: project.path)
        let product = model.products.add(name: "Pocket Ledger", resources: [ProductResource(name: "App", projectID: folder.id)])
        let chat = model.conversations.newChat(for: product.id)
        model.conversations.bindSession(ChatSessionBinding(primaryProjectID: folder.id, projectPath: project.path,
                                                           activeRunID: "RUN-DOOR"), to: chat.id)
        let door = AutomationDoor()
        door.model = model
        return (model, door, product, folder, chat)
    }

    @MainActor
    private func ask(_ door: AutomationDoor, _ object: [String: Any]) throws -> [String: Any] {
        let request = state.appendingPathComponent("req-\(UUID().uuidString).json")
        var body = object
        body["project"] = project.path
        try JSONSerialization.data(withJSONObject: body).write(to: request)
        return door.serve(request)
    }

    private let brief = "Every Monday check last week's search queries in Search Console and write one article for the site."

    @MainActor
    func testARunInHisChatMakesAnAutomationHeSeesAtOnce() async throws {
        let (model, door, product, folder, chat) = try await ready()
        let empty = try ask(door, ["op": "list"])
        XCTAssertEqual(empty["ok"] as? Bool, true)
        XCTAssertEqual((empty["automations"] as? [Any])?.count, 0)

        let made = try ask(door, ["op": "create", "name": "Weekly SEO", "when": "weekly mon 09:00", "brief": brief, "mode": "branch"])
        XCTAssertEqual(made["ok"] as? Bool, true, "\(made)")
        let automation = try XCTUnwrap(model.automations.automations.first)
        XCTAssertEqual(automation.name, "Weekly SEO")
        XCTAssertEqual(automation.productID, product.id)
        XCTAssertEqual(automation.projectID, folder.id, "it works in the chat's folder")
        XCTAssertEqual(automation.brief, brief)
        XCTAssertTrue(automation.enabled, "made at his request: on")
        XCTAssertEqual(automation.workMode, .branch)
        XCTAssertEqual(automation.trigger.schedule?.cadence, .weekly(days: [2]))
        XCTAssertEqual(automation.trigger.schedule?.hour, 9)
        XCTAssertTrue(model.conversations.entries(inChat: chat.id).contains { $0.kind == .event && $0.text.contains("Weekly SEO") },
                      "said in the chat it was asked in")
        XCTAssertTrue(model.toasts.contains { $0.key == "automation-made-\(automation.id.uuidString)" && $0.actions.count == 2 },
                      "and in a card, with Open and Turn off")

        let listed = try ask(door, ["op": "list"])
        let first = try XCTUnwrap((listed["automations"] as? [[String: Any]])?.first)
        XCTAssertEqual(first["name"] as? String, "Weekly SEO")
        XCTAssertEqual(first["on"] as? Bool, true)
        XCTAssertEqual(first["mode"] as? String, "branch")

        let twice = try ask(door, ["op": "create", "name": "weekly seo", "when": "daily 08:00", "brief": brief])
        XCTAssertEqual(twice["ok"] as? Bool, false, "never a second one with the same name")
        XCTAssertEqual(model.automations.automations.count, 1)

        let checks = try ask(door, ["op": "create", "name": "Nightly check", "when": "weekdays 23:30 away", "brief": brief, "mode": "check"])
        XCTAssertEqual(checks["ok"] as? Bool, true)
        let nightly = try XCTUnwrap(model.automations.automations.first { $0.name == "Nightly check" })
        XCTAssertEqual(nightly.workMode, .checkOnly)
        XCTAssertEqual(nightly.trigger.schedule?.waitUntilAway, true)
    }

    @MainActor
    func testNothingIsMadeFromBadWordsOrByAnAutomationsOwnRun() async throws {
        let (model, door, product, _, chat) = try await ready()
        for bad: [String: Any] in [
            ["op": "create", "name": "X", "when": "every monday", "brief": brief],
            ["op": "create", "name": "", "when": "daily 09:00", "brief": brief],
            ["op": "create", "name": "X", "when": "daily 09:00", "brief": "  "],
            ["op": "create", "name": "X", "when": "daily 25:00", "brief": brief],
            ["op": "dance"],
        ] {
            XCTAssertEqual(try ask(door, bad)["ok"] as? Bool, false, "\(bad)")
        }
        XCTAssertTrue(model.automations.automations.isEmpty)

        // The same project, but the chat is an automation's own run: it makes none.
        let runChat = model.conversations.newAutomationChat(id: UUID(), for: product.id, runID: UUID(), copyID: UUID(), title: "Run")
        let binding = try XCTUnwrap(model.conversations.chat(id: chat.id)?.session)
        model.conversations.bindSession(ChatSessionBinding(primaryProjectID: nil, projectPath: project.path, activeRunID: "OTHER"), to: chat.id)
        model.conversations.bindSession(binding, to: runChat.id)
        let refused = try ask(door, ["op": "create", "name": "Loop", "when": "hourly 1", "brief": brief])
        XCTAssertEqual(refused["ok"] as? Bool, false, "an automation does not multiply itself")
        XCTAssertTrue((refused["error"] as? String)?.contains("automation's own run") == true, "\(refused)")
        XCTAssertTrue(model.automations.automations.isEmpty)
    }

    func testTheWordsForWhen() {
        let kyiv = TimeZone(identifier: "Europe/Kyiv")!
        XCTAssertEqual(AutomationWhen.parse("manual"), .manual)
        XCTAssertEqual(AutomationWhen.parse("daily 09:05", timeZone: kyiv)?.schedule?.cadence, .daily)
        XCTAssertEqual(AutomationWhen.parse("daily 09:05", timeZone: kyiv)?.schedule?.minute, 5)
        XCTAssertEqual(AutomationWhen.parse("daily 09:05", timeZone: kyiv)?.schedule?.timeZoneID, "Europe/Kyiv")
        XCTAssertEqual(AutomationWhen.parse("Weekdays 18:30")?.schedule?.cadence, .weekdays)
        XCTAssertEqual(AutomationWhen.parse("weekly thu,mon,thu 07:00")?.schedule?.cadence, .weekly(days: [2, 5]))
        XCTAssertEqual(AutomationWhen.parse("monthly 31 23:59")?.schedule?.cadence, .monthly(day: 31))
        XCTAssertEqual(AutomationWhen.parse("hourly 3")?.schedule?.cadence, .hourly(every: 3))
        XCTAssertEqual(AutomationWhen.parse("daily 02:00 away")?.schedule?.waitUntilAway, true)
        for bad in ["", "daily", "daily 9:5", "daily 24:00", "hourly 13", "hourly 0", "weekly funday 09:00",
                    "weekly mon 09:00 extra", "monthly 32 09:00", "manual away", "every day at 9"] {
            XCTAssertNil(AutomationWhen.parse(bad), bad)
        }
    }

    /// A chat Codex answers has no run folder. Its first turn is told what Bulava is, the product and
    /// how to make an automation; the turn carries a word naming the chat and leave to write Bulava's
    /// requests; an automation asked for with that word is made in that chat — while the turn lasts,
    /// and not after it. A later turn in the same thread is not told it all again.
    @MainActor
    func testACodexChatIsToldBulavaAndMakesAnAutomationFromItsTurn() async throws {
        let (model, _, product, _, _) = try await ready()
        let door = model.automationDoor               // the one the app's turns are given words by
        door.attach(model, stateDir: state)
        defer { door.detach() }
        model.settings.chatMode = .codex
        model.settings.claudeStandsInForCodex = false
        let chat = model.conversations.newChat(for: product.id)

        var asked: [CodexTurnRequest] = []
        var release: CheckedContinuation<Void, Never>?
        model.runCodexTurn = { request in
            asked.append(request)
            await withCheckedContinuation { release = $0 }
            return CodexChatRunner.Outcome(threadID: "thread-1", blocks: [], failure: nil, usage: nil, exitCode: 0)
        }
        func turn(_ text: String, number: Int) async throws -> CodexTurnRequest {
            guard case .sent = model.sendDirectMessage(text, productID: product.id, chatID: chat.id) else {
                throw XCTSkip("the message was not sent")
            }
            for _ in 0..<200 where asked.count < number || release == nil { try await Task.sleep(for: .milliseconds(10)) }
            return try XCTUnwrap(asked.count == number ? asked.last : nil)
        }
        func finish() async throws {
            release?.resume(); release = nil
            for _ in 0..<200 where model.sendingChatIDs.contains(chat.id) { try await Task.sleep(for: .milliseconds(10)) }
        }

        let first = try await turn("Щопонеділка перевіряй SEO", number: 1)
        XCTAssertTrue(first.prompt.hasPrefix("<bulava-context>"), first.prompt)
        XCTAssertTrue(first.prompt.contains("## Bulava — где ты работаешь"))
        XCTAssertTrue(first.prompt.contains("этот чат ведёшь ты, Codex"))
        XCTAssertTrue(first.prompt.contains(product.name) && first.prompt.contains(project.path), "the product and its folder")
        XCTAssertTrue(first.prompt.contains("не выдумывай"))
        XCTAssertTrue(first.prompt.contains("Щопонеділка перевіряй SEO"), "and his message after it")
        let requests = state.appendingPathComponent("automation-requests")
        XCTAssertEqual(first.writableRoots, [requests.path], "Codex's sandbox lets it leave a request")
        XCTAssertEqual(first.environment["SUPERVISOR_STATE_DIR"], state.path)
        let word = try XCTUnwrap(first.environment["BULAVA_CHAT_TURN"])

        let made = try ask(door, ["op": "create", "name": "Weekly SEO", "when": "weekly mon 09:00", "brief": brief, "turn": word])
        XCTAssertEqual(made["ok"] as? Bool, true, "\(made)")
        XCTAssertEqual(model.automations.automations.first?.productID, product.id)
        XCTAssertTrue(model.conversations.entries(inChat: chat.id).contains { $0.kind == .event && $0.text.contains("Weekly SEO") },
                      "said in the Codex chat it was asked in")
        XCTAssertEqual((try ask(door, ["op": "list", "turn": "made-up"]))["ok"] as? Bool, false, "a word no turn was given")

        try await finish()
        let late = try ask(door, ["op": "list", "turn": word])
        XCTAssertEqual(late["ok"] as? Bool, false, "the word is good for its turn only")
        XCTAssertNotNil(model.conversations.chat(id: chat.id)?.session?.codexContextDigest)

        let second = try await turn("Дякую", number: 2)
        XCTAssertEqual(second.threadID, "thread-1")
        XCTAssertFalse(second.prompt.contains("<bulava-context>"), "the thread was told already")
        XCTAssertNotEqual(second.environment["BULAVA_CHAT_TURN"], word, "every turn a word of its own")
        try await finish()

        // He says something new about the product: the same thread is told it all again.
        var edited = try XCTUnwrap(model.products.product(id: product.id))
        edited.summary = "Облік витрат для фрилансерів"
        model.products.update(edited)
        let third = try await turn("А тепер?", number: 3)
        XCTAssertEqual(third.threadID, "thread-1")
        XCTAssertTrue(third.prompt.hasPrefix("<bulava-context>") && third.prompt.contains("Облік витрат для фрилансерів"),
                      "a changed context goes in again")
        try await finish()
    }

    /// A run names its run: of two chats that both had the project's session, the one bound to
    /// that run is answered; a run that is not going on is answered by none.
    @MainActor
    func testARunIsAnsweredInTheChatBoundToItsOwnRun() async throws {
        let (model, door, product, folder, chat) = try await ready()
        let instance = try XCTUnwrap(model.snapshot.instances.first)
        let older = model.conversations.newChat(for: product.id)
        model.conversations.bindSession(ChatSessionBinding(primaryProjectID: folder.id, projectPath: project.path,
                                                           claudeSessionID: instance.sessionID, activeRunID: "RUN-OLD"),
                                        to: older.id)
        let made = try ask(door, ["op": "create", "name": "Weekly SEO", "when": "daily 09:00", "brief": brief, "run": "RUN-DOOR"])
        XCTAssertEqual(made["ok"] as? Bool, true, "\(made)")
        XCTAssertTrue(model.conversations.entries(inChat: chat.id).contains { $0.kind == .event && $0.text.contains("Weekly SEO") })
        XCTAssertFalse(model.conversations.entries(inChat: older.id).contains { $0.kind == .event && $0.text.contains("Weekly SEO") },
                       "not the older chat that once had the same session")
        XCTAssertEqual((try ask(door, ["op": "list", "run": "RUN-GONE"]))["ok"] as? Bool, false, "no such run going on")
    }

    /// A run going on with no chat of its own — a night run — whose Claude session an older chat once
    /// had: it names its run, no chat is bound to that run, and nothing is made in the old chat's name.
    @MainActor
    func testARunWithNoChatOfItsOwnMakesNothingInAnOlderChatsName() async throws {
        let (model, door, _, folder, chat) = try await ready()
        // The run carries a Claude session — the one the older chat had.
        let dir = state.appendingPathComponent("instances/\(Slug.forPath(project.path))")
        try "sess-shared".write(to: dir.appendingPathComponent("claude-session-id"), atomically: true, encoding: .utf8)
        await model.refresh()
        let instance = try XCTUnwrap(model.snapshot.instances.first)
        XCTAssertEqual(instance.runID, "RUN-DOOR")
        XCTAssertEqual(instance.sessionID, "sess-shared")
        model.conversations.bindSession(ChatSessionBinding(primaryProjectID: folder.id, projectPath: project.path,
                                                           claudeSessionID: "sess-shared", activeRunID: "RUN-OLD"),
                                        to: chat.id)
        XCTAssertNotNil(model.matchingInstance(for: try XCTUnwrap(model.conversations.chat(id: chat.id)?.session)),
                        "the old chat does match the run through its session")
        let refused = try ask(door, ["op": "create", "name": "Nightly", "when": "daily 02:00", "brief": brief, "run": "RUN-DOOR"])
        XCTAssertEqual(refused["ok"] as? Bool, false, "\(refused)")
        XCTAssertTrue(model.automations.automations.isEmpty)
        XCTAssertFalse(model.conversations.entries(inChat: chat.id).contains { $0.kind == .event && $0.text.contains("Nightly") })
        XCTAssertEqual((try ask(door, ["op": "list", "run": "RUN-DOOR"]))["ok"] as? Bool, false, "nor is it shown the list")
    }

    /// A request left by a command that died long ago is dropped, not acted on; once detached,
    /// Bulava stops saying it is there.
    @MainActor
    func testAnOldRequestIsDroppedAndADetachedDoorFallsSilent() async throws {
        let (model, _, _, _, _) = try await ready()
        let door = model.automationDoor
        door.attach(model, stateDir: state)
        let requests = try XCTUnwrap(door.requestsDirectory)
        let old = requests.appendingPathComponent("1-old.json")
        try JSONSerialization.data(withJSONObject: ["op": "create", "project": project.path, "name": "Ghost",
                                                    "when": "daily 09:00", "brief": brief]).write(to: old)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-600)], ofItemAtPath: old.path)
        for _ in 0..<100 where FileManager.default.fileExists(atPath: old.path) { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: old.path), "dropped")
        XCTAssertFalse(FileManager.default.fileExists(atPath: requests.appendingPathComponent("1-old.done").path), "and not answered")
        XCTAssertTrue(model.automations.automations.isEmpty)

        let service = requests.appendingPathComponent("service.json")
        XCTAssertTrue(FileManager.default.fileExists(atPath: service.path))
        door.detach()
        try await Task.sleep(for: .milliseconds(900))
        XCTAssertFalse(FileManager.default.fileExists(atPath: service.path), "no word after it has gone")
    }

    /// The command is named by its full path — the engine lives under "Application Support" — quoted
    /// for the shell; an engine without it is said to be out of date, not offered.
    @MainActor
    func testTheCodexContextNamesTheCommandItCanRun() async throws {
        let (model, _, product, folder, chat) = try await ready()
        let cli = "/Users/x/Library/Application Support/Bulava/engine/bin/worker-automation.sh"
        let text = model.codexContext(product: product, primary: folder, chatID: chat.id, automationCommand: cli)
        XCTAssertTrue(text.contains("`'\(cli)' list`"), text)
        XCTAssertTrue(text.contains("`'\(cli)' create --name"), text)
        XCTAssertTrue(text.contains("$TMPDIR"), "the brief goes in a temporary file, not the product's folder")
        let none = model.codexContext(product: product, primary: folder, chatID: chat.id, automationCommand: nil)
        XCTAssertFalse(none.contains("create --name"))
        XCTAssertTrue(none.contains("устарел"))
        XCTAssertEqual(AppModel.shellQuoted("it's"), "'it'\\''s'")
    }

    /// Every chat's context says what Bulava is and which of its tools the run has — automations
    /// among them — so "make this run every week" is something any chat knows it can do.
    @MainActor
    func testEveryChatIsToldWhatBulavaIsAndWhatItCanDo() async throws {
        let (model, _, product, folder, chat) = try await ready()
        let files = try XCTUnwrap(model.writeSessionContext(chatID: chat.id, product: product, primary: folder))
        let text = try String(contentsOf: files.context, encoding: .utf8)
        XCTAssertTrue(text.contains("## Bulava — где ты работаешь"), text)
        for tool in ["$IDIR/automation list", "$IDIR/automation create", "$IDIR/decide", "$IDIR/phone-link",
                     "$IDIR/capture", "$IDIR/browser", "$IDIR/history"] {
            XCTAssertTrue(text.contains(tool), "the chat is told about \(tool)")
        }
        XCTAssertTrue(text.contains("не выдумывай"), "and not to make up what it does not know about Bulava")
        XCTAssertTrue(text.contains(product.name), "the product is still there")
    }
}

/// The whole way, for real: a message in a chat Codex answers, a real `codex exec` turn in its
/// sandbox, this checkout's `automation` command, Bulava's door — and an automation in his list.
/// Off unless asked for (`TEST_RUNNER_BULAVA_LIVE_CODEX=1`): it spends a real Codex turn.
///
/// Bulava's state lives outside the temporary folders Codex's sandbox may always write to, so the
/// request only arrives because the turn was given that folder; and the turn's word, used after the
/// turn, is refused through the same command.
nonisolated final class AutomationDoorLiveCodexTests: XCTestCase {

    @MainActor
    func testACodexChatMakesAnAutomationForRealThroughBulava() async throws {
        guard ProcessInfo.processInfo.environment["BULAVA_LIVE_CODEX"] == "1" else { throw XCTSkip("a real Codex turn not requested") }
        let checkout = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let cli = checkout.appendingPathComponent("engine/bin/worker-automation.sh").path
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: cli))

        let token = UUID().uuidString.lowercased().prefix(12)
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent("bulava-live-\(token)")
        let liveState = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Caches/bulava-live-\(token)/state")
        XCTAssertFalse(liveState.path.hasPrefix(FileManager.default.temporaryDirectory.resolvingSymlinksInPath().path))
        let project = temp.appendingPathComponent("Ledger")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: liveState, withIntermediateDirectories: true)
        try "# Pocket Ledger\nA ledger for freelancers.\n".write(to: project.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
        setenv("BULAVA_STATE_DIR", temp.appendingPathComponent("app").path, 1)
        defer {
            unsetenv("BULAVA_STATE_DIR")
            try? FileManager.default.removeItem(at: temp)
            try? FileManager.default.removeItem(at: liveState.deletingLastPathComponent())
        }

        let model = AppModel()
        await model.client.updatePaths(SupervisorPaths(stateDir: temp.appendingPathComponent("engine")))
        let folder = model.projects.add(path: project.path)
        let product = model.products.add(name: "Pocket Ledger", resources: [ProductResource(name: "Ledger", projectID: folder.id)])
        model.automationDoor.attach(model, stateDir: liveState)
        defer { model.automationDoor.detach() }
        model.automationCommand = { cli }
        model.settings.chatMode = .codex
        model.settings.claudeStandsInForCodex = false
        let chat = model.conversations.newChat(for: product.id)
        model.updateRunChoices(for: chat.id) { $0.codexEffort = .low }

        let real = model.runCodexTurn
        var asked: CodexTurnRequest?
        var outcome: CodexChatRunner.Outcome?
        model.runCodexTurn = { request in
            asked = request
            let result = await real(request)
            outcome = result
            return result
        }

        let message = "Зроби автоматизацію «Перевірка README»: щопонеділка о 09:00 перевіряй, що README.md у цій папці "
            + "не порожній, і коротко звітуй. Лише перевірка, нічого не змінюй. Не став уточнень — просто створи."
        guard case .sent = model.sendDirectMessage(message, productID: product.id, chatID: chat.id) else {
            return XCTFail("the message was not sent")
        }
        for _ in 0..<1200 where outcome == nil { try await Task.sleep(for: .milliseconds(500)) }
        let result = try XCTUnwrap(outcome, "the Codex turn did not end within ten minutes")
        XCTAssertNil(result.failure, "\(result.failure ?? "")")
        let request = try XCTUnwrap(asked)
        XCTAssertTrue(request.prompt.hasPrefix("<bulava-context>") && request.prompt.contains("'\(cli)' create"))
        XCTAssertEqual(request.writableRoots, [liveState.appendingPathComponent("automation-requests").path])

        let automation = try XCTUnwrap(model.automations.automations.first { $0.productID == product.id },
                                       "no automation was made; Codex answered: \(result.blocks)")
        print("LIVE_CODEX made: \(automation.name) — \(AutomationPresentation.triggerLine(automation.trigger)) — \(automation.checksOnly ? "checks only" : "on a branch")")
        XCTAssertTrue(automation.name.localizedCaseInsensitiveContains("README"), automation.name)
        XCTAssertEqual(automation.trigger.schedule?.cadence, .weekly(days: [2]))
        XCTAssertEqual(automation.trigger.schedule?.hour, 9)
        XCTAssertEqual(automation.projectID, folder.id)
        XCTAssertTrue(automation.enabled)
        XCTAssertTrue(model.conversations.entries(inChat: chat.id).contains { $0.kind == .event && $0.text.contains(automation.name) },
                      "said in the chat it was asked in")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: project.path).filter { !$0.hasPrefix(".") }, ["README.md"],
                       "the product's folder untouched")

        // The turn is over: its word, through the same command, is refused.
        let word = try XCTUnwrap(request.environment["BULAVA_CHAT_TURN"])
        let late = try await Self.run(cli, ["list"], in: project,
                                      environment: ["BULAVA_CHAT_TURN": word, "SUPERVISOR_STATE_DIR": liveState.path])
        XCTAssertEqual(late.status, 1, late.output)
        XCTAssertTrue(late.output.contains("turn") || late.output.contains("хід") || late.output.contains("ход"), late.output)
        print("LIVE_CODEX late word: exit \(late.status) — \(late.output.trimmingCharacters(in: .whitespacesAndNewlines))")
    }

    private static func run(_ tool: String, _ arguments: [String], in folder: URL,
                            environment: [String: String]) async throws -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [tool] + arguments
        process.currentDirectoryURL = folder
        var env = ProcessInfo.processInfo.environment
        env.merge(environment) { _, new in new }
        process.environment = env
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            DispatchQueue.global().async { process.waitUntilExit(); done.resume() }
        }
        let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        return (process.terminationStatus, output)
    }
}
