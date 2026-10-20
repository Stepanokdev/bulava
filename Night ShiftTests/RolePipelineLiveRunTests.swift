import AppKit
import SwiftUI
import XCTest
@testable import Bulava

/// «Повний цикл» run for real, from the chat: the pipeline is chosen in the chat's own picker, the
/// message typed into the composer and sent, and then real Claude and Codex do every role, the work
/// and the review, on a small project made for it. Off unless asked: `BULAVA_LIVE_ROLE_RUN=1`. It
/// spends real model time — tens of minutes.
nonisolated final class RolePipelineLiveRunTests: XCTestCase {

    @MainActor
    func testTheRolePipelineRunsFromTheChat() async throws {
        let env = ProcessInfo.processInfo.environment
        guard env["BULAVA_LIVE_ROLE_RUN"] == "1" || env["BULAVA_LIVE_ROLE_PROBE"] == "1" else {
            throw XCTSkip("a live run was not asked for")
        }
        let root = URL(fileURLWithPath: env["BULAVA_LIVE_ROOT"] ?? FileManager.default.temporaryDirectory.appendingPathComponent("bulava-live-\(UUID().uuidString.prefix(8))").path)
        let project = root.appendingPathComponent("slug-kit")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        try "def slugify(text):\n    raise NotImplementedError\n".write(to: project.appendingPathComponent("slug.py"), atomically: true, encoding: .utf8)
        try "# slug-kit\n\nA tiny helper that turns titles into URL slugs. Tests: `python3 -m unittest`.\n".write(to: project.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
        _ = await Shell.run("cd \"$1\" && git init -q && git add -A && git -c user.email=t@t -c user.name=t commit -qm init", args: [project.path], timeout: 30)

        FixtureState.use(root.appendingPathComponent("app").path)
        let supervisorBefore = env["SUPERVISOR_STATE_DIR"]
        let supervisor = root.appendingPathComponent("supervisor")
        setenv("SUPERVISOR_STATE_DIR", supervisor.path, 1)
        defer {
            FixtureState.restore()
            if let supervisorBefore { setenv("SUPERVISOR_STATE_DIR", supervisorBefore, 1) } else { unsetenv("SUPERVISOR_STATE_DIR") }
        }
        // The pipeline as it stands in his library.
        let source = URL(fileURLWithPath: env["BULAVA_LIVE_PIPELINE"] ?? (NSHomeDirectory() + "/.claude/supervisor/pipelines/povnij-cikl"))
        try FileManager.default.createDirectory(at: supervisor.appendingPathComponent("pipelines"), withIntermediateDirectories: true)
        try? FileManager.default.removeItem(at: supervisor.appendingPathComponent("pipelines/povnij-cikl"))
        try FileManager.default.copyItem(at: source, to: supervisor.appendingPathComponent("pipelines/povnij-cikl"))

        LanguageBundle.adopt(.uk)
        defer { LanguageBundle.adopt(.system) }
        NSApp.setValue(true, forKey: "accessibilityEnhancedUserInterface")
        let model = AppModel()
        await model.loadPipelineLibrary()
        let folder = model.projects.add(path: project.path)
        let product = model.products.add(name: "Slug kit", resources: [ProductResource(name: "slug-kit", projectID: folder.id)])
        model.route = .product(product.id)
        let window = NSWindow(contentRect: CGRect(x: 40, y: 40, width: 1500, height: 940),
                              styleMask: [.titled, .closable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: RootView().environment(model).environment(UpdateController())
            .environment(\.locale, Locale(identifier: "uk")))
        window.makeKeyAndOrderFront(nil)
        defer { window.close() }
        let hand = WindowHand(window)
        await hand.settle(1200)
        if env["BULAVA_LIVE_ROLE_PROBE"] == "1" { hand.dump("product"); return }
        func log(_ s: String) { print("LIVE \(Date().formatted(date: .omitted, time: .standard)) \(s)") }

        // The pipeline, chosen in the chat's own picker.
        try await hand.click("Пайплайн|Pipeline", role: "AXButton", exact: true)
        await hand.settle(700)
        if env["BULAVA_LIVE_PICKER_PROBE"] == "1" { hand.dump("picker"); return }
        try await hand.click("Повний цикл", role: "AXButton")
        await hand.settle(700)
        XCTAssertEqual(model.pipelineID(forChat: model.conversations.displayedChatID(for: product.id)), "povnij-cikl",
                       "the new conversation will run «Повний цикл»")

        // The message, typed into the composer and sent with its button.
        let task = "Реалізуй slugify(text) у slug.py: нижній регістр, пробіли й підкреслення стають дефісами, все, крім латинських літер, цифр і дефісів, прибирається, кілька дефісів підряд — один, без дефісів на краях. Додай test_slug.py з unittest."
        let composer = try hand.find("Message Night Shift…|Повідомлення", role: "AXTextArea")
        await hand.click(at: NSPoint(x: composer.1.frame.midX, y: composer.1.frame.midY), in: window)
        if let view = composer.1.object as? NSView, window.firstResponder !== view { window.makeFirstResponder(view) }
        let typed = try XCTUnwrap(window.firstResponder as? NSTextView, "the composer has the keyboard")
        typed.insertText(task, replacementRange: typed.selectedRange())
        await hand.settle(500)
        try await hand.click("Угору|Send", role: "AXButton")
        await hand.settle(1500)
        let chatID = try XCTUnwrap(model.conversations.displayedChatID(for: product.id), "the chat the message made")
        XCTAssertEqual(model.pipelineID(forChat: chatID), "povnij-cikl", "the chat runs «Повний цикл»")
        log("sent")

        // Then it runs. Any question the chat puts on screen for a first run in a new folder is
        // answered the way he would answer it, with its own button.
        let instances = supervisor.appendingPathComponent("instances")
        var events = URL(fileURLWithPath: "/nonexistent")
        var seen = 0
        let deadline = Date().addingTimeInterval(Double(env["BULAVA_LIVE_MINUTES"] ?? "60").map { $0 * 60 } ?? 3600)
        var finished: [String: Any]?
        while Date() < deadline {
            await hand.settle(5000)
            for label in ["Довірити і надіслати", "Trust and send", "Створити git і надіслати", "Create git and send"] {
                if let b = hand.lookup(label, role: "AXButton") { await hand.click(at: NSPoint(x: b.1.frame.midX, y: b.1.frame.midY), in: window); log("answered «\(b.1.label)»") }
            }
            if !FileManager.default.fileExists(atPath: events.path),
               let dir = try? FileManager.default.contentsOfDirectory(atPath: instances.path).first {
                events = instances.appendingPathComponent(dir).appendingPathComponent("run-events.jsonl")
            }
            let lines = ((try? String(contentsOf: events, encoding: .utf8)) ?? "").split(separator: "\n").map(String.init)
            for line in lines.dropFirst(seen) {
                guard let o = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] else { continue }
                log("event \(o["stage"] ?? "?") \(o["state"] ?? "?") \(o["note"] ?? "")")
                if (o["stage"] as? String) == "run" { finished = o }
            }
            seen = lines.count
            if finished != nil { break }
        }
        let idir = events.deletingLastPathComponent()
        let out = root.appendingPathComponent("evidence")
        try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        _ = await Shell.run("cp -R \"$1\" \"$2/instance\" 2>/dev/null; cd \"$3\" && git log --oneline --all > \"$2/git-log.txt\"; git diff HEAD --stat > \"$2/diff-stat.txt\" 2>&1; git branch -a > \"$2/branches.txt\"",
                            args: [idir.path, out.path, project.path], timeout: 60)
        log("evidence in \(out.path)")
        let run = try XCTUnwrap(finished, "the run did not finish in time; events so far are in \(events.path)")
        log("finished: \(run)")

        // What happened, in the order it happened.
        let all = ((try? String(contentsOf: events, encoding: .utf8)) ?? "").split(separator: "\n")
            .compactMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] }
        func at(_ stage: String, _ state: String) -> Int? {
            all.first { ($0["stage"] as? String) == stage && ($0["state"] as? String) == state }?["ms"] as? Int
        }
        let baStart = try XCTUnwrap(at("position", "running")), qaStart = try XCTUnwrap(at("position-2", "running"))
        let baEnd = try XCTUnwrap(at("position", "done")), qaEnd = try XCTUnwrap(at("position-2", "done"))
        let acStart = try XCTUnwrap(at("position-3", "running")), axStart = try XCTUnwrap(at("position-4", "running"))
        let acEnd = try XCTUnwrap(at("position-3", "done")), axEnd = try XCTUnwrap(at("position-4", "done"))
        let agreeStart = try XCTUnwrap(at("align", "running")), agreeEnd = try XCTUnwrap(at("align", "done"))
        XCTAssertLessThan(max(baStart, qaStart), min(baEnd, qaEnd), "the analyst and the tester worked side by side")
        XCTAssertGreaterThanOrEqual(min(acStart, axStart), max(baEnd, qaEnd), "the architects started after both had finished")
        XCTAssertLessThan(max(acStart, axStart), min(acEnd, axEnd), "the two architects worked side by side")
        XCTAssertGreaterThanOrEqual(agreeStart, max(acEnd, axEnd), "the agreement came after both architects")
        let msgDir = try XCTUnwrap((try? FileManager.default.contentsOfDirectory(at: idir.appendingPathComponent("messages"), includingPropertiesForKeys: nil))?.first)
        for role in ["position", "position-2", "position-3", "position-4"] {
            let text = (try? String(contentsOf: msgDir.appendingPathComponent("role-\(role).md"), encoding: .utf8)) ?? ""
            XCTAssertGreaterThan(text.count, 200, "role \(role) wrote its result")
        }
        let agreement = (try? String(contentsOf: msgDir.appendingPathComponent("peer-alignment.md"), encoding: .utf8)) ?? ""
        XCTAssertGreaterThan(agreement.count, 300, "the agreement was written")
        let composed = (try? String(contentsOf: msgDir.appendingPathComponent("composed.txt"), encoding: .utf8)) ?? ""
        XCTAssertTrue(composed.contains("[РОЛІ ПІДГОТОВКИ]") && composed.contains("Тест-кейси з узгодженого рішення"),
                      "the worker was handed the roles and the test cases")
        XCTAssertGreaterThanOrEqual(at("claude", "running") ?? at("claude", "delivered") ?? 0, agreeEnd, "the work began after the agreement")
        let plan = (try? String(contentsOf: idir.appendingPathComponent("plan.md"), encoding: .utf8)) ?? ""
        XCTAssertEqual(plan, agreement, "the review is held to the agreement")
        XCTAssertNotNil(all.first { ($0["stage"] as? String) == "gate.review" }, "Codex reviewed the work")
        log("ORDER analyst \(baStart)…\(baEnd) tester \(qaStart)…\(qaEnd) architects \(acStart)/\(axStart)…\(acEnd)/\(axEnd) agreement \(agreeStart)…\(agreeEnd)")
    }
}
