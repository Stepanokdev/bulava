import XCTest
@testable import Bulava

nonisolated final class SlashCommandCatalogTests: XCTestCase {
    private var root: URL!
    private var home: URL!
    private var project: URL!
    private var added: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("bulava-slash-\(UUID().uuidString)", isDirectory: true)
        home = root.appendingPathComponent("home", isDirectory: true)
        project = root.appendingPathComponent("project", isDirectory: true)
        added = root.appendingPathComponent("backend", isDirectory: true)
        try FileManager.default.createDirectory(at: project.appendingPathComponent(".git"),
                                                withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: added, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    func testDiscoversVisiblePersonalProjectAndAddedFolderSkills() throws {
        try write("home/.claude/commands/deploy.md", """
        ---
        description: Legacy personal deploy
        ---
        Legacy body
        """)
        try write("home/.claude/skills/deploy/SKILL.md", """
        ---
        description: >
          Deploy the selected build
          after verification
        argument-hint: "[environment]"
        ---
        Modern body
        """)
        try write("home/.claude/skills/hidden/SKILL.md", """
        ---
        description: Background knowledge
        user-invocable: no
        ---
        Hidden body
        """)
        try write("project/.claude/commands/legacy-project.md", "Project legacy command")
        try write("project/.claude/skills/project-only/SKILL.md", """
        ---
        description: This project's workflow
        ---
        Project body
        """)
        try write("backend/.claude/skills/backend-check/SKILL.md", """
        ---
        description: Check the added backend
        ---
        Backend body
        """)
        try write("backend/.claude/commands/not-loaded.md", "Must not be suggested")

        let commands = discover()
        let names = Set(commands.map(\.name))

        XCTAssertTrue(names.contains("deploy"))
        XCTAssertTrue(names.contains("legacy-project"))
        XCTAssertTrue(names.contains("project-only"))
        XCTAssertTrue(names.contains("backend-check"))
        XCTAssertFalse(names.contains("hidden"))
        XCTAssertFalse(names.contains("not-loaded"), "--add-dir loads skills, not legacy commands")

        let deploy = try XCTUnwrap(commands.first { $0.name == "deploy" })
        XCTAssertEqual(deploy.description, "Deploy the selected build after verification")
        XCTAssertEqual(deploy.argumentHint, "[environment]")
        XCTAssertEqual(deploy.source, .personal)
    }

    func testSkillOverridesAndPluginCatalogFollowClaudeSettings() throws {
        try write("project/.claude/skills/disabled/SKILL.md", """
        ---
        description: Disabled from settings
        ---
        Body
        """)
        let plugin = root.appendingPathComponent("plugin", isDirectory: true)
        try write("plugin/skills/review/SKILL.md", """
        ---
        name: focused-review
        description: Review only the requested scope
        argument-hint: "[scope]"
        ---
        Body
        """)
        let singleSkillPlugin = root.appendingPathComponent("single-plugin", isDirectory: true)
        try write("single-plugin/SKILL.md", """
        ---
        name: release-notes
        description: Prepare focused release notes
        ---
        Body
        """)

        try writeJSON("home/.claude/settings.json", [
            "skillOverrides": [
                "disabled": "off",
                "scope-tools:focused-review": "off"
            ],
            "enabledPlugins": ["scope-tools@market": true]
        ])
        try writeJSON("backend/.claude/settings.json", [
            "enabledPlugins": ["release-tools@market": true]
        ])
        try writeJSON("home/.claude/plugins/installed_plugins.json", [
            "version": 2,
            "plugins": [
                "scope-tools@market": [["installPath": plugin.path]],
                "release-tools@market": [["installPath": singleSkillPlugin.path]]
            ]
        ])

        let commands = discover()
        XCTAssertFalse(commands.contains { $0.name == "disabled" })
        let pluginCommand = try XCTUnwrap(commands.first { $0.name == "scope-tools:focused-review" })
        XCTAssertEqual(pluginCommand.argumentHint, "[scope]")
        XCTAssertEqual(pluginCommand.source, .plugin)
        XCTAssertNotNil(commands.first { $0.name == "release-tools:release-notes" })
    }

    func testQueryOnlyLivesInTheFirstCommandTokenAndRanksPrefixesFirst() throws {
        let commands = [
            ClaudeSlashCommand(name: "deep-audit", description: "", argumentHint: "", source: .personal),
            ClaudeSlashCommand(name: "audit-deep", description: "", argumentHint: "", source: .personal),
            ClaudeSlashCommand(name: "night", description: "", argumentHint: "", source: .personal)
        ]

        XCTAssertEqual(SlashCommandQuery("/")?.matches(in: commands).count, 3)
        XCTAssertEqual(SlashCommandQuery("/aud")?.matches(in: commands).map(\.name),
                       ["audit-deep", "deep-audit"])
        XCTAssertNil(SlashCommandQuery("/night status"))
        XCTAssertNil(SlashCommandQuery("hello /night"))
        XCTAssertNil(SlashCommandQuery("/night\nstatus"))
    }

    private func discover() -> [ClaudeSlashCommand] {
        SlashCommandCatalog.discover(.init(primaryProject: project,
                                           addedProjects: [added],
                                           homeDirectory: home))
    }

    private func write(_ relativePath: String, _ contents: String) throws {
        let file = root.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try Data(contents.utf8).write(to: file)
    }

    private func writeJSON(_ relativePath: String, _ object: Any) throws {
        let data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted])
        let file = root.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try data.write(to: file)
    }
}
