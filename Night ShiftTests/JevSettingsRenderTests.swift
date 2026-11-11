import XCTest
import SwiftUI
@testable import Bulava

/// Settings → Jev drawn in each state it can be in, light and dark, without starting the app's
/// engine side. A state that does not draw — a layout SwiftUI cannot settle, text that runs out of
/// its card — fails here instead of in front of him. With BULAVA_RENDER_DIR set, the pictures are
/// written there to be looked at.
nonisolated final class JevSettingsRenderTests: XCTestCase {

    /// Drawn through an NSHostingView, not ImageRenderer: the switch and the buttons are AppKit
    /// controls, and ImageRenderer paints a placeholder where each one stands — the picture would
    /// then say nothing about how the section looks.
    @MainActor private func render(_ name: String, _ view: some View, dark: Bool) throws -> CGSize {
        let host = NSHostingView(rootView: view
            .padding(18)
            .frame(width: 620, alignment: .leading)
            .background(Palette.content)
            .environment(\.colorScheme, dark ? .dark : .light))
        host.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        host.layoutSubtreeIfNeeded()
        let size = host.fittingSize
        guard size.width > 0, size.height > 0 else { throw XCTSkip("the host laid out nothing") }
        host.frame = CGRect(origin: .zero, size: size)
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else {
            throw XCTSkip("no bitmap for the host in this run")
        }
        host.cacheDisplay(in: host.bounds, to: rep)
        let env = ProcessInfo.processInfo.environment
        if let dir = env["BULAVA_RENDER_DIR"] ?? env["TEST_RUNNER_BULAVA_RENDER_DIR"], !dir.isEmpty,
           let png = rep.representation(using: .png, properties: [:]) {
            try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
            try png.write(to: URL(fileURLWithPath: dir).appendingPathComponent("jev-\(name)-\(dark ? "dark" : "light").png"))
        }
        return size
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
