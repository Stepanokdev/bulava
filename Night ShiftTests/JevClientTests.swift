import XCTest
@testable import Bulava

/// Settings → Jev reads what the engine's `jev.sh` prints. The section is only as right as this
/// reading: a mode it misreads is a switch that says "off" over an engine that is asking Jev.
nonisolated final class JevClientTests: XCTestCase {

    func testStatusAsTheEnginePrintsIt() throws {
        let json = #"{"mode":"on","key":true,"model":"jev-1.13.0","decisions":3}"#
        let s = try JSONDecoder().decode(JevStatus.self, from: Data(json.utf8))
        XCTAssertEqual(s, JevStatus(mode: "on", key: true, model: "jev-1.13.0", decisions: 3))
        XCTAssertTrue(s.isOn)
    }

    /// Shadow is on: Jev is asked, only its answer does not decide. The switch must show it on.
    func testShadowCountsAsOnAndOffDoesNot() throws {
        let shadow = JevStatus(mode: "shadow", key: true, model: "jev-1.13.0", decisions: 0)
        let off = JevStatus(mode: "off", key: true, model: "jev-1.13.0", decisions: 0)
        XCTAssertTrue(shadow.isOn)
        XCTAssertFalse(off.isOn)
    }

    func testACheckThatAnswered() throws {
        let json = #"{"ok":true,"model":"jev-1.13.0","seconds":0.187475,"input_tokens":352,"verdict":"continue","p":0.06}"#
        let r = try JSONDecoder().decode(JevTestResult.self, from: Data(json.utf8))
        XCTAssertTrue(r.ok)
        XCTAssertEqual(r.inputTokens, 352)
        XCTAssertEqual(r.verdict, "continue")
        XCTAssertEqual(r.seconds ?? 0, 0.187475, accuracy: 0.000001)
    }

    func testACheckThatFailedNamesWhy() throws {
        let r = try JSONDecoder().decode(JevTestResult.self, from: Data(#"{"ok":false,"error":"http-401"}"#.utf8))
        XCTAssertFalse(r.ok)
        XCTAssertEqual(r.error, "http-401")
        XCTAssertNil(r.inputTokens)
    }

    /// The real engine of this checkout, in a state directory of its own: what it prints is what
    /// the decoder above reads, and the key never appears in it.
    @MainActor func testTheEngineScriptAnswersInThatShape() async throws {
        let engine = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("engine/bin/jev.sh")
        guard FileManager.default.fileExists(atPath: engine.path) else { throw XCTSkip("no engine in this checkout") }
        let state = FileManager.default.temporaryDirectory.appendingPathComponent("bulava-jev-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: state, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: state) }
        let keyCmd = state.appendingPathComponent("key")
        try "#!/bin/bash\nprintf ts_test_KEY_0123456789abcdef\n".write(to: keyCmd, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: keyCmd.path)
        let env = ["SUPERVISOR_STATE_DIR": state.path, "SUPERVISOR_JEV_KEY_CMD": keyCmd.path]

        let mode = await Shell.run("bash \"$1\" mode on", args: [engine.path], extraEnv: env, timeout: 20)
        XCTAssertTrue(mode.ok, mode.combined)
        let r = await Shell.run("bash \"$1\" status --json", args: [engine.path], extraEnv: env, timeout: 20)
        XCTAssertTrue(r.ok, r.combined)
        let s = try JSONDecoder().decode(JevStatus.self, from: Data(r.stdout.utf8))
        XCTAssertEqual(s.mode, "on")
        XCTAssertTrue(s.key)
        XCTAssertFalse(r.stdout.contains("ts_test_KEY"))
    }
}
