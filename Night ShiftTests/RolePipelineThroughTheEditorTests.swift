import XCTest
@testable import Bulava

/// The role pipeline the owner asked for, made with the editor's own operations — "New pipeline",
/// "Add step", a step's name, its model, "Required step", its own prompt, a drag from an output to an
/// input — saved and checked the way the editor does it. Off unless asked for
/// (`BULAVA_CREATE_ROLE_PIPELINE=1`): it writes a pipeline into the library this build uses.
nonisolated final class RolePipelineThroughTheEditorTests: XCTestCase {

    static let name = "Повний цикл"

    @MainActor
    func testMakeTheRolePipelineThroughTheEditor() async throws {
        let env = ProcessInfo.processInfo.environment
        guard env["BULAVA_CREATE_ROLE_PIPELINE"] == "1" || env["TEST_RUNNER_BULAVA_CREATE_ROLE_PIPELINE"] == "1" else {
            throw XCTSkip("making a pipeline in the library was not asked for")
        }
        let model = AppModel()
        await model.loadPipelineLibrary()
        let registry = try XCTUnwrap(model.pipelineRegistry, "the engine's palette")
        if let old = model.pipelineLibrary.first(where: { $0.displayName == Self.name }) {
            _ = await model.deletePipeline(old.id)
        }

        // "New pipeline" → the name sheet → `finish`.
        let created = await model.createPipeline(name: Self.name)
        guard case .success(let pid) = created else { return XCTFail("could not create: \(created)") }

        let state = PipelineEditorState(id: pid)
        await state.load(model)
        XCTAssertNotNil(state.doc)

        // "Add step" from the palette, exactly as the canvas does it.
        var column = 0.0
        func add(_ key: String, _ title: String, row: Double, params: [String: JSONValue] = [:], prompt: String? = nil) throws -> String {
            let spec = try XCTUnwrap(registry.modules[key], key)
            let doc = try XCTUnwrap(state.doc)
            let nid = doc.freeNodeID(for: key)
            var p: [String: JSONValue] = [:]
            for s in spec.p ?? [] { if let d = s.default { p[s.k] = d } }
            for (k, v) in params { p[k] = v }
            state.edit { $0.nodes.append(PipelineNode(id: nid, module: "bulava/\(key)@1", params: p.isEmpty ? nil : p,
                                                       x: 24 + column * 220, y: 40 + row * 150)) }
            state.edit(coalescing: "title:" + nid) { $0.setTitle(title, of: nid) }
            if let prompt {
                state.edit(coalescing: "prompt:" + nid) { d in
                    if let i = d.nodes.firstIndex(where: { $0.id == nid }) { d.nodes[i].prompt = prompt }
                }
            }
            return nid
        }
        // A drag from an output dot to an input dot, with the canvas's own rule for the review loop.
        func connect(_ from: String, _ out: String, _ to: String, _ inPort: String) {
            let edge = PipelineEdge(from: "\(from).\(out)", to: "\(to).\(inPort)",
                                    loop: out == "fail" && inPort == "feedback" ? PipelineLoop(max: registry.reviewDefault) : nil)
            state.edit { d in
                guard !d.edges.contains(where: { $0.from == edge.from && $0.to == edge.to }) else { return }
                d.edges.append(edge)
            }
        }
        let required: [String: JSONValue] = ["required": .bool(true)]

        column = 1; let context = try add("prep.context", "Контекст задачі", row: 0)
        let triage = try add("prep.classify", "Тріаж", row: 1)
        column = 2
        let ba = try add("prep.position", "Бізнес-аналітик", row: 0, params: required.merging(["engine": .string("codex")]) { $1 }, prompt: Self.analyst)
        let qa = try add("prep.position", "Тестувальник", row: 1, params: required.merging(["engine": .string("claude")]) { $1 }, prompt: Self.tester)
        column = 3
        let archClaude = try add("prep.position", "Архітектор Claude", row: 0, params: required.merging(["engine": .string("claude")]) { $1 }, prompt: Self.architect)
        let archCodex = try add("prep.position", "Архітектор Codex", row: 1, params: required.merging(["engine": .string("codex")]) { $1 }, prompt: Self.architect)
        column = 4; let agree = try add("prep.align", "Домовленість", row: 0, params: required)
        column = 5; let brief = try add("prep.compose", "Бриф виконавцю", row: 0)
        column = 1; let work = try add("agent.claude", "Claude реалізує", row: 2.4)
        column = 2; let review = try add("gate.review", "Рев'ю Codex", row: 2.4)
        column = 3; let merge = try add("out.merge", "Злиття гілки", row: 2.4)

        connect("chat", "task", context, "task")
        connect("chat", "task", triage, "task")
        for role in [ba, qa] {
            connect(context, "context", role, "context")
            connect(triage, "context", role, "context")
        }
        for architect in [archClaude, archCodex] {
            connect(ba, "position", architect, "context")
            connect(qa, "position", architect, "context")
            connect(architect, "position", agree, "positions")
        }
        connect(agree, "checks", brief, "in")
        connect(brief, "brief", work, "brief")
        connect(work, "work", review, "work")
        connect(review, "pass", merge, "work")
        connect(review, "fail", work, "feedback")
        state.edit(coalescing: "description") { $0.description = Self.summary }

        await state.saveNow()
        await state.reload()
        let saved = try XCTUnwrap(state.doc)
        XCTAssertEqual(saved.nodes.count, 12, "every step is saved")
        XCTAssertEqual(saved.node(ba)?.title, "Бізнес-аналітик")
        XCTAssertEqual(saved.node(archCodex)?.params?["engine"], .string("codex"))
        let checked = await model.editorValidate(saved)
        let validation = try XCTUnwrap(checked)
        XCTAssertTrue(validation.issues.filter(\.isError).isEmpty, "it can run: \(validation.issues.map(\.msg.local))")
        await model.loadPipelineLibrary()
        XCTAssertTrue(model.pipelineLibrary.contains { $0.id == pid }, "it is in the library")
        print("ROLE PIPELINE \(pid)")
    }

    static let summary = "Спершу тріаж задачі. Потім паралельно: бізнес-аналітик (Codex) розбирає вимоги, тестувальник (Claude) пише тест-кейси. Далі два архітектори окремо — Claude і Codex — читають обидва результати й пропонують, як це зробити. Codex зводить усе в одне рішення, Claude реалізує, Codex перевіряє і може повернути."

    static let analyst = """
    Ти — бізнес-аналітик. Розбери задачу як бізнес-вимогу, а не як код.

    ЗАДАЧА
    {{TASK}}

    КОНТЕКСТ
    {{CONTEXT}}

    Прочитай репозиторій лише для розуміння, нічого не змінюй. Дай коротко:
    НАВІЩО — яку проблему людини це розв'язує і як вона зрозуміє, що задача зроблена.
    ВИМОГИ — пронумеровані, кожна перевірювана.
    ХТО І ЯК КОРИСТУЄТЬСЯ — основні сценарії, крок за кроком.
    НЕЯСНОСТІ — що в задачі можна зрозуміти двояко, і яке тлумачення ти пропонуєш.
    ПОЗА МЕЖАМИ — чого ця задача не стосується.
    """

    static let tester = """
    Ти — тестувальник. Напиши тест-кейси до задачі ще до того, як її почнуть робити.

    ЗАДАЧА
    {{TASK}}

    КОНТЕКСТ
    {{CONTEXT}}

    Прочитай репозиторій лише для розуміння, нічого не змінюй. Дай пронумерований список тест-кейсів:
    для кожного — передумова, кроки, очікуваний результат. Окремо — граничні випадки, помилки,
    збереження після перезапуску, мобільні та порожні стани, якщо вони стосуються задачі. Познач,
    які кейси можна перевірити автоматичним тестом, а які лише вручну.
    """

    static let architect = """
    Ти — архітектор. Запропонуй, як найкраще реалізувати цю задачу в цьому репозиторії.

    ЗАДАЧА
    {{TASK}}

    КОНТЕКСТ
    {{CONTEXT}}

    Нижче — результати бізнес-аналітика і тестувальника; спирайся на них. Пропозицію іншого
    архітектора ти не бачиш, і це навмисно. Прочитай репозиторій, нічого не змінюй. Дай коротко:
    РІШЕННЯ — ключові архітектурні рішення з посиланнями на файли.
    ЧОМУ ТАК — що відкинув і чому.
    ЯК ЦЕ ПРОЙДЕ ТЕСТ-КЕЙСИ — які кейси закриває яка частина рішення.
    РИЗИКИ — що може зламатися поруч.
    """
}
