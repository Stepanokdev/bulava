import XCTest
import SwiftUI
@testable import Bulava

/// Settings → Jev drawn in each state it can be in, light and dark, without starting the app's
/// engine side. A state that does not draw — a layout SwiftUI cannot settle, text that runs out of
/// its card — fails here instead of in front of him. With BULAVA_RENDER_DIR set, the pictures are
/// written there to be looked at.
nonisolated final class JevSettingsRenderTests: XCTestCase {

    @MainActor private func render(_ name: String, _ view: some View, dark: Bool) throws -> CGSize {
        let framed = view
            .padding(18)
            .frame(width: 620, alignment: .leading)
            .background(Palette.content)
            .environment(\.colorScheme, dark ? .dark : .light)
        let renderer = ImageRenderer(content: framed)
        renderer.scale = 2
        guard let image = renderer.nsImage else { throw XCTSkip("ImageRenderer gave nothing in this host") }
        if let dir = ProcessInfo.processInfo.environment["BULAVA_RENDER_DIR"], !dir.isEmpty,
           let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
           let png = rep.representation(using: .png, properties: [:]) {
            try png.write(to: URL(fileURLWithPath: dir).appendingPathComponent("jev-\(name)-\(dark ? "dark" : "light").png"))
        }
        return image.size
    }

    @MainActor func testEveryStateDraws() throws {
        let off = JevStatus(mode: "off", key: false, model: "jev-1.13.0", decisions: 0)
        let on = JevStatus(mode: "on", key: true, model: "jev-1.13.0", decisions: 12)
        let states: [(String, JevSettingsSection)] = [
            ("no-engine", JevSettingsSection(showing: nil)),
            ("off", JevSettingsSection(showing: off)),
            ("waiting-for-key", JevSettingsSection(showing: off, waitingForKey: true)),
            ("on", JevSettingsSection(showing: on, check: JevTestResult(ok: true, model: "jev-1.13.0", seconds: 0.21,
                                                                        inputTokens: 352, verdict: "continue"))),
            ("shadow", JevSettingsSection(showing: JevStatus(mode: "shadow", key: true, model: "jev-1.13.0", decisions: 0))),
            ("check-failed", JevSettingsSection(showing: on, check: JevTestResult(ok: false, error: "http-401"))),
        ]
        for (name, view) in states {
            for dark in [false, true] {
                let size = try render(name, view, dark: dark)
                XCTAssertEqual(size.width, 620, accuracy: 1, "\(name): the card is as wide as Settings gives it")
                XCTAssertGreaterThan(size.height, 80, "\(name): drawn, not collapsed")
                XCTAssertLessThan(size.height, 600, "\(name): no runaway layout")
            }
        }
    }
}
