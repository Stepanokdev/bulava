import XCTest
@testable import Bulava

nonisolated final class ForemanFenceTests: XCTestCase {

    private var root: URL!
    private var outside: URL!
    private var profile: URL!

    override func setUpWithError() throws {
        try XCTSkipUnless(ForemanFence.isAvailable, "no sandbox-exec on this machine")
        let fm = FileManager.default
        let stem = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("bulava-fence-\(UUID().uuidString)", isDirectory: true)
        root = stem.appendingPathComponent("product", isDirectory: true)
        outside = stem.appendingPathComponent("secrets", isDirectory: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        try fm.createDirectory(at: outside, withIntermediateDirectories: true)
        try Data("CANARY-OUTSIDE".utf8).write(to: outside.appendingPathComponent("creds.txt"))
        try Data("ok".utf8).write(to: root.appendingPathComponent("readme.txt"))

        try fm.createSymbolicLink(at: root.appendingPathComponent("way-out"),
                                  withDestinationURL: outside)

        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("bulava-fence-profiles-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        profile = try XCTUnwrap(ForemanFence.writeProfile(root: root.path, into: dir))
    }

    override func tearDownWithError() throws {
        for url in [root, outside, profile].compactMap({ $0?.deletingLastPathComponent() }) {
            try? FileManager.default.removeItem(at: url)
        }
    }

    private func readsUnderFence(_ path: String) throws -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sandbox-exec")
        process.arguments = ["-f", profile.path, "/bin/cat", path]
        process.currentDirectoryURL = root
        let out = Pipe()
        process.standardOutput = out
        process.standardError = FileHandle.nullDevice
        try process.run()
        let data = (try? out.fileHandleForReading.readToEnd()) ?? Data()
        process.waitUntilExit()
        return process.terminationStatus == 0 && !data.isEmpty
    }

    func testThisProductsRuntimeDirectoryIsReachable() throws {
        let mine = try XCTUnwrap(ForemanFence.runtimeDirectories(forRoot: root.path).first)
        try FileManager.default.createDirectory(atPath: mine, withIntermediateDirectories: true)
        let probe = URL(fileURLWithPath: mine).appendingPathComponent("probe.txt")
        try Data("ok".utf8).write(to: probe)
        defer { try? FileManager.default.removeItem(at: probe) }

        XCTAssertTrue(try readsUnderFence(probe.path),
                      "the CLI cannot open its own scratch — the session dies on its first message")
    }

    func testAnotherProjectsRuntimeScratchIsNotReadable() throws {
        let uid = getuid()
        let stranger = URL(fileURLWithPath: "/tmp/claude-\(uid)/-Users-someone-else-Secret-Project",
                           isDirectory: true)
        try FileManager.default.createDirectory(at: stranger, withIntermediateDirectories: true)
        let canary = stranger.appendingPathComponent("canary.txt")
        try Data("CANARY-OTHER-PROJECT".utf8).write(to: canary)
        defer { try? FileManager.default.removeItem(at: stranger) }

        XCTAssertFalse(try readsUnderFence(canary.path),
                       "the foreman can read another project's scratch")
        XCTAssertFalse(try readsUnderFence("/tmp/claude-\(uid)"),
                       "the parent of every project's scratch must stay closed")
    }

    func testAnotherSessionsSocketIsNotReadable() throws {
        let socks = URL(fileURLWithPath: "/tmp/cc-socks", isDirectory: true)
        try? FileManager.default.createDirectory(at: socks, withIntermediateDirectories: true)
        let pretend = socks.appendingPathComponent("bulava-fence-\(getpid()).sock")
        try Data("CANARY-SOCKET".utf8).write(to: pretend)
        defer { try? FileManager.default.removeItem(at: pretend) }

        XCTAssertFalse(try readsUnderFence(pretend.path),
                       "the foreman can reach another session's socket")
    }

    func testTheProductsOwnFilesAreReadable() throws {
        XCTAssertTrue(try readsUnderFence(root.appendingPathComponent("readme.txt").path),
                      "the fence exists to scope the foreman, not to blind him")
    }

    func testAnAbsolutePathOutsideTheProductIsRefused() throws {
        XCTAssertFalse(try readsUnderFence(outside.appendingPathComponent("creds.txt").path))
    }

    func testASymlinkOutOfTheProductIsRefused() throws {
        XCTAssertFalse(try readsUnderFence(root.appendingPathComponent("way-out/creds.txt").path))
    }

    func testTraversalOutOfTheProductIsRefused() throws {
        XCTAssertFalse(try readsUnderFence(root.appendingPathComponent("../secrets/creds.txt").path))
    }

    func testAnotherProjectOfHisIsNotReadable() throws {
        let other = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Developer")
        try XCTSkipUnless(FileManager.default.fileExists(atPath: other.path), "no Developer folder")
        let found = (try? FileManager.default.contentsOfDirectory(atPath: other.path))?
            .first { !$0.hasPrefix(".") }
        let probe: String = try XCTUnwrap(found)
        XCTAssertFalse(try readsUnderFence(other.appendingPathComponent(probe).path),
                       "one product's foreman must not be able to read another product")
    }

    func testTheDirectorsHomeIsNotReadable() throws {

        let home = FileManager.default.homeDirectoryForCurrentUser
        let candidates = [".zshrc", ".zprofile", ".gitconfig"]
            .map { home.appendingPathComponent($0).path }
            .filter { FileManager.default.fileExists(atPath: $0) }
        try XCTSkipIf(candidates.isEmpty, "no dotfile to probe with")
        for path in candidates {
            XCTAssertFalse(try readsUnderFence(path), "\(path) was readable through the fence")
        }
    }

    func testTheCLIsOwnConfigurationStaysReadable() throws {
        let claudeDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/settings.json").path
        try XCTSkipUnless(FileManager.default.fileExists(atPath: claudeDir), "no ~/.claude yet")
        XCTAssertTrue(try readsUnderFence(claudeDir))
    }

    // MARK: The profile itself

    func testAPathWithAQuoteCannotEndTheProfileEarly() {
        let nasty = "/tmp/we\"ird\\path"
        let text = ForemanFence.profile(root: nasty)
        XCTAssertTrue(text.contains(#"(subpath "/tmp/we\"ird\\path")"#),
                      "an unescaped quote would end the string and the rest would parse as something else")
    }

    func testTheProductIsAllowedLastSoItSurvivesLivingInsideADeniedRoot() {
        let text = ForemanFence.profile(root: "/Users/someone/Developer/thing", home: "/Users/someone")
        let denyLine = text.range(of: "(deny file-read-data")
        let allowProduct = text.range(of: #"(subpath "/Users/someone/Developer/thing")"#)
        XCTAssertNotNil(denyLine)
        XCTAssertNotNil(allowProduct)

        XCTAssertTrue(allowProduct!.lowerBound > denyLine!.lowerBound)
    }
}

// MARK: - What the fence must not open

nonisolated final class ForemanFenceScopeTests: XCTestCase {

    private var root: URL!
    private var profile: URL!

    override func setUpWithError() throws {
        try XCTSkipUnless(ForemanFence.isAvailable, "no sandbox-exec on this machine")
        let fm = FileManager.default

        root = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".bulava-scope-\(UUID().uuidString)/product", isDirectory: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("ok".utf8).write(to: root.appendingPathComponent("readme.txt"))
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("bulava-scope-p-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        profile = try XCTUnwrap(ForemanFence.writeProfile(root: root.path, into: dir))
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root.deletingLastPathComponent())
        try? FileManager.default.removeItem(at: profile.deletingLastPathComponent())
    }

    private func run(_ arguments: [String]) throws -> (ok: Bool, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sandbox-exec")
        process.arguments = ["-f", profile.path] + arguments
        process.currentDirectoryURL = root
        let out = Pipe()
        process.standardOutput = out
        process.standardError = FileHandle.nullDevice
        try process.run()
        let data = (try? out.fileHandleForReading.readToEnd()) ?? Data()
        process.waitUntilExit()
        return (process.terminationStatus == 0 && !data.isEmpty,
                String(decoding: data, as: UTF8.self))
    }

    private func reads(_ path: String) throws -> Bool { try run(["/bin/cat", path]).ok }

    // MARK: Reads inside ~/.claude

    func testTheTranscriptsOfOtherProductsAreNotReadable() throws {
        let projects = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/projects")
        let names = (try? FileManager.default.contentsOfDirectory(atPath: projects.path)) ?? []
        let mine = ForemanFence.sessionDirectory(forRoot: ForemanFence.realPath(root.path))
        let other = names.map { projects.appendingPathComponent($0) }
            .first { $0.path != mine && !$0.lastPathComponent.hasPrefix(".") }
        let dir = try XCTUnwrap(other, "no other product transcripts on this machine to probe with")
        _ = dir

        var probe: URL?
        for name in names {
            let candidate = projects.appendingPathComponent(name)
            guard candidate.path != mine else { continue }
            if let transcript = (try? FileManager.default.contentsOfDirectory(atPath: candidate.path))?
                .first(where: { $0.hasSuffix(".jsonl") }) {
                probe = candidate.appendingPathComponent(transcript); break
            }
        }
        let target = try XCTUnwrap(probe, "no other product has a transcript to probe with")
        XCTAssertFalse(try reads(target.path),
                       "one product's foreman could read another product's whole conversation")
    }

    func testHisCrossProjectPromptHistoryIsNotReadable() throws {
        let history = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/history.jsonl")
        try XCTSkipUnless(FileManager.default.fileExists(atPath: history.path), "no history.jsonl")
        XCTAssertFalse(try reads(history.path))
    }

    func testAnArbitraryFileInsideDotClaudeIsNotReadable() throws {

        let probe = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/bulava-scope-probe.txt")
        try Data("SCOPE-CANARY".utf8).write(to: probe)
        defer { try? FileManager.default.removeItem(at: probe) }
        XCTAssertFalse(try reads(probe.path))
    }

    func testTheNamedConfigurationFilesAreReadable() throws {
        let settings = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/settings.json")
        try XCTSkipUnless(FileManager.default.fileExists(atPath: settings.path), "no settings.json")
        XCTAssertTrue(try reads(settings.path))
    }

    func testItsOwnSessionDirectoryIsReadable() throws {
        let mine = URL(fileURLWithPath:
            ForemanFence.sessionDirectory(forRoot: ForemanFence.realPath(root.path)))
        let probe = mine.appendingPathComponent("probe.jsonl")
        try Data("{}".utf8).write(to: probe)
        XCTAssertTrue(try reads(probe.path), "--resume reads the transcript it wrote")
    }

    func testAnotherApplicationsDataInLibraryIsNotReadable() throws {
        let probe = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/bulava-scope-probe.txt")
        try? FileManager.default.createDirectory(at: probe.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try Data("LIBRARY-CANARY".utf8).write(to: probe)
        defer { try? FileManager.default.removeItem(at: probe) }
        XCTAssertFalse(try reads(probe.path),
                       "Application Support is other apps' data, not the foreman's")
    }

    // MARK: Writes

    func testNothingMayWriteInsideTheProduct() throws {
        let result = try run(["/bin/sh", "-c", "echo x > ./written.txt"])
        XCTAssertFalse(result.ok)
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: root.appendingPathComponent("written.txt").path),
            "the foreman has no tool that writes, and a project hook must not either")
    }

    func testNothingMayWriteIntoHisHome() throws {
        let target = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".bulava-scope-written")
        _ = try run(["/bin/sh", "-c", "echo x > \(target.path)"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: target.path))
        try? FileManager.default.removeItem(at: target)
    }

    func testTheSessionMayStillWriteItsOwnTranscript() throws {
        let mine = ForemanFence.sessionDirectory(forRoot: ForemanFence.realPath(root.path))
        let result = try run(["/bin/sh", "-c", "echo '{}' > \(mine)/written.jsonl && echo done"])
        XCTAssertTrue(result.ok, "a session that cannot write its transcript cannot be resumed")
        try? FileManager.default.removeItem(atPath: mine + "/written.jsonl")
    }

    // MARK: The profile

    func testTheProfileNamesFilesInDotClaudeRatherThanTheDirectory() {
        let text = ForemanFence.profile(root: "/Users/someone/p", home: "/Users/someone")
        XCTAssertTrue(text.contains(#"(literal "/Users/someone/.claude/settings.json")"#))
        XCTAssertFalse(text.contains(#"(subpath "/Users/someone/.claude")"#),
                       "a subpath on ~/.claude opens every other product's transcript")
        XCTAssertFalse(text.contains(#"(subpath "/Users/someone/Library")"#),
                       "a subpath on ~/Library opens every other application's data")
        XCTAssertTrue(text.contains("(deny file-write*)"))
    }
}

// MARK: - The real CLI, under the real fence

nonisolated final class ForemanFenceLiveTests: XCTestCase {

    func testAPromptedTurnCompletesUnderTheFence() throws {
        try XCTSkipUnless(ForemanFence.isAvailable, "no sandbox-exec on this machine")
        let fm = FileManager.default
        let stem = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("bulava-fence-live-\(UUID().uuidString)", isDirectory: true)
        let root = stem.appendingPathComponent("product", isDirectory: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("# Product\n".utf8).write(to: root.appendingPathComponent("README.md"))
        defer { try? fm.removeItem(at: stem) }
        let profile = try XCTUnwrap(ForemanFence.writeProfile(root: root.path, into: stem))

        let claude = ["/opt/homebrew/bin/claude", "/usr/local/bin/claude",
                      fm.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin/claude").path]
            .first { fm.isExecutableFile(atPath: $0) }
        try XCTSkipIf(claude == nil, "no claude on this machine")

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")

        process.arguments = ["-lc", "exec /usr/bin/sandbox-exec -f \"$1\" \"$2\" \"${@:3}\"",
                             "ns", profile.path, claude!,
                             "-p", "Answer with one word: ok",
                             "--tools", "", "--strict-mcp-config"]
        process.currentDirectoryURL = root
        var env = ProcessInfo.processInfo.environment
        env.removeValue(forKey: "ANTHROPIC_API_KEY")
        env.removeValue(forKey: "ANTHROPIC_AUTH_TOKEN")
        process.environment = env
        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err
        try process.run()

        let stdout = String(data: (try? out.fileHandleForReading.readToEnd()) ?? Data(), encoding: .utf8) ?? ""
        let stderr = String(data: (try? err.fileHandleForReading.readToEnd()) ?? Data(), encoding: .utf8) ?? ""
        process.waitUntilExit()

        XCTAssertFalse(stderr.contains("EPERM"),
                       "the fence refused the CLI its own files:\n\(stderr.prefix(500))")
        try XCTSkipIf(process.terminationStatus != 0 && stderr.localizedCaseInsensitiveContains("login"),
                      "this machine is not signed in to Claude")
        XCTAssertEqual(process.terminationStatus, 0,
                       "the turn did not complete under the fence:\n\(stderr.prefix(500))")
        XCTAssertTrue(stdout.localizedCaseInsensitiveContains("ok"),
                      "no answer came back:\n\(stdout.prefix(300))")
    }
}
