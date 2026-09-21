import XCTest
@testable import Bulava

/// "I don't understand which skills are just for this project, and those numbers mean nothing."
///
/// The number beside each skill was a machine-wide total: 17 uses of `minimalist-ui` says nothing
/// about whether THIS product has ever wanted it. These pin down the narrower count, read from the
/// transcripts of one project.
nonisolated final class SkillsPerProjectTests: XCTestCase {

    // MARK: - Finding a project's transcripts

    func testTheTranscriptFolderIsThePathWithSlashesFlattened() {
        XCTAssertEqual(
            SkillUseInProject.directoryName(forProjectPath: "/Users/dev/Developer/pocket-ledger"),
            "-Users-dev-Developer-pocket-ledger")
    }

    private func projects(_ names: [String]) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("claude-projects-\(UUID().uuidString)")
        for name in names {
            try FileManager.default.createDirectory(at: root.appendingPathComponent(name),
                                                    withIntermediateDirectories: true)
        }
        return root
    }

    func testAProjectsOwnFolderIsFound() throws {
        let root = try projects(["-Users-dev-Developer-pocket-ledger",
                                 "-Users-dev-Developer-something-else"])
        defer { try? FileManager.default.removeItem(at: root) }

        let found = SkillUseInProject.directories(
            forProjectPath: "/Users/dev/Developer/pocket-ledger", root: root)
            .map(\.lastPathComponent)
        XCTAssertEqual(found, ["-Users-dev-Developer-pocket-ledger"])
    }

    /// A night's work often happens entirely inside a worktree, which is its own working folder
    /// with its own transcripts. Counting only the main folder reported zero for a project that
    /// had been worked on seven times.
    func testWorktreesOfTheSameProjectCount() throws {
        let root = try projects([
            "-Users-dev-Developer-pocket-ledger",
            "-Users-dev-Developer--nightshift-worktrees-pocket-ledger-3CC6DEF7",
            "-Users-dev-Developer--nightshift-worktrees-pocket-ledger-52F3B57A",
            "-Users-dev-Developer--nightshift-worktrees-other-app-99999999",
        ])
        defer { try? FileManager.default.removeItem(at: root) }

        let found = Set(SkillUseInProject.directories(
            forProjectPath: "/Users/dev/Developer/pocket-ledger", root: root)
            .map(\.lastPathComponent))
        XCTAssertEqual(found.count, 3)
        XCTAssertFalse(found.contains("-Users-dev-Developer--nightshift-worktrees-other-app-99999999"))
    }

    /// `…-ledger` is a prefix of `…-pocket-ledger`, and prefix matching would fold two different
    /// projects into one.
    func testADifferentProjectWithASimilarNameIsNotCounted() throws {
        let root = try projects(["-Users-dev-Developer-ledger",
                                 "-Users-dev-Developer-pocket-ledger"])
        defer { try? FileManager.default.removeItem(at: root) }

        XCTAssertEqual(
            SkillUseInProject.directories(forProjectPath: "/Users/dev/Developer/ledger", root: root)
                .map(\.lastPathComponent),
            ["-Users-dev-Developer-ledger"])
    }

    // MARK: - Counting

    private func line(_ skill: String, day: String) -> String {
        #"""
        {"timestamp":"\#(day)T10:00:00.000Z","message":{"content":[{"type":"tool_use","id":"t1","name":"Skill","input":{"skill":"\#(skill)"}}]}}
        """#
    }

    func testUsesAndTheDayAreCounted() {
        var use = SkillUseInProject()
        use.absorb(transcript: [
            line("minimalist-ui", day: "2026-08-30"),
            line("minimalist-ui", day: "2026-09-03"),
            line("humanizer", day: "2026-09-01"),
        ].joined(separator: "\n"))

        XCTAssertEqual(use.uses["minimalist-ui"], 2)
        XCTAssertEqual(use.uses["humanizer"], 1)
        XCTAssertEqual(use.lastUsed["minimalist-ui"], "2026-09-03", "the newest day, not the last line")
        XCTAssertEqual(use.total, 3)
    }

    func testLinesThatAreNotSkillCallsCostNothing() {
        var use = SkillUseInProject()
        use.absorb(transcript: """
        {"timestamp":"2026-09-03T10:00:00Z","message":{"content":[{"type":"text","text":"the Skill word appears here"}]}}
        not json at all
        {"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"t1"}]}}
        """)
        XCTAssertTrue(use.uses.isEmpty)
    }

    func testASkillCallNestedDeepIsStillFound() {
        var use = SkillUseInProject()
        use.absorb(transcript: #"""
        {"timestamp":"2026-09-03T10:00:00Z","a":{"b":[{"c":{"name":"Skill","input":{"skill":"impeccable"}}}]}}
        """#)
        XCTAssertEqual(use.uses["impeccable"], 1)
    }

    func testAScanThatRanIsDistinguishableFromOneThatDidNot() throws {
        let root = try projects([])
        defer { try? FileManager.default.removeItem(at: root) }
        XCTAssertFalse(SkillUseInProject.empty.counted)
        XCTAssertTrue(SkillUseInProject.scan(projectPath: "/nope", root: root).counted,
                      "zero uses and ‘not looked yet’ are different answers")
    }

    // MARK: - What the row then says

    private func skill(_ name: String, uses: Int, scope: InstalledSkill.Scope = .global)
        -> InstalledSkill {
        InstalledSkill(name: name, scope: scope, uses: uses, frontmatterSize: 300)
    }

    func testAttributionFillsInTheNumberForOneProject() {
        var use = SkillUseInProject()
        use.counted = true
        use.uses = ["minimalist-ui": 4]
        use.lastUsed = ["minimalist-ui": "2026-09-03"]
        use.transcripts = 13

        let inventory = SkillInventory(skills: [skill("minimalist-ui", uses: 17),
                                                skill("humanizer", uses: 15)],
                                       counted: true, loaded: true)
            .attributed(to: use)

        XCTAssertEqual(inventory.skills.first { $0.name == "minimalist-ui" }?.usesHere, 4)
        XCTAssertEqual(inventory.skills.first { $0.name == "humanizer" }?.usesHere, 0,
                       "zero here is an answer, not a missing one")
        XCTAssertEqual(inventory.transcriptsHere, 13)
        XCTAssertEqual(inventory.usedHere.map(\.name), ["minimalist-ui"])
    }

    func testAnUncountedScanChangesNothing() {
        let inventory = SkillInventory(skills: [skill("minimalist-ui", uses: 17)],
                                       counted: true, loaded: true)
        XCTAssertNil(inventory.attributed(to: .empty).skills.first?.usesHere)
    }

    @MainActor func testTheRowSaysHereRatherThanEverywhereWhenItKnows() {
        var here = skill("minimalist-ui", uses: 17)
        here.usesHere = 4
        here.lastUsedHere = "2026-09-03"
        let label = SkillRowProbe.usageLabel(here, counted: true)
        XCTAssertTrue(label.contains("4"), label)
        XCTAssertTrue(label.contains("2026-09-03"), label)
        XCTAssertFalse(label.contains("17"), "the machine-wide total is not the answer here: \(label)")
    }

    /// Unused here but used elsewhere is the interesting case, and it must not read as "useless".
    @MainActor func testASkillUnusedHereSaysWhereItIsUsed() {
        var elsewhere = skill("humanizer", uses: 15)
        elsewhere.usesHere = 0
        let label = SkillRowProbe.usageLabel(elsewhere, counted: true)
        XCTAssertTrue(label.contains("15"), label)
    }

    @MainActor func testASkillUsedNowhereSaysSo() {
        var never = skill("ci-cd-and-automation", uses: 0)
        never.usesHere = 0
        XCTAssertFalse(SkillRowProbe.usageLabel(never, counted: true).contains("0 "),
                       "a bare zero is not a sentence")
    }
}
