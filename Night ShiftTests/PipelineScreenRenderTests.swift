import AppKit
import SwiftUI
import XCTest
@testable import Bulava

/// No screen may ask the window to be taller than it is.
///
/// 19 Oct: on Pipelines the whole window slid up under its title bar — the screen's header and its
/// buttons out of sight, the list showing through the toolbar. A subtitle there was `fixedSize`
/// vertically: asked how small the window could be, it measured itself one word per line, the
/// content asked for twice the window, and AppKit kept the bottom and cut the top.
nonisolated final class PipelineScreenRenderTests: XCTestCase {

    @MainActor
    private func window(_ model: AppModel, _ route: Route) async throws -> (NSWindow, NSHostingView<AnyView>) {
        model.route = route
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 1300, height: 820),
                              styleMask: [.titled, .closable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false
        let host = NSHostingView(rootView: AnyView(RootView().environment(model).environment(UpdateController())
            .environment(\.locale, Locale(identifier: "uk"))))
        window.contentView = host
        window.layoutIfNeeded()
        try await Task.sleep(for: .milliseconds(500))
        host.layoutSubtreeIfNeeded()
        return (window, host)
    }

    @MainActor
    func testNoScreenMakesTheWindowTallerThanItIs() async throws {
        let state = FileManager.default.temporaryDirectory.appendingPathComponent("bulava-screens-\(UUID().uuidString)")
        FixtureState.use(state.path)
        defer { FixtureState.restore(); try? FileManager.default.removeItem(at: state) }
        LanguageBundle.adopt(.uk)
        defer { LanguageBundle.adopt(.system) }
        let model = AppModel()
        await model.loadPipelineLibrary()
        let product = model.products.add(name: "Ledger")
        var routes: [(String, Route)] = [("products", .products), ("skills", .skills), ("automations", .automations),
                                         ("pipelines", .pipelines), ("browser", .browser), ("preflight", .preflight),
                                         ("product", .product(product.id))]
        if let first = model.pipelineLibrary.first { routes.append(("pipeline editor", .pipeline(first.id))) }
        for (name, route) in routes {
            let (window, _) = try await window(model, route)
            XCTAssertEqual(window.frame.height, 820, accuracy: 1, "\(name) made the window \(window.frame.height) tall")
            window.close()
        }
    }

    /// The same screens drawn on a copy of real data, for a person to look at. Off unless asked.
    @MainActor
    func testDrawThePipelineScreens() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let source = env["BULAVA_PERF_DATA"] ?? env["TEST_RUNNER_BULAVA_PERF_DATA"], !source.isEmpty else {
            throw XCTSkip("no state folder to draw with (BULAVA_PERF_DATA)")
        }
        let copy = FileManager.default.temporaryDirectory.appendingPathComponent("bulava-draw-\(UUID().uuidString)")
        try FileManager.default.copyItem(at: URL(fileURLWithPath: source), to: copy)
        defer { try? FileManager.default.removeItem(at: copy) }
        FixtureState.use(copy.path)
        defer { FixtureState.restore() }
        LanguageBundle.adopt(.uk)
        defer { LanguageBundle.adopt(.system) }
        let model = AppModel()
        await model.loadPipelineLibrary()
        let out = URL(fileURLWithPath: env["TEST_RUNNER_BULAVA_RENDER_DIR"] ?? FileManager.default.temporaryDirectory.appendingPathComponent("bulava-frames").path)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        var routes: [(String, Route)] = [("pipelines-library", .pipelines)]
        if let first = model.pipelineLibrary.first { routes.append(("pipeline-editor", .pipeline(first.id))) }
        if let mine = env["BULAVA_DRAW_PIPELINE"] ?? env["TEST_RUNNER_BULAVA_DRAW_PIPELINE"] { routes.append(("pipeline-mine", .pipeline(mine))) }
        for (name, route) in routes {
            let (window, host) = try await window(model, route)
            let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: rep)
            try XCTUnwrap(rep.representation(using: .png, properties: [:])).write(to: out.appendingPathComponent("\(name).png"))
            print("FRAME \(out.appendingPathComponent("\(name).png").path) window=\(window.frame.size)")
            window.close()
        }
        print("PIPELINES \(model.pipelineLibrary.map(\.id))")
    }
}
