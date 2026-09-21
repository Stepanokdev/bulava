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
}
