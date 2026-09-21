import XCTest
@testable import Bulava

/// A folder holding several repositories is a workspace, and connecting it must connect them.
///
/// The report: a workspace of fifteen checkouts, a python venv, Tutor's runtime data and a Chrome
/// profile was connected as one project. The engine saw "not a git repository" and made one out of
/// it — 23 108 files staged, 495 MB of objects, the project's secrets in the index, no commit at
/// the end and a start that never returned.
///
/// The rule that decides all of this now lives in ONE place, the engine, because for a while it
/// lived in two and they disagreed three ways: depth counted from different things, a damaged store
/// was a repository to one and not the other, and vendored checkouts leaked into the engine's list.
/// So the app's half is no longer a second implementation — it is reading. These tests are about
/// the reading: that every answer the engine can give is understood, and that a line the engine did
/// not write changes nothing.
nonisolated final class WorkspaceFolderTests: XCTestCase {

    private func findings(_ text: String) -> WorkspaceScan.Findings { WorkspaceScan.parse(text) }

    // MARK: - Every answer the engine gives

    func testAWorkspaceBecomesItsRepositories() {
        let f = findings("""
        kind=container
        complete=yes
        repo\t/w/frontend-app-home
        repo\t/w/src/edx-platform
        """)
        XCTAssertEqual(f.kind, .container)
        XCTAssertTrue(f.isContainer)
        XCTAssertEqual(f.repositories, ["/w/frontend-app-home", "/w/src/edx-platform"])
        XCTAssertTrue(f.complete)
    }

    func testAnOrdinaryFolderIsStillOneProject() {
        let f = findings("kind=plain\ncomplete=yes")
        XCTAssertEqual(f.kind, .plain)
        XCTAssertFalse(f.isContainer)
        XCTAssertTrue(f.repositories.isEmpty)
    }

    func testARepositoryIsNeverTakenApart() {
        let f = findings("kind=repo\ncomplete=yes")
        XCTAssertEqual(f.kind, .repo)
        XCTAssertFalse(f.isContainer, "a project with history must not be split into its vendored parts")
    }

    /// Bare and damaged stores are the third class nobody had thought about: forty-one of them sit
    /// on the director's disk, and they used to read as ordinary files.
    func testGitStoragesAreTheirOwnAnswer() {
        let f = findings("""
        kind=storage
        complete=yes
        storage\tbare\t/w/alpha.git
        storage\tbroken\t/w/half
        """)
        XCTAssertEqual(f.kind, .storage)
        XCTAssertFalse(f.isContainer, "a store is not a workspace to expand")
        XCTAssertEqual(f.storages.map(\.0), ["bare", "broken"])
        XCTAssertEqual(f.storages.map(\.1), ["/w/alpha.git", "/w/half"])
    }

    func testASubfolderOfAnotherRepositoryIsNamedAsOne() {
        let f = findings("kind=inside\ncomplete=yes\nrepo\t/w/monorepo")
        XCTAssertEqual(f.kind, .inside)
        XCTAssertFalse(f.isContainer)
        XCTAssertEqual(f.repositories, ["/w/monorepo"], "the owning repository is what to offer instead")
    }

    /// "I found no repositories" and "I did not finish looking" are the same sentence to anything
    /// that only counts — and that difference is the whole bug this came from.
    func testAFolderThatCouldNotBeFullyReadSaysSo() {
        let f = findings("kind=unknown\ncomplete=no\nwhy=нижче 6-го рівня є ще теки")
        XCTAssertEqual(f.kind, .unknown)
        XCTAssertFalse(f.complete)
        XCTAssertEqual(f.incompleteReason, "нижче 6-го рівня є ще теки")
        XCTAssertFalse(f.isContainer, "nothing was found, so nothing is claimed")
    }

    func testAPartialListIsStillAList() {
        let f = findings("""
        kind=container
        complete=no
        why=огляд не вклався у 30 с
        repo\t/w/one
        """)
        XCTAssertTrue(f.isContainer)
        XCTAssertEqual(f.repositories, ["/w/one"])
        XCTAssertFalse(f.complete, "a partial answer must not read as a complete one")
    }

    // MARK: - What the engine never wrote

    func testNoiseIsIgnoredRatherThanGuessedAt() {
        let f = findings("""
        warning: something on stderr got mixed in
        kind=container
        repo\t/w/one
        repo
        storage\tbare
        complete=yes
        """)
        XCTAssertEqual(f.kind, .container)
        XCTAssertEqual(f.repositories, ["/w/one"], "a truncated line must not become a path")
        XCTAssertTrue(f.storages.isEmpty, "a truncated storage line must not become a storage")
    }

    func testAnEmptyAnswerIsNotAnOrdinaryFolder() {
        let f = findings("")
        XCTAssertEqual(f.kind, .unknown, "saying nothing must not read as “plain folder, go ahead”")
    }

    // MARK: - Names

    func testNestedRepositoriesAreNamedByWhereTheyAre() {
        XCTAssertEqual(WorkspaceScan.relativeName(of: "/w/src/edx-platform", under: "/w"),
                       "src/edx-platform",
                       "two checkouts called the same thing under different parents must stay apart")
        XCTAssertEqual(WorkspaceScan.relativeName(of: "/w/one", under: "/w"), "one")
        XCTAssertEqual(WorkspaceScan.relativeName(of: "/elsewhere/one", under: "/w"), "one",
                       "a path from outside the container still gets a usable name")
    }
}
