import XCTest
import SwiftUI
import AppKit
@testable import Bulava

nonisolated final class PaletteContrastTests: XCTestCase {

    // MARK: - Measuring

    @MainActor private func rgb(_ color: Color, dark: Bool) -> (r: Double, g: Double, b: Double) {
        var out = (r: 0.0, g: 0.0, b: 0.0)
        let appearance = NSAppearance(named: dark ? .darkAqua : .aqua)!
        appearance.performAsCurrentDrawingAppearance {
            guard let ns = NSColor(color).usingColorSpace(.sRGB) else { return }
            out = (Double(ns.redComponent), Double(ns.greenComponent), Double(ns.blueComponent))
        }
        return out
    }

    private func luminance(_ c: (r: Double, g: Double, b: Double)) -> Double {
        func channel(_ v: Double) -> Double {
            v <= 0.03928 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * channel(c.r) + 0.7152 * channel(c.g) + 0.0722 * channel(c.b)
    }

    @MainActor private func ratio(_ a: Color, on b: Color, dark: Bool) -> Double {
        let (l1, l2) = (luminance(rgb(a, dark: dark)), luminance(rgb(b, dark: dark)))
        return (max(l1, l2) + 0.05) / (min(l1, l2) + 0.05)
    }

    @MainActor private func assertAA(_ fg: Color, on bg: Color, dark: Bool,
                          _ what: String, min: Double = 4.5,
                          file: StaticString = #filePath, line: UInt = #line) {
        let measured = ratio(fg, on: bg, dark: dark)
        XCTAssertGreaterThanOrEqual(
            measured, min,
            "\(what) in \(dark ? "dark" : "light"): \(String(format: "%.2f", measured)):1, needs \(min):1",
            file: file, line: line)
    }

    // MARK: - The accent as ink

    @MainActor func testAccentReadsAsForegroundOnEverySurfaceItLandsOn() {
        for dark in [false, true] {
            assertAA(Palette.accentEmphasis, on: Palette.panel, dark: dark, "accentEmphasis on a card")
            assertAA(Palette.accentEmphasis, on: Palette.content, dark: dark, "accentEmphasis on content")
            assertAA(Palette.accentEmphasis, on: Palette.chrome, dark: dark, "accentEmphasis on chrome")
            assertAA(Palette.accentEmphasis, on: Palette.panelOnChrome, dark: dark,
                     "accentEmphasis on an inspector card")

            assertAA(Palette.accent, on: Palette.content, dark: dark, "accent on content", min: 3)
        }
    }

    // MARK: - The accent as a fill

    @MainActor func testTextOnAFilledAccentSurvivesBothThemes() {
        for dark in [false, true] {
            assertAA(Palette.onAccent, on: Palette.accent, dark: dark, "onAccent on the primary button")
            assertAA(Palette.onAccent, on: Palette.accentEmphasis, dark: dark,
                     "onAccent on the button's hover fill")
        }
    }

    // MARK: - The mark

    @MainActor func testTheMarkIsNeverTheWeakLink() {

        for dark in [false, true] {
            assertAA(Palette.brandLime, on: Palette.brandField, dark: dark, "the mark on its plate", min: 7)
        }
    }

    // MARK: - What the surfaces still owe

    @MainActor func testBodyTextKeepsItsContrastAfterTheSurfacesWentNeutral() {
        for dark in [false, true] {
            assertAA(Palette.text, on: Palette.panel, dark: dark, "body text on a card", min: 7)
            assertAA(Palette.textSecondary, on: Palette.panel, dark: dark, "secondary text on a card")
            assertAA(Palette.textTertiary, on: Palette.content, dark: dark, "tertiary text on content")
            assertAA(Palette.textTertiary, on: Palette.chrome, dark: dark, "tertiary text on chrome")

            assertAA(Palette.textFaint, on: Palette.chrome, dark: dark, "metadata on chrome", min: 3)
        }
    }

    // MARK: - The mark's geometry

    func testTheGlyphIsWhatItClaimsToBe() {

        let box = CGRect(x: 0, y: 0, width: 200, height: 200)
        let bounds = BulavaGlyph.cgPath(in: box).boundingBox
        XCTAssertTrue(box.insetBy(dx: -0.5, dy: -0.5).contains(bounds), "the mark overflows its box")
        XCTAssertEqual(bounds.height, 200, accuracy: 1, "the mark does not fill the height it is given")
        XCTAssertEqual(bounds.width / bounds.height,
                       BulavaGlyph.inkBounds.width / BulavaGlyph.inkBounds.height, accuracy: 0.01,
                       "the mark is being stretched")

        let d = BulavaGlyph.svgPath
        XCTAssertEqual(d.filter { $0 == "M" }.count, 1, "the outline is no longer a single contour")
        XCTAssertTrue(d.hasSuffix("Z"), "the outline is not closed")
        XCTAssertGreaterThan(d.filter { $0 == "L" }.count, 80, "the outline lost its detail")

        let coordinates = d.split(separator: " ").compactMap {
            Double($0.first?.isLetter == true ? $0.dropFirst() : $0[...])
        }
        // Read outside the assertion: Swift 6.4 will not touch a main-actor property inside
        // XCTAssert's nonisolated autoclosure.
        let points = BulavaGlyph.cgPath(in: box).points.count
        XCTAssertEqual(points, coordinates.count / 2,
                       "the path parser and the string disagree about how many points there are")
    }
}

// MARK: - The contract says only what someone actually knows

nonisolated final class RunSpecHonestyTests: XCTestCase {

    private func json(_ spec: RunSpec) throws -> [String: Any] {
        let data = try JSONEncoder().encode(spec)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    func testAnUnstatedSurfaceIsAbsentRatherThanDenied() throws {
        var task = BacklogTask(title: "Ship the analytics loop", projectPath: "/tmp/p")
        task.surfaceVisual = true
        let obj = try json(RunSpec.infer(from: task, projectPath: "/tmp/p"))
        let surface = try XCTUnwrap(obj["surface"] as? [String: Any])
        XCTAssertEqual(surface["visual"] as? Bool, true)
        XCTAssertNil(surface["behavior"], "an unstated surface must not be serialized as false")
        XCTAssertNil(surface["user_facing_copy"], "an unstated surface must not be serialized as false")

        let caps = try XCTUnwrap(obj["capabilities"] as? [String: Any])
        XCTAssertNil(caps["network"])
        XCTAssertNil(caps["push"])
    }

    func testAStatedSurfaceSurvivesIntoTheContract() throws {
        var task = BacklogTask(title: "Consent screen", projectPath: "/tmp/p")
        task.surfaceBehavior = true
        task.surfaceUserFacingCopy = true
        let surface = try XCTUnwrap(try json(RunSpec.infer(from: task, projectPath: "/tmp/p"))["surface"] as? [String: Any])
        XCTAssertEqual(surface["behavior"] as? Bool, true)
        XCTAssertEqual(surface["user_facing_copy"] as? Bool, true)
    }

    func testEveryStepsAcceptanceReachesTheContract() throws {

        var task = BacklogTask(title: "Six steps", projectPath: "/tmp/p")
        task.acceptance = (1...6).flatMap { s in (1...3).map { "step \(s) criterion \($0)" } }
        let obj = try json(RunSpec.infer(from: task, projectPath: "/tmp/p"))
        let acceptance = try XCTUnwrap(obj["acceptance"] as? [String])
        XCTAssertEqual(acceptance.count, 18)
        XCTAssertTrue(acceptance.contains("step 6 criterion 3"), "the last step's criteria were dropped")
    }
}
