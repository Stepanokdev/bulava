import XCTest
@testable import Bulava

/// The engine Bulava ships renders the reports the app opens and speaks to the worker for it; its
/// own tests for both are run here, so the app's test run proves them too.
///
/// - `test-artifact.sh`: the report opens with the logo and bulava.app, says its own words in the
///   report's language, reads a Russian verdict, and never shows a frame alone taller than the view.
/// - `test-brand-mark.sh`: every page the engine renders carries the mark, drawn from the app's glyph.
/// - `test-worker-language.sh`: the worker answers in the language the person writes in, and every
///   message names it — not the language of the engine's notes, nor of a message the app sent.
/// - `test-receipt.sh`: the run's receipt still renders.
nonisolated final class EngineReportAndLanguageTests: XCTestCase {

    private static let engine = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("engine")

    private func run(_ script: String, file: StaticString = #filePath, line: UInt = #line) throws {
        let path = Self.engine.appendingPathComponent("tests/\(script)")
        guard FileManager.default.fileExists(atPath: path.path) else {
            throw XCTSkip("the engine's tests are not in this checkout")
        }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/bash")
        p.arguments = [path.path]
        p.currentDirectoryURL = Self.engine
        let out = Pipe()
        p.standardOutput = out
        p.standardError = out
        try p.run()
        let text = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        p.waitUntilExit()
        let failures = text.split(separator: "\n").filter { $0.contains("❌") }.joined(separator: "\n")
        XCTAssertEqual(p.terminationStatus, 0, "\(script) failed:\n\(failures.isEmpty ? text : failures)",
                       file: file, line: line)
    }

    func testTheReportTheAppOpens() throws { try run("test-artifact.sh") }
    func testEveryPageCarriesTheMark() throws { try run("test-brand-mark.sh") }
    func testTheWorkerAnswersInThePersonsLanguage() throws { try run("test-worker-language.sh") }
    func testTheReceiptRenders() throws { try run("test-receipt.sh") }
}
