import XCTest
@testable import Bulava

/// A checkpoint too big because of a few files names those files, and the app reads that list.
///
/// The director's folder held a four-gigabyte screen recording, untracked, and every start there
/// ended in a red paragraph about megabytes. The engine now stops with exit 79 and writes the
/// biggest files down (`heavy-state`); the chat shows them with «leave them out and send». These
/// tests hold the two halves to one contract: what the engine writes is what the app parses.
nonisolated final class HeavyFilesTests: XCTestCase {

    private var engine: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("engine")
    }

    private func run(_ dir: URL, _ tool: String, _ args: String...) throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = args
        p.currentDirectoryURL = dir
        p.environment = ["HOME": dir.path, "GIT_CONFIG_NOSYSTEM": "1", "PATH": "/usr/bin:/bin:/usr/sbin"]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try p.run(); p.waitUntilExit()
        XCTAssertEqual(p.terminationStatus, 0, "\(tool) \(args.joined(separator: " "))")
    }

    // MARK: The engine's list, as the app reads it

    @MainActor
    func testTheEnginesListIsWhatTheAppReads() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("bulava-heavy-\(UUID().uuidString)").resolvingSymlinksInPath()
        let dir = root.appendingPathComponent("project"), state = root.appendingPathComponent("state")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: state, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }

        try run(dir, "/usr/bin/git", "init", "-q", "-b", "main")
        try run(dir, "/usr/bin/git", "config", "user.name", "Ihor Director")
        try run(dir, "/usr/bin/git", "config", "user.email", "ihor@example.com")
        try "weights\n".write(to: dir.appendingPathComponent("model.bin"), atomically: true, encoding: .utf8)
        try run(dir, "/usr/bin/git", "add", "model.bin")
        try run(dir, "/usr/bin/git", "commit", "-qm", "base")
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("Movies"), withIntermediateDirectories: true)
        try run(dir, "/usr/sbin/mkfile", "-n", "3m", "Movies/Screen Recording [final].mov")
        try run(dir, "/usr/sbin/mkfile", "-n", "1800k", "model.bin") // tracked, grown past the one-file limit
        try "note\n".write(to: dir.appendingPathComponent("readme.md"), atomically: true, encoding: .utf8)

        let env = ["SUPERVISOR_STATE_DIR": state.path,
                   "SUPERVISOR_CHECKPOINT_MAX_BYTES": "2097152",
                   "SUPERVISOR_CHECKPOINT_MAX_FILE_BYTES": "1572864"]
        let record = await Shell.run(#"bash -c '. "$1/bin/supervisor-lib.sh"; checkpoint_heavy_record "$2"' _ "$1" "$2""#,
                                     args: [engine.path, dir.path], extraEnv: env, timeout: 60)
        XCTAssertEqual(record.exitCode, 0, record.combined)
        let r = await Shell.run("bash \"$1/bin/night-shift.sh\" heavy-state \"$2\"",
                                args: [engine.path, dir.path], extraEnv: env, timeout: 60)
        XCTAssertEqual(r.exitCode, 0, r.stderr)
        let files = try XCTUnwrap(HeavyFiles.parse(r.stdout), "unparseable: \(r.stdout)")

        XCTAssertEqual(files.files.map(\.path), ["Movies/Screen Recording [final].mov", "model.bin"], "biggest first")
        let movie = try XCTUnwrap(files.files.first)
        XCTAssertEqual(movie.name, "Screen Recording [final].mov")
        XCTAssertEqual(movie.folder, "Movies")
        XCTAssertEqual(movie.size, 3 * 1_048_576)
        XCTAssertFalse(movie.tracked)
        XCTAssertEqual(movie.rule, #"/Movies/Screen Recording \[final\].mov"#, "anchored, the glob class escaped")
        XCTAssertTrue(movie.canLeaveOut)
        let weights = try XCTUnwrap(files.files.last)
        XCTAssertTrue(weights.tracked)
        XCTAssertNil(weights.rule, "a tracked file has no rule — a rule would not untrack it")
        XCTAssertFalse(weights.canLeaveOut)
        XCTAssertEqual(weights.folder, "", "a file at the top lies in no folder")
        XCTAssertEqual(files.limitBytes, 2_097_152)
        XCTAssertGreaterThan(files.totalBytes, files.limitBytes)
        XCTAssertFalse(files.fitsAfter, "the tracked file alone is over the one-file limit")
        XCTAssertTrue(files.canLeaveOut)
        XCTAssertEqual(files.tracked.map(\.path), ["model.bin"])
    }

    // MARK: Parsing

    func testAPayloadParsesAndSaysWhatTheButtonsCanDo() throws {
        let text = """
        ⚠ a line the engine printed first
        {"fits_after":true,"file_limit_bytes":268435456,"files":[{"path":"Screen Recording 2026-09-30.mov","rule":"/Screen Recording 2026-09-30.mov","size":4013948928,"tracked":false}],"limit_bytes":1073741824,"remaining_bytes":1204,"total_bytes":4013950132}
        """
        let files = try XCTUnwrap(HeavyFiles.parse(text))
        XCTAssertEqual(files.totalBytes, 4_013_950_132)
        XCTAssertEqual(files.remainingBytes, 1204)
        XCTAssertTrue(files.fitsAfter)
        XCTAssertEqual(files.leavable.count, 1)
        XCTAssertTrue(files.tracked.isEmpty)
        XCTAssertEqual(files.files[0].folder, "")
        XCTAssertNil(HeavyFiles.parse("{\"error\":\"none\"}"), "the engine's «nothing recorded» is not a list")
        XCTAssertNil(HeavyFiles.parse(""))
    }

    func testOnlyTrackedFilesLeaveNothingToPressAndSaySo() throws {
        let text = #"{"fits_after":false,"file_limit_bytes":100,"files":[{"path":"assets/big.psd","rule":null,"size":500,"tracked":true}],"limit_bytes":1000,"remaining_bytes":500,"total_bytes":500}"#
        let files = try XCTUnwrap(HeavyFiles.parse(text))
        XCTAssertFalse(files.canLeaveOut, "an ignore rule cannot take out a tracked file")
        XCTAssertEqual(files.files[0].folder, "assets")
        XCTAssertNotNil(HeavyFilesRow.trackedNote(files), "the row explains instead of offering what would not work")
        XCTAssertFalse(HeavyFilesRow.headline(files).isEmpty)
    }

    func testAFileNoRuleCanHoldIsNotOffered() throws {
        let text = #"{"fits_after":true,"file_limit_bytes":100,"files":[{"path":"odd\nname.bin","rule":null,"size":500,"tracked":false}],"limit_bytes":1000,"remaining_bytes":0,"total_bytes":500}"#
        let files = try XCTUnwrap(HeavyFiles.parse(text))
        XCTAssertFalse(files.files[0].canLeaveOut)
        XCTAssertFalse(files.canLeaveOut)
    }
}
