import XCTest
@testable import Bulava

nonisolated final class TerminalQuestionParserTests: XCTestCase {
    func testTheRealClaudeFormKeepsTheQuestionOptionsAndDescriptions() throws {
        let pane = """
        ────────────────────────────────────────────────────────────────────────────────
        ←  ☐ Читання закону  ☐ Sheet  ✔ Submit  →

        │ Крім двох екранів (категорії → список+пошук), потрібен третій — читання самого
        │ тексту закону? На вебі це окрема сторінка з повним текстом, змістом та експортом.

        ❯ 1. Так, нативний рідер (рекомендовано)
             Парсимо HTML Рада у блоки, рендеримо в LazyColumn, зміст у sheet.
          2. Тільки чинна редакція
             Той самий рідер, але без перемикача редакцій. Менше роботи, швидше в реліз.
          3. Без третього екрана
             Список законів веде на сторонній браузер. Найшвидше, але читати в застосунку не можна.
          4. Type something.
        ────────────────────────────────────────────────────────────────────────────────
          5. Chat about this

        Enter to select · Tab/Arrow keys to navigate · Esc to cancel
        """

        let parsed = try XCTUnwrap(TerminalQuestionParser.parse(pane))
        XCTAssertEqual(parsed.source, .terminal)
        XCTAssertTrue(parsed.questions[0].question.contains("потрібен третій"))
        XCTAssertEqual(parsed.questions[0].options,
                       ["Так, нативний рідер (рекомендовано)", "Тільки чинна редакція",
                        "Без третього екрана"])
        XCTAssertEqual(parsed.questions[0].optionDescriptions?["Тільки чинна редакція"],
                       "Той самий рідер, але без перемикача редакцій. Менше роботи, швидше в реліз.")
        XCTAssertEqual(parsed.terminalSelectedIndex, 1)
        XCTAssertEqual(parsed.terminalOptionIndices["Без третього екрана"], 3)
        XCTAssertEqual(parsed.terminalCustomOptionIndex, 4)
    }

    func testOrdinaryTerminalOutputIsNotInventedIntoAQuestion() {
        XCTAssertNil(TerminalQuestionParser.parse("Building project…\n34 steps\n❯ "))
    }

    func testLaterPageWithoutQuestionRailIsStillRendered() throws {
        let pane = """
        ────────────────────────────────────────────────────────────────────────────────
        ←  ☒ Читання закону  ☐ Sheet  ✔ Submit  →

        Що покласти в sheet на другому екрані?

        ❯ 1. Пошук + усі фільтри (рекомендовано)
             Рядок пошуку плюс веб-фільтри: тип, ким видано, стан.
          2. Тільки пошук
             У sheet лише пошуковий рядок.
          3. Type something.
        ────────────────────────────────────────────────────────────────────────────────
          4. Chat about this

        Enter to select · Tab/Arrow keys to navigate · Esc to cancel
        """

        let parsed = try XCTUnwrap(TerminalQuestionParser.parse(pane))
        XCTAssertEqual(parsed.questions.first?.question, "Що покласти в sheet на другому екрані?")
        XCTAssertEqual(parsed.questions.first?.options,
                       ["Пошук + усі фільтри (рекомендовано)", "Тільки пошук"])
        XCTAssertEqual(parsed.terminalCustomOptionIndex, 3)
    }

    func testFinalReviewIsAnActionableCardInsteadOfWorkingStatus() throws {
        let pane = """
        ────────────────────────────────────────────────────────────────────────────────
        ←  ☒ Читання закону  ☒ Sheet  ✔ Submit  →

        Review your answers

         │ ● Чи потрібен третій екран?
           → Так, нативний рідер
         ● Що покласти в sheet?
           → Пошук + усі фільтри

        Ready to submit your answers?

        ❯ 1. Submit answers
          2. Cancel
        """

        let parsed = try XCTUnwrap(TerminalQuestionParser.parse(pane))
        XCTAssertTrue(parsed.terminalReview)
        XCTAssertEqual(parsed.questions.first?.question, "Підтвердити вибрані відповіді?")
        XCTAssertEqual(parsed.questions.first?.options,
                       [TerminalQuestionParser.reviewSubmitLabel,
                        TerminalQuestionParser.reviewCancelLabel])
        XCTAssertEqual(parsed.terminalOptionIndices[TerminalQuestionParser.reviewSubmitLabel], 1)
        let descriptions = parsed.questions.first?.optionDescriptions
        let submitDescription = descriptions?[TerminalQuestionParser.reviewSubmitLabel]
        XCTAssertTrue(submitDescription?.contains("Пошук + усі фільтри") == true)
    }

    @MainActor
    func testAnswerBridgeSelectsTheExactVisibleOption() async throws {
        let token = UUID().uuidString.lowercased()
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("night-shift-question-\(token)", isDirectory: true)
        let script = directory.appendingPathComponent("form.zsh")
        let received = directory.appendingPathComponent("received.bin")
        let submitted = directory.appendingPathComponent("submitted.bin")
        let session = "ns-question-\(token.prefix(12))"
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer {
            Task { _ = await Shell.run("tmux kill-session -t \"$1\" 2>/dev/null || true", args: [session]) }
            try? FileManager.default.removeItem(at: directory)
        }

        let fixture = """
        #!/bin/zsh
        cat <<'FORM'
        ────────────────────────────────────────────────────────────────────────────────
        │ Який варіант обрати?

        ❯ 1. Перший
          2. Другий
          3. Type something.
        ────────────────────────────────────────────────────────────────────────────────
        FORM
        print 'Enter to select · Tab/Arrow keys to navigate · Esc to cancel'
        stty raw -echo
        dd bs=1 count=4 of="$1" 2>/dev/null
        stty sane
        cat <<'REVIEW'

        Review your answers

         ● Який варіант обрати?
           → Другий

        Ready to submit your answers?

        ❯ 1. Submit answers
          2. Cancel
        REVIEW
        stty raw -echo
        dd bs=1 count=1 of="$2" 2>/dev/null
        """
        try fixture.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)

        let launch = await Shell.run(
            "tmux new-session -d -s \"$1\" -x 160 -y 40 \"exec /bin/zsh $2 $3 $4\"",
            args: [session, script.path, received.path, submitted.path])
        XCTAssertTrue(launch.launched)
        XCTAssertEqual(launch.exitCode, 0)

        let client = SupervisorClient()
        var pending: PendingUserQuestion?
        for _ in 0..<20 where pending == nil {
            let pane = await client.capturePane(session: session, lines: 80)
            pending = TerminalQuestionParser.parse(pane)
            if pending == nil { try await Task.sleep(for: .milliseconds(50)) }
        }
        let question = try XCTUnwrap(pending)
        let result = await client.answerTerminalQuestion(session: session, expected: question,
                                                         answer: "Другий")
        XCTAssertTrue(result.launched)
        XCTAssertEqual(result.exitCode, 0)

        for _ in 0..<20 where !FileManager.default.fileExists(atPath: received.path) {
            try await Task.sleep(for: .milliseconds(50))
        }
        let bytes = try Data(contentsOf: received)
        XCTAssertEqual(bytes.last, 0x0D)
        XCTAssertTrue(bytes.starts(with: [0x1B, 0x4F, 0x42]) ||
                      bytes.starts(with: [0x1B, 0x5B, 0x42]))
        for _ in 0..<20 where !FileManager.default.fileExists(atPath: submitted.path) {
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertEqual(try Data(contentsOf: submitted).last, 0x0D)
    }

    /// Claude Code 2.1.289's permission dialog, captured from a live pane. It waited in a pane
    /// nobody watched; read as a question, it is answered like any of Claude's forms.
    func testAPermissionDialogIsAQuestionWithItsOwnOptions() throws {
        let pane = """
        ❯ Use the Bash tool to run exactly: touch /tmp/claude-501/pp/permtest.txt — nothing else.
          Creating a test file at the specified path
          ⎿  $ touch /tmp/claude-501/pp/permtest.txt
        ────────────────────────────────────────────────────────
         Bash command
         Create a test file at the specified path
        ╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌
         touch /tmp/claude-501/pp/permtest.txt
        ╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌
         Do you want to proceed?
         ❯ 1. Yes
           2. Yes, and always allow access to /tmp/claude-501/pp from this project
           3. No
         Esc to cancel · Tab to amend
        """
        let q = try XCTUnwrap(TerminalQuestionParser.parse(pane))
        XCTAssertEqual(q.source, .terminal, "answered by keys in the pane, like any of Claude's forms")
        XCTAssertEqual(q.summary, "Bash command — touch /tmp/claude-501/pp/permtest.txt",
                       "what is being asked for, not only \"Do you want to proceed?\"")
        XCTAssertEqual(q.questions.first?.options,
                       ["Yes", "Yes, and always allow access to /tmp/claude-501/pp from this project", "No"])
        XCTAssertEqual(q.terminalSelectedIndex, 1)
        XCTAssertEqual(q.terminalOptionIndices["No"], 3)
        XCTAssertNil(q.terminalCustomOptionIndex)
    }

    /// Claude Code's safety-check dialog in a session nobody seems to be at: it counts down and then
    /// denies itself. Shaped after the card that met the director on 6 Oct, where the reason and the
    /// countdown sat between the dashed rules and so became the question's own words.
    private static func countingDown(_ left: String, wrapped: Bool = false) -> String {
        let warning = wrapped
            ? " ⚠ Claude Code will automatically deny this request in\n \(left), to avoid blocking progress on an unattended session"
            : " ⚠ Claude Code will automatically deny this request in \(left), to avoid blocking progress on an unattended session"
        return """
        ────────────────────────────────────────────────────────
         Bash command  bash -c 'serve; rm -f "$S/old"'
        ╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌
         This shell -c script runs rm and could not be checked
        \(warning)
        ╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌

         Do you want to proceed?
         ❯ 1. Yes
           2. No

         Esc to cancel · Tab to amend
        """
    }

    /// The countdown is not part of the question. Read with it, the screen was a different question
    /// every second, so no answer from the Mac or the phone was ever accepted, and the card went on
    /// showing a time that had stopped being true.
    func testACountdownIsNotPartOfTheQuestion() throws {
        let early = try XCTUnwrap(TerminalQuestionParser.parse(Self.countingDown("0:22")))
        let late = try XCTUnwrap(TerminalQuestionParser.parse(Self.countingDown("0:05")))
        XCTAssertEqual(early, late, "the same dialog, a few seconds apart, is one question")
        XCTAssertEqual(early.questions.first?.options, ["Yes", "No"])
        let text = (early.questions.first?.question ?? "") + (early.summary ?? "")
        XCTAssertFalse(text.contains("0:22"), "a card must not show a time that is already wrong")
        XCTAssertTrue(text.contains("deny this request in a moment"), "the warning itself stays: \(text)")

        let wrappedEarly = try XCTUnwrap(TerminalQuestionParser.parse(Self.countingDown("0:22", wrapped: true)))
        let wrappedLate = try XCTUnwrap(TerminalQuestionParser.parse(Self.countingDown("0:21", wrapped: true)))
        XCTAssertEqual(wrappedEarly, wrappedLate, "the phrase wraps anywhere in a narrow pane")
        XCTAssertEqual(TerminalQuestionParser.steady("deny this request in 45s, to avoid"),
                       "deny this request in a moment, to avoid")
        XCTAssertEqual(TerminalQuestionParser.steady("Wrote 3 files in 0:22"), "Wrote 3 files in 0:22",
                       "only Claude's own countdown goes, not every time on the screen")
    }

    /// The 6 Oct failure end to end: the card is read at 0:22, the dialog has ticked on by the time
    /// the answer arrives, and the answer must still reach it — one Enter on "Yes".
    @MainActor
    func testAnAnswerReachesADialogThatCountedDownMeanwhile() async throws {
        let token = UUID().uuidString.lowercased()
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("night-shift-countdown-\(token)", isDirectory: true)
        let script = directory.appendingPathComponent("dialog.zsh")
        let first = directory.appendingPathComponent("first.txt")
        let second = directory.appendingPathComponent("second.txt")
        let received = directory.appendingPathComponent("received.bin")
        let session = "ns-countdown-\(token.prefix(12))"
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer {
            Task { _ = await Shell.run("tmux kill-session -t \"$1\" 2>/dev/null || true", args: [session]) }
            try? FileManager.default.removeItem(at: directory)
        }
        try Self.countingDown("0:22").write(to: first, atomically: true, encoding: .utf8)
        try Self.countingDown("0:21").write(to: second, atomically: true, encoding: .utf8)
        let fixture = """
        #!/bin/zsh
        cat "$1"
        sleep 0.8
        print -n '\\033[2J\\033[H'
        cat "$2"
        stty raw -echo
        dd bs=1 count=1 of="$3" 2>/dev/null
        """
        try fixture.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)

        let launch = await Shell.run(
            "tmux new-session -d -s \"$1\" -x 160 -y 40 \"exec /bin/zsh $2 $3 $4 $5\"",
            args: [session, script.path, first.path, second.path, received.path])
        XCTAssertEqual(launch.exitCode, 0)

        let client = SupervisorClient()
        var asked: PendingUserQuestion?
        var pane = ""
        for _ in 0..<40 where asked == nil {
            pane = await client.capturePane(session: session, lines: 80)
            if pane.contains("in 0:22") { asked = TerminalQuestionParser.parse(pane) }
            if asked == nil { try await Task.sleep(for: .milliseconds(25)) }
        }
        let card = try XCTUnwrap(asked, "the dialog was read while it said 0:22")
        for _ in 0..<80 where !pane.contains("in 0:21") {
            try await Task.sleep(for: .milliseconds(25))
            pane = await client.capturePane(session: session, lines: 80)
        }
        XCTAssertTrue(pane.contains("in 0:21"), "the dialog has ticked on before the answer arrives")

        let result = await client.answerTerminalQuestion(session: session, expected: card, answer: "Yes")
        XCTAssertEqual(result.exitCode, 0, "refused as another question: \(result.stderr)")
        for _ in 0..<40 where !FileManager.default.fileExists(atPath: received.path) {
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertEqual(try Data(contentsOf: received).last, 0x0D, "Enter on the option the cursor is already on")
    }

    /// The folder-trust screen has "Esc to cancel" too and no numbered options. It is not taken for
    /// a permission dialog — it is read as what it is: two choices, the cursor on the first.
    func testTheTrustScreenIsReadAsItsOwnTwoChoices() throws {
        let pane = """
         Quick safety check: Is this a project you created or one you trust?
         ❯ No, exit
           Yes, I trust this folder
         Enter to confirm · Esc to cancel
        """
        let q = try XCTUnwrap(TerminalQuestionParser.parse(pane))
        XCTAssertEqual(q.questions.first?.options, ["No, exit", "Yes, I trust this folder"])
        XCTAssertEqual(q.summary, "Quick safety check: Is this a project you created or one you trust?")
        XCTAssertEqual(q.terminalSelectedIndex, 1)
        XCTAssertEqual(q.terminalOptionIndices["Yes, I trust this folder"], 2)
    }

    // MARK: - Any screen that asks

    /// 5 Oct: a start sat on this, a screen nothing here knew, and was rolled back with it on screen.
    static let externalImports = """
    ╭──────────────────────────────────────────────────────────────────────────╮
    │ Allow external CLAUDE.md file imports?                                   │
    │                                                                          │
    │ This project's CLAUDE.md imports files outside the current working      │
    │ directory. Never allow this for third-party repositories.                │
    │                                                                          │
    │ External imports:                                                        │
    │   /Users/someone/edx/green/devspace/idd/CLAUDE.md                        │
    │                                                                          │
    │ Important: Only use Claude Code with files you trust. Accessing untrusted│
    │ files may pose security risks https://code.claude.com/docs/en/security   │
    │                                                                          │
    │ ❯ No, disable external imports                                           │
    │   Yes, allow external imports                                            │
    │                                                                          │
    │ Enter to confirm · Esc to cancel                                         │
    ╰──────────────────────────────────────────────────────────────────────────╯
    """

    func testAScreenNobodyKnewIsStillAQuestion() throws {
        let q = try XCTUnwrap(TerminalQuestionParser.parse(Self.externalImports))
        XCTAssertEqual(q.source, .terminal)
        XCTAssertEqual(q.questions.first?.options,
                       ["No, disable external imports", "Yes, allow external imports"],
                       "the choices, without the box and the cursor drawn around them")
        XCTAssertEqual(q.terminalSelectedIndex, 1)
        XCTAssertEqual(q.terminalOptionIndices["Yes, allow external imports"], 2)
        XCTAssertTrue(q.terminalKeys.isEmpty, "a list is answered by moving through it")
        let text = try XCTUnwrap(q.questions.first?.question)
        XCTAssertTrue(text.contains("/Users/someone/edx/green/devspace/idd/CLAUDE.md"),
                      "the question is the screen's own words, the file it is about included")
        XCTAssertTrue(text.contains("Only use Claude Code with files you trust"))
    }

    func testTheSameScreenWithoutItsBoxReadsTheSame() throws {
        let pane = Self.externalImports.components(separatedBy: "\n")
            .map { TerminalQuestionParser.inside($0) }.joined(separator: "\n")
        let q = try XCTUnwrap(TerminalQuestionParser.parse(pane))
        XCTAssertEqual(q.questions.first?.options,
                       ["No, disable external imports", "Yes, allow external imports"])
    }

    func testANumberedMenuOfAnotherShapeKeepsItsNumbers() throws {
        let pane = """
         Select model
         Switch between Claude models. Applies to this session.

           1. Default (recommended)   Opus 5.5 for complex work
         ❯ 2. Sonnet                  Sonnet 5.5 for daily tasks
           3. Haiku                   Haiku 4.5 for quick answers

         Enter to confirm · Esc to exit
        """
        let q = try XCTUnwrap(TerminalQuestionParser.parse(pane))
        XCTAssertEqual(q.questions.first?.options.count, 3)
        XCTAssertEqual(q.terminalSelectedIndex, 2)
        XCTAssertEqual(q.terminalOptionIndices.values.sorted(), [1, 2, 3])
        XCTAssertTrue(q.questions.first?.question.contains("Select model") == true)
    }

    func testAScreenWithNothingToChooseIsAnsweredWithItsKeys() throws {
        let pane = """
         Claude Code has been updated to 2.1.300.
         Restart to use the new version.

         Press Enter to continue…
        """
        let q = try XCTUnwrap(TerminalQuestionParser.parse(pane))
        let only = try XCTUnwrap(q.questions.first?.options.first)
        XCTAssertEqual(q.questions.first?.options.count, 1)
        XCTAssertEqual(q.terminalKeys[only], ["Enter"])
        XCTAssertTrue(q.questions.first?.question.contains("has been updated") == true)
    }

    func testEnterAndEscHintsAreTwoAnswers() throws {
        let pane = """
         A newer settings file was found in this project.
         Enter to continue · Esc to skip
        """
        let q = try XCTUnwrap(TerminalQuestionParser.parse(pane))
        XCTAssertEqual(q.questions.first?.options, ["Continue (Enter)", "Skip (Esc)"])
        XCTAssertEqual(q.terminalKeys["Skip (Esc)"], ["Escape"])
    }

    func testAYesNoLineIsYesAndNo() throws {
        let q = try XCTUnwrap(TerminalQuestionParser.parse(" Overwrite the existing hooks? (y/n)"))
        XCTAssertEqual(q.questions.first?.options.count, 2)
        let yes = try XCTUnwrap(q.questions.first?.options.first)
        XCTAssertEqual(q.terminalKeys[yes], ["y", "Enter?"],
                       "Enter only if the screen still asks — a single-key prompt has moved on")
    }

    func testTheComposerAndARunningTurnAreNotQuestions() {
        XCTAssertNil(TerminalQuestionParser.parse("""
        ● Done. The tests pass.
        ────────────────────────────────────────
        ❯ 
        ────────────────────────────────────────
          ? for shortcuts
        """))
        XCTAssertNil(TerminalQuestionParser.parse("✻ Thinking… (14s · ↓ 2.1k tokens · esc to interrupt)"))
        XCTAssertNil(TerminalQuestionParser.parse("""
        The agent said: press Enter to continue when ready.
        1
        2
        3
        4
        5
        6
        7
        ────────────────────────────────────────
        ❯ 
        ────────────────────────────────────────
        """), "words like a hint far up the conversation are not the screen asking")
    }

    /// The external-imports screen answered for real, in a pane: the second choice is one step down
    /// from the cursor, then Enter — and a screen of keys gets exactly its key.
    @MainActor
    func testAnUnnumberedScreenIsAnsweredByMovingToTheChoice() async throws {
        let token = UUID().uuidString.lowercased()
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("night-shift-screen-\(token)", isDirectory: true)
        let screen = directory.appendingPathComponent("screen.txt")
        let script = directory.appendingPathComponent("screen.zsh")
        let received = directory.appendingPathComponent("received.bin")
        let session = "ns-screen-\(token.prefix(12))"
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer {
            Task { _ = await Shell.run("tmux kill-session -t \"$1\" 2>/dev/null || true", args: [session]) }
            try? FileManager.default.removeItem(at: directory)
        }
        try Self.externalImports.write(to: screen, atomically: true, encoding: .utf8)
        try """
        #!/bin/zsh
        cat "$1"
        stty raw -echo
        dd bs=1 count=4 of="$2" 2>/dev/null
        stty sane
        sleep 30
        """.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        let launch = await Shell.run(
            "tmux new-session -d -s \"$1\" -x 160 -y 40 \"exec /bin/zsh $2 $3 $4\"",
            args: [session, script.path, screen.path, received.path])
        let launched = launch.exitCode
        XCTAssertEqual(launched, 0)

        let client = SupervisorClient()
        var pending: PendingUserQuestion?
        for _ in 0..<40 where pending == nil {
            pending = TerminalQuestionParser.parse(await client.capturePane(session: session, lines: 80))
            if pending == nil { try await Task.sleep(for: .milliseconds(50)) }
        }
        let question = try XCTUnwrap(pending)
        let result = await client.answerTerminalQuestion(session: session, expected: question,
                                                         answer: "Yes, allow external imports")
        let answered = result.exitCode
        XCTAssertEqual(answered, 0)
        // `dd` creates the file as it starts reading; wait for what it read.
        for _ in 0..<80 where ((try? Data(contentsOf: received))?.count ?? 0) < 4 {
            try await Task.sleep(for: .milliseconds(50))
        }
        let bytes = try Data(contentsOf: received)
        XCTAssertTrue(bytes.starts(with: [0x1B, 0x4F, 0x42]) || bytes.starts(with: [0x1B, 0x5B, 0x42]),
                      "one step down, from «No» to «Yes»")
        XCTAssertEqual(bytes.last, 0x0D, "and Enter")
    }

    @MainActor
    func testAScreenOfKeysGetsExactlyItsKey() async throws {
        let token = UUID().uuidString.lowercased()
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("night-shift-keys-\(token)", isDirectory: true)
        let script = directory.appendingPathComponent("keys.zsh")
        let received = directory.appendingPathComponent("received.bin")
        let session = "ns-keys-\(token.prefix(12))"
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer {
            Task { _ = await Shell.run("tmux kill-session -t \"$1\" 2>/dev/null || true", args: [session]) }
            try? FileManager.default.removeItem(at: directory)
        }
        try """
        #!/bin/zsh
        print ' A newer settings file was found in this project.'
        print ' Enter to continue · Esc to skip'
        stty raw -echo
        dd bs=1 count=1 of="$1" 2>/dev/null
        stty sane
        print ' done'
        sleep 30
        """.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        let launch = await Shell.run(
            "tmux new-session -d -s \"$1\" -x 160 -y 40 \"exec /bin/zsh $2 $3\"",
            args: [session, script.path, received.path])
        let launched = launch.exitCode
        XCTAssertEqual(launched, 0)

        let client = SupervisorClient()
        var pending: PendingUserQuestion?
        for _ in 0..<40 where pending == nil {
            pending = TerminalQuestionParser.parse(await client.capturePane(session: session, lines: 80))
            if pending == nil { try await Task.sleep(for: .milliseconds(50)) }
        }
        let question = try XCTUnwrap(pending)
        let result = await client.answerTerminalQuestion(session: session, expected: question,
                                                         answer: "Skip (Esc)")
        let answered = result.exitCode
        XCTAssertEqual(answered, 0)
        for _ in 0..<80 where ((try? Data(contentsOf: received))?.count ?? 0) < 1 {
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertEqual(try Data(contentsOf: received), Data([0x1B]), "Escape, and nothing after it")
    }
}
