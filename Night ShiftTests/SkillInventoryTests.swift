import XCTest
@testable import Bulava

nonisolated final class SkillInventoryTests: XCTestCase {

    private func skill(_ name: String, _ scope: InstalledSkill.Scope = .global,
                       uses: Int = 0, size: Int = 0, source: String? = nil,
                       project: String = "", path: String = "") -> InstalledSkill {
        InstalledSkill(name: name, scope: scope,
                       path: path.isEmpty ? "/tmp/\(scope.rawValue)/\(name)" : path,
                       projectPath: project,
                       uses: uses, lastUsed: uses > 0 ? "2026-08-29" : nil,
                       frontmatterSize: size, source: source)
    }

    // MARK: - What can be done to a skill

    func testAPluginSkillIsNeitherRemovedNorUpdated() {
        let s = skill("from-pack", .plugin, uses: 4, source: "https://example.invalid/pack")
        XCTAssertFalse(s.canRemove, "it belongs to the plugin, not to us")
        XCTAssertFalse(s.canUpdate, "the plugin updates it")
    }

    func testAHandPlacedSkillCanBeRemovedButNotUpdated() {
        let s = skill("hand-written", .global, uses: 2)
        XCTAssertTrue(s.canRemove)
        XCTAssertFalse(s.canUpdate, "there is no recorded source to update from")
    }

    func testAResolverInstalledSkillCanBeBoth() {
        let s = skill("macos-design", .project, uses: 1, source: "https://example.invalid/x")
        XCTAssertTrue(s.canRemove)
        XCTAssertTrue(s.canUpdate)
    }

    func testAnEmptySourceIsNoSource() {
        XCTAssertFalse(skill("x", .project, source: "").canUpdate)
    }

    // MARK: - What the panel counts

    func testTheUnusedAreTheOnesWorthActingOn() {
        let inv = SkillInventory(skills: [
            skill("used", uses: 14, size: 200),
            skill("cold", uses: 0, size: 600),
            skill("also-cold", uses: 0, size: 400),
        ], transcriptsScanned: 4722, counted: true, loaded: true)

        XCTAssertEqual(inv.unused.count, 2)
        XCTAssertEqual(inv.unusedFrontmatter, 1000,
                       "what the unused ones cost every session that loads them")
    }

    func testAUsedSkillDoesNotCountAgainstTheContextCost() {
        let inv = SkillInventory(skills: [skill("used", uses: 3, size: 9_000)],
                                 counted: true, loaded: true)
        XCTAssertEqual(inv.unusedFrontmatter, 0)
    }

    func testNothingIsUnusedUntilTheCountingHasHappened() {
        let shelf = SkillInventory(skills: [skill("a", uses: 0, size: 500),
                                            skill("b", uses: 0, size: 500)],
                                   counted: false, loaded: true)
        XCTAssertTrue(shelf.unused.isEmpty, "uncounted is not unused")
        XCTAssertEqual(shelf.unusedFrontmatter, 0, "and it costs no accusation either")

        var counted = shelf
        counted.counted = true
        XCTAssertEqual(counted.unused.count, 2, "once counted, the same zeros do mean unused")
    }

    func testAnEmptyInventoryIsNotLoaded() {
        XCTAssertFalse(SkillInventory.empty.loaded,
                       "the panel must be able to tell «nothing installed» from «not read yet»")
        XCTAssertTrue(SkillInventory.empty.unused.isEmpty)
    }

    // MARK: - Identity

    func testTheSameNameInTwoScopesIsTwoRows() {
        XCTAssertNotEqual(skill("design", .project).id, skill("design", .global).id)
    }

    func testTheSameNameInTwoProjectsIsTwoRows() {
        let a = skill("design", .project, project: "/p/a", path: "/p/a/.claude/skills/design")
        let b = skill("design", .project, project: "/p/b", path: "/p/b/.claude/skills/design")
        XCTAssertNotEqual(a.id, b.id)
    }

    // MARK: - Whose skills a product's panel shows

    func testAProductPanelShowsOnlyItsOwnProjectsSkills() {
        let inventory = SkillInventory(skills: [
            skill("global-one", .global, uses: 3),
            skill("mine", .project, project: "/p/a"),
            skill("theirs", .project, project: "/p/b"),
            skill("from-pack", .plugin, uses: 1),
        ], transcriptsScanned: 100, loaded: true)

        let mine = inventory.belongingTo(projects: ["/p/a"])
        XCTAssertEqual(mine.skills.map(\.name), ["mine"])
        XCTAssertTrue(mine.loaded, "the filtered reading is still a reading")
    }

    func testAProductWithTwoProjectsOwnsBoth() {
        let inventory = SkillInventory(skills: [
            skill("one", .project, project: "/p/a"),
            skill("two", .project, project: "/p/b"),
            skill("other", .project, project: "/p/c"),
        ], loaded: true)
        XCTAssertEqual(Set(inventory.belongingTo(projects: ["/p/a", "/p/b"]).skills.map(\.name)),
                       ["one", "two"])
    }

    func testAProductWithNoProjectsOwnsNothing() {
        let inventory = SkillInventory(skills: [skill("one", .project, project: "/p/a")], loaded: true)
        XCTAssertTrue(inventory.belongingTo(projects: []).skills.isEmpty)
    }
}

nonisolated final class SkillInventoryDecodingTests: XCTestCase {

    private func engineRoot() -> URL? {

        var dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        for _ in 0..<5 {
            let candidate = dir.appendingPathComponent("engine/bin/lib/skill-usage.py")
            if FileManager.default.fileExists(atPath: candidate.path) { return candidate }
            dir = dir.deletingLastPathComponent()
        }
        return nil
    }

    func testTheAppDecodesWhatTheEngineActuallyEmits() throws {
        guard let script = engineRoot() else {
            throw XCTSkip("engine not beside the test — nothing to check the contract against")
        }
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("skills-contract-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: root) }
        let a = root.appendingPathComponent("projA")

        for (dir, name) in [("projA/.claude/skills/design", "design"),
                            ("projA/.agents/skills/repo-skill", "repo-skill")] {
            let d = root.appendingPathComponent(dir)
            try fm.createDirectory(at: d, withIntermediateDirectories: true)
            try "---\nname: \(name)\n---\nbody\n"
                .write(to: d.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["python3", script.path, a.path, "--json"]
        var env = ProcessInfo.processInfo.environment

        env["SUPERVISOR_TRANSCRIPT_ROOT"] = root.appendingPathComponent("none").path
        process.environment = env
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let rows = try XCTUnwrap(object["installed"] as? [[String: Any]])

        let decoded = rows.compactMap { row -> InstalledSkill? in
            guard let name = row["name"] as? String,
                  let scope = InstalledSkill.Scope(rawValue: (row["scope"] as? String) ?? "")
            else { return nil }
            return InstalledSkill(name: name, scope: scope,
                                  path: (row["path"] as? String) ?? "",
                                  projectPath: (row["project"] as? String) ?? "",
                                  uses: 0, lastUsed: nil, frontmatterSize: 0, source: nil)
        }

        let repoSkill = try XCTUnwrap(decoded.first { $0.name == "repo-skill" },
                                      "a skill in .agents/skills must survive decoding")
        XCTAssertEqual(repoSkill.scope, .project, ".agents/skills is project-local")
        XCTAssertEqual(repoSkill.projectPath, a.path, "and it names the project it belongs to")

        let design = try XCTUnwrap(decoded.first { $0.name == "design" })
        XCTAssertEqual(design.scope, .project)

        let inventory = SkillInventory(skills: decoded, transcriptsScanned: 0, loaded: true)
        let panel = inventory.belongingTo(projects: [a.path])
        XCTAssertEqual(Set(panel.skills.map(\.name)), ["design", "repo-skill"],
                       "both project-local roots reach the product's panel")
    }
}
