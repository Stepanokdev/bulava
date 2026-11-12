import XCTest
import SwiftUI
@testable import Bulava

/// The run view is the interface, and it speaks the interface's language. The engine journals its
/// notes in Ukrainian; in an English Bulava a continued task used to read «Claude's position ·
/// Skipped · Продовження відкритої задачі» and «Claude does the work · Working · Сесія
/// підтвердила, що отримала бриф». These hold every sentence the engine writes into a run to the
/// interface language, and whatever was put into those sentences — a model's reason, a step's
/// name, a tool's error, the worker's own summary — to exactly what was written.
nonisolated final class RunNoteWordingTests: XCTestCase {

    // MARK: - The languages

    /// A bundle with no translations: what an English Bulava says, whatever this Mac's language.
    private static let english: Bundle = {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("run-note-wording-en.bundle")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return Bundle(path: dir.path)!
    }()

    private func language(_ code: String) throws -> Bundle {
        let path = try XCTUnwrap(Bundle(for: AppModel.self).path(forResource: code, ofType: "lproj"),
                                 "the app carries no \(code) bundle")
        return try XCTUnwrap(Bundle(path: path))
    }

    private func en(_ note: String) -> String { RunNoteWording.interfaceText(note, bundle: Self.english) }

    private static func hasCyrillic(_ s: String) -> Bool {
        s.unicodeScalars.contains { (0x0400...0x04FF).contains($0.value) }
    }

    // MARK: - What the engine writes

    /// One of every sentence the engine puts into a run's notes, with Latin text wherever the
    /// engine fills something in, so that any Cyrillic left in the English is the engine's own.
    static let engineSentences: [String] = [
        // pipeline.sh
        "Пайплайн «full-cycle» не знайдено",
        "Опис пайплайна «full-cycle» не проходить перевірку",
        "Тріаж: не потрібен для цієї задачі",
        "Тріаж: не потрібен для цієї задачі — The requirements are concrete.",
        "Повідомлення забрано",
        "Продовження відкритої задачі",
        "Обов'язковий крок «Triage» не вдався — повідомлення затримано, виконавець його не отримав",
        "Обов'язковий крок «Context», «Triage» не вдався — повідомлення затримано, виконавець його не отримав",
        "Обов'язковий крок context не вдався",
        "Обов'язковий крок position position-2 не вдався",
        "Підготовку завершено",
        // pipeline-deliver.sh
        "Сесія підтвердила, що отримала бриф",
        "Бриф не дійшов — він у черзі повторної доставки",
        // review-gate.sh
        "Виконавець зупинився — ворота перевіряють",
        "Шматок 2 «Sign-in» прийнято — далі «Feed»",
        "Шматок 2 «Sign-in» прийнято. Ти надіслав нову задачу — беруся за неї замість «Feed»",
        "Прийнято",
        "Прийнято із зауваженнями",
        "Рев'ю зупинилось — потрібне твоє рішення",
        "Прийнято рецензентом, але не все закомічено: app server",
        "Передав агентові твоє уточнення — рев'ю після того, як він його врахує",
        "Агент чекає на своїх фонових помічників — перевірки почнуться після них",
        "Нема ні змін, ні заявленого результату — попросив заявити",
        "Вікно Claude вичерпано — продовжить, коли повернеться",
        "Чекає на Codex — без нього роботу не прийнято",
        "Не можу перевірити: транскрипт сесії недоступний",
        "Немає виклику: humanizer — потрібне твоє рішення",
        "Немає виклику: humanizer — роботу повернуто",
        "Скіл викликано: humanizer",
        "Звіту не знайдено",
        "Звіту не знайдено — попросив назвати шлях",
        "Рецензент звіту недоступний — чекаю",
        "Рецензент звіту недоступний — чекаю (rate limited)",
        "Звіт повернуто · зауважень: 3",
        "Агент зупинився, але роботу не здав (no commit) — повернув без перевірок",
        "Збірка й перевірки пройшли",
        "Збірка або перевірки не пройшли — рецензент це побачить",
        "Перевірку збіркою вимкнено",
        "Нічого зібрати чи протестувати (inconclusive)",
        "Незалежні перевірки пропущено: збірка червона",
        "Незалежні перевірки вже були — їхні знахідки йдуть Codex",
        "Незалежні перевірки Claude: код і безпека",
        "Незалежна перевірка не відпрацювала: security",
        "Незалежна перевірка не відпрацювала: security — далі Codex",
        "Незалежні перевірки знайшли 2 — повернуто виконавцю",
        "Незалежним перевіркам нічого перевіряти: diff порожній",
        "Незалежні перевірки: нічого, що треба повертати",
        "Рецензент недоступний — exit 1",
        "Віддав хід — попросив працювати далі",
        "Повернуто на виправлення",
        "Повернуто на доопрацювання · зауважень: 2",
        "Без git і без коду — перевіряти нічого, лишається те, що прогін заявив",
        "Codex зупинив рев'ю: потрібне твоє рішення",
        "Codex зупинив рев'ю: The access token is missing.",
        "Виконавець кілька разів поспіль віддав хід — потрібне твоє рішення",
        "Робота прийнята із зауваженням: перевірку зупинив сам інструмент перевірки, а не робота — sandbox denied",
        "Перевірка 3 рази поспіль упиралась у сам інструмент перевірки, а не в роботу: sandbox denied",
        "codex не запустився: CLI відхилив сам виклик (код 2). Це не недоступність рецензента, очікування цього не виправить — потрібне оновлення CLI або рушія.",
        "codex не запустився: CLI відхилив сам виклик (код 2) — unknown flag. Це не недоступність рецензента, очікування цього не виправить — потрібне оновлення CLI або рушія. Повний лог: /tmp/i/review-stderr.log",
        "codex не запустився: CLI відхилив сам виклик (код 2). Це не недоступність рецензента, очікування цього не виправить — потрібне оновлення CLI або рушія. Повний лог: /tmp/i/review-stderr.log",
        // supervisor-lib.sh
        "Codex недоступний понад 12 год (rate limit) — задачу зупинено без його ревʼю; робота лишилась у гілці.",
        "Фінальне ревʼю не проводилось. Без Codex: фінальне ревʼю — limit",
        "Фінальне ревʼю виконав Claude замість Codex. Без Codex: підготовка ×2 — limit; звірка позицій",
        "Codex брав участь не в усьому. Без Codex: консультація; частина Codex; питання воркера; фінальне ревʼю; і ще 2",
        // A verdict with Codex's participation after it, as `mark_done` joins them.
        "Прийнято — Фінальне ревʼю виконав Claude замість Codex. Без Codex: фінальне ревʼю — limit",
        "Codex зупинив рев'ю: потрібне твоє рішення — Codex брав участь не в усьому. Без Codex: підготовка",
    ]

    func testTheContinuedTaskOnTheScreenshotReadsInEnglish() {
        XCTAssertEqual(en("Продовження відкритої задачі"), "Continuing an open task")
        XCTAssertEqual(en("Сесія підтвердила, що отримала бриф"), "The session confirmed it received the brief")
    }

    func testEverySentenceOfTheEngineReadsInEnglish() {
        for note in Self.engineSentences {
            let said = en(note)
            XCTAssertFalse(Self.hasCyrillic(said), "left in Ukrainian: «\(note)» → «\(said)»")
        }
    }

    /// The Ukrainian interface says what it always said: the engine's own words, letter for letter.
    func testUkrainianSaysTheEnginesOwnWords() throws {
        let uk = try language("uk")
        for note in Self.engineSentences {
            XCTAssertEqual(RunNoteWording.interfaceText(note, bundle: uk), note)
        }
    }

    func testRussianIsRussian() throws {
        let ru = try language("ru")
        let ukrainianOnly = CharacterSet(charactersIn: "іїєґІЇЄҐʼ'")
        for note in Self.engineSentences {
            let said = RunNoteWording.interfaceText(note, bundle: ru)
            XCTAssertNotEqual(said, note, "ru left «\(note)» as the engine wrote it")
            XCTAssertNil(said.rangeOfCharacter(from: ukrainianOnly), "ru: «\(note)» → «\(said)»")
        }
    }

    // MARK: - What is not the engine's

    func testWhatWasPutIntoASentenceIsCarriedOverAsWritten() {
        XCTAssertEqual(en("Тріаж: не потрібен для цієї задачі — Вимоги конкретні й перевірювані."),
                       "Triage: not needed for this task — Вимоги конкретні й перевірювані.")
        XCTAssertEqual(en("Рецензент недоступний — тайм-аут"), "The reviewer is unavailable — тайм-аут")
        XCTAssertEqual(en("Обов'язковий крок «Тріаж» не вдався"), "Required step “Тріаж” failed")
        XCTAssertEqual(en("Codex зупинив рев'ю: потрібне твоє рішення"), "Codex stopped the review: your decision is needed")
        XCTAssertEqual(en("Фінальне ревʼю виконав Claude замість Codex. Без Codex: підготовка ×2 — ліміт; і ще 3"),
                       "Claude did the final review instead of Codex. Without Codex: preparation ×2 — ліміт; and 3 more")
    }

    /// The worker's summary, a reviewer's sentence, anything else: shown as it is, never guessed at.
    func testANoteThatIsNotTheEnginesIsShownAsItIs() {
        for note in ["Картка «Глиняна чашка» / 450 грн / «Купити» в main.shelf",
                     "Прийнято, але ...", "Fixed the login form", ""] {
            XCTAssertEqual(en(note), note)
        }
    }

    // MARK: - The run itself

    /// The screenshot's run: a follow-up message skips the positions and the agreement, and the
    /// worker confirms the brief. The journal keeps the engine's words; the view says them in English.
    func testAContinuedRunKeepsTheJournalAndShowsTheInterfaceLanguage() {
        let mid = "M1"
        let lines = """
        {"ms": 1, "message_id": "M1", "stage": "pipeline", "state": "running", "stages": [{"id": "position", "node": "position"}, {"id": "align", "node": "align"}, {"id": "claude", "node": "claude"}]}
        {"ms": 2, "message_id": "M1", "stage": "position", "state": "skipped", "note": "Продовження відкритої задачі", "node": "position", "reason": "followup"}
        {"ms": 3, "message_id": "M1", "stage": "align", "state": "skipped", "note": "Продовження відкритої задачі", "node": "align", "reason": "followup"}
        {"ms": 4, "message_id": "M1", "stage": "claude", "state": "delivered", "note": "Сесія підтвердила, що отримала бриф", "node_role": "agent"}
        {"ms": 5, "message_id": "M2", "stage": "position", "state": "skipped", "note": "Тріаж: не потрібен для цієї задачі", "node": "position", "reason": "triage"}
        """
        let events = RunEvent.parse(lines: lines.split(separator: "\n"))
        let g = RunReducer.reduce(events: events, messageID: mid, document: nil)
        XCTAssertEqual(g.status("position").note, "Продовження відкритої задачі", "the journal keeps the engine's words")
        XCTAssertEqual(en(g.status("position").note ?? ""), "Continuing an open task")
        XCTAssertEqual(en(g.status("align").note ?? ""), "Continuing an open task", "another run's note does not reach this one")
        XCTAssertEqual(en(g.status("claude").note ?? ""), "The session confirmed it received the brief")
    }

    /// The run on the screenshot, drawn: «Claude + Codex», a message that continues an open task.
    /// Set `BULAVA_RENDER_DIR` to keep the picture.
    @MainActor
    func testTheContinuedRunIsDrawnInOneLanguage() throws {
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let manifest = repo.appendingPathComponent("engine/supervisor/pipelines/manifests/adaptive-peer/pipeline.json")
        try XCTSkipUnless(FileManager.default.fileExists(atPath: manifest.path), "no checkout beside the tests")
        let doc = try JSONDecoder().decode(PipelineDocument.self, from: Data(contentsOf: manifest))
        let journal = """
        {"ms": 1792531963885, "message_id": "M", "stage": "pipeline", "state": "running", "stages": [{"id": "context", "node": "context"}, {"id": "peer-claude", "node": "peer-claude", "group": "peers"}, {"id": "peer-codex", "node": "peer-codex", "group": "peers"}, {"id": "align", "node": "align"}, {"id": "compose", "node": "compose"}, {"id": "deliver", "node": "deliver"}]}
        {"ms": 1792531964000, "message_id": "M", "stage": "context", "state": "done", "node": "context"}
        {"ms": 1792531964100, "message_id": "M", "stage": "peer-claude", "state": "skipped", "note": "Продовження відкритої задачі", "node": "peer-claude", "reason": "followup"}
        {"ms": 1792531964200, "message_id": "M", "stage": "peer-codex", "state": "skipped", "note": "Продовження відкритої задачі", "node": "peer-codex", "reason": "followup"}
        {"ms": 1792531964300, "message_id": "M", "stage": "align", "state": "skipped", "note": "Продовження відкритої задачі", "node": "align", "reason": "followup"}
        {"ms": 1792531964400, "message_id": "M", "stage": "compose", "state": "done", "node": "compose"}
        {"ms": 1792531964500, "message_id": "M", "stage": "deliver", "state": "running", "node": "deliver"}
        {"ms": 1792531970000, "message_id": "M", "stage": "deliver", "state": "delivered", "note": "Сесія підтвердила, що отримала бриф", "node_role": "agent"}
        {"ms": 1792531970100, "message_id": "M", "stage": "pipeline", "state": "done", "note": "Підготовку завершено"}
        """
        let g = RunReducer.reduce(events: RunEvent.parse(lines: journal.split(separator: "\n")), messageID: "M", document: doc)
        XCTAssertEqual(g.status("peer-claude").state, .skipped)
        XCTAssertEqual(g.status("deliver").state, .running)
        let view = RunGraphView(run: ChatRun(graph: g, document: doc), registry: nil, live: false)
            .frame(width: 360).padding(12).background(Palette.content)
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        let image = try XCTUnwrap(renderer.nsImage)
        if let out = ProcessInfo.processInfo.environment["BULAVA_RENDER_DIR"],
           let tiff = image.tiffRepresentation,
           let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
            try png.write(to: URL(fileURLWithPath: out).appendingPathComponent("continued-run-graph.png"))
        }
    }

    // MARK: - The engine and the interface stay together

    /// Every sentence the engine's scripts journal into a run, read from the scripts themselves:
    /// a new sentence there that the interface cannot say fails here, not on somebody's screen.
    func testEverySentenceInTheEnginesScriptsHasInterfaceWords() throws {
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let scripts = ["engine/bin/pipeline.sh", "engine/bin/pipeline-deliver.sh", "engine/hooks/review-gate.sh"]
        var seen = 0
        for script in scripts {
            let url = repo.appendingPathComponent(script)
            try XCTSkipUnless(FileManager.default.fileExists(atPath: url.path), "no checkout beside the tests")
            let text = try String(contentsOf: url, encoding: .utf8)
            for line in text.split(separator: "\n") {
                let code = line.drop { $0 == " " || $0 == "\t" }
                guard !code.hasPrefix("#"),
                      code.range(of: #"(^|[\s;&|{(])(run_event|gate_event|mark_done)\s"#, options: .regularExpression) != nil,
                      let literal = Self.quotedStrings(in: code).first(where: Self.hasCyrillic)
                else { continue }
                seen += 1
                let sample = Self.expand(literal)
                let said = en(sample)
                XCTAssertFalse(Self.hasCyrillic(said), "\(script): «\(sample)» → «\(said)»")
            }
        }
        XCTAssertGreaterThan(seen, 30, "the scan found the engine's sentences")
    }

    /// The double-quoted strings of a shell line, `$(…)` and `${…}` inside them kept whole.
    private static func quotedStrings(in line: Substring) -> [String] {
        var out: [String] = []
        var i = line.startIndex
        while i < line.endIndex {
            guard line[i] == "\"" else { i = line.index(after: i); continue }
            var j = line.index(after: i)
            var depth = 0
            var body = ""
            while j < line.endIndex {
                let c = line[j]
                if c == "\\", line.index(after: j) < line.endIndex {
                    body.append(c); body.append(line[line.index(after: j)]); j = line.index(j, offsetBy: 2); continue
                }
                if c == "$", line.index(after: j) < line.endIndex, "({".contains(line[line.index(after: j)]) {
                    depth += 1; body.append(c); body.append(line[line.index(after: j)]); j = line.index(j, offsetBy: 2); continue
                }
                if depth > 0, c == ")" || c == "}" { depth -= 1 }
                if depth == 0, c == "\"" { break }
                body.append(c)
                j = line.index(after: j)
            }
            out.append(body)
            i = j < line.endIndex ? line.index(after: j) : j
        }
        return out
    }

    /// What the engine puts in a variable when that is one of its own sentences, not a free one.
    private static let samples = [
        "_cpn": "Codex брав участь не в усьому. Без Codex: підготовка",  // codex_participation_note
    ]

    /// A shell word with every expansion filled in: a variable or a command is «S» (or its sample),
    /// `${x:+word}` is the word, `${x:-word}` is the default.
    private static func expand(_ s: String) -> String {
        var out = ""
        var i = s.startIndex
        while i < s.endIndex {
            let c = s[i]
            let next = s.index(after: i)
            guard c == "$", next < s.endIndex else { out.append(c); i = next; continue }
            let open = s[next]
            if open == "{" || open == "(" {
                let close: Character = open == "{" ? "}" : ")"
                var depth = 1
                var j = s.index(after: next)
                while j < s.endIndex {
                    if s[j] == open { depth += 1 }
                    if s[j] == close { depth -= 1; if depth == 0 { break } }
                    j = s.index(after: j)
                }
                let inner = String(s[s.index(after: next)..<min(j, s.endIndex)])
                if open == "{", let r = inner.range(of: ":+") ?? inner.range(of: ":-") {
                    out += expand(String(inner[r.upperBound...]))
                } else {
                    out += open == "{" ? samples[inner] ?? "S" : "S"
                }
                i = j < s.endIndex ? s.index(after: j) : j
            } else if open == "_" || (open.isASCII && (open.isLetter || open.isNumber)) {
                var j = next
                while j < s.endIndex, s[j] == "_" || (s[j].isASCII && (s[j].isLetter || s[j].isNumber)) { j = s.index(after: j) }
                out += samples[String(s[next..<j])] ?? "S"
                i = j
            } else {
                out.append(c); i = next
            }
        }
        return out
    }
}
