import XCTest
import SwiftUI
@testable import Bulava

/// Pictures of the phone panel, for looking at — not a pixel comparison.
///
/// Skipped unless `BULAVA_SNAPSHOT_DIR` names a folder. Then it renders the panel as it looks with
/// no phone paired and with one, in light and dark, into that folder.
nonisolated final class PhoneLinkPanelSnapshot: XCTestCase {

    @MainActor
    func testRenderThePanel() async throws {
        guard let out = ProcessInfo.processInfo.environment["BULAVA_SNAPSHOT_DIR"], !out.isEmpty else {
            throw XCTSkip("Set BULAVA_SNAPSHOT_DIR to render the phone panel.")
        }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("bulava-panel-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        setenv("BULAVA_STATE_DIR", dir.path, 1)
        defer { unsetenv("BULAVA_STATE_DIR"); try? FileManager.default.removeItem(at: dir) }

        let model = AppModel()
        model.mobileLink.preferredPort = 0
        model.mobileLink.attach(model, allowInTests: true)
        model.mobileLink.beginPairing()
        for _ in 0..<100 {
            if case .listening = model.mobileLink.serverState { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        try render(model, name: "panel-no-phone", out: out)

        _ = model.mobileLink.devices.register(name: "Ivan’s iPhone", platform: "ios", appVersion: "1.0")
        model.mobileLink.beginPairing()
        try render(model, name: "panel-paired", out: out)
        model.mobileLink.shutdown()
    }

    @MainActor
    private func render(_ model: AppModel, name: String, out: String) throws {
        for (suffix, appearance, scheme) in [("light", NSAppearance.Name.aqua, ColorScheme.light),
                                             ("dark", .darkAqua, .dark)] {
            let view = PhoneLinkPanel()
                .environment(model)
                .environment(\.colorScheme, scheme)
            let renderer = ImageRenderer(content: view)
            renderer.scale = 2
            var data: Data?
            NSAppearance(named: appearance)!.performAsCurrentDrawingAppearance {
                if let image = renderer.nsImage, let tiff = image.tiffRepresentation,
                   let rep = NSBitmapImageRep(data: tiff) {
                    data = rep.representation(using: .png, properties: [:])
                }
            }
            let png = try XCTUnwrap(data, "the panel did not render")
            try png.write(to: URL(fileURLWithPath: out).appendingPathComponent("\(name)-\(suffix).png"))
        }
    }
}
