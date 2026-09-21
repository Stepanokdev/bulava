import XCTest
@testable import Bulava

nonisolated final class CodexDecisionVisibilityTests: XCTestCase {

    func testOnlyCodexChoicesForThisRunBecomeChatArtifacts() async throws {
        let state = FileManager.default.temporaryDirectory
            .appendingPathComponent("bulava-codex-decision-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: state) }

        let project = "/tmp/pocket-ledger"
        let slug = Slug.forPath(project)
        let instance = state.appendingPathComponent("instances/\(slug)")
        try FileManager.default.createDirectory(at: instance, withIntermediateDirectories: true)
        try project.write(to: instance.appendingPathComponent("project"), atomically: true, encoding: .utf8)
        try "night-\(slug)".write(to: instance.appendingPathComponent("session"), atomically: true,
                                  encoding: .utf8)
        try "run-current".write(to: instance.appendingPathComponent("run-id"), atomically: true,
                                encoding: .utf8)
        try "started".write(to: instance.appendingPathComponent("started-at"), atomically: true,
                            encoding: .utf8)
        try """
        {"asked_at":1787562000,"tool_use_id":"ask-7","reason_code":"product_fork",
         "headline":"Обери поведінку продукту","recommendation":"Варіант A",
         "default_action":"Не змінювати продукт","unblock_action":"Іван: обери варіант",
         "questions":[{"question":"Обрати A чи B?","header":"Поведінка","multiSelect":false,
                       "options":["A","B"],
                       "optionDescriptions":{"A":"Оборотно","B":"Змінює продукт"}}]}
        """.write(to: instance.appendingPathComponent("ask-user.json"), atomically: true,
                    encoding: .utf8)

        let lines = [
            """
            {"ts":"2026-08-24T10:00:00Z","kind":"answer","slug":"\(slug)","run_id":"run-current","decision":"auto","source":"codex","tool_use_id":"tool-1","answer":"Обрати A. Це оборотний варіант і він покривається тестом.","questions":[{"question":"Обрати A чи B?"}]}
            """,
            """
            {"ts":"2026-08-24T10:01:00Z","kind":"answer","slug":"\(slug)","run_id":"run-other","decision":"auto","answer":"Чуже рішення"}
            """,
            """
            {"ts":"2026-08-24T10:02:00Z","kind":"answer","slug":"\(slug)","run_id":"run-current","decision":"answered","answer":"Особиста відповідь Івана"}
            """
        ]
        try (lines.joined(separator: "\n") + "\n")
            .write(to: state.appendingPathComponent("decisions.jsonl"), atomically: true, encoding: .utf8)

        let snapshot = await SupervisorClient(paths: SupervisorPaths(stateDir: state)).snapshot()
        let found = try XCTUnwrap(snapshot.instances.first)
        let decisions = found.codexArtifacts.filter { $0.kind == .decision }
        XCTAssertEqual(decisions.count, 1)
        XCTAssertTrue(decisions[0].text.contains("Обрати A чи B?"))
        XCTAssertTrue(decisions[0].text.contains("**Codex обрав:**"))
        XCTAssertTrue(decisions[0].text.contains("оборотний варіант"),
                      "the visible turn lost Codex's explanation")
        XCTAssertFalse(decisions[0].text.contains("Чуже рішення"))
        XCTAssertFalse(decisions[0].text.contains("Особиста відповідь Івана"))
        XCTAssertEqual(found.pendingQuestion?.toolUseID, "ask-7")
        XCTAssertEqual(found.pendingQuestion?.questions[0].optionDescriptions?["B"], "Змінює продукт",
                       "the native choice card lost Claude's option explanation")
    }
}
