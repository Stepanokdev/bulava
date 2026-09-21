import XCTest
@testable import Bulava

/// "The app has never installed a skill for a task — pocket-ledger, not once. And I don't want
/// generic native Claude skills, they read as AI slop."
///
/// Both halves are answered by not installing anything. His skills are hand-picked and global, so
/// they are ALREADY loaded in every project; what was missing was which of them applies where.
/// The one thing that is genuinely a decision — which look a product wears — stays his.
nonisolated final class SkillFitTests: XCTestCase {

    private let hisSkills: Set<String> = [
        "macos-design", "design-taste-frontend", "frontend-ui-engineering", "impeccable",
        "humanizer", "high-end-visual-design", "minimalist-ui", "industrial-brutalist-ui",
        "code-review-and-quality",
    ]

    private func shape(_ names: [String]) -> SkillFit.Shape {
        SkillFit.shape(ofProjectAt: "/nowhere", fileNames: names)
    }

    // MARK: - Reading the repository

    func testWebUIIsRecognisedFromItsFiles() {
        let found = shape(["App.tsx", "styles.css", "package.json"])
        XCTAssertTrue(found.hasWebUI)
        XCTAssertFalse(found.hasAppleUI)
    }

    func testAnAppleProjectIsRecognised() {
        let found = shape(["ContentView.swift", "Thing.xcodeproj"])
        XCTAssertTrue(found.hasAppleUI)
        XCTAssertFalse(found.hasWebUI)
    }

    func testAServerWithNoInterfaceOffersNoDesignSkill() {
        let found = shape(["main.go", "handler.go", "Dockerfile"])
        XCTAssertFalse(found.showsAnUI)
        let fits = SkillFit.suggest(shape: found, installed: hisSkills)
        XCTAssertTrue(fits.isEmpty, "a Go server has no business wearing a design skill")
    }

    /// Every suggestion has to come off the file tree. A project called "lawria-mobile" is not
    /// evidence of anything.
    func testNothingIsInferredFromTheProjectsName() {
        let fits = SkillFit.suggest(shape: shape(["README.md"]), installed: hisSkills)
        XCTAssertEqual(fits.map(\.skill), ["humanizer"],
                       "prose is the only thing a bare README is evidence of")
    }

    // MARK: - What is offered

    func testOnlySkillsHeActuallyHasAreOffered() {
        let fits = SkillFit.suggest(shape: shape(["App.tsx"]), installed: ["humanizer"])
        XCTAssertTrue(fits.isEmpty, "suggesting something that is not installed is not a suggestion")
    }

    func testAMacAppIsOfferedTheMacSkillAndNotTheWebOne() {
        var found = shape(["ContentView.swift", "Thing.xcodeproj"])
        found.hasMacTarget = true
        let names = SkillFit.suggest(shape: found, installed: hisSkills).map(\.skill)
        XCTAssertTrue(names.contains("macos-design"))
        XCTAssertFalse(names.contains("design-taste-frontend"),
                       "a Mac app is not a website")
    }

    func testAniOSAppIsNotOfferedTheMacSkill() {
        let found = shape(["ContentView.swift", "Thing.xcodeproj"])   // hasMacTarget stays false
        XCTAssertFalse(SkillFit.suggest(shape: found, installed: hisSkills)
            .map(\.skill).contains("macos-design"),
                       "the native patterns for iOS are a different set")
    }

    func testEverySuggestionSaysWhy() {
        for fit in SkillFit.suggest(shape: shape(["App.tsx", "README.md"]), installed: hisSkills) {
            XCTAssertFalse(fit.because.isEmpty, fit.skill)
        }
    }

    // MARK: - The look, which is his decision

    /// Three of these set a whole look. Applying two at once is a defect, and which one a product
    /// wears is a brand decision — so the app must not pick.
    func testAnUnmadeChoiceOfLookIsReportedAsUnmade() {
        let fits = SkillFit.suggest(shape: shape(["App.tsx"]), installed: hisSkills)
        let looks = fits.filter { SkillFit.aesthetics.contains($0.skill) }
        XCTAssertEqual(looks.count, 3, "all three are offered, none is chosen")
        XCTAssertTrue(looks.allSatisfy(\.needsHisChoice),
                      "picking a brand for him is not a service")
    }

    /// A look this project has already used IS the answer — he decided it by using it.
    func testALookAlreadyUsedHereIsTakenAsTheAnswer() {
        let fits = SkillFit.suggest(shape: shape(["App.tsx"]), installed: hisSkills,
                                     usedHere: ["minimalist-ui"])
        let looks = fits.filter { SkillFit.aesthetics.contains($0.skill) }
        XCTAssertEqual(looks.map(\.skill), ["minimalist-ui"])
        XCTAssertFalse(looks[0].needsHisChoice)
    }

    /// Two looks in one project is the defect the standards name. It is surfaced, not silently
    /// resolved by preferring one.
    func testTwoLooksInOneProjectAreFlaggedRatherThanReconciled() {
        let fits = SkillFit.suggest(shape: shape(["App.tsx"]), installed: hisSkills,
                                     usedHere: ["minimalist-ui", "high-end-visual-design"])
        let looks = fits.filter { SkillFit.aesthetics.contains($0.skill) }
        XCTAssertEqual(Set(looks.map(\.skill)), ["minimalist-ui", "high-end-visual-design"])
        XCTAssertTrue(looks.allSatisfy(\.needsHisChoice))
    }

    func testNoLookIsOfferedWhereThereIsNoInterface() {
        let fits = SkillFit.suggest(shape: shape(["main.py"]), installed: hisSkills)
        XCTAssertTrue(fits.filter { SkillFit.aesthetics.contains($0.skill) }.isEmpty)
    }

    // MARK: - Real repositories

    /// This app: a macOS Xcode project, so it gets the Mac skill and not the web one.
    func testThisRepositoryReadsAsAMacApp() throws {
        let repo = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().path
        try XCTSkipUnless(FileManager.default.fileExists(atPath: repo + "/Night Shift.xcodeproj"))
        XCTAssertTrue(SkillFit.mentionsMacPlatform(projectAt: repo),
                      "the Xcode project says SDKROOT = macosx")
    }
}
