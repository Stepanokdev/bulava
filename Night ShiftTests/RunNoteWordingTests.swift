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
        // preflight.sh, through `.skip-<stage>`
        "Тріаж не вибрав жодної ролі для цієї задачі — домовлятися нема про що",
        "Менше двох ролей дали результат — домовлятися нема про що",
        "Одна позиція — звіряти нічого",
        // preflight.sh, through `.unavailable-<stage>`
        "codex не отримав чого читати — підготовка не залишила тексту питання",
        "claude не запускався: підготовлений текст питання не є коректним UTF-8, і CLI відхилив би виклик ще до старту сесії. Це не збій моделі — зіпсуті байти прийшли зі збереженого контексту, і виправляти треба джерело",
        "codex не авторизований — `codex login status` каже «Not logged in», тож облікових даних для виклику немає. Потрібен повторний вхід у Codex.",
        "codex не запускався — на підготовку вже не лишалось часу",
        "codex зараз недоступний — вичерпано вікно, відновлення близько сьогодні о 14:30",
        "codex зараз недоступний — вичерпано вікно, відновлення близько завтра о 09:05",
        "claude зараз недоступний — вичерпано вікно, відновлення близько 13.11 о 18:00",
        "codex зараз недоступний — вичерпано вікно",
        "codex зараз недоступний — не вдалося прочитати його ліміти",
        "codex доступний",
        "codex замовк на 600с і не подавав ознак роботи — виклик зупинено",
        "codex завершився без помилки, але не сказав нічого",
        "codex завершився без помилки, але не сказав нічого; неповну відповідь відкинуто, бо половина позиції — не позиція",
        "claude не запускався: підготовлений текст питання не є коректним UTF-8, і CLI відхилив би виклик ще до старту сесії. Це не збій моделі — зіпсутий текст прийшов із збереженого контексту, і його треба виправити в джерелі",
        "codex зупинився з помилкою (код 1) через 42с",
        "codex зупинився з помилкою (код 1) через 42с — error: 401 Unauthorized Це не помилка коду: підписку не авторизовано (потрібен повторний вхід у Codex).; повний лог: /tmp/i/peer-codex.log",
        "codex замовк на 600с і не подавав ознак роботи — виклик зупинено — stream idle; неповну відповідь відкинуто, бо половина позиції — не позиція; повний лог: /tmp/i/peer-codex.log",
        // pipeline-codex-part.sh, through `.unavailable-<stage>`
        "Codex не авторизований — «Design» не підготовлено; Claude робить задачу повністю.",
        "Codex недоступний зараз (codex зараз недоступний — вичерпано вікно) — «Design» не підготовлено; Claude робить задачу повністю.",
        "Не вдалося записати бриф у /tmp/i/art — «Design» не підготовлено.",
        "Текст для Codex не є коректним UTF-8 — «Design» не підготовлено.",
        "Codex завершився, нічого не сказавши",
        "Codex не закінчив «Design» за 1800с",
        "Codex зупинився з помилкою (код 2) через 12с",
        "Codex відповів без патча між ===PATCH=== і ===END===",
        "Патч Codex для «Design» не накладається на поточну теку",
        "Не вдалося дописати бриф — Claude не дізнався б про патч «Design».",
        // supervisor-lib.sh
        "Codex недоступний понад 12 год (rate limit) — задачу зупинено без його ревʼю; робота лишилась у гілці.",
        "Фінальне ревʼю не проводилось. Без Codex: фінальне ревʼю — limit",
        "Фінальне ревʼю виконав Claude замість Codex. Без Codex: підготовка ×2 — limit; звірка позицій",
        "Codex брав участь не в усьому. Без Codex: консультація; частина Codex; питання воркера; фінальне ревʼю; і ще 2",
        // A verdict with Codex's participation after it, as `mark_done` joins them.
        "Прийнято — Фінальне ревʼю виконав Claude замість Codex. Без Codex: фінальне ревʼю — limit",
        "Codex зупинив рев'ю: потрібне твоє рішення — Codex брав участь не в усьому. Без Codex: підготовка",
        // A reason the tool gave, then the participation: the reason's open end must not take it.
        "Перевірка 3 рази поспіль упиралась у сам інструмент перевірки, а не в роботу: sandbox denied — Codex брав участь не в усьому. Без Codex: частина Codex — codex зараз недоступний — вичерпано вікно",
        "Перевірка 3 рази поспіль упиралась у сам інструмент перевірки, а не в роботу: sandbox denied — Фінальне ревʼю не проводилось. Без Codex: фінальне ревʼю",
        "Перевірка 3 рази поспіль упиралась у сам інструмент перевірки, а не в роботу: sandbox denied — Фінальне ревʼю виконав Claude замість Codex. Без Codex: фінальне ревʼю ×2",
        "Рецензент недоступний — codex зараз недоступний — не вдалося прочитати його ліміти",
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

    /// A tool's words are carried over as written even when they hold Cyrillic and «—»; the
    /// participation the gate adds after them is still the engine's and is said in the interface's
    /// language.
    func testAToolsReasonAndCodexsParticipationAreToldApart() throws {
        let tool = "доступ заборонено — пісочниця"
        let note = "Перевірка 3 рази поспіль упиралась у сам інструмент перевірки, а не в роботу: \(tool) — Codex брав участь не в усьому. Без Codex: підготовка"
        XCTAssertEqual(en(note),
                       "The check ran into the checking tool itself, not the work, 3 times in a row: \(tool) — Codex did not take part in everything. Without Codex: preparation")
        XCTAssertEqual(RunNoteWording.interfaceText(note, bundle: try language("uk")), note)
        let ru = RunNoteWording.interfaceText(note, bundle: try language("ru"))
        XCTAssertTrue(ru.contains(": \(tool) — "), ru)
        XCTAssertFalse(ru.contains("Codex брав участь"), ru)
    }

    func testAPeerFailureKeepsWhatTheCLISaid() {
        XCTAssertEqual(en("codex зупинився з помилкою (код 1) через 42с — помилка мережі; повний лог: /tmp/л.log"),
                       "codex stopped with an error (code 1) after 42 s — помилка мережі; full log: /tmp/л.log")
        XCTAssertEqual(en("codex зараз недоступний — вичерпано вікно, відновлення близько завтра о 09:05"),
                       "codex is unavailable now — its usage window is used up; it is back around tomorrow at 09:05")
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
        let found = try Self.engineLiterals()
        for s in found {
            let said = en(s.sample)
            XCTAssertFalse(Self.hasCyrillic(said), "\(s.script): «\(s.sample)» → «\(said)»")
        }
        XCTAssertGreaterThan(found.count, 60, "the scan found the engine's sentences")
        XCTAssertTrue(found.contains { $0.gapStage != nil && $0.script.hasSuffix("review-gate.sh") }, "the scan reads codex_gap")
    }

    /// Why a step went without Codex reaches the card inside the participation note, after the
    /// engine itself has stored it (`codex_gap`, clipped to 400 bytes) and summed it up
    /// (`codex_participation_note`). Every reason the scripts give is put through that real path,
    /// and what comes out reads in the interface's language: English and Russian with nothing of
    /// the engine's Ukrainian left, Ukrainian exactly as the engine wrote it.
    func testEveryReasonForGoingWithoutCodexReadsThroughTheRealSummary() throws {
        let repo = Self.repo
        let uk = try language("uk"), ru = try language("ru")
        let ukrainianOnly = CharacterSet(charactersIn: "іїєґІЇЄҐʼ'")
        var checked = 0
        for s in try Self.engineLiterals() {
            guard let stage = s.gapStage else { continue }
            let note = try Self.participationNote(stage: stage, reason: s.sample, repo: repo)
            XCTAssertTrue(note.hasPrefix("Codex брав участь не в усьому. Без Codex: ") || note.hasPrefix("Фінальне ревʼю"), note)
            checked += 1
            let english = en(note)
            XCTAssertFalse(Self.hasCyrillic(english), "\(s.script) (\(stage)): «\(note)» → «\(english)»")
            XCTAssertEqual(RunNoteWording.interfaceText(note, bundle: uk), note, "\(s.script) (\(stage))")
            let russian = RunNoteWording.interfaceText(note, bundle: ru)
            XCTAssertNil(russian.rangeOfCharacter(from: ukrainianOnly), "ru: «\(note)» → «\(russian)»")
        }
        XCTAssertGreaterThan(checked, 25, "the reasons were put through the engine")
    }

    /// A reason with «; » of its own stays one step, and the steps after it are still steps.
    func testAReasonWithASemicolonStaysOneStep() {
        let note = "Codex брав участь не в усьому. Без Codex: консультація ×2 — Codex не авторизований — `codex login status` каже «Not logged in», тож викликати нема чим — облікових даних просто немає. Потрібен повторний вхід у Codex; лічильник цього не бачить; звірка позицій — Codex не звірив дві позиції — Claude працює за своєю"
        XCTAssertEqual(en(note), "Codex did not take part in everything. Without Codex: consultation ×2 — Codex is not signed in — `codex login status` says “Not logged in”, so there is nothing to call it with — there are simply no credentials. …; aligning the positions — Codex did not compare the two positions — Claude works from its own")
    }

    // MARK: - Reading the engine

    private static let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()

    /// One sentence the engine writes, as a sample with its blanks filled; `gapStage` when it also
    /// becomes a reason Codex was missing from that step.
    struct EngineLiteral { let script: String; let sample: String; let gapStage: String? }

    /// The journal's own writers, the ones whose words reach it through a file the pipeline
    /// journals (`.skip-<stage>`, `.unavailable-<stage>`), and every reason given to `codex_gap`
    /// directly or through the variable it is handed.
    static func engineLiterals() throws -> [EngineLiteral] {
        // script → the stage `codex_gap` files its unavailable/failed reasons under
        let scripts: [(String, String?)] = [
            ("engine/bin/pipeline.sh", nil), ("engine/bin/pipeline-deliver.sh", nil), ("engine/hooks/review-gate.sh", nil),
            ("engine/bin/preflight.sh", "preflight"), ("engine/bin/pipeline-codex-part.sh", "part"),
            ("engine/bin/consult-codex.sh", "consultation"), ("engine/hooks/answer-question.sh", "question"),
        ]
        let writer = try! NSRegularExpression(pattern:
            #"(^|[\s;&|{(])(run_event|gate_event|mark_done|stage_skip_note|peer_unavailable|unavailable|decline|codex_gap)\s"#)
        let gapCall = try! NSRegularExpression(pattern: #"codex_gap\s+"[^"]*"\s+([a-z]+)\s"#)
        // A reason assigned before it is handed on: a case arm, or a sentence of its own.
        let assigned = try! NSRegularExpression(pattern: #"^(?:[0-9*]+\)\s+(?:status=\S+;\s+)?)?(?:reason|_why_degraded)="[^$]"#)
        var out: [EngineLiteral] = []
        for (script, stage) in scripts {
            let url = repo.appendingPathComponent(script)
            guard FileManager.default.fileExists(atPath: url.path) else { throw XCTSkip("no checkout beside the tests") }
            // A call continued on the next line is one call.
            let text = try String(contentsOf: url, encoding: .utf8).replacingOccurrences(of: "\\\n", with: " ")
            for line in text.split(separator: "\n") {
                let code = String(line.drop { $0 == " " || $0 == "\t" })
                let whole = NSRange(code.startIndex..., in: code)
                guard !code.hasPrefix("#") else { continue }
                let writes = writer.firstMatch(in: code, range: whole) != nil
                // Only where such a reason goes on to `codex_gap`: the gate's own `reason=` is what
                // it tells the worker, never a note of the run.
                let isReason = stage != nil && assigned.firstMatch(in: code, range: whole) != nil
                guard writes || isReason,
                      let literal = quotedStrings(in: Substring(code)).first(where: hasCyrillic)
                else { continue }
                let fn = writer.firstMatch(in: code, range: whole).flatMap { Range($0.range(at: 2), in: code) }.map { String(code[$0]) }
                var gap: String?
                if let m = gapCall.firstMatch(in: code, range: whole), let r = Range(m.range(at: 1), in: code) {
                    gap = String(code[r])
                } else if isReason || ["peer_unavailable", "unavailable", "decline"].contains(fn ?? "") {
                    gap = stage
                }
                out.append(EngineLiteral(script: script, sample: expand(literal), gapStage: gap))
            }
        }
        return out
    }

    /// The participation note the engine itself writes after `codex_gap <stage> <reason>`.
    private static func participationNote(stage: String, reason: String, repo: URL) throws -> String {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("gap-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/bash")
        // The reason goes through the environment: an argument is handed over decomposed, and the
        // engine never sees its own sentences that way.
        p.arguments = ["-c", #"source "$0" >/dev/null 2>&1; codex_gap "$1" "$2" "$GAP_REASON" && codex_participation_note "$(codex_participation "$1")""#,
                       repo.appendingPathComponent("engine/bin/supervisor-lib.sh").path, dir.path, stage]
        p.environment = ProcessInfo.processInfo.environment.merging(["GAP_REASON": reason]) { $1 }
        let pipe = Pipe()
        p.standardOutput = pipe
        try p.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// `supervisor-lib.sh` builds two sentences the run's notes carry: what a spent window says
    /// (`provider_unavailable_note`) and which steps went without Codex (`codex_participation_note`).
    /// Their words are read from the functions themselves.
    func testTheLibrarysSentencesHaveInterfaceWords() throws {
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let url = repo.appendingPathComponent("engine/bin/supervisor-lib.sh")
        try XCTSkipUnless(FileManager.default.fileExists(atPath: url.path), "no checkout beside the tests")
        let text = try String(contentsOf: url, encoding: .utf8)

        let provider = try XCTUnwrap(Self.body(of: "provider_unavailable_note", in: text))
        var said = 0
        for format in Self.matches(#"printf '([^']*)'"#, in: provider) where Self.hasCyrillic(format) {
            var note = format
            for fill in ["codex", "сьогодні о 14:30"] {
                if let r = note.range(of: "%s") { note.replaceSubrange(r, with: fill) }
            }
            said += 1
            XCTAssertFalse(Self.hasCyrillic(en(note)), "provider_unavailable_note: «\(note)» → «\(en(note))»")
        }
        XCTAssertGreaterThanOrEqual(said, 3, "the scan found provider_unavailable_note's sentences")

        let participation = try XCTUnwrap(Self.body(of: "codex_participation_note", in: text))
        let openings = Self.matches(#""([^"]+\. )""#, in: participation)
        let stages = Self.matches(#"[a-z]+:"([^"]+)""#, in: participation)
        XCTAssertEqual(openings.count, 3, "the participation's openings")
        XCTAssertEqual(stages.count, 6, "the participation's stages")
        for opening in openings {
            let note = opening + "Без Codex: " + stages.joined(separator: "; ")
            XCTAssertFalse(Self.hasCyrillic(en(note)), "codex_participation_note: «\(note)» → «\(en(note))»")
        }
    }

    /// The lines of a shell function, from its `name() {` to the first `}` at the start of a line.
    private static func body(of function: String, in text: String) -> String? {
        guard let start = text.range(of: "\n\(function)() {") else { return nil }
        let rest = text[start.upperBound...]
        guard let end = rest.range(of: "\n}") else { return nil }
        return String(rest[..<end.lowerBound])
    }

    private static func matches(_ pattern: String, in text: String) -> [String] {
        let regex = try! NSRegularExpression(pattern: pattern)
        return regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap {
            Range($0.range(at: 1), in: text).map { String(text[$0]) }
        }
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
        "_why_degraded": "запит до Codex не повернув відповіді",
        // Numbers the engine fills in before a «с» of seconds.
        "PEER_IDLE_FOR": "600", "elapsed": "42", "TIMEOUT": "1800",
    ]

    /// A shell word with every expansion filled in: a variable or a command is «S» (or its sample),
    /// `${x:+word}` is the word, `${x:-word}` is the default.
    private static func expand(_ s: String) -> String {
        var out = ""
        var i = s.startIndex
        while i < s.endIndex {
            let c = s[i]
            let next = s.index(after: i)
            // An escaped character is the character itself: «\`codex login status\`».
            if c == "\\", next < s.endIndex { out.append(s[next]); i = s.index(after: next); continue }
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
