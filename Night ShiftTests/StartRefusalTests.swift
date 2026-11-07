import XCTest
@testable import Bulava

/// Two starts the engine stopped for something only the person can clear, which 1.14 took for
/// breakages: it offered to repair them and sent each to us as an anonymous `chat.start_failed`
/// report (20 Oct). The output below is the engine's, as those reports carried it.
nonisolated final class StartRefusalTests: XCTestCase {

    private let notSignedIn = """
        ⚠️ хуки не підтвердили run-id за 12s — робота може піти без нагляду.
           Claude Code не ввійшов в акаунт і чекає входу. Увійди: claude auth login
        handshake-blocked=login
        ❌ підтвердження нема — відкат старту.
        """

    private let workspace = """
        ❌ У цій теці 2 репозиторії. Це робоча тека, а не репозиторій — Bulava не робить git поверх чужих репозиторіїв.
          • mfes/frontend-app-learning
          • src/edx-platform
        Підключи кожен репозиторій окремо (Bulava робить це сама, коли додаєш теку) і запускай у ньому.
        start-refused=folder
        """

    @MainActor
    private func model() -> (AppModel, UUID, UUID) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("bulava-start-refusal-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        setenv("BULAVA_STATE_DIR", dir.path, 1)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: dir)
            unsetenv("BULAVA_STATE_DIR")
        }
        let m = AppModel()
        m.settings.autoRepair = true
        m.settings.shareErrorReports = false
        let product = m.products.add(name: "pocket-ledger")
        let chat = m.conversations.newChat(for: product.id)
        let entry = m.conversations.appendUser("ship it", productID: product.id, chatID: chat.id)
        m.conversations.updateDelivery(entryID: entry.id, .failed)
        return (m, chat.id, entry.id)
    }

    func testTheMarkersAreReadAsWholeLinesOnly() {
        XCTAssertTrue(StartRefusal.needsSignIn(notSignedIn))
        XCTAssertFalse(StartRefusal.notAProject(notSignedIn))
        XCTAssertTrue(StartRefusal.notAProject(workspace))
        XCTAssertFalse(StartRefusal.needsSignIn(workspace))
        XCTAssertFalse(StartRefusal.needsSignIn("the word handshake-blocked=login inside a line"))
        XCTAssertFalse(StartRefusal.notAProject("Night Shift did not start."))
    }

    @MainActor
    func testANotSignedInStartAsksForTheSignInAndIsNotRepaired() {
        let (m, chat, entry) = model()
        XCTAssertTrue(m.stopOnStartTheyMustClear(chatID: chat, entryID: entry, output: notSignedIn))
        XCTAssertNil(m.repairs[chat], "a login is not a breakage — nothing is repaired or reported")
        XCTAssertEqual(m.signInPromptEntryID(inChat: chat), entry,
                       "the sign-in row stands under the message that did not go")
        XCTAssertTrue(m.chatHasAQuestionForYou(chat))
        XCTAssertFalse(m.chatErrors[chat]?.contains("handshake-blocked") ?? true,
                       "the engine's marker is not shown to the person")
    }

    /// A chat that ran before keeps its binding, so the refresh looks for a sign-in notice in it.
    /// There is none — the start never began — and that must not take the row away again.
    @MainActor
    func testTheRefreshDoesNotTakeAStartsSignInRowAway() {
        let (m, chat, entry) = model()
        m.stopOnStartTheyMustClear(chatID: chat, entryID: entry, output: notSignedIn)
        m.noticeExpiredLogin(in: m.conversations.chats.first { $0.id == chat }!)
        XCTAssertEqual(m.signInPromptEntryID(inChat: chat), entry)
        XCTAssertNotNil(m.chatErrors[chat])
    }

    @MainActor
    func testAFolderThatIsNotAProjectIsSaidAndNotRepaired() {
        let (m, chat, entry) = model()
        XCTAssertTrue(m.stopOnStartTheyMustClear(chatID: chat, entryID: entry, output: workspace))
        XCTAssertNil(m.repairs[chat], "the folder is the person's to change, not ours to repair")
        XCTAssertTrue(m.chatErrors[chat]?.contains("робоча тека, а не репозиторій") == true,
                      "the engine's reason is what the person reads")
        XCTAssertFalse(m.chatErrors[chat]?.contains("start-refused=") ?? true)
        XCTAssertTrue(m.toast?.actions.isEmpty == true, "and no Fix it button")
    }

    /// 30 Oct, 1.16.3: a chat whose folder was gone sent «Проєкт не знайдено» to us five times in a
    /// minute, each with a repair that could not bring a folder back. Now it is asked before the start.
    @MainActor
    func testAFolderThatIsGoneIsSaidBeforeTheStartAndNotRepaired() {
        let (m, chat, entry) = model()
        let gone = FileManager.default.temporaryDirectory
            .appendingPathComponent("bulava-moved-away-\(UUID().uuidString)").path
        XCTAssertTrue(m.stopOnFolderTheyMustClear(chatID: chat, entryID: entry, path: gone, name: "pocket-ledger"))
        XCTAssertNil(m.repairs[chat], "a folder that is gone is not ours to repair or report")
        XCTAssertTrue(m.chatErrors[chat]?.contains(gone) == true, "the person is told which folder")
        XCTAssertTrue(m.chatErrors[chat]?.contains("pocket-ledger") == true)
        XCTAssertTrue(m.toast?.actions.isEmpty == true, "and no Fix it button")
    }

    /// A folder macOS keeps Bulava out of is there: saying it is gone would send the person looking
    /// for something right where they left it.
    func testAFolderBulavaCannotEnterIsNotCalledGone() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("bulava-closed-\(UUID().uuidString)")
        let inner = root.appendingPathComponent("project")
        try FileManager.default.createDirectory(at: inner, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: root.path)
        addTeardownBlock {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: root.path)
            try? FileManager.default.removeItem(at: root)
        }
        let closed = try XCTUnwrap(StartRefusal.folderProblem(path: inner.path, name: "p"))
        XCTAssertEqual(closed, String(format: String(localized: "I cannot read the folder of “%@” (%@). Give Bulava access to it in System Settings, or connect another path."), "p", inner.path))
    }

    func testAFolderThatIsThereIsNoProblem() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("bulava-here-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        XCTAssertNil(StartRefusal.folderProblem(path: dir.path, name: "p"))
        // Enterable but not listable is enough for the engine, so it is enough here.
        let enterOnly = dir.appendingPathComponent("enter-only")
        try FileManager.default.createDirectory(at: enterOnly, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o300], ofItemAtPath: enterOnly.path)
        addTeardownBlock { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: enterOnly.path) }
        XCTAssertNil(StartRefusal.folderProblem(path: enterOnly.path, name: "p"), "the engine can cd into it")
        let file = dir.appendingPathComponent("not-a-folder")
        FileManager.default.createFile(atPath: file.path, contents: Data())
        XCTAssertNotNil(StartRefusal.folderProblem(path: file.path, name: "p"), "a file where the folder was is not one")
    }

    /// The engine's own refusal of a missing folder carries the marker too, for a folder that goes
    /// between the check above and the start (`engine/tests/test-workspace-container.sh`).
    @MainActor
    func testTheEnginesMissingFolderRefusalIsNotRepaired() {
        let (m, chat, entry) = model()
        let out = "❌ Проєкт не знайдено: /Users/someone/Projects/app\nstart-refused=folder"
        XCTAssertTrue(m.stopOnStartTheyMustClear(chatID: chat, entryID: entry, output: out))
        XCTAssertNil(m.repairs[chat])
        XCTAssertEqual(m.chatErrors[chat], "❌ Проєкт не знайдено: /Users/someone/Projects/app")
    }

    /// 5 Nov, 1.17: a Mac without tmux. `start`'s refusal, as the report carried it, now with the
    /// marker (`engine/tests/test-missing-tool.sh`).
    private let noTmux = "❌ tmux не встановлено (brew install tmux)\nstart-refused=tool:tmux"

    func testAMissingToolIsReadFromItsOwnLineOnly() {
        XCTAssertEqual(StartRefusal.missingTool(noTmux), "tmux")
        XCTAssertNil(StartRefusal.missingTool("❌ tmux не встановлено (brew install tmux)"),
                     "the words alone are not the marker")
        XCTAssertNil(StartRefusal.missingTool("say start-refused=tool:tmux in a line"))
        XCTAssertNil(StartRefusal.missingTool("start-refused=tool:"), "no name, no tool")
        XCTAssertNil(StartRefusal.missingTool("start-refused=tool:tmux; rm -rf ~"),
                     "only a plain command name is taken from the line")
        XCTAssertNil(StartRefusal.missingTool(workspace))
        XCTAssertFalse(StartRefusal.notAProject(noTmux), "a missing tool is not a folder problem")
        XCTAssertEqual(StartRefusal.brewFormula(forTool: "tmux"), "tmux")
        XCTAssertNil(StartRefusal.brewFormula(forTool: "something-else"), "no button guesses a formula")
    }

    @MainActor
    func testAStartWithoutTmuxAsksForTheInstallAndIsNotRepaired() {
        let (m, chat, entry) = model()
        XCTAssertTrue(m.stopOnStartTheyMustClear(chatID: chat, entryID: entry, output: noTmux))
        XCTAssertNil(m.repairs[chat], "a tool to install is not a breakage — nothing is repaired or reported")
        XCTAssertEqual(m.toolBlocked[chat], "tmux", "the install row stands under the message")
        XCTAssertTrue(m.chatHasAQuestionForYou(chat))
        XCTAssertEqual(m.chatErrors[chat], StartRefusal.missingToolMessage("tmux"),
                       "said in the app's words and language, not the engine's Ukrainian line")
        XCTAssertFalse(m.chatErrors[chat]?.contains("start-refused") ?? true)
        XCTAssertTrue(m.toast?.actions.isEmpty == true, "and no Fix it button")

        m.retryDirectMessage(entryID: entry)
        XCTAssertNil(m.toolBlocked[chat], "sending again takes the row away")
    }

    /// With the engine of this checkout run for real: a Mac without tmux refuses the start, the app
    /// puts the install row under the message, the row's button asks Terminal for `brew install
    /// tmux`, tmux appears, Send again takes the row away, and the engine's start goes through.
    /// Two things are stood in for, because doing them for real would change the Mac the suite runs
    /// on: Terminal (the command is caught, not typed) and Homebrew's work (tmux is linked onto the
    /// PATH it installs to).
    ///
    /// What this does NOT prove: that the app's own resend reaches the worker. The app's start goes
    /// to the installed engine (`OrchestratorHome.detect`) and asks the real `~/.claude.json` for
    /// folder trust, so the engine start here is run beside the app, not by it.
    @MainActor
    func testFromARealRefusalThroughTheInstallToAStart() throws {
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let engine = repo.appendingPathComponent("engine/bin/night-shift.sh").path
        guard FileManager.default.fileExists(atPath: engine) else { throw XCTSkip("no engine checkout beside the tests") }
        // Short, under /tmp: a tmux socket path must fit in 104 bytes, and $TMPDIR's does not.
        let tmp = URL(fileURLWithPath: "/tmp/bnt-\(UUID().uuidString.prefix(8))")
        let farm = tmp.appendingPathComponent("bin"), project = tmp.appendingPathComponent("project")
        let tmuxDir = tmp.appendingPathComponent("tmux")
        for d in [farm, project, tmuxDir, tmp.appendingPathComponent("state")] {
            try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        }
        let env: [String: String] = [
            "HOME": NSHomeDirectory(), "PATH": farm.path, "TMUX_TMPDIR": tmuxDir.path,
            "SUPERVISOR_STATE_DIR": tmp.appendingPathComponent("state").path,
            "SUPERVISOR_CLAUDE_CMD": "cat", "SUPERVISOR_HANDSHAKE_WAIT": "0", "SUPERVISOR_NO_ATTACH": "1",
        ]
        func bash(_ script: String, _ args: [String] = [], env: [String: String]) -> (Int32, String) {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/bin/bash")
            p.arguments = ["-c", script, "bash"] + args
            p.environment = env
            let pipe = Pipe()
            p.standardOutput = pipe; p.standardError = pipe
            do { try p.run() } catch { return (-1, "\(error)") }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            return (p.terminationStatus, String(decoding: data, as: UTF8.self))
        }
        addTeardownBlock {
            _ = bash("bash \"$1\" stop \"$2\"; tmux kill-server", [engine, project.path], env: env)
            try? FileManager.default.removeItem(at: tmp)
        }
        // Everything this Mac has on the usual PATH, tmux left out.
        let system = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        _ = bash("""
            IFS=: read -r -a dirs <<< "$2"
            for d in "${dirs[@]}"; do for f in "$d"/*; do n="${f##*/}"
              [ "$n" = tmux ] || { [ -x "$f" ] && [ ! -e "$1/$n" ] && ln -s "$f" "$1/$n"; }
            done; done
            cd "$3" && git init -q && echo hi > f.txt && git add -A && git -c user.email=t@t -c user.name=t commit -qm init
            """, [farm.path, system, project.path], env: ["PATH": system, "HOME": NSHomeDirectory()])
        XCTAssertNotEqual(bash("command -v tmux", env: env).0, 0, "tmux is still reachable — nothing here would be proven")

        // 1. The real refusal, read by the app.
        let (refusedExit, refused) = bash("bash \"$1\" start \"$2\" --no-attach", [engine, project.path], env: env)
        XCTAssertNotEqual(refusedExit, 0)
        let (m, chat, entry) = model()
        XCTAssertTrue(m.stopOnStartTheyMustClear(chatID: chat, entryID: entry, output: refused), refused)
        XCTAssertEqual(m.toolBlocked[chat], "tmux")
        XCTAssertNil(m.repairs[chat], "nothing repaired or reported")

        // 2. The row's button: Homebrew, in Terminal, for tmux.
        var typed: [String] = []
        m.terminalRunner = { typed.append($0) }
        m.installMissingTool("tmux")
        let brew = ["/opt/homebrew/bin/brew", "/usr/local/bin/brew"].first { FileManager.default.fileExists(atPath: $0) }
        if let brew {
            XCTAssertEqual(typed, ["\(brew) install tmux"])
        } else {
            XCTAssertTrue(typed.isEmpty, "no Homebrew: brew.sh is opened instead, nothing is typed")
        }
        m.installMissingTool("some-tool")
        XCTAssertEqual(typed.count, brew == nil ? 0 : 1, "a tool with no known formula types nothing")

        // 3. Homebrew's work: tmux where it installs it. Send again, and the same start goes through.
        let realTmux = ["/opt/homebrew/bin/tmux", "/usr/local/bin/tmux"].first { FileManager.default.fileExists(atPath: $0) }
        let tmuxPath = try XCTUnwrap(realTmux, "this Mac has no tmux to stand in for the install")
        try FileManager.default.createSymbolicLink(atPath: farm.appendingPathComponent("tmux").path,
                                                   withDestinationPath: tmuxPath)
        m.retryDirectMessage(entryID: entry)
        XCTAssertNil(m.toolBlocked[chat], "sending again takes the row away")
        let (startedExit, started) = bash("bash \"$1\" start \"$2\" --no-attach", [engine, project.path], env: env)
        XCTAssertEqual(startedExit, 0, started)
        XCTAssertNil(StartRefusal.missingTool(started), "no longer refused for tmux")
        XCTAssertEqual(bash("tmux list-sessions -F '#S' | grep -q .", env: env).0, 0,
                       "the run's tmux session is there")
    }

    /// A message to a chat that already ran goes through worker-send, which refuses before trying.
    func testASendWithoutTmuxIsReadAsAMissingTool() {
        let out = "start-refused=tool:tmux\n❌ tmux не встановлено (brew install tmux)"
        let result = RelayResult.read(output: out, exitCode: 1, launched: true, endedBy: .exited)
        XCTAssertEqual(result.tier, .error)
        XCTAssertEqual(result.missingTool, "tmux")
        XCTAssertTrue(result.undelivered, "refused before trying: never delivered")
        XCTAssertNil(RelayResult.read(output: "❌ Нема такої теки: /x", exitCode: 1, launched: true,
                                      endedBy: .exited).missingTool)
    }

    @MainActor
    func testAnyOtherFailedStartIsLeftToTheRepair() {
        let (m, chat, entry) = model()
        XCTAssertFalse(m.stopOnStartTheyMustClear(chatID: chat, entryID: entry,
                                                  output: "install.sh: line 3: jq: command not found"))
        XCTAssertNil(m.chatErrors[chat])
    }

    /// A resume of a signed-out Claude: it exited before its sign-in screen could be read, and the
    /// engine now asks Claude Code and says `handshake-blocked=login` (21.10, two reports).
    func testAResumeThatStoppedOnASignInIsReadAsOne() {
        let out = "⚠️ хуки не підтвердили run-id за 60s\nhandshake-blocked=login\n❌ не вдалося відновити\nTIER=none"
        let result = RelayResult.read(output: out, exitCode: 3, launched: true, endedBy: .exited)
        XCTAssertEqual(result.tier, .none)
        XCTAssertTrue(result.needsSignIn)
        let other = RelayResult.read(output: "❌ не вдалося відновити\nTIER=none", exitCode: 3, launched: true, endedBy: .exited)
        XCTAssertFalse(other.needsSignIn, "an ordinary failed resume is still one")
    }

    /// A resume of a conversation Claude Code no longer keeps (1.16.1, 23.10): worker-send's own
    /// output, as `tests/test-resume-gone.sh` pins it — nothing to repair, nothing to report.
    @MainActor
    func testAConversationClaudeNoLongerKeepsIsSaidAndNotRepaired() {
        let out = "resume-refused=transcript\nTIER=none\nнема живої/відновлюваної сесії — потрібен свіжий воркер"
        let result = RelayResult.read(output: out, exitCode: 3, launched: true, endedBy: .exited)
        XCTAssertEqual(result.tier, .none)
        XCTAssertTrue(result.conversationGone)
        XCTAssertFalse(result.needsSignIn)
        XCTAssertEqual(StartRefusal.withoutMarkers("resume-refused=transcript\nok"), "ok")
        XCTAssertFalse(RelayResult.read(output: "TIER=none", exitCode: 3, launched: true,
                                        endedBy: .exited).conversationGone,
                       "an ordinary failed resume is still one")

        let (m, chat, _) = model()
        m.failChat(chat, "gone", .needsYou)
        XCTAssertNil(m.repairs[chat], "a conversation that is gone is not repaired or reported")
        XCTAssertTrue(m.toast?.actions.isEmpty == true, "and no Fix it button")
    }
}
