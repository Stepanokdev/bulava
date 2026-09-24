import XCTest
@testable import Bulava

nonisolated final class ProjectPlacementTests: XCTestCase {

    private func project(_ name: String) -> Project {
        Project(name: name, path: "/tmp/\(name)", kind: .unknown, stacks: [])
    }

    private let elsewhere = [
        Project(name: "Meetings Recorder", path: "/tmp/mr", kind: .iosNative, stacks: []),
        Project(name: "pocket-ledger", path: "/tmp/lm", kind: .iosNative, stacks: []),
    ]

    // MARK: - Scoped

    func testOneWritableResourceIsTheAnswerHoweverTheRequestSounds() {
        let mine = project("orbit-console")
        let scope = ProjectPlacement.Scope(writable: [mine])

        let out = ProjectPlacement.resolve(ref: "Meetings Recorder", scope: scope,
                                           global: elsewhere + [mine])
        XCTAssertEqual(out?.id, mine.id, "the hint pointed outside the product and was ignored")
    }

    func testANamedResourceInsideTheProductWins() {
        let api = project("orbit-api")
        let web = project("orbit-web")
        let scope = ProjectPlacement.Scope(writable: [api, web])
        XCTAssertEqual(ProjectPlacement.resolve(ref: "orbit-api", scope: scope, global: elsewhere)?.id,
                       api.id)
    }

    func testSeveralResourcesAndNoMatchResolvesToNothing() {
        let scope = ProjectPlacement.Scope(writable: [project("orbit-api"), project("orbit-web")])
        XCTAssertNil(ProjectPlacement.resolve(ref: "Meetings Recorder", scope: scope, global: elsewhere))
    }

    func testAProductWithNoResourcesResolvesToNothingRatherThanAnything() {
        XCTAssertNil(ProjectPlacement.resolve(ref: "Meetings Recorder",
                                              scope: ProjectPlacement.Scope(), global: elsewhere))
        XCTAssertNil(ProjectPlacement.resolve(ref: nil,
                                              scope: ProjectPlacement.Scope(), global: elsewhere))
    }

    func testAProductWithOnlyReadOnlyResourcesIsStillScoped() {
        let contract = project("openedx-contracts")
        let scope = ProjectPlacement.Scope(writable: [], readOnly: [contract])
        XCTAssertNil(ProjectPlacement.resolve(ref: "Meetings Recorder", scope: scope, global: elsewhere),
                     "a read-only-only product must not be answered with someone else's repository")
    }

    func testAStaleDefaultPointingOutsideTheProductIsIgnored() {
        let outside = elsewhere[0]
        let scope = ProjectPlacement.Scope(writable: [project("a"), project("b")],
                                           defaultProjectID: outside.id)
        XCTAssertNil(ProjectPlacement.resolve(ref: nil, scope: scope, global: elsewhere + [outside]))
    }

    func testADefaultInsideTheProductIsUsed() {
        let a = project("a"), b = project("b")
        let scope = ProjectPlacement.Scope(writable: [a, b], defaultProjectID: b.id)
        XCTAssertEqual(ProjectPlacement.resolve(ref: nil, scope: scope, global: elsewhere)?.id, b.id)
    }

    func testAnAmbiguousHintResolvesToNothing() {
        let scope = ProjectPlacement.Scope(writable: [project("orbit-api"), project("orbit-web")])
        XCTAssertNil(ProjectPlacement.resolve(ref: "orbit", scope: scope, global: elsewhere))
    }

    // MARK: - Unscoped

    func testWithNoProductContextTheGlobalListIsUsed() {
        XCTAssertEqual(ProjectPlacement.resolve(ref: "pocket-ledger", scope: nil, global: elsewhere)?.name,
                       "pocket-ledger")
        let single = [project("only-one")]
        XCTAssertEqual(ProjectPlacement.resolve(ref: nil, scope: nil, global: single)?.name, "only-one")
        XCTAssertNil(ProjectPlacement.resolve(ref: nil, scope: nil, global: elsewhere),
                     "two candidates and no hint is still ambiguous")
    }

    // MARK: - The host for unplaced steps

    func testTheHostMustBeInsideTheScope() {
        let mine = project("orbit-console")
        let scope = ProjectPlacement.Scope(writable: [mine])
        XCTAssertEqual(ProjectPlacement.host(preferring: elsewhere[0], scope: scope)?.id, mine.id,
                       "a host resolved outside the product would place every unplaced step there")
        XCTAssertEqual(ProjectPlacement.host(preferring: mine, scope: scope)?.id, mine.id)
    }

    func testThereIsNoHostWhenTheProductHasNowhereWritable() {
        let scope = ProjectPlacement.Scope(writable: [], readOnly: [project("contracts")])
        XCTAssertNil(ProjectPlacement.host(preferring: elsewhere[0], scope: scope))
    }

    func testWithNoScopeTheCallersChoiceStands() {
        XCTAssertEqual(ProjectPlacement.host(preferring: elsewhere[0], scope: nil)?.id, elsewhere[0].id)
    }
}

// MARK: - Read versus change

nonisolated final class ProjectPlacementIntentTests: XCTestCase {

    private let workspace = Project(name: "orbit-console", path: "/tmp/pc", kind: .unknown, stacks: [])
    private let source = Project(name: "openedx-platform", path: "/tmp/ox", kind: .unknown, stacks: [])

    private var scope: ProjectPlacement.Scope {
        ProjectPlacement.Scope(writable: [workspace], readOnly: [source])
    }

    func testNamingAReadOnlyResourceForAReadFindsIt() {
        let out = ProjectPlacement.resolve(ref: "openedx-platform", scope: scope,
                                           global: [], intent: .read)
        XCTAssertEqual(out?.id, source.id,
                       "a look named the source and was answered with the workspace")
    }

    func testNamingTheWorkspaceForAReadStillFindsTheWorkspace() {
        XCTAssertEqual(ProjectPlacement.resolve(ref: "orbit-console", scope: scope,
                                                global: [], intent: .read)?.id, workspace.id)
    }

    func testNamingAReadOnlyResourceForAChangeResolvesToNothing() {
        XCTAssertNil(ProjectPlacement.resolve(ref: "openedx-platform", scope: scope,
                                              global: [], intent: .change))
    }

    func testAChangeWithNoHintUsesTheSoleWritableResource() {
        XCTAssertEqual(ProjectPlacement.resolve(ref: nil, scope: scope, global: [],
                                                intent: .change)?.id, workspace.id)
    }

    func testAReadWithNoHintAndTwoHostsIsAmbiguous() {
        XCTAssertNil(ProjectPlacement.resolve(ref: nil, scope: scope, global: [], intent: .read))
    }

    func testAReadOnlyOnlyProductCanBeRead() {
        let readOnlyOnly = ProjectPlacement.Scope(writable: [], readOnly: [source])
        XCTAssertEqual(ProjectPlacement.resolve(ref: nil, scope: readOnlyOnly, global: [],
                                                intent: .read)?.id, source.id)
        XCTAssertNil(ProjectPlacement.resolve(ref: nil, scope: readOnlyOnly, global: [],
                                              intent: .change),
                     "there is nowhere to change anything, and that is not a licence to go outside")
    }
}

// MARK: - A product that is gone

nonisolated final class DeletedProductScopeTests: XCTestCase {

    @MainActor func testAKnownButMissingProductIsAnEmptyScopeRatherThanNoScope() {
        let model = AppModel()
        let gone = UUID()
        let scope = model.scope(forProductID: gone)
        XCTAssertNotNil(scope, "a passed id must never read as 'no product context'")
        XCTAssertTrue(scope?.isEmpty == true)
        XCTAssertEqual(model.productProjects(gone), [],
                       "an empty array, not nil — nil would mean the global list")
    }

    @MainActor func testResolvingForAMissingProductAnswersNothing() {
        let model = AppModel()
        XCTAssertNil(model.resolveForemanProject(ref: "Meetings Recorder", in: UUID()),
                     "a deleted product must not be answered with somebody else's repository")
        XCTAssertNil(model.resolveForemanProject(ref: nil, in: UUID()))
    }

    @MainActor func testNoIdAtAllStillMeansNoScope() {
        let model = AppModel()
        XCTAssertNil(model.scope(forProductID: nil))
        XCTAssertNil(model.productProjects(nil))
    }
}

// MARK: - Every branch pins its answer

nonisolated final class IntentPinningTests: XCTestCase {

    private var source: String {
        get throws {
            let root = URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent().deletingLastPathComponent()
            return try String(contentsOf: root
                .appendingPathComponent("Night Shift/App/AppModel+Events.swift"), encoding: .utf8)
        }
    }

    private func intentSwitch() throws -> String {
        let text = try source
        guard let start = text.range(of: "private func executeForemanIntent") else {
            XCTFail("executeForemanIntent has moved"); return ""
        }

        // The end of the function, found by STRUCTURE rather than by a comment. Anchoring on a
        // doc comment meant this scanned the whole rest of the file the moment comments were
        // removed — and then reported every unpinned reply in every other function as a defect.
        let rest = text[start.upperBound...]
        let boundary = ["\n    private func ", "\n    func ", "\n    @MainActor "]
            .compactMap { rest.range(of: $0)?.lowerBound }
            .min()
        guard let end = boundary else { return String(rest) }
        return String(rest[..<end])
    }

    func testEveryForemanReplyInTheSwitchIsPinnedToAProduct() throws {
        let body = try intentSwitch()
        XCTAssertFalse(body.isEmpty)

        var unpinned: [String] = []

        for call in ["postForemanText(", "propose("] {
            var searchRange = body.startIndex..<body.endIndex
            while let found = body.range(of: call, range: searchRange) {

                let tail = body[found.lowerBound...]
                let stop = tail.range(of: "\n\n")?.lowerBound
                    ?? tail.range(of: "\n        case ")?.lowerBound ?? tail.endIndex
                let statement = String(tail[..<stop])
                if !statement.contains("productID:") {
                    unpinned.append(statement.split(separator: "\n").first.map(String.init) ?? statement)
                }
                searchRange = found.upperBound..<body.endIndex
            }
        }
        XCTAssertTrue(unpinned.isEmpty,
                      "an answer that does not name its product lands wherever he is looking "
                      + "(scanned \(body.count) chars):\n"
                      + unpinned.map { "«\($0)»" }.joined(separator: "\n"))
    }

    func testEveryProjectResolutionInTheSwitchIsScopedToTheProduct() throws {
        let body = try intentSwitch()
        var unscoped: [String] = []
        var searchRange = body.startIndex..<body.endIndex
        while let found = body.range(of: "resolveForemanProject(", range: searchRange) {
            let tail = body[found.lowerBound...]
            let stop = tail.range(of: ")")?.upperBound ?? tail.endIndex
            let call = String(tail[..<stop])
            if !call.contains("in: productID") { unscoped.append(call) }
            searchRange = found.upperBound..<body.endIndex
        }
        XCTAssertTrue(unscoped.isEmpty,
                      "a resolution that ignores the asking product can answer with another's repo:\n"
                      + unscoped.joined(separator: "\n"))
    }
}
