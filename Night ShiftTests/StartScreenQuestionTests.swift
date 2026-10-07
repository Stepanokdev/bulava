import XCTest
@testable import Bulava

/// A screen Claude asks on while a chat's run is starting reaches that chat, and the answer reaches
/// the screen.
///
/// 5 Oct: a start sat on "Allow external CLAUDE.md file imports?" in a pane nobody could see, and was
/// rolled back after twelve seconds. The engine now waits for an answer and says so in the run's
/// folder (`screen-wait.json`); the chat being started is bound to no run until the start returns, so
/// these pin the way the question still gets to it — and the way its answer gets back, as keys, to
/// the very session that is waiting.
nonisolated final class StartScreenQuestionTests: XCTestCase {

    private var state: URL!
    private var project: String!
    private var session: String!
    private var received: URL!

    override func setUp() async throws {
        let token = UUID().uuidString.lowercased()
        state = FileManager.default.temporaryDirectory.appendingPathComponent("bulava-start-screen-\(token)")
        project = state.appendingPathComponent("project").path
        session = "ns-start-\(token.prefix(12))"
        received = state.appendingPathComponent("received.bin")
        try FileManager.default.createDirectory(atPath: project, withIntermediateDirectories: true)

        // The run's folder as the engine leaves it while it waits on the screen.
        let dir = state.appendingPathComponent("instances/\(Slug.forPath(project))")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let files = [
            "project": project!, "session": session!, "run-id": "RUN-SCREEN", "started-at": "",
            "screen-wait.json": #"{"at":\#(Int(Date().timeIntervalSince1970)),"stage":"start"}"#,
        ]
        for (name, text) in files {
            try text.write(to: dir.appendingPathComponent(name), atomically: true, encoding: .utf8)
        }

        // …and the worker's pane: the screen from the report, waiting for its keys.
        let screen = state.appendingPathComponent("screen.txt")
        try TerminalQuestionParserTests.externalImports.write(to: screen, atomically: true, encoding: .utf8)
        let script = state.appendingPathComponent("screen.zsh")
        try """
        #!/bin/zsh
        cat "$1"
        stty raw -echo
        dd bs=1 count=4 of="$2" 2>/dev/null
        stty sane
        sleep 60
        """.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        _ = await Shell.run("tmux new-session -d -s \"$1\" -x 160 -y 40 \"exec /bin/zsh $2 $3 $4\"",
                            args: [session, script.path, screen.path, received.path])
    }

    override func tearDown() async throws {
        _ = await Shell.run("tmux kill-session -t \"$1\" 2>/dev/null || true", args: [session])
        try? FileManager.default.removeItem(at: state)
    }

    private func waitingInstance(_ client: SupervisorClient) async throws -> SupervisorInstance {
        for _ in 0..<40 {
            if let inst = await client.snapshot().instances.first, inst.pendingQuestion != nil { return inst }
            try await Task.sleep(for: .milliseconds(50))
        }
        let last = await client.snapshot()
        return try XCTUnwrap(last.instances.first)
    }

    func testTheRunsFolderAndItsPaneMakeAQuestion() async throws {
        let client = SupervisorClient(paths: SupervisorPaths(stateDir: state))
        let inst = try await waitingInstance(client)
        XCTAssertNotNil(inst.screenWaitSince, "the engine's marker is read")
        let pending = try XCTUnwrap(inst.pendingQuestion,
                                    "and the pane is read for it, though Claude has not reported itself waiting")
        XCTAssertEqual(pending.questions.first?.options,
                       ["No, disable external imports", "Yes, allow external imports"])
    }

    /// The phone's answer to a screen that has moved on is refused with the reason, and the chat is
    /// not told it was answered. 6 Oct: four answers from the phone, each shown as a sent message,
    /// none of them a keypress on the dialog.
    @MainActor
    func testAPhoneAnswerTheScreenRefusedIsReportedAndNotWrittenAsSent() async throws {
        // The same run, but its pane moves on to another dialog before the answer arrives.
        _ = await Shell.run("tmux kill-session -t \"$1\" 2>/dev/null || true", args: [session])
        let first = state.appendingPathComponent("first.txt")
        let second = state.appendingPathComponent("second.txt")
        try TerminalQuestionParserTests.externalImports.write(to: first, atomically: true, encoding: .utf8)
        try """
        ────────────────────────────────────────────────────────
         Bash command
        ╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌
         rm -rf build
        ╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌
         Do you want to proceed?
         ❯ 1. Yes
           2. No
         Esc to cancel · Tab to amend
        """.write(to: second, atomically: true, encoding: .utf8)
        let script = state.appendingPathComponent("moving.zsh")
        try """
        #!/bin/zsh
        cat "$1"
        sleep 1.5
        print -n '\\033[2J\\033[H'
        cat "$2"
        stty raw -echo
        dd bs=1 count=4 of="$3" 2>/dev/null
        stty sane
        sleep 60
        """.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        _ = await Shell.run("tmux new-session -d -s \"$1\" -x 160 -y 40 \"exec /bin/zsh $2 $3 $4 $5\"",
                            args: [session, script.path, first.path, second.path, received.path])

        let appData = state.appendingPathComponent("app")
        try FileManager.default.createDirectory(at: appData, withIntermediateDirectories: true)
        setenv("BULAVA_STATE_DIR", appData.path, 1)
        let model = AppModel()
        await model.client.updatePaths(SupervisorPaths(stateDir: state))
        _ = try await waitingInstance(model.client)
        await model.refresh()
        let chat = model.conversations.currentChat(for: UUID())
        model.startingChats[chat.id] = project
        model.syncDirectChats()
        let card = try XCTUnwrap(model.conversations.entries(inChat: chat.id).last { $0.kind == .question })

        // The pane moves on to the other dialog; the card still holds the first.
        var moved = false
        for _ in 0..<60 where !moved {
            try await Task.sleep(for: .milliseconds(50))
            moved = await model.client.capturePane(session: session, lines: 80).contains("rm -rf build")
        }
        XCTAssertTrue(moved)

        let refused = await model.answerUnboundQuestionWaiting(entry: card, text: "Yes, allow external imports")
        XCTAssertNotNil(refused, "the phone is told it did not go in")
        XCTAssertFalse(model.conversations.entries(inChat: chat.id).contains { $0.kind == .user },
                       "and no answer is written into the chat as if it had been given")
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertTrue(((try? Data(contentsOf: received))?.isEmpty ?? true), "nothing was pressed on the other dialog")
        model.startingChats[chat.id] = nil
    }

    @MainActor
    func testTheStartingChatShowsItAndItsAnswerReachesTheScreen() async throws {
        // The app's own data in the test's folder, never in anybody's Bulava.
        let appData = state.appendingPathComponent("app")
        try FileManager.default.createDirectory(at: appData, withIntermediateDirectories: true)
        setenv("BULAVA_STATE_DIR", appData.path, 1)
        let model = AppModel()
        await model.client.updatePaths(SupervisorPaths(stateDir: state))
        _ = try await waitingInstance(model.client)
        await model.refresh()

        let productID = UUID()
        let chat = model.conversations.currentChat(for: productID)

        // Not bound to anything yet: this is the start in progress.
        XCTAssertNil(chat.session)
        model.startingChats[chat.id] = project
        model.syncDirectChats()
        let card = try XCTUnwrap(model.conversations.entries(inChat: chat.id).last { $0.kind == .question },
                                 "the question is in the chat being started")
        XCTAssertEqual(card.decision?.items.first?.options,
                       ["No, disable external imports", "Yes, allow external imports"])
        XCTAssertEqual(model.startingInstance(for: chat.id)?.session, session)

        // Answered from the card — the Mac's or the phone's, they come the same way.
        model.answerUnboundQuestion(entry: card, text: "Yes, allow external imports")
        // `dd` creates the file the moment it starts reading; what matters is the four bytes in it.
        for _ in 0..<80 where ((try? Data(contentsOf: received))?.count ?? 0) < 4 {
            try await Task.sleep(for: .milliseconds(50))
        }
        let bytes = try Data(contentsOf: received)
        XCTAssertTrue(bytes.starts(with: [0x1B, 0x4F, 0x42]) || bytes.starts(with: [0x1B, 0x5B, 0x42]),
                      "one step down to «Yes»")
        XCTAssertEqual(bytes.last, 0x0D, "and Enter, into the session that was waiting")

        // The screen is gone and the engine removes its marker: so is the card.
        try FileManager.default.removeItem(
            at: state.appendingPathComponent("instances/\(Slug.forPath(project))/screen-wait.json"))
        await model.refresh()
        XCTAssertNil(model.conversations.entries(inChat: chat.id).last { $0.kind == .question })
        model.startingChats[chat.id] = nil
    }
}
