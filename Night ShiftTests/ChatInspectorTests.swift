import XCTest
@testable import Bulava

nonisolated final class ChatInspectorTests: XCTestCase {
    private let project = ChatInspectorProject(id: UUID(), name: "App", path: "/tmp/app",
                                               access: .workspace, isPrimary: true)

    func testPorcelainPreservesSpacesAndRenameOrigins() {
        let raw = " M Sources/Main View.swift\0?? notes/new note.md\0R  Sources/New.swift\0Sources/Old.swift\0"
        let changes = SupervisorClient.parsePorcelain(raw)

        XCTAssertEqual(changes.count, 3)
        XCTAssertEqual(changes.first { $0.path == "Sources/Main View.swift" }?.kind, .modified)
        XCTAssertEqual(changes.first { $0.path == "notes/new note.md" }?.kind, .untracked)
        let renamed = changes.first { $0.path == "Sources/New.swift" }
        XCTAssertEqual(renamed?.kind, .renamed)
        XCTAssertEqual(renamed?.previousPath, "Sources/Old.swift")
        XCTAssertEqual(renamed?.staged, true)
    }

    func testInspectionCombinesStatusBranchAndNumstat() {
        let output = "@@BRANCH@@\ncodex/context-inspector\n@@STATUS@@\n"
            + " M Sources/App.swift\0@@NUMSTAT@@\n12\t3\tSources/App.swift\n"

        let inspection = SupervisorClient.parseChatInspection(output, project: project)
        XCTAssertTrue(inspection.isGitRepository)
        XCTAssertEqual(inspection.branch, "codex/context-inspector")
        XCTAssertEqual(inspection.changes.count, 1)
        XCTAssertEqual(inspection.changes[0].added, 12)
        XCTAssertEqual(inspection.changes[0].removed, 3)
    }

    func testNonRepositoryProducesNoInventedChanges() {
        let inspection = SupervisorClient.parseChatInspection("@@NOT_GIT@@\n", project: project)
        XCTAssertFalse(inspection.isGitRepository)
        XCTAssertNil(inspection.branch)
        XCTAssertTrue(inspection.changes.isEmpty)
    }
}

// MARK: - Sixty changes, none of them the work

nonisolated final class InspectorNoiseTests: XCTestCase {

    private func porcelain(_ entries: [String]) -> String {
        entries.joined(separator: "\u{0}") + "\u{0}"
    }

    func testFindersLeftoversAreNeverAChange() {
        let changes = SupervisorClient.parsePorcelain(porcelain([
            " M .DS_Store", " M MVP/.DS_Store", " M src/App.swift", "?? Thumbs.db",
        ]))
        XCTAssertEqual(changes.map(\.path), ["src/App.swift"])
    }

    func testANestedRepositoryIsItsOwnRepositorysNews() {
        let changes = SupervisorClient.parsePorcelain(porcelain([
            " M MVP/presale-copilot", " M edx_ai", " M src/App.swift",
        ]), nested: ["MVP/presale-copilot", "edx_ai"])
        XCTAssertEqual(changes.map(\.path), ["src/App.swift"],
                       "another repo's moved HEAD is not a change in this one")
    }

    func testTheWorkItselfSurvivesTheFiltering() {
        let changes = SupervisorClient.parsePorcelain(porcelain([
            " M .DS_Store", "?? artifacts/latest/index.html", " M .gitignore", " M nested",
        ]), nested: ["nested"])
        XCTAssertEqual(changes.map(\.path), [".gitignore", "artifacts/latest/index.html"])
        XCTAssertEqual(changes.first?.kind, .modified)
    }

    func testARenameIsStillReadAsOnePairWhenItsNeighbourIsNoise() {

        let changes = SupervisorClient.parsePorcelain(porcelain([
            "R  new/name.swift", "old/name.swift", " M .DS_Store", " M src/B.swift",
        ]))
        XCTAssertEqual(changes.map(\.path), ["new/name.swift", "src/B.swift"])
        XCTAssertEqual(changes.first?.previousPath, "old/name.swift")
    }

    func testTheGitlinkSectionIsParsedOutOfTheRealOutput() {
        let output = """
        @@BRANCH@@
        main
        @@STATUS@@
        \u{0} M MVP/presale-copilot\u{0} M src/App.swift\u{0}
        @@GITLINKS@@
        160000 abc123 0\tMVP/presale-copilot
        @@NUMSTAT@@
        1\t1\tsrc/App.swift
        """
        let project = ChatInspectorProject(id: nil, name: "MVP", path: "/tmp/mvp",
                                           access: .workspace, isPrimary: true)
        let inspection = SupervisorClient.parseChatInspection(output, project: project)
        XCTAssertEqual(inspection.branch, "main")
        XCTAssertEqual(inspection.changes.map(\.path), ["src/App.swift"])
        XCTAssertEqual(inspection.changes.first?.added, 1)
    }
}
