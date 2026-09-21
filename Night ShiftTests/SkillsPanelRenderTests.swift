import XCTest
import SwiftUI
import AppKit
@testable import Bulava

nonisolated final class SkillsPanelRenderTests: XCTestCase {

    private static let width: CGFloat = 300
    private static let project = "/tmp/a-product"
    @MainActor private var width: CGFloat { Self.width }

    @MainActor private func inventory() -> SkillInventory {
        SkillInventory(skills: [
            InstalledSkill(name: "humanizer", scope: .global, path: "/g/humanizer",
                           uses: 15, lastUsed: "2026-08-29", frontmatterSize: 649,
                           description: "Rewrites AI-sounding prose into something a person would actually write.",
                           source: nil),
            InstalledSkill(name: "macos-design", scope: .project,
                           path: "\(Self.project)/.claude/skills/macos-design",
                           projectPath: Self.project, uses: 1, lastUsed: "2026-08-04",
                           frontmatterSize: 643,
                           description: "Design and build native-feeling macOS application UIs.",
                           source: "https://github.com/ceorkm/macos-design-skill"),

            InstalledSkill(name: "42crunch-api-security-testing", scope: .global,
                           path: "/g/42crunch-api-security-testing",
                           uses: 0, lastUsed: nil, frontmatterSize: 1285,
                           description: "Runs 42Crunch API security tests against an OpenAPI definition.",
                           source: nil),
            InstalledSkill(name: "document-skills", scope: .plugin, path: "/pl/document-skills",
                           uses: 2, lastUsed: "2026-08-12", frontmatterSize: 300,
                           description: "Document processing suite: Excel, Word, PowerPoint and PDF.",
                           source: nil),
        ], transcriptsScanned: 4722, counted: true, loaded: true)
    }

    override func setUp() {
        super.setUp()
        LanguageBundle.adopt(.uk)
    }

    override func tearDown() {
        LanguageBundle.adopt(.system)
        super.tearDown()
    }

    @MainActor private func render(_ view: some View, name: String, dark: Bool,
                                   width: CGFloat? = nil) -> NSImage? {
        let width = width ?? Self.width

        let host = NSHostingView(rootView:
            view
                .frame(width: width)
                .padding(13)
                .background(Palette.chrome)
                .environment(\.colorScheme, dark ? .dark : .light)
                .environment(\.locale, Locale(identifier: "uk"))
        )
        host.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        host.layoutSubtreeIfNeeded()
        let size = host.fittingSize
        guard size.width > 0, size.height > 0 else { return nil }
        host.frame = CGRect(origin: .zero, size: size)
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return nil }
        host.cacheDisplay(in: host.bounds, to: rep)
        let image = NSImage(size: size)
        image.addRepresentation(rep)

        let env = ProcessInfo.processInfo.environment
        let dir = env["BULAVA_RENDER_DIR"] ?? env["TEST_RUNNER_BULAVA_RENDER_DIR"]
            ?? FileManager.default.temporaryDirectory.appendingPathComponent("bulava-frames").path
        if let png = rep.representation(using: .png, properties: [:]) {
            try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
            print("FRAME_DIR \(dir)")
            let url = URL(fileURLWithPath: dir)
                .appendingPathComponent("\(name)-\(dark ? "dark" : "light").png")
            try? png.write(to: url)
        }
        return image
    }

    @MainActor private func check(_ view: some View, _ name: String, minHeight: CGFloat,
                                  width: CGFloat? = nil,
                                  file: StaticString = #filePath, line: UInt = #line) {
        let w = width ?? Self.width
        for dark in [false, true] {
            guard let image = render(view, name: name, dark: dark, width: w) else {
                return XCTFail("\(name) (\(dark ? "dark" : "light")) rendered nothing", file: file, line: line)
            }
            XCTAssertGreaterThan(image.size.height, minHeight,
                                 "\(name) collapsed to \(image.size.height)pt", file: file, line: line)
            XCTAssertLessThan(image.size.width, w + 40,
                              "\(name) is wider than the panel — it would clip", file: file, line: line)
        }
    }

    @MainActor func testTheFullList() {
        check(SkillsPanelBody(inventory: inventory()), "skills-list", minHeight: 140)
    }

    @MainActor func testTheEmptyState() {
        check(SkillsPanelBody(inventory: SkillInventory(skills: [], transcriptsScanned: 0, loaded: true)),
              "skills-empty", minHeight: 24)
    }

    @MainActor func testTheLoadingState() {
        check(SkillsPanelBody(inventory: .empty, loading: true), "skills-loading", minHeight: 24)
    }

    @MainActor func testTheBusyAndFailedStates() {
        check(SkillsPanelBody(inventory: inventory(),
                              busySkill: "project:macos-design",
                              failure: "❌ macos-design у області «global» — резолвер ставить лише проєктно"),
              "skills-busy-failed", minHeight: 160)
    }

    @MainActor func testTheProjectPanelShowsOnlyThisProduct() {
        let scoped = inventory().belongingTo(projects: [Self.project])
        XCTAssertEqual(scoped.skills.count, 1, "only the project-scoped row survives")
        XCTAssertTrue(scoped.skills.allSatisfy { $0.scope == .project })
        check(SkillsPanelBody(inventory: scoped), "skills-panel-project", minHeight: 24)
    }

    @MainActor func testTheProjectPanelWithNothingInstalled() {
        check(SkillsPanelBody(inventory: SkillInventory(skills: [], transcriptsScanned: 4722, counted: true, loaded: true)),
              "skills-panel-none", minHeight: 24)
    }

    // MARK: - The library window

    @MainActor private func servers() -> MCPInventory {
        MCPInventory(servers: [
            MCPServer(name: "chrome-devtools", target: "npx -y chrome-devtools-mcp@latest",
                      health: .connected, transport: "stdio", scope: .user,
                      description: "", uses: 1703, lastUsed: "2026-08-28"),
            MCPServer(name: "appium-mcp", target: "node .../appium-mcp/dist/index.js",
                      health: .connected, transport: "stdio", scope: .user,
                      description: "Intelligent MCP server providing AI assistants with powerful tools and resources for Appium mobile automation",
                      uses: 869, lastUsed: "2026-08-30"),
            MCPServer(name: "claude.ai Gmail", target: "https://gmailmcp.googleapis.com/mcp/v1",
                      health: .needsAuth, transport: "http", scope: .account,
                      description: "", uses: 0, lastUsed: nil),
            MCPServer(name: "xcodebuildmcp", target: "npx -y xcodebuildmcp@latest mcp",
                      health: .failed, transport: "stdio", scope: .user,
                      description: "XcodeBuildMCP provides comprehensive tooling for Apple platform development (iOS, macOS, watchOS, tvOS, visionOS).",
                      uses: 0, lastUsed: nil),
        ], counted: true, loaded: true)
    }

    @MainActor func testTheFirstFrameIsNotAnEmptyWindow() {
        check(SkillLibraryContent(inventory: .empty, loading: true),
              "library-first-frame", minHeight: 20, width: 560)
    }

    @MainActor func testTheLibraryWithServers() {
        check(VStack(alignment: .leading, spacing: 11) {
            SkillStats(inventory: inventory(), mcp: servers())
            SkillLibraryContent(inventory: inventory(), mcp: servers())
        }, "library-with-mcp", minHeight: 300, width: 560)
    }

    @MainActor func testTheShelfBeforeTheNumbers() {
        var uncounted = inventory()
        uncounted.counted = false
        uncounted.skills = uncounted.skills.map { s in
            var s = s
            s.uses = 0
            s.description = "Guides stable API and interface design. Use when designing APIs, module boundaries, or public contracts."
            return s
        }
        check(SkillLibraryContent(inventory: uncounted), "library-uncounted", minHeight: 150, width: 560)

        XCTAssertEqual(SkillRowProbe.usageLabel(uncounted.skills[0], counted: false),
                       String(localized: "counting uses…"))
        XCTAssertNotEqual(SkillRowProbe.usageLabel(uncounted.skills[0], counted: true),
                          String(localized: "counting uses…"))
    }

    @MainActor func testTheMCPSectionSaysItIsComing() {
        check(SkillLibraryContent(inventory: inventory(), loading: true),
              "library-mcp-pending", minHeight: 200, width: 560)
    }

    @MainActor func testSkillsThatWereUsedButAreGone() {
        var inv = inventory()
        inv.missing = [MissingSkill(name: "artifact-design", uses: 7, lastUsed: "2026-08-29"),
                       MissingSkill(name: "dataviz", uses: 3, lastUsed: "2026-08-06")]
        check(SkillLibraryContent(inventory: inv, mcp: servers()),
              "library-missing", minHeight: 300, width: 560)

        XCTAssertTrue(inv.belongingTo(projects: [Self.project]).missing.isEmpty)
    }

    @MainActor func testTheLibraryGroupsByScope() {
        check(VStack(alignment: .leading, spacing: 11) {
            SkillStats(inventory: inventory())
            SkillLibraryContent(inventory: inventory())
        }, "library", minHeight: 200, width: 560)
    }

    @MainActor func testTheLibraryWithNothingMatchingTheFilter() {
        check(SkillLibraryContent(inventory: inventory(), query: "zzz"), "library-no-match", minHeight: 100, width: 560)
    }

    @MainActor func testTheLibraryWhileReading() {
        check(SkillLibraryContent(inventory: .empty, loading: true), "library-loading",
              minHeight: 20, width: 560)
    }

    @MainActor func testTheLongestRow() {
        let long = InstalledSkill(name: "42crunch-api-security-testing", scope: .global, uses: 0,
                                  lastUsed: nil, frontmatterSize: 1285, source: nil)
        check(SkillsPanelBody(inventory: SkillInventory(skills: [long], transcriptsScanned: 0, counted: true, loaded: true)),
              "skills-long-name", minHeight: 24)
    }
}
