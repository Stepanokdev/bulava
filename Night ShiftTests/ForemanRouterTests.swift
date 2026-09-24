import XCTest
@testable import Bulava

nonisolated final class ForemanConfirmTests: XCTestCase {

    func testPlainYesConfirms() {
        for s in ["так", "Так", "так!", "так.", " так ", "yes", "ok", "давай", "підтверджую", "+"] {
            XCTAssertTrue(ForemanConfirm.isAffirmative(s), "\(s) should be affirmative")
            XCTAssertFalse(ForemanConfirm.isNegative(s), "\(s) should not be negative")
        }
    }

    func testPlainNoCancels() {
        for s in ["ні", "no", "стоп", "скасуй", "не треба", "та ні", "cancel"] {
            XCTAssertTrue(ForemanConfirm.isNegative(s), "\(s) should be negative")
            XCTAssertFalse(ForemanConfirm.isAffirmative(s), "\(s) should not be affirmative")
        }
    }

    func testMixedMessagesDoNotConfirm() {
        for s in ["так, але не запускай", "ок не зараз", "давай не сьогодні",
                  "може й так, а може ні", "думаю, варто змерджити пізніше", "та хз, може мерджити"] {
            XCTAssertFalse(ForemanConfirm.isAffirmative(s), "\(s) must NOT confirm")
        }
    }

    func testAmbiguousIsNeitherYesNorNo() {

        let s = "а що там ще по інших проєктах?"
        XCTAssertFalse(ForemanConfirm.isAffirmative(s))
        XCTAssertFalse(ForemanConfirm.isNegative(s))
    }
}

nonisolated final class ForemanRouterParseTests: XCTestCase {

    func testParsesCleanJSON() {
        let i = ForemanRouter.parse(#"{"action":"approve","target":"ledger","reply":"приймаю"}"#)
        XCTAssertEqual(i?.action, .approve)
        XCTAssertEqual(i?.target, "ledger")
        XCTAssertEqual(i?.reply, "приймаю")
    }

    func testStripsProseAndFencesAroundJSON() {
        let raw = "Ось рішення:\n```json\n{\"action\":\"status\",\"target\":null,\"reply\":\"ок\"}\n```\nдякую"
        let i = ForemanRouter.parse(raw)
        XCTAssertEqual(i?.action, .status)
        XCTAssertNil(i?.target)
    }

    func testNullAndEmptyTargetBecomeNil() {
        XCTAssertNil(ForemanRouter.parse(#"{"action":"relay","target":"null","reply":"x"}"#)?.target)
        XCTAssertNil(ForemanRouter.parse(#"{"action":"relay","target":"","reply":"x"}"#)?.target)
    }

    func testUnknownActionRejected() {

        XCTAssertNil(ForemanRouter.parse(#"{"action":"rm -rf","reply":"x"}"#))
        XCTAssertNil(ForemanRouter.parse(#"{"action":"","reply":"x"}"#))
    }

    func testGarbageAndNonJSONReturnNil() {
        XCTAssertNil(ForemanRouter.parse("не JSON взагалі"))
        XCTAssertNil(ForemanRouter.parse(""))
        XCTAssertNil(ForemanRouter.parse("{broken"))
        XCTAssertNil(ForemanRouter.parse("}{"))
    }

    func testConsequentialActionsMapFromSnakeCase() {
        XCTAssertEqual(ForemanRouter.parse(#"{"action":"run_queue","reply":""}"#)?.action, .runQueue)
        XCTAssertEqual(ForemanRouter.parse(#"{"action":"stop_all","reply":""}"#)?.action, .stopAll)
        XCTAssertEqual(ForemanRouter.parse(#"{"action":"dispatch_ready","reply":""}"#)?.action, .dispatchReady)
    }
}

nonisolated final class AcceptanceGateTests: XCTestCase {
    private func snap(_ cls: ReviewClassKind, disposition: String? = "passed", scope: Bool = false,
                      present: Bool = true, overall: Bool = true, green: Bool = true,
                      bound: Bool = true, frame: Bool = true, headStable: Bool = true) -> AcceptanceSnapshot {
        AcceptanceSnapshot(reviewClass: cls, hasScopeViolation: scope, disposition: disposition,
                           evidencePresent: present, evidenceOverallPass: overall, evidenceCleanGreen: green,
                           evidenceBoundToHead: bound, frameValid: frame, headStable: headStable)
    }
    private func ok(_ s: AcceptanceSnapshot, _ m: String) { XCTAssertNil(AcceptanceGate.evaluate(s), m) }
    private func no(_ s: AcceptanceSnapshot, _ m: String) { XCTAssertNotNil(AcceptanceGate.evaluate(s), m) }

    func testApprovable() {
        ok(snap(.code), "code: passed + green")
        ok(snap(.visual), "visual: passed + green + frame")
        ok(snap(.informational, disposition: nil, present: false, overall: false, green: false, bound: false, frame: false),
           "informational needs only its deliverable")
        ok(snap(.code, frame: false), "frame is irrelevant for code")
    }
    func testBlocked() {
        no(snap(.code, disposition: nil), "missing verdict fails closed")
        no(snap(.code, disposition: "debt"), "non-passed verdict blocks")
        no(snap(.code, disposition: "needs-user"), "needs-user blocks")
        no(snap(.code, present: false), "no evidence blocks")
        no(snap(.code, bound: false), "stale (unbound) evidence blocks")
        no(snap(.code, overall: false), "overall not-pass blocks")
        no(snap(.code, green: false), "a non-clean criterion blocks")
        no(snap(.code, scope: true), "scope violation blocks code")
        no(snap(.visual, scope: true), "scope violation blocks visual")
        no(snap(.informational, scope: true), "scope violation blocks even informational")
        no(snap(.visual, frame: false), "visual without a valid frame blocks")
        no(snap(.visual, headStable: false), "an unstable head blocks even when otherwise green")
        no(snap(.code, headStable: false), "TOCTOU: head changed after the check")
    }
}

// MARK: - Isolation between conversations

nonisolated final class ForemanIsolationTests: XCTestCase {

    private let a = UUID()
    private let b = UUID()

    func testARoundInOneProductDoesNotSupersedeAnotherProducts() {
        var m = ForemanRounds()
        let genA = m.bump(a)
        let genB = m.bump(b)
        XCTAssertTrue(m.isCurrent(genA, a))
        XCTAssertTrue(m.isCurrent(genB, b))

        _ = m.bump(b)
        XCTAssertTrue(m.isCurrent(genA, a),
                      "a message in one product superseded a reply being composed in another")
        XCTAssertFalse(m.isCurrent(genB, b))
    }

    func testANewerRoundInTheSameProductStillSupersedesTheOlderOne() {
        var m = ForemanRounds()
        let first = m.bump(a)
        _ = m.bump(a)
        XCTAssertFalse(m.isCurrent(first, a),
                       "within one conversation, superseding is the whole point of the counter")
    }

    func testGenerationsStartFromNothingPerProduct() {
        var m = ForemanRounds()
        XCTAssertEqual(m.current(a), 0)
        XCTAssertEqual(m.bump(a), 1)
        XCTAssertEqual(m.current(b), 0, "products do not share a counter")
    }
}

// MARK: - Work stays inside the product it was asked in

nonisolated final class PlacementScopeTests: XCTestCase {

    private func project(_ name: String) -> Project {
        Project(name: name, path: "/tmp/\(name)", kind: .unknown, stacks: [])
    }

    func testTheAskNamesOnlyTheProductsOwnResources() {
        let ask = AppModel.askWhichResource([project("orbit-console"), project("orbit-api")])
        XCTAssertTrue(ask.contains("orbit-console"))
        XCTAssertTrue(ask.contains("orbit-api"))
        XCTAssertFalse(ask.contains("Meetings Recorder"))
    }

    func testEveryResourceReplyIsLocalized() {
        let asks = [AppModel.askWhichResource([]),
                    AppModel.askWhichResource([project("one")]),
                    AppModel.askWhichResource([project("one"), project("two")])]
        for ask in asks {
            XCTAssertFalse(ask.isEmpty)

            XCTAssertFalse(ask.contains("%@"), "an unresolved format specifier reached the reader")
        }
    }

    func testASingleResourceIsNamedRatherThanListed() {
        let ask = AppModel.askWhichResource([project("orbit-console")])
        XCTAssertTrue(ask.contains("orbit-console"))
        XCTAssertFalse(ask.contains("•"), "a list of one is not a list")
    }

    func testAProductWithNoResourceSaysSoInsteadOfOfferingOthers() {
        let ask = AppModel.askWhichResource([])
        XCTAssertFalse(ask.contains("•"), "there is nothing to offer, so nothing is listed")
        XCTAssertFalse(ask.isEmpty)
    }

    // MARK: - The scope decision itself

    func testAScopedProductWithNoResourcesPlansNothing() async {
        let model = await AppModel()
        let drafts = await model.decomposeMission(text: "зроби щось", defaultProject: nil,
                                                 visual: false, allowed: [])
        XCTAssertTrue(drafts.isEmpty,
                      "a product with nowhere to work must produce no plan, not a global one")
    }
}
