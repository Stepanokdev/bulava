import XCTest
@testable import Bulava

/// The templates keep the promises their cards make: the ones for any repository are ready to
/// switch on as they are, and the ones that need setup say what and are stopped only by that.
nonisolated final class AutomationTemplateTests: XCTestCase {

    @MainActor private func draft(_ template: AutomationTemplate) -> AutomationDraft {
        var d = AutomationDraft()
        d.productID = UUID()
        d.projectID = UUID()
        d.folderIsRepository = true
        d.apply(template)
        return d
    }

    @MainActor func testTemplateIdsAreUnique() {
        let ids = AutomationTemplate.all().map(\.id)
        XCTAssertEqual(Set(ids).count, ids.count)
    }

    @MainActor func testTheGeneralTemplatesAreNotOneDevelopersOwn() {
        let ids = Set(AutomationTemplate.all().map(\.id))
        for specific in ["seo", "meeting", "models"] {
            XCTAssertFalse(ids.contains(specific), "\(specific) is not a starter for everyone")
        }
        XCTAssertGreaterThanOrEqual(AutomationTemplate.all().filter { $0.group == .anyRepository }.count, 6)
    }

    @MainActor func testEveryTemplateForAnyRepositoryIsReadyAsItIs() {
        for template in AutomationTemplate.all() where template.group == .anyRepository {
            XCTAssertNil(draft(template).problem, "\(template.id) should save without anything filled in")
        }
    }

    @MainActor func testEveryTemplateThatNeedsSetupSaysWhatAndIsStoppedOnlyByThat() {
        for template in AutomationTemplate.all() where template.group == .needsSetup {
            XCTAssertNotNil(template.needs, "\(template.id) has to say what it needs")
            let problem = draft(template).problem
            XCTAssertNotNil(problem, "\(template.id) must not switch on before it is set up")
            XCTAssertFalse(problem == String(localized: "Give it a name.") || problem == String(localized: "Say what it should do."),
                           "\(template.id) is stopped by its setup, not by an empty form")
        }
    }

    @MainActor func testChoosingATemplateKeepsWhatHeWrote() {
        let all = AutomationTemplate.all()
        var d = AutomationDraft()
        d.apply(all[0])
        d.brief = "My own words."
        d.apply(all[1])
        XCTAssertEqual(d.brief, "My own words.", "a template does not overwrite his brief")
        XCTAssertEqual(d.name, all[1].name, "a name the previous template filled in is replaced")
    }

    @MainActor func testAFolderWithoutGitAndAMailWithoutAFilterAreStoppedBeforeTheNight() {
        var d = AutomationDraft()
        d.productID = UUID(); d.projectID = UUID()
        d.name = "x"; d.brief = "y"; d.when = .manual
        d.folderIsRepository = false
        XCTAssertNotNil(d.problem)
        d.folderIsRepository = true
        XCTAssertNil(d.problem)
        d.when = .event; d.eventKind = .mail
        XCTAssertNotNil(d.problem, "every newsletter would start a run")
        d.mailFrom = "billing@"
        XCTAssertNil(d.problem)
    }

    @MainActor func testAWebAddressNeedsAWebSchemeAndAHost() {
        XCTAssertTrue(AutomationDraft.isWebAddress("https://github.com/owner/repo/releases.atom"))
        XCTAssertTrue(AutomationDraft.isWebAddress("  http://example.com/feed  "))
        XCTAssertFalse(AutomationDraft.isWebAddress("https:"), "no host")
        XCTAssertFalse(AutomationDraft.isWebAddress("httpfoo://example.com"), "not a web scheme")
        XCTAssertFalse(AutomationDraft.isWebAddress("ftp://example.com"))
        XCTAssertFalse(AutomationDraft.isWebAddress("example.com"))
    }

    @MainActor func testTheCursorGoesToTheFieldATemplateStillLacks() {
        let byID = Dictionary(uniqueKeysWithValues: AutomationTemplate.all().map { ($0.id, $0) })
        XCTAssertEqual(draft(byID["releases"]!).missingSetupField, .feedURL)
        XCTAssertEqual(draft(byID["parity"]!).missingSetupField, .repoPath)
        XCTAssertEqual(draft(byID["mail"]!).missingSetupField, .mailFrom)
        XCTAssertNil(draft(byID["digest"]!).missingSetupField, "a ready template leaves the cursor on the name")
        var mail = draft(byID["mail"]!)
        mail.mailSubject = "invoice"
        XCTAssertNil(mail.missingSetupField, "a subject alone is a filter")
    }

    @MainActor func testStartingFromScratchKeepsOnlyWhereItWorks() {
        var d = draft(AutomationTemplate.all().first { $0.id == "mail" }!)
        let product = d.productID, project = d.projectID
        d.brief = "My own words."
        d.clear()
        XCTAssertEqual(d.productID, product)
        XCTAssertEqual(d.projectID, project)
        XCTAssertEqual(d.folderIsRepository, true)
        XCTAssertTrue(d.name.isEmpty)
        XCTAssertTrue(d.brief.isEmpty)
        XCTAssertNil(d.templateID)
        XCTAssertEqual(d.when, .schedule)
        XCTAssertTrue(d.mailFrom.isEmpty && d.mailSubject.isEmpty)
    }
}
