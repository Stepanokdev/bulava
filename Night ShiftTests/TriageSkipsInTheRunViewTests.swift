import XCTest
import SwiftUI
@testable import Bulava

/// A real run of «Повний цикл» (21 Oct, debug Bulava of this tree, real Claude and Codex): the
/// triage left the analyst and both architects out and called the designer. These are that run's
/// own journal lines and the pipeline it ran, and the chat's run view must say exactly that —
/// three steps skipped by the triage, with its reasons, and Codex's part done before Claude.
nonisolated final class TriageSkipsInTheRunViewTests: XCTestCase {
    private let mid = "F499CDA9-72B2-454E-B248-43E5F9D27137"

    private let journal = #"""
{"v": 1, "ms": 1792531963885, "message_id": "F499CDA9-72B2-454E-B248-43E5F9D27137", "pipeline": "povnij-cikl", "stage": "pipeline", "state": "running", "kind": "manifest", "snapshot": "/tmp/art", "revision": 3, "stages": [{"id": "context", "node": "context", "group": null, "optional": false}, {"id": "position", "node": "position", "group": "peers-2", "optional": false}, {"id": "position-2", "node": "position-2", "group": "peers-2", "optional": false}, {"id": "position-3", "node": "position-3", "group": "peers-3", "optional": false}, {"id": "position-4", "node": "position-4", "group": "peers-3", "optional": false}, {"id": "align", "node": "align", "group": null, "optional": false}, {"id": "compose", "node": "compose", "group": null, "optional": false}, {"id": "design", "node": "design", "group": null, "optional": true}, {"id": "claude", "node": "claude", "group": null, "optional": false}]}
{"v": 1, "ms": 1792531964200, "message_id": "F499CDA9-72B2-454E-B248-43E5F9D27137", "pipeline": "povnij-cikl", "stage": "context", "state": "running", "node": "context"}
{"v": 1, "ms": 1792532024155, "message_id": "F499CDA9-72B2-454E-B248-43E5F9D27137", "pipeline": "povnij-cikl", "stage": "context", "state": "done", "node": "context", "ms_taken": 59904}
{"v": 1, "ms": 1792532024239, "message_id": "F499CDA9-72B2-454E-B248-43E5F9D27137", "pipeline": "povnij-cikl", "stage": "position", "state": "skipped", "note": "Тріаж: не потрібен для цієї задачі — Вимоги конкретні й перевірювані, тому окремий бізнес-аналіз не потрібен.", "node": "position", "reason": "triage"}
{"v": 1, "ms": 1792532024314, "message_id": "F499CDA9-72B2-454E-B248-43E5F9D27137", "pipeline": "povnij-cikl", "stage": "position-2", "state": "running", "node": "position-2"}
{"v": 1, "ms": 1792532074728, "message_id": "F499CDA9-72B2-454E-B248-43E5F9D27137", "pipeline": "povnij-cikl", "stage": "position-2", "state": "done", "node": "position-2", "ms_taken": 50376}
{"v": 1, "ms": 1792532074801, "message_id": "F499CDA9-72B2-454E-B248-43E5F9D27137", "pipeline": "povnij-cikl", "stage": "position-3", "state": "skipped", "note": "Тріаж: не потрібен для цієї задачі — Додавання картки та тесту не потребує архітектурних рішень.", "node": "position-3", "reason": "triage"}
{"v": 1, "ms": 1792532074864, "message_id": "F499CDA9-72B2-454E-B248-43E5F9D27137", "pipeline": "povnij-cikl", "stage": "position-4", "state": "skipped", "note": "Тріаж: не потрібен для цієї задачі — Локальні зміни HTML, стилів і тесту не виправдовують окремого архітектурного кроку.", "node": "position-4", "reason": "triage"}
{"v": 1, "ms": 1792532074942, "message_id": "F499CDA9-72B2-454E-B248-43E5F9D27137", "pipeline": "povnij-cikl", "stage": "align", "state": "running", "node": "align"}
{"v": 1, "ms": 1792532120309, "message_id": "F499CDA9-72B2-454E-B248-43E5F9D27137", "pipeline": "povnij-cikl", "stage": "align", "state": "done", "node": "align", "ms_taken": 45331}
{"v": 1, "ms": 1792532120387, "message_id": "F499CDA9-72B2-454E-B248-43E5F9D27137", "pipeline": "povnij-cikl", "stage": "compose", "state": "running", "node": "compose"}
{"v": 1, "ms": 1792532120554, "message_id": "F499CDA9-72B2-454E-B248-43E5F9D27137", "pipeline": "povnij-cikl", "stage": "compose", "state": "done", "node": "compose", "ms_taken": 129}
{"v": 1, "ms": 1792532120628, "message_id": "F499CDA9-72B2-454E-B248-43E5F9D27137", "pipeline": "povnij-cikl", "stage": "design", "state": "running", "node": "design"}
{"v": 1, "ms": 1792532163718, "message_id": "F499CDA9-72B2-454E-B248-43E5F9D27137", "pipeline": "povnij-cikl", "stage": "design", "state": "done", "node": "design", "ms_taken": 43046}
{"v": 1, "ms": 1792532163823, "message_id": "F499CDA9-72B2-454E-B248-43E5F9D27137", "pipeline": "povnij-cikl", "stage": "claude", "state": "running", "node": "claude"}
{"v": 1, "ms": 1792532170873, "message_id": "F499CDA9-72B2-454E-B248-43E5F9D27137", "pipeline": "povnij-cikl", "stage": "claude", "state": "delivered", "note": "Сесія підтвердила, що отримала бриф", "node_role": "agent"}
{"v": 1, "ms": 1792532171046, "message_id": "F499CDA9-72B2-454E-B248-43E5F9D27137", "pipeline": "povnij-cikl", "stage": "claude", "state": "done", "node": "claude", "ms_taken": 7178}
{"v": 1, "ms": 1792532171088, "message_id": "F499CDA9-72B2-454E-B248-43E5F9D27137", "pipeline": "povnij-cikl", "stage": "pipeline", "state": "done", "note": "Підготовку завершено"}
{"v": 1, "ms": 1792532438069, "message_id": "F499CDA9-72B2-454E-B248-43E5F9D27137", "pipeline": "povnij-cikl", "stage": "outcome", "state": "declared", "note": "Картка «Глиняна чашка» / 450 грн / «Купити» в main.shelf на токенах style.css (додано --space-2/4/6 без зміни відступів сторінки); у патчі Codex виправлено фокус-обвідку, що налазила на ціну; тест перевіряє вкладеність і точний текст, ловить 7 мутацій; перевірено в браузері на 320/375/414/1280px", "result": "succeeded_changes"}
{"v": 1, "ms": 1792532452205, "message_id": "F499CDA9-72B2-454E-B248-43E5F9D27137", "pipeline": "povnij-cikl", "stage": "gate", "state": "running", "note": "Виконавець зупинився — ворота перевіряють"}
{"v": 1, "ms": 1792532453690, "message_id": "F499CDA9-72B2-454E-B248-43E5F9D27137", "pipeline": "povnij-cikl", "stage": "gate.scope", "state": "done"}
{"v": 1, "ms": 1792532453733, "message_id": "F499CDA9-72B2-454E-B248-43E5F9D27137", "pipeline": "povnij-cikl", "stage": "gate.verify", "state": "running"}
{"v": 1, "ms": 1792532454181, "message_id": "F499CDA9-72B2-454E-B248-43E5F9D27137", "pipeline": "povnij-cikl", "stage": "gate.verify", "state": "done", "note": "Нічого зібрати чи протестувати (inconclusive)"}
{"v": 1, "ms": 1792532454242, "message_id": "F499CDA9-72B2-454E-B248-43E5F9D27137", "pipeline": "povnij-cikl", "stage": "gate.review", "state": "running", "round": 1, "max": 3}
{"v": 1, "ms": 1792532486780, "message_id": "F499CDA9-72B2-454E-B248-43E5F9D27137", "pipeline": "povnij-cikl", "stage": "gate.review", "state": "retrying", "note": "Повернуто на доопрацювання · зауважень: 2", "round": 1, "max": 3, "findings": 2}
{"v": 1, "ms": 1792532698894, "message_id": "F499CDA9-72B2-454E-B248-43E5F9D27137", "pipeline": "povnij-cikl", "stage": "gate", "state": "running", "note": "Виконавець зупинився — ворота перевіряють"}
{"v": 1, "ms": 1792532700802, "message_id": "F499CDA9-72B2-454E-B248-43E5F9D27137", "pipeline": "povnij-cikl", "stage": "gate.scope", "state": "done"}
{"v": 1, "ms": 1792532700834, "message_id": "F499CDA9-72B2-454E-B248-43E5F9D27137", "pipeline": "povnij-cikl", "stage": "gate.verify", "state": "running"}
{"v": 1, "ms": 1792532703890, "message_id": "F499CDA9-72B2-454E-B248-43E5F9D27137", "pipeline": "povnij-cikl", "stage": "gate.verify", "state": "done", "note": "Нічого зібрати чи протестувати (inconclusive)"}
{"v": 1, "ms": 1792532703931, "message_id": "F499CDA9-72B2-454E-B248-43E5F9D27137", "pipeline": "povnij-cikl", "stage": "gate.review", "state": "running", "round": 2, "max": 3}
{"v": 1, "ms": 1792532732519, "message_id": "F499CDA9-72B2-454E-B248-43E5F9D27137", "pipeline": "povnij-cikl", "stage": "gate.review", "state": "failed", "note": "Прийнято із зауваженнями"}
{"v": 1, "ms": 1792532732568, "message_id": "F499CDA9-72B2-454E-B248-43E5F9D27137", "pipeline": "povnij-cikl", "stage": "run", "state": "debt", "disposition": "debt"}
"""#

    private let pipeline = #"""
{"revision": 3, "edges": [{"from": "chat.task", "to": "context.task"}, {"from": "chat.task", "to": "classify.task"}, {"from": "context.context", "to": "position.context"}, {"from": "classify.context", "to": "position.context"}, {"from": "context.context", "to": "position-2.context"}, {"from": "classify.context", "to": "position-2.context"}, {"from": "position.position", "to": "position-3.context"}, {"from": "position-2.position", "to": "position-3.context"}, {"from": "position-3.position", "to": "align.positions"}, {"from": "position.position", "to": "position-4.context"}, {"from": "position-2.position", "to": "position-4.context"}, {"from": "position-4.position", "to": "align.positions"}, {"from": "align.checks", "to": "compose.in"}, {"from": "claude.work", "to": "review.work"}, {"from": "review.pass", "to": "merge.work"}, {"loop": {"max": 3}, "from": "review.fail", "to": "claude.feedback"}, {"from": "compose.brief", "to": "design.brief"}, {"from": "design.brief", "to": "claude.brief"}], "schema": "bulava.pipeline/1", "id": "povnij-cikl", "name": "Повний цикл", "nodes": [{"module": "bulava/trigger.chat@1", "id": "chat"}, {"module": "bulava/prep.context@1", "title": "Контекст задачі", "id": "context"}, {"module": "bulava/prep.classify@1", "title": "Тріаж", "id": "classify"}, {"title": "Бізнес-аналітик", "params": {"skipOnFollowup": false, "required": true, "engine": "codex", "when": "triage"}, "id": "position", "module": "bulava/prep.position@1"}, {"title": "Тестувальник", "params": {"skipOnFollowup": false, "required": true, "engine": "claude"}, "id": "position-2", "module": "bulava/prep.position@1"}, {"title": "Архітектор Claude", "params": {"skipOnFollowup": false, "required": true, "engine": "claude", "when": "triage"}, "id": "position-3", "module": "bulava/prep.position@1"}, {"title": "Архітектор Codex", "params": {"skipOnFollowup": false, "required": true, "engine": "codex", "when": "triage"}, "id": "position-4", "module": "bulava/prep.position@1"}, {"module": "bulava/prep.align@1", "params": {"skipOnFollowup": false, "required": true}, "title": "Домовленість", "id": "align"}, {"module": "bulava/prep.compose@1", "title": "Бриф виконавцю", "id": "compose"}, {"id": "design", "module": "bulava/agent.codexPart@1", "title": "Дизайнер", "params": {"when": "triage"}}, {"module": "bulava/agent.claude@1", "title": "Claude реалізує", "id": "claude"}, {"module": "bulava/gate.review@1", "title": "Рев'ю Codex", "id": "review"}, {"module": "bulava/out.merge@1", "title": "Злиття гілки", "id": "merge"}]}
"""#

    private func graph() throws -> (RunGraph, PipelineDocument) {
        let doc = try JSONDecoder().decode(PipelineDocument.self, from: Data(pipeline.utf8))
        let events = RunEvent.parse(lines: journal.split(separator: "\n"))
        return (RunReducer.reduce(events: events, messageID: mid, document: doc), doc)
    }

    func testTheRolesTheTriageLeftOutAreShownSkippedWithItsReason() throws {
        let (g, _) = try graph()
        for id in ["position", "position-3", "position-4"] {
            XCTAssertEqual(g.status(id).state, .skipped, "\(id) should read as skipped")
            XCTAssertTrue((g.status(id).note ?? "").contains("Тріаж"), "\(id) note: \(g.status(id).note ?? "-")")
        }
    }

    func testTheRolesThatRanAreShownDone() throws {
        let (g, _) = try graph()
        XCTAssertEqual(g.status("position-2").state, .done, "the tester ran")
        XCTAssertEqual(g.status("align").state, .done, "the agreement ran on the tester alone")
        XCTAssertEqual(g.status("design").state, .done, "Codex's part, the designer, was done")
    }

    @MainActor
    func testTheViewDrawsIt() throws {
        let (g, doc) = try graph()
        let view = RunGraphView(run: ChatRun(graph: g, document: doc), registry: nil, live: false)
            .frame(width: 360)
            .padding(12)
            .background(Palette.content)
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        let image = try XCTUnwrap(renderer.nsImage, "the run view did not render")
        XCTAssertGreaterThan(image.size.height, 200, "every step of the pipeline has a row")
        if let out = ProcessInfo.processInfo.environment["BULAVA_RENDER_DIR"],
           let tiff = image.tiffRepresentation,
           let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
            try png.write(to: URL(fileURLWithPath: out).appendingPathComponent("triage-run-graph.png"))
        }
    }
}
