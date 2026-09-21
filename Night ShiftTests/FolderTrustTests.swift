import XCTest
@testable import Bulava

nonisolated final class FolderTrustTests: XCTestCase {

    private func config(_ pairs: [(String, Bool?)]) -> Data {
        var projects: [String: Any] = [:]
        for (path, accepted) in pairs {
            projects[path] = accepted.map { ["hasTrustDialogAccepted": $0] } ?? [:]
        }
        return try! JSONSerialization.data(withJSONObject: ["projects": projects])
    }

    func testATrustedFolderIsTrusted() {
        let data = config([("/Users/x/work/app", true)])
        XCTAssertEqual(ClaudeFolderTrust.verdict(forProjectPath: "/Users/x/work/app", config: data,
                                                 repoRoot: nil),
                       .trusted)
    }

    func testAFolderNobodyHasOpenedWillAsk() {
        let data = config([("/Users/x/other", true)])
        XCTAssertEqual(ClaudeFolderTrust.verdict(forProjectPath: "/Users/x/work/app", config: data,
                                                 repoRoot: nil),
                       .willAsk, "never opened means the dialog is still coming")
    }

    func testTrustInheritsDownTheTree() {
        let data = config([("/Users/x/work", true)])
        XCTAssertEqual(ClaudeFolderTrust.verdict(forProjectPath: "/Users/x/work/app/sub",
                                                 config: data, repoRoot: nil),
                       .trusted, "a subfolder of a trusted repo needs no answer of its own")
    }

    func testAFalseIsAnUnansweredEntryAndNotARefusal() {

        let data = config([("/Users/x/work", true), ("/Users/x/work/app", false)])
        XCTAssertEqual(ClaudeFolderTrust.verdict(forProjectPath: "/Users/x/work/app", config: data,
                                                 repoRoot: nil),
                       .trusted)
    }

    func testAFalseWithNoYesAboveItStillAsks() {
        let data = config([("/Users/x/work/app", false)])
        XCTAssertEqual(ClaudeFolderTrust.verdict(forProjectPath: "/Users/x/work/app", config: data,
                                                 repoRoot: nil),
                       .willAsk)
    }

    func testAnEntryWithoutTheFlagKeepsLookingUpward() {
        let data = config([("/Users/x/work", true), ("/Users/x/work/app", nil)])
        XCTAssertEqual(ClaudeFolderTrust.verdict(forProjectPath: "/Users/x/work/app", config: data,
                                                 repoRoot: nil),
                       .trusted, "no answer recorded is not the same as a no")
    }

    func testTrustStopsAtTheRepositoryRoot() {

        let data = config([("/Users/x/work", true)])
        XCTAssertEqual(ClaudeFolderTrust.verdict(forProjectPath: "/Users/x/work/app/sub",
                                                 config: data, repoRoot: "/Users/x/work/app"),
                       .willAsk, "a trusted umbrella does not cover a repository checked out inside it")
    }

    func testTheRepositoryRootItselfIsTheLastPlaceItLooks() {
        let data = config([("/Users/x/work/app", true)])
        XCTAssertEqual(ClaudeFolderTrust.verdict(forProjectPath: "/Users/x/work/app/sub",
                                                 config: data, repoRoot: "/Users/x/work/app"),
                       .trusted)
    }

    func testUnreadableRecordIsUnknownAndNeverAnAlarm() {
        XCTAssertEqual(ClaudeFolderTrust.verdict(forProjectPath: "/Users/x/work/app",
                                                 config: Data("not json".utf8), repoRoot: nil),
                       .unknown)
        XCTAssertEqual(ClaudeFolderTrust.verdict(forProjectPath: "/x",
                                                 configURL: URL(fileURLWithPath: "/nope/.claude.json")),
                       .unknown, "a fresh machine has no record, and that is not a problem to report")
    }

    // MARK: Saying yes

    private func scratchConfig() throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("claude-\(UUID().uuidString).json")
        let body: [String: Any] = [
            "oauthAccount": ["emailAddress": "someone@example.com"],
            "numStartups": 41,
            "projects": ["/Users/x/elsewhere": ["hasTrustDialogAccepted": true,
                                                "history": ["one", "two"]]],
        ]
        try JSONSerialization.data(withJSONObject: body).write(to: url)
        return url
    }

    func testGrantingTrustIsWhatTheDialogWouldHaveWritten() throws {
        let config = try scratchConfig()
        defer { try? FileManager.default.removeItem(at: config) }
        let repo = try makeRepo()
        defer { try? FileManager.default.removeItem(at: repo.deletingLastPathComponent()) }

        XCTAssertEqual(ClaudeFolderTrust.verdict(forProjectPath: repo.path, configURL: config),
                       .willAsk)
        XCTAssertTrue(ClaudeFolderTrust.grant(forProjectPath: repo.path, configURL: config))
        XCTAssertEqual(ClaudeFolderTrust.verdict(forProjectPath: repo.path, configURL: config),
                       .trusted)
    }

    func testAGrantAnswersForTheWholeRepositoryNotJustTheSubfolder() {

        let config = try! scratchConfig()
        defer { try? FileManager.default.removeItem(at: config) }
        let repo = try! makeRepo()
        defer { try? FileManager.default.removeItem(at: repo.deletingLastPathComponent()) }
        let sub = repo.appendingPathComponent("Sources")
        try! FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)

        XCTAssertTrue(ClaudeFolderTrust.grant(forProjectPath: sub.path, configURL: config))
        XCTAssertEqual(ClaudeFolderTrust.verdict(forProjectPath: repo.path, configURL: config),
                       .trusted, "the repository is the unit Claude Code asks about")
    }

    func testGrantingKeepsEverythingElseInTheFileIntact() throws {

        let config = try scratchConfig()
        defer { try? FileManager.default.removeItem(at: config) }
        let repo = try makeRepo()
        defer { try? FileManager.default.removeItem(at: repo.deletingLastPathComponent()) }

        XCTAssertTrue(ClaudeFolderTrust.grant(forProjectPath: repo.path, configURL: config))
        let root = try JSONSerialization.jsonObject(with: Data(contentsOf: config)) as? [String: Any]
        XCTAssertEqual(root?["numStartups"] as? Int, 41)
        XCTAssertEqual((root?["oauthAccount"] as? [String: Any])?["emailAddress"] as? String,
                       "someone@example.com")
        let projects = root?["projects"] as? [String: Any]
        let untouched = projects?["/Users/x/elsewhere"] as? [String: Any]
        XCTAssertEqual(untouched?["hasTrustDialogAccepted"] as? Bool, true)
        XCTAssertEqual((untouched?["history"] as? [String])?.count, 2)
        XCTAssertEqual(try FileManager.default
            .attributesOfItem(atPath: config.path)[.posixPermissions] as? Int, 0o600,
                       "a private file must not come back from an atomic write world-readable")
    }

    func testAGrantIntoAFileThatIsNotThereFailsInsteadOfInventingOne() {
        XCTAssertFalse(ClaudeFolderTrust.grant(forProjectPath: "/Users/x/work/app",
                                               configURL: URL(fileURLWithPath: "/nope/.claude.json")))
    }

    func testNothingToAnswerMeansNoFolderToOffer() throws {
        let config = try scratchConfig()
        defer { try? FileManager.default.removeItem(at: config) }
        XCTAssertNil(ClaudeFolderTrust.folderNeedingTrust(forProjectPath: "/Users/x/elsewhere",
                                                          configURL: config))
    }

    private func makeRepo() throws -> URL {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("trust-\(UUID().uuidString)")
        let repo = tmp.appendingPathComponent("repo")
        try FileManager.default.createDirectory(at: repo.appendingPathComponent(".git"),
                                                withIntermediateDirectories: true)
        return URL(fileURLWithPath: Slug.canonicalPath(repo.path))
    }

    func testTheRepositoryIsFoundThroughASubmodulePointerFile() throws {

        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("trust-\(UUID().uuidString)")
        let repo = tmp.appendingPathComponent("outer/inner")
        let deep = repo.appendingPathComponent("Sources")
        try FileManager.default.createDirectory(at: deep, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        try "gitdir: ../.git/modules/inner".write(to: repo.appendingPathComponent(".git"),
                                                  atomically: true, encoding: .utf8)
        XCTAssertEqual(ClaudeFolderTrust.repoRoot(containing: deep.path),
                       Slug.canonicalPath(repo.path))
    }
}
