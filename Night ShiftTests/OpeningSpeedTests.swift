import AppKit
import SwiftUI
import XCTest
@testable import Bulava

/// How long each screen and sheet takes to appear on a real Mac's data: a copy of the app's own
/// state, the chat history of tens of megabytes included. «Деякі вікна не одразу відкриваються» —
/// measured here rather than guessed. Off unless `BULAVA_PERF_DATA` names a state folder to copy;
/// the copy is thrown away, the original is never written.
nonisolated final class OpeningSpeedTests: XCTestCase {

    @MainActor
    func testHowLongEachScreenTakesToAppear() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let source = env["BULAVA_PERF_DATA"] ?? env["TEST_RUNNER_BULAVA_PERF_DATA"], !source.isEmpty else {
            throw XCTSkip("no state folder to measure on (BULAVA_PERF_DATA)")
        }
        let copy = FileManager.default.temporaryDirectory.appendingPathComponent("bulava-perf-\(UUID().uuidString)")
        try FileManager.default.copyItem(at: URL(fileURLWithPath: source), to: copy)
        defer { try? FileManager.default.removeItem(at: copy) }
        FixtureState.use(copy.path)
        defer { FixtureState.restore() }

        var lines: [String] = []
        func measure(_ name: String, _ work: () -> Void) -> Double {
            let start = CFAbsoluteTimeGetCurrent()
            work()
            let ms = (CFAbsoluteTimeGetCurrent() - start) * 1000
            lines.append(String(format: "%8.1f ms  %@", ms, name))
            return ms
        }
        var model: AppModel!
        _ = measure("AppModel() — loading the state") { model = AppModel() }
        let updates = UpdateController()

        func show(_ name: String, _ view: some View, width: CGFloat = 1400, height: CGFloat = 900) {
            _ = measure(name) {
                let host = NSHostingView(rootView: view.environment(model).environment(updates).frame(width: width, height: height))
                host.frame = CGRect(x: 0, y: 0, width: width, height: height)
                host.layoutSubtreeIfNeeded()
                if let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) { host.cacheDisplay(in: host.bounds, to: rep) }
            }
        }

        show("main window, first appearance", RootView())
        let biggest = model.products.products.max { a, b in
            model.conversations.chats(for: a.id).count < model.conversations.chats(for: b.id).count
        }
        for route in [Route.products, .automations, .pipelines, .skills, .browser, .preflight] {
            model.route = route
            show("main window → \(route)", RootView())
        }
        if let product = biggest {
            model.route = .product(product.id)
            show("main window → product «\(product.name)»", RootView())
            let chats = model.conversations.chats(for: product.id).sorted {
                model.conversations.entries(inChat: $0.id).count > model.conversations.entries(inChat: $1.id).count
            }
            if let chat = chats.first {
                model.conversations.open(chat.id, for: product.id)
                show("its longest chat (\(model.conversations.entries(inChat: chat.id).count) entries)", RootView())
                show("automation editor from that chat", AutomationEditor(request: .fromChat(chat.id)), width: 640, height: 700)
            }
            show("add a folder to it", AddProductSheet(mode: .addResource(productID: product.id)), width: 640, height: 600)
        }
        show("new automation (templates)", AutomationEditor(request: .new(productID: biggest?.id, template: nil)), width: 640, height: 700)
        show("new product", AddProductSheet(mode: .newProduct), width: 640, height: 600)
        show("settings", SettingsView(), width: 700, height: 600)
        _ = measure("saving the chat list (each chat change)") {
            if let chat = model.conversations.chats.first { model.conversations.rename(chat.id, to: chat.title) }
        }

        // What he actually does: one window, switching between screens — the wait between a click and
        // the screen it asked for.
        let window = NSHostingView(rootView: RootView().environment(model).environment(updates).frame(width: 1400, height: 900))
        window.frame = CGRect(x: 0, y: 0, width: 1400, height: 900)
        window.layoutSubtreeIfNeeded()
        func switchTo(_ name: String, _ route: Route) {
            _ = measure("switch → \(name)") {
                model.route = route
                // Layout only: drawing into a bitmap here would be the CPU doing the blur the GPU does
                // on screen, and that, not the app, would be measured.
                window.layoutSubtreeIfNeeded()
            }
        }
        let rounds = Int(env["TEST_RUNNER_BULAVA_PERF_ROUNDS"] ?? env["BULAVA_PERF_ROUNDS"] ?? "2") ?? 2
        for round in 1...rounds {
            switchTo("products (\(round))", .products)
            switchTo("automations (\(round))", .automations)
            if let product = biggest { switchTo("product «\(product.name)» (\(round))", .product(product.id)) }
            switchTo("pipelines (\(round))", .pipelines)
            switchTo("browser (\(round))", .browser)
            for other in model.products.byRecentWork.prefix(4) where other.id != biggest?.id {
                switchTo("product «\(other.name)» (\(round))", .product(other.id))
            }
        }

        // While a run answers: every new line in its chat, and what the open window does with it.
        if let product = biggest, let chat = model.conversations.chats(for: product.id).max(by: {
            model.conversations.entries(inChat: $0.id).count < model.conversations.entries(inChat: $1.id).count }) {
            model.route = .product(product.id)
            model.conversations.open(chat.id, for: product.id)
            window.layoutSubtreeIfNeeded()
            lines.append("  (\(model.conversations.entries.count) entries in all, \(model.conversations.chats.count) chats)")
            for n in 1...5 {
                _ = measure("a new line in the open chat, and the window after it (\(n))") {
                    model.conversations.appendForeman("рядок \(n)", productID: product.id, chatID: chat.id)
                    window.layoutSubtreeIfNeeded()
                }
            }
            _ = measure("entries of every chat, after a change (what the sidebar reads)") {
                model.conversations.appendForeman("ще рядок", productID: product.id, chatID: chat.id)
                for c in model.conversations.chats { _ = model.conversations.entries(inChat: c.id).count }
            }
        }

        let report = lines.joined(separator: "\n")
        print("OPENING SPEED\n" + report)
        let out = FileManager.default.temporaryDirectory.appendingPathComponent("bulava-opening-speed.txt")
        try report.write(to: out, atomically: true, encoding: .utf8)
    }
}
