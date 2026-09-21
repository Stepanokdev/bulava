import XCTest
@testable import Bulava

nonisolated final class SlugTests: XCTestCase {

    func testSlugMatchesEngineInstance() {
        // Values computed against the engine's own rule — sanitized basename plus the first 12
        // hex of the SHA-1 of the canonical path — rather than copied off this machine's live
        // instances. They used to be copied, which put two of the author's client paths into a
        // test that will be read by strangers.
        XCTAssertEqual(Slug.forPath("/Users/dev/Developer/MyProjects/Night Shift"),
                       "Night-Shift-03b9a496a889")
        XCTAssertEqual(Slug.forPath("/Users/dev/Developer/Clients/pocket-ledger"),
                       "pocket-ledger-d36bb3c26f66")
    }

    func testBasenameSanitized() {

        let slug = Slug.forPath("/tmp/My Project!! (v2)")
        XCTAssertTrue(slug.hasPrefix("My-Project-v2-"), slug)
        XCTAssertFalse(slug.contains("--"))
    }

    func testCanonicalPathHasNoTrailingSlash() {
        XCTAssertFalse(Slug.canonicalPath("/usr/").hasSuffix("/"))
    }
}

nonisolated final class TemporarySessionCleanupTests: XCTestCase {
    func testOnlyDeletedNightShiftProjectsUnderTempAreDisposable() {
        let root = "/private/var/folders/example/T"
        let fixture = root + "/tmp.ABC123/project"

        XCTAssertTrue(SupervisorClient.isAbandonedTemporarySession(
            name: "night-project-123", workingDirectory: fixture,
            temporaryRoot: root, pathExists: false))
        XCTAssertFalse(SupervisorClient.isAbandonedTemporarySession(
            name: "night-project-123", workingDirectory: fixture,
            temporaryRoot: root, pathExists: true), "a running fixture is not an orphan")
        XCTAssertFalse(SupervisorClient.isAbandonedTemporarySession(
            name: "my-terminal", workingDirectory: fixture,
            temporaryRoot: root, pathExists: false), "unrelated tmux sessions are never touched")
        XCTAssertFalse(SupervisorClient.isAbandonedTemporarySession(
            name: "night-ledger", workingDirectory: "/Users/dev/Developer/ledger",
            temporaryRoot: root, pathExists: false), "real project paths are never swept")
    }
}

nonisolated final class CaptureClassifierTests: XCTestCase {
    func testTypeFromKeywords() {
        XCTAssertEqual(CaptureClassifier.suggestType(for: "fix the crash on launch"), .bug)
        XCTAssertEqual(CaptureClassifier.suggestType(for: "adjust spacing in the layout"), .design)
        XCTAssertEqual(CaptureClassifier.suggestType(for: "write SEO articles"), .content)
        XCTAssertEqual(CaptureClassifier.suggestType(for: "додай свайп меню"), .feature)
    }

    func testPriorityFromKeywords() {
        XCTAssertEqual(CaptureClassifier.suggestPriority(for: "URGENT: prod is down"), .p0)
        XCTAssertEqual(CaptureClassifier.suggestPriority(for: "important cleanup"), .p1)
        XCTAssertEqual(CaptureClassifier.suggestPriority(for: "someday maybe"), .p2)
    }

    func testProjectMatchByName() {
        let projects = [Project(name: "Narada", path: "/a/Narada"),
                        Project(name: "Map Alerts", path: "/a/Map Alerts")]
        let id = CaptureClassifier.suggestProject(for: "bug in map alerts screen", in: projects)
        XCTAssertEqual(id, projects[1].id)
    }
}

nonisolated final class BacklogTaskTests: XCTestCase {
    func testDispatchTextCarriesFeedbackAndAttachments() {
        var task = BacklogTask(title: "Swipe menu", detail: "left swipe hides it",
                               projectPath: "/p", type: .feature)
        task.reviewFeedback = ["animation too slow"]
        task.attachments = [Attachment(kind: .image, filename: "before.png", relativePath: "before.png")]
        let text = task.dispatchText
        XCTAssertTrue(text.contains("Swipe menu"))
        XCTAssertTrue(text.contains("left swipe hides it"))
        XCTAssertTrue(text.contains("animation too slow"))
        XCTAssertTrue(text.contains("before.png"))
    }

    func testExternalBlockerMakesUndispatchable() {
        var task = BacklogTask(title: "IAP", projectPath: "/p", state: .ready)
        XCTAssertTrue(task.isDispatchable)
        task.externalBlocker = "backend PR #481"
        XCTAssertFalse(task.isDispatchable)
    }

    func testSchemaTolerantDecodeOfOldRecord() throws {

        let json = """
        {"id":"\(UUID().uuidString)","title":"Legacy","detail":"","projectID":null,
         "projectPath":null,"type":"feature","priority":2,"state":"ready",
         "createdAt":"2026-01-01T00:00:00Z","updatedAt":"2026-01-01T00:00:00Z",
         "reviewFeedback":[],"attachments":[]}
        """.data(using: .utf8)!
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
        let task = try dec.decode(BacklogTask.self, from: json)
        XCTAssertEqual(task.title, "Legacy")
        XCTAssertTrue(task.dependsOn.isEmpty)
        XCTAssertNil(task.boundBranch)
    }
}

nonisolated final class BacklogStoreSchedulingTests: XCTestCase {
    @MainActor private func freshStore() -> BacklogStore {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("nsbstest-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return BacklogStore(fileURL: dir.appendingPathComponent("backlog.json"),
                            adoptedURL: dir.appendingPathComponent("adopted.json"))
    }

    @MainActor func testDependencyGatesAndResumes() {
        let store = freshStore()
        let base = store.add(BacklogTask(title: "Ship API", projectPath: "/p", state: .ready))
        var dependent = BacklogTask(title: "Wire UI", projectPath: "/p", state: .ready)
        dependent.dependsOn = [base.id]
        dependent.autoResume = true
        store.add(dependent)

        XCTAssertTrue(store.isBlocked(store.task(id: dependent.id)!))
        XCTAssertFalse(store.resumable().contains { $0.id == dependent.id })

        store.setState(base.id, .executing)
        XCTAssertTrue(store.isBlocked(store.task(id: dependent.id)!))

        store.setState(base.id, .merged)
        XCTAssertFalse(store.isBlocked(store.task(id: dependent.id)!))
        XCTAssertTrue(store.resumable().contains { $0.id == dependent.id })
    }

    @MainActor func testResumableExcludesAlreadyDispatched() {
        let store = freshStore()
        var t = BacklogTask(title: "One-shot", projectPath: "/p", state: .ready)
        t.autoResume = true
        let added = store.add(t)
        XCTAssertTrue(store.resumable().contains { $0.id == added.id })
        store.markDispatched(added.id)
        XCTAssertFalse(store.resumable().contains { $0.id == added.id })
    }

    @MainActor func testExternalPRBlockerDetection() {
        let store = freshStore()
        var pr = BacklogTask(title: "Behind PR", projectPath: "/p", state: .ready)
        pr.externalBlocker = "backend PR #481"
        store.add(pr)
        var vague = BacklogTask(title: "Behind ops", projectPath: "/p", state: .ready)
        vague.externalBlocker = "waiting on the ops team"
        store.add(vague)

        let flagged = store.withExternalPRBlocker()
        XCTAssertTrue(flagged.contains { $0.title == "Behind PR" })
        XCTAssertFalse(flagged.contains { $0.title == "Behind ops" })
    }
}

nonisolated final class DecoderTests: XCTestCase {

    func testPressureThresholdsAreWhereTheColourChanges() {
        func p(_ v: Double) -> UsagePressure { UsageWindow(usedPercent: v, resetsAt: nil).pressure }
        XCTAssertEqual(p(0), .comfortable)
        XCTAssertEqual(p(74.9), .comfortable)
        XCTAssertEqual(p(75), .tight)
        XCTAssertEqual(p(89.9), .tight)
        XCTAssertEqual(p(90), .nearlyOut)
        XCTAssertEqual(p(100), .nearlyOut)

        XCTAssertEqual(p(-5), .comfortable)
        XCTAssertEqual(p(140), .nearlyOut)
    }

    func testUsageDecodeHandlesIntAndDoublePercent() {
        let intJSON = #"{"ts":1,"five_hour":{"used_percentage":37,"resets_at":100}}"#.data(using: .utf8)!
        let dblJSON = #"{"ts":1,"five_hour":{"used_percentage":0.0,"resets_at":0}}"#.data(using: .utf8)!
        XCTAssertEqual(UsageSnapshot.decode(from: intJSON)?.fiveHour.usedPercent, 37)
        XCTAssertEqual(UsageSnapshot.decode(from: dblJSON)?.fiveHour.usedPercent, 0)
        XCTAssertNil(UsageSnapshot.decode(from: dblJSON)?.fiveHour.resetsAt)
    }

    func testEvidenceDecodeAndCounts() {
        let json = #"""
        {"project_dir":"/p","session_id":"s","base_sha":"abc","stacks":["backend-go"],
         "criteria":[{"criterion":"go builds","command":"go build ./...","exit_code":0,"artifact":"x","status":"pass","note":""},
                     {"criterion":"go tests","command":"go test ./...","exit_code":1,"artifact":"y","status":"fail","note":""}],
         "overall_status":"fail"}
        """#.data(using: .utf8)!
        let ev = Evidence.decode(from: json)
        XCTAssertEqual(ev?.overallStatus, .fail)
        XCTAssertEqual(ev?.passed, 1)
        XCTAssertEqual(ev?.failed, 1)
    }

    func testQueueOutcomeMapping() {
        XCTAssertTrue(QueueOutcome(raw: "passed").isSuccess)
        XCTAssertTrue(QueueOutcome(raw: "needs-user").needsAttention)
        XCTAssertEqual(QueueOutcome(raw: "debt").label, "Review debt")
    }

    func testTrimmedTail() {
        XCTAssertEqual("hi\n\n".trimmedTail, "hi")
        XCTAssertEqual("a\nb\n".trimmedTail, "a\nb")
    }
}

nonisolated final class ProjectScannerTests: XCTestCase {
    func testDetectsGoBackend() throws {
        let dir = try makeTempDir()
        try "module x".write(to: dir.appendingPathComponent("go.mod"), atomically: true, encoding: .utf8)
        let (kind, stacks) = ProjectScanner.detect(path: dir.path)
        XCTAssertEqual(kind, .backendGo)
        XCTAssertTrue(stacks.contains("backend-go"))
    }

    func testDetectsWebLandingVsFrontend() throws {
        let dir = try makeTempDir()
        try #"{"dependencies":{"react":"18"}}"#.write(to: dir.appendingPathComponent("package.json"), atomically: true, encoding: .utf8)
        XCTAssertEqual(ProjectScanner.detect(path: dir.path).kind, .webFrontend)
    }

    private func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("nstest-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
}
