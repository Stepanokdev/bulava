import XCTest
@testable import Bulava

/// With two Codex installs, the app runs the newest one — the same rule the engine follows.
///
/// Seen on a real machine: Homebrew's npm-global Codex (0.153) first on PATH, nvm's (0.156) second.
/// The service offers each CLI the models of its own version, so GPT-6 Sol and Luna were missing
/// from the menu and would have been refused by the CLI that actually ran.
nonisolated final class CodexInstallsTests: XCTestCase {

    private var root: URL!

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("codex-installs-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    /// An npm-shaped install: `<prefix>/bin/codex` → `../lib/node_modules/@openai/codex/bin/codex.js`.
    @discardableResult
    private func install(_ prefix: String) throws -> String {
        let base = root.appendingPathComponent(prefix, isDirectory: true)
        let bin = base.appendingPathComponent("bin", isDirectory: true)
        let package = base.appendingPathComponent("lib/node_modules/@openai/codex/bin", isDirectory: true)
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
        let script = package.appendingPathComponent("codex.js")
        try Data("#!/bin/sh\n".utf8).write(to: script)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        let link = bin.appendingPathComponent("codex")
        try FileManager.default.createSymbolicLink(atPath: link.path,
                                                   withDestinationPath: "../lib/node_modules/@openai/codex/bin/codex.js")
        return bin.path
    }

    private var shim: URL { root.appendingPathComponent("shim", isDirectory: true) }

    func testTheNewestInstallAnswersWhateverThePathOrder() throws {
        let brew = try install("brew")
        let nvm = try install("nvm")
        let versions = ["\(brew)/codex": "0.153.4", "\(nvm)/codex": "0.156.0"]

        let path = CodexInstalls.preferNewest(in: "\(brew):\(nvm):/usr/bin", shim: shim,
                                              version: { versions[$0] })
        XCTAssertEqual(path, "\(shim.path):\(brew):\(nvm):/usr/bin", "only the shim is added in front")
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(
            atPath: shim.appendingPathComponent("codex").path), "\(nvm)/codex")
    }

    func testVersionsAreComparedAsNumbers() throws {
        let a = try install("a")
        let b = try install("b")
        let versions = ["\(a)/codex": "0.9.0", "\(b)/codex": "0.10.0"]
        _ = CodexInstalls.preferNewest(in: "\(a):\(b)", shim: shim, version: { versions[$0] })
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(
            atPath: shim.appendingPathComponent("codex").path), "\(b)/codex")
    }

    /// Anything else first on PATH is somebody's deliberate choice, and it is not even run.
    func testAWrapperFirstOnPathIsLeftInCharge() throws {
        let wrapper = root.appendingPathComponent("wrapper", isDirectory: true)
        try FileManager.default.createDirectory(at: wrapper, withIntermediateDirectories: true)
        let script = wrapper.appendingPathComponent("codex")
        try Data("#!/bin/sh\n".utf8).write(to: script)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        let nvm = try install("nvm")

        var asked: [String] = []
        let given = "\(wrapper.path):\(nvm)"
        let path = CodexInstalls.preferNewest(in: given, shim: shim, version: { asked.append($0); return "9.9.9" })
        XCTAssertEqual(path, given)
        XCTAssertTrue(asked.isEmpty, "nothing is run when the first codex is not an install")
    }

    func testOneInstallIsUsedAsItIs() throws {
        let nvm = try install("nvm")
        XCTAssertEqual(CodexInstalls.preferNewest(in: "\(nvm):/usr/bin", shim: shim, version: { _ in "0.156.0" }),
                       "\(nvm):/usr/bin")
    }

    /// The copy that lost its native binary prints nothing; the working one takes over.
    func testAnInstallThatCannotSayItsVersionIsPassedOver() throws {
        let broken = try install("broken")
        let nvm = try install("nvm")
        let path = CodexInstalls.preferNewest(in: "\(broken):\(nvm)", shim: shim,
                                              version: { $0.hasPrefix(nvm) ? "0.156.0" : nil })
        XCTAssertTrue(path.hasPrefix(shim.path))
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(
            atPath: shim.appendingPathComponent("codex").path), "\(nvm)/codex")
    }
}
