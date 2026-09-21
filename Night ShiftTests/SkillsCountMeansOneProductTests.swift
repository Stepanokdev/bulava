import XCTest
@testable import Bulava

/// The headline number has to be true of the product named directly above it.
///
/// Caught by looking at the built screen: it read "77 installed" while the picker said one
/// product. Every project on the machine is scanned — the global list is the same everywhere and
/// pruning it is a machine-wide decision — but a project-scoped skill installed in some OTHER
/// repository is not this product's, and counting it made the number mean the machine.
nonisolated final class SkillsCountMeansOneProductTests: XCTestCase {

    private func skill(_ name: String, _ scope: InstalledSkill.Scope,
                       project: String = "") -> InstalledSkill {
        InstalledSkill(name: name, scope: scope, path: "/skills/\(name)",
                       projectPath: project, uses: 0, frontmatterSize: 200)
    }

    private var everything: SkillInventory {
        SkillInventory(skills: [
            skill("minimalist-ui", .global),
            skill("humanizer", .global),
            skill("release", .project, project: "/Users/i/Developer/Night Shift"),
            skill("macos-design", .project, project: "/Users/i/Developer/Night Shift"),
            skill("release-app", .project, project: "/Users/i/Developer/pocket-ledger"),
            skill("design", .plugin),
        ], counted: true, loaded: true)
    }

    func testOneProductSeesItsOwnFolderAndNobodyElsesFolder() {
        let shown = everything.visible(forProjectPath: "/Users/i/Developer/Night Shift")
        XCTAssertEqual(Set(shown.skills.map(\.name)),
                       ["minimalist-ui", "humanizer", "release", "macos-design", "design"])
        XCTAssertFalse(shown.skills.contains { $0.name == "release-app" },
                       "a skill installed in another repository is not this product's")
    }

    /// The global and plugin lists are the same everywhere, so they always stay.
    func testWhatLoadsEverywhereIsAlwaysShown() {
        let shown = everything.visible(forProjectPath: "/Users/i/Developer/pocket-ledger")
        XCTAssertTrue(shown.skills.contains { $0.name == "minimalist-ui" })
        XCTAssertTrue(shown.skills.contains { $0.name == "design" })
        XCTAssertTrue(shown.skills.contains { $0.name == "release-app" })
        XCTAssertFalse(shown.skills.contains { $0.name == "macos-design" })
    }

    func testEveryProjectMeansEverything() {
        XCTAssertEqual(everything.visible(forProjectPath: nil).skills.count, 6)
        XCTAssertEqual(everything.visible(forProjectPath: "").skills.count, 6)
    }

    /// `/tmp/…` and `/private/tmp/…` are the same directory, and a path that was not resolved was
    /// being dropped in silence elsewhere in this codebase for exactly that reason. Resolving a
    /// symlink needs the directory to exist, so this one does.
    func testThePathIsComparedCanonically() throws {
        let real = URL(fileURLWithPath: "/tmp")
            .appendingPathComponent("bulava-skills-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: real, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: real) }

        let viaTmp = "/tmp/" + real.lastPathComponent
        let viaPrivate = "/private/tmp/" + real.lastPathComponent
        XCTAssertNotEqual(viaTmp, viaPrivate, "the two spellings differ as text")

        let inventory = SkillInventory(skills: [skill("one", .project, project: viaTmp)],
                                       counted: true, loaded: true)
        XCTAssertEqual(inventory.visible(forProjectPath: viaPrivate).skills.count, 1,
                       "the same directory spelled two ways must not lose the skill")
    }

    func testTheCountFollowsWhatIsOnScreen() {
        let all = everything.visible(forProjectPath: nil)
        let one = everything.visible(forProjectPath: "/Users/i/Developer/Night Shift")
        XCTAssertGreaterThan(all.skills.count, one.skills.count,
                             "if these were equal the picker would be decoration")
    }
}
