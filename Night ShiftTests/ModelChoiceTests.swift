import XCTest
@testable import Bulava

/// Which model does the work, and how the app learns what models exist.
///
/// The pinned list (`claude-opus-5`, `claude-haiku-4-5-20251001`) went stale the day anything new
/// shipped, and Fable was never in it at all; the Codex side was a free-text box. Both now name
/// something that keeps up on its own — a CLI family alias for Claude, the CLI's own catalogue
/// file for Codex.
nonisolated final class ModelChoiceTests: XCTestCase {

    // MARK: - Claude

    func testEveryFamilyIsOfferedIncludingFable() {
        let offered = Set(ClaudeModelChoice.allCases.map(\.rawValue))
        for family in ["fable", "opus", "sonnet", "haiku"] {
            XCTAssertTrue(offered.contains(family), "\(family) has to be pickable")
        }
    }

    /// Aliases, not version numbers: `--model opus` is documented as "the latest Opus", which is
    /// what keeps this list from needing a release of Bulava behind every model launch.
    func testAFamilyIsPassedAsAnAliasNotAPinnedVersion() {
        XCTAssertEqual(ClaudeModelChoice.opus.flagValue, "opus")
        XCTAssertEqual(ClaudeModelChoice.fable.flagValue, "fable")
        XCTAssertEqual(ClaudeModelChoice.sonnet.flagValue, "sonnet")
        XCTAssertEqual(ClaudeModelChoice.haiku.flagValue, "haiku")
        XCTAssertEqual(ClaudeModelChoice.auto.flagValue, "")
        for choice in ClaudeModelChoice.allCases where choice != .auto {
            XCTAssertFalse(choice.flagValue.contains("-"),
                           "\(choice.rawValue) looks like a pinned id, not a family alias")
        }
    }

    /// The shorthand earlier builds wrote was never a model id. It becomes the family it named.
    func testSettingsThatNamedAModelInShorthandStillOpen() throws {
        for (stored, expected) in [("opus5", ClaudeModelChoice.opus),
                                   ("sonnet5", .sonnet),
                                   ("haiku45", .haiku)] {
            let json = #"{"stateDirPath":"/tmp","pollSeconds":4,"claudeModel":"\#(stored)"}"#
            let settings = try JSONDecoder().decode(AppSettings.self, from: Data(json.utf8))
            XCTAssertEqual(settings.claudeModel, expected, "stored \(stored)")
        }
    }

    /// A real model id is a choice in its own right now, and stays the one that was chosen. It
    /// used to be folded into its family, which was right while versions could not be picked and
    /// is wrong the moment they can: it would move someone off the version they pinned.
    func testAPinnedVersionStaysPinned() throws {
        for stored in ["claude-opus-5", "claude-opus-4-7", "claude-haiku-4-5-20251001"] {
            let json = #"{"stateDirPath":"/tmp","pollSeconds":4,"claudeModel":"\#(stored)"}"#
            let settings = try JSONDecoder().decode(AppSettings.self, from: Data(json.utf8))
            XCTAssertEqual(settings.claudeModel.rawValue, stored)
            XCTAssertTrue(settings.claudeModel.isPinnedVersion)
            XCTAssertEqual(settings.claudeModel.flagValue, stored)
        }
    }

    /// A model id goes onto a command line. Anything that could not be one is not a model name,
    /// and Automatic is the safe reading of it.
    func testAStoredNameThatCouldNotBeAModelOpensAsAutomatic() throws {
        for stored in ["opus; whoami", "$(id)", ""] {
            let json = #"{"stateDirPath":"/tmp","pollSeconds":4,"claudeModel":"\#(stored)"}"#
            let settings = try JSONDecoder().decode(AppSettings.self, from: Data(json.utf8))
            XCTAssertEqual(settings.claudeModel, .auto, "stored \(stored)")
        }
    }

    // MARK: - The mode

    /// The switch for one-engine work is out of the interface, so the stored mode is not read.
    /// Anyone who had chosen "Codex only" before that would otherwise be stuck in it: no review
    /// gate, and nothing on screen to explain why. If the switch comes back, this test is what
    /// says the pin has to go with it.
    func testTheStoredModeIsIgnoredWhileTheSwitchIsOut() throws {
        for stored in ["codex", "claude", "claudeAndCodex"] {
            let json = #"{"stateDirPath":"/tmp","pollSeconds":4,"chatMode":"\#(stored)"}"#
            let settings = try JSONDecoder().decode(AppSettings.self, from: Data(json.utf8))
            XCTAssertEqual(settings.chatMode, .claudeAndCodex, "stored \(stored)")
            XCTAssertTrue(settings.chatMode.usesClaude)
            XCTAssertTrue(settings.chatMode.usesCodex)
            XCTAssertTrue(settings.chatMode.reviewsWork, "the review gate is the point of it")
        }
    }

    /// And the choice is still written down, so it is there if the switch returns.
    func testTheModeIsStillSavedEvenThoughItIsNotRead() throws {
        var settings = AppSettings.fallback
        settings.chatMode = .codex
        let data = try JSONEncoder().encode(settings)
        let raw = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(raw["chatMode"] as? String, "codex")
    }

    // MARK: - Claude models, as the CLI lists them

    /// A cut of the real catalogue: two current models, two previous versions, one that the
    /// subscription cannot reach, and one that needs a newer CLI than this machine has.
    private let claudeCatalogue = """
    {"surfaces":{"cc":{"model_selector_config":[{"id":"cc",
      "models":[
        {"id":"claude-fable-5-1","name":"Fable 5.1","short_name":"Fable","section":"main",
         "description":"For your toughest challenges","min_claude_code_version":"2.1.251",
         "thinking":{"type":"effort"},
         "runtime":{"family":"mythos","default_effort":"high",
                    "effort_levels":["low","medium","high","xhigh","max"]},
         "offered_on":["first_party","bedrock"]},
        {"id":"claude-opus-5","name":"Opus 5","short_name":"Opus","section":"main",
         "thinking":{"type":"effort"},
         "runtime":{"family":"opus","default_effort":"high",
                    "effort_levels":["low","medium","high","xhigh","max"]},
         "offered_on":["first_party","bedrock"]},
        {"id":"claude-haiku-4-5-20251001","name":"Haiku 4.5","short_name":"Haiku","section":"main",
         "thinking":{"type":"none"},
         "runtime":{"family":"haiku"},
         "offered_on":["first_party","bedrock"]},
        {"id":"claude-opus-4-7","name":"Opus 4.7","short_name":"Opus","section":"overflow",
         "thinking":{"type":"effort"},
         "runtime":{"family":"opus","default_effort":"xhigh",
                    "effort_levels":["low","medium","high","xhigh","max"]},
         "offered_on":["first_party","bedrock"]},
        {"id":"claude-opus-4-6","name":"Opus 4.6","short_name":"Opus","section":"overflow",
         "thinking":{"type":"effort"},
         "runtime":{"family":"opus","default_effort":"high",
                    "effort_levels":["low","medium","high","max"]},
         "offered_on":["first_party","bedrock"]},
        {"id":"claude-opus-4-1-20250805","name":"Opus 4.1","short_name":"Opus","section":"overflow",
         "thinking":{"type":"none"},
         "runtime":{"family":"opus"},
         "offered_on":["bedrock","vertex"]},
        {"id":"claude bad id; rm -rf /","name":"Nope","section":"main",
         "runtime":{"family":"opus"},"offered_on":["first_party"]}
      ],
      "provider_alias_targets":{
        "opus":{"default":"claude-opus-5","per_provider":{"gateway":"claude-opus-4-7"}},
        "fable":{"default":"claude-fable-5-1"},
        "haiku":{"default":"claude-haiku-4-5-20251001"},
        "sonnet":{"default":"claude-sonnet-5"}
      }}],
      "model_selector_state":[{"id":"cc","model":"claude-opus-4-6",
        "thinking":{"type":"effort","effort":"high"},
        "thinking_by_model":[
          {"id":"claude-opus-4-7","thinking":{"type":"effort","effort":"xhigh"}},
          {"id":"claude-opus-4-6","thinking":{"type":"effort","effort":"medium"}}
        ]}]}}}
    """

    private func claude(cli: String = "2.1.269") -> ClaudeModelCatalog {
        ClaudeModelCatalog.decode(Data(claudeCatalogue.utf8), cliVersion: cli)
    }

    func testTheClaudeCatalogueIsReadInItsOwnOrder() {
        let found = claude()
        XCTAssertTrue(found.loaded)
        XCTAssertEqual(found.models.map(\.id),
                       ["claude-fable-5-1", "claude-opus-5", "claude-haiku-4-5-20251001",
                        "claude-opus-4-7", "claude-opus-4-6"])
        XCTAssertEqual(found.current.map(\.name), ["Fable 5.1", "Opus 5", "Haiku 4.5"])
        XCTAssertEqual(found.older.map(\.name), ["Opus 4.7", "Opus 4.6"])
    }

    /// `offered_on` is the catalogue saying who can run it. Opus 4.1 is Bedrock and Vertex only —
    /// offering it on a subscription is a menu entry that fails the moment it is chosen.
    func testAModelTheSubscriptionCannotReachIsNotOffered() {
        XCTAssertNil(claude().model(id: "claude-opus-4-1-20250805"))
    }

    /// A model newer than the installed CLI is not a choice, it is a broken run.
    func testAModelTheInstalledCLIHasNeverHeardOfIsNotOffered() {
        XCTAssertNil(claude(cli: "2.1.200").model(id: "claude-fable-5-1"))
        XCTAssertNotNil(claude(cli: "2.1.251").model(id: "claude-fable-5-1"))
        // Nothing is filtered when the version is unknown: guessing would take away models that work.
        XCTAssertNotNil(claude(cli: "").model(id: "claude-fable-5-1"))
    }

    func testAVersionIsComparedAsNumbersNotText() {
        XCTAssertTrue(ClaudeModelCatalog.isVersion("2.1.9", olderThan: "2.1.251"))
        XCTAssertFalse(ClaudeModelCatalog.isVersion("2.1.269", olderThan: "2.1.251"))
        XCTAssertFalse(ClaudeModelCatalog.isVersion("2.2", olderThan: "2.1.251"))
        XCTAssertFalse(ClaudeModelCatalog.isVersion("2.1.251", olderThan: "2.1.251"))
    }

    func testAnIdThatCouldNotGoOnACommandLineIsDropped() {
        XCTAssertEqual(claude().models.filter { $0.name == "Nope" }.count, 0)
        XCTAssertNil(ClaudeModelCatalog.safeID("opus; whoami"))
        XCTAssertEqual(ClaudeModelCatalog.safeID(" claude-opus-5 "), "claude-opus-5")
    }

    /// The whole question the old menu could not answer: which Opus is "Opus"?
    func testAFamilyNamesTheVersionItResolvesTo() {
        let found = claude()
        XCTAssertEqual(found.resolved(.opus)?.id, "claude-opus-5")
        XCTAssertEqual(found.versionName(for: .opus), "Opus 5")
        XCTAssertEqual(found.versionName(for: .fable), "Fable 5.1")
        // Automatic resolves too, through the selector state — see the tests further down.
        XCTAssertEqual(found.versionName(for: .auto), "Opus 4.6")
        // Sonnet's alias points at a model this catalogue does not carry, so there is nothing to
        // claim — the family still works, it just goes unlabelled.
        XCTAssertNil(found.versionName(for: .sonnet))
    }

    func testAPinnedVersionResolvesToItself() {
        let found = claude()
        XCTAssertEqual(found.resolved(ClaudeModelChoice(rawValue: "claude-opus-4-7"))?.name, "Opus 4.7")
        XCTAssertEqual(found.label(for: ClaudeModelChoice(rawValue: "claude-opus-4-7")), "Opus 4.7")
        XCTAssertEqual(found.label(for: ClaudeModelChoice(rawValue: "claude-opus-9")), "claude-opus-9",
                       "a version this catalogue never heard of is still what is being sent")
    }

    /// Offering a level the model refuses means the CLI warns, runs at its default, and the
    /// composer goes on claiming the level nobody got.
    func testOnlyDepthsTheChosenClaudeModelAcceptsAreOffered() {
        let found = claude()
        XCTAssertEqual(found.levels(for: ClaudeModelChoice(rawValue: "claude-opus-4-6")).map(\.rawValue),
                       ["auto", "low", "medium", "high", "max", "ultracode"],
                       "Opus 4.6 does not take xhigh")
        XCTAssertEqual(found.levels(for: .opus).map(\.rawValue),
                       ["auto", "low", "medium", "high", "xhigh", "max", "ultracode"])
        // Automatic is not "nothing chosen" any more: the catalogue says which model answers with
        // no `--model`, so its levels are the ones on offer.
        XCTAssertEqual(found.levels(for: .auto).map(\.rawValue),
                       ["auto", "low", "medium", "high", "max", "ultracode"])
        XCTAssertEqual(ClaudeModelCatalog.empty.levels(for: .auto), ClaudeEffortChoice.allCases,
                       "with no catalogue there is still nothing to narrow by")
    }

    /// Haiku 4.5 has no reasoning levels at all. A depth slider over it is a control that lies,
    /// and `--effort` at it is a flag the CLI warns about and ignores.
    func testAModelWithNoDepthIsNotGivenOne() {
        let found = claude()
        XCTAssertFalse(found.thinks(.haiku))
        XCTAssertEqual(found.levels(for: .haiku), [.auto])
        XCTAssertEqual(found.effortFlag(.max, for: .haiku), ClaudeModelCatalog.noDepth)
        XCTAssertEqual(found.depthLabel(.auto, for: .haiku), String(localized: "No depth setting"))

        XCTAssertTrue(found.thinks(.opus))
        XCTAssertEqual(found.effortFlag(.max, for: .opus), "max")
        XCTAssertEqual(found.effortFlag(.auto, for: .opus), "high")
    }

    /// `Automatic` is the model's own default depth, and the versions differ: Opus 4.7 was tuned
    /// to xhigh where Opus 5 defaults to high. One fixed level for all of them was wrong in both
    /// directions.
    func testAutomaticIsTheClaudeModelsOwnDefaultDepth() {
        let found = claude()
        XCTAssertEqual(found.automaticLevel(for: .opus), .high)
        XCTAssertEqual(found.automaticLevel(for: ClaudeModelChoice(rawValue: "claude-opus-4-7")), .xhigh)
        XCTAssertEqual(found.effort(.auto, for: ClaudeModelChoice(rawValue: "claude-opus-4-7")), .xhigh)
        XCTAssertEqual(found.effort(.low, for: ClaudeModelChoice(rawValue: "claude-opus-4-7")), .low,
                       "a chosen depth is never second-guessed")
        // For Automatic the selector state's own depth answers — `medium` in this fixture, which
        // is not the app's fallback and is the point: it is what the CLI would actually use.
        XCTAssertEqual(found.automaticLevel(for: .auto), .medium)
        XCTAssertEqual(ClaudeModelCatalog.empty.automaticLevel(for: .opus),
                       ClaudeEffortChoice.conversationDefault)
        XCTAssertEqual(ClaudeModelCatalog.empty.automaticLevel(for: .auto),
                       ClaudeEffortChoice.conversationDefault,
                       "with no catalogue the app's own fallback is the honest answer")
    }

    /// `ultracode` is Bulava's deepest setting and the CLI takes it; the catalogue lists the
    /// service's own levels and never mentions it, so it must not be filtered away with them.
    func testUltracodeSurvivesTheCataloguesList() {
        XCTAssertTrue(claude().levels(for: .opus).contains(.ultracode))
        XCTAssertFalse(claude().levels(for: .haiku).contains(.ultracode))
    }

    func testNoClaudeCatalogueMeansNothingIsTakenAway() {
        let none = ClaudeModelCatalog.empty
        XCTAssertFalse(none.loaded)
        XCTAssertEqual(none.levels(for: .haiku), ClaudeEffortChoice.allCases)
        XCTAssertTrue(none.thinks(.haiku))
        XCTAssertNil(none.versionName(for: .opus))
        XCTAssertEqual(none.label(for: .opus), String(localized: "Opus"))
    }

    func testAMalformedClaudeCatalogueIsIgnoredRatherThanCrashing() {
        XCTAssertFalse(ClaudeModelCatalog.decode(Data("not json".utf8)).loaded)
        XCTAssertFalse(ClaudeModelCatalog.decode(Data(#"{"surfaces":{"cc":{}}}"#.utf8)).loaded)
        XCTAssertFalse(ClaudeModelCatalog.decode(Data(#"{"documentBytes":"!!!"}"#.utf8)).loaded)
    }

    /// What is actually on disk is the cache file, which carries the catalogue base64-encoded in
    /// `documentBytes`, one file per source plus a bookkeeping record that is not a catalogue.
    func testTheCacheFileOnDiskIsReadAndTheNewestOneWins() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("claude-catalogue-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let olderDocument = """
        {"surfaces":{"cc":{"model_selector_config":[{"id":"cc","models":[
          {"id":"claude-opus-4-6","name":"Opus 4.6","section":"main","thinking":{"type":"effort"},
           "runtime":{"family":"opus","default_effort":"high","effort_levels":["low"]},
           "offered_on":["first_party"]}],
          "provider_alias_targets":{"opus":{"default":"claude-opus-4-6"}}}]}}}
        """
        let stale = Data(olderDocument.utf8).base64EncodedString()
        let fresh = Data(claudeCatalogue.utf8).base64EncodedString()
        try Data(#"{"fetchedAt":1,"documentBytes":"\#(stale)"}"#.utf8)
            .write(to: dir.appendingPathComponent("published-old.json"))
        try Data(#"{"fetchedAt":2,"documentBytes":"\#(fresh)"}"#.utf8)
            .write(to: dir.appendingPathComponent("published-new.json"))
        // Not a catalogue, and reading it as one would lose the real answer.
        try Data(#"{"version":1,"sources":{}}"#.utf8)
            .write(to: dir.appendingPathComponent("published-floor.json"))

        let found = ClaudeModelCatalog.read(cliVersion: "2.1.269", from: dir)
        XCTAssertTrue(found.loaded)
        XCTAssertEqual(found.resolved(.opus)?.name, "Opus 5")
        XCTAssertEqual(found.models.count, 5)
    }

    /// The shape CLI 2.1.280 writes instead: one file per account, `<account>-<org>-cc.json`, with
    /// the selector under `catalog` and none of the document's `runtime`, `offered_on` or alias
    /// table. A cut of the real file from the day Opus 5.5 shipped.
    private let claudeCatalogueV2 = """
    {"version":2,"fetchedAt":3,"staleAt":4,"catalog":{"surface":"cc",
      "config":{"id":"cc","models":[
        {"id":"claude-opus-5-5","name":"Opus 5.5","short_name":"Opus","section":"main",
         "description":"Most capable for ambitious work","min_claude_code_version":"2.1.280",
         "thinking":{"type":"effort","effort_options":[{"id":"low"},
           {"id":"medium","badge":{"message":"Default"}},{"id":"high"},{"id":"xhigh"},{"id":"max"}]}},
        {"id":"claude-fable-5-1","name":"Fable 5.1","short_name":"Fable","section":"main",
         "min_claude_code_version":"2.1.251",
         "thinking":{"type":"effort","effort_options":[{"id":"low"},{"id":"medium"},
           {"id":"high","badge":{"message":"Default"}},{"id":"xhigh"},{"id":"max"}]}},
        {"id":"claude-sonnet-5","name":"Sonnet 5","short_name":"Sonnet","section":"main",
         "thinking":{"type":"effort","effort_options":[{"id":"low"},{"id":"medium"},
           {"id":"high","badge":{"message":"Default"}},{"id":"xhigh"},{"id":"max"}]}},
        {"id":"claude-haiku-4-5-20251001","name":"Haiku 4.5","short_name":"Haiku","section":"main",
         "thinking":{"type":"none"}},
        {"id":"claude-opus-5","name":"Opus 5","short_name":"Opus","section":"overflow",
         "thinking":{"type":"effort","effort_options":[{"id":"low"},{"id":"medium"},
           {"id":"high","badge":{"message":"Default"}},{"id":"xhigh"},{"id":"max"}]}},
        {"id":"claude-opus-4-6","name":"Opus 4.6","short_name":"Opus","section":"overflow",
         "thinking":{"type":"effort","effort_options":[{"id":"low"},{"id":"medium"},
           {"id":"high","badge":{"message":"Default"}},{"id":"max"}]}}
      ],"settings_vocabulary":{}},
      "state":{"id":"cc","model":"claude-opus-5-5","selection_source":"global_default",
        "thinking":{"type":"effort","effort":"medium"},
        "thinking_by_model":[{"id":"claude-opus-5-5","thinking":{"type":"effort","effort":"medium"}},
                             {"id":"claude-opus-5","thinking":{"type":"effort","effort":"high"}}]}}}
    """

    func testTheNewPerAccountCatalogueIsRead() {
        let found = ClaudeModelCatalog.decode(Data(claudeCatalogueV2.utf8), cliVersion: "2.1.280")
        XCTAssertTrue(found.loaded)
        XCTAssertEqual(found.current.map(\.name), ["Opus 5.5", "Fable 5.1", "Sonnet 5", "Haiku 4.5"])
        XCTAssertEqual(found.older.map(\.name), ["Opus 5", "Opus 4.6"])
        // The alias table is gone from this shape; each family is its newest main-list model.
        XCTAssertEqual(found.aliases, ["opus": "claude-opus-5-5", "fable": "claude-fable-5-1",
                                       "sonnet": "claude-sonnet-5",
                                       "haiku": "claude-haiku-4-5-20251001"])
        XCTAssertEqual(found.versionName(for: .opus), "Opus 5.5")
        XCTAssertEqual(found.resolved(.auto)?.id, "claude-opus-5-5")
    }

    /// Levels come from each model's own `effort_options` and its default from the one badged
    /// "Default" — Opus 5.5 defaults to medium where Opus 5 defaulted to high.
    func testTheNewCataloguesDepthsAreTheModelsOwn() {
        let found = ClaudeModelCatalog.decode(Data(claudeCatalogueV2.utf8), cliVersion: "2.1.280")
        let opus55 = ClaudeModelChoice(rawValue: "claude-opus-5-5")
        XCTAssertEqual(found.model(id: "claude-opus-5-5")?.levels, ["low", "medium", "high", "xhigh", "max"])
        XCTAssertEqual(found.automaticLevel(for: opus55), .medium)
        XCTAssertEqual(found.automaticLevel(for: ClaudeModelChoice(rawValue: "claude-opus-5")), .high)
        XCTAssertFalse(found.levels(for: ClaudeModelChoice(rawValue: "claude-opus-4-6")).contains(.xhigh))
        XCTAssertFalse(found.thinks(.haiku), "Haiku takes no depth in this shape either")
        XCTAssertEqual(found.effortFlag(.high, for: .haiku), ClaudeModelCatalog.noDepth)
    }

    /// A CLI older than Opus 5.5 cannot run it, so it is not offered — and "Opus" then means the
    /// newest Opus that CLI can actually start.
    func testTheNewCatalogueStillHonoursTheInstalledCLI() {
        let found = ClaudeModelCatalog.decode(Data(claudeCatalogueV2.utf8), cliVersion: "2.1.279")
        XCTAssertNil(found.model(id: "claude-opus-5-5"))
        XCTAssertEqual(found.aliases["opus"], "claude-opus-5")
    }

    /// Both shapes on one disk, as on every machine that updated the CLI: the per-account file is
    /// the fresher one and has to win, or the menu stays on the models of the last old-style fetch.
    func testTheFresherShapeWinsOnDisk() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("claude-catalogue-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let stale = Data(claudeCatalogue.utf8).base64EncodedString()
        try Data(#"{"fetchedAt":2,"documentBytes":"\#(stale)"}"#.utf8)
            .write(to: dir.appendingPathComponent("published-old.json"))
        try Data(#"{"version":1,"sources":{}}"#.utf8)
            .write(to: dir.appendingPathComponent("published-floor.json"))
        try Data(claudeCatalogueV2.utf8)
            .write(to: dir.appendingPathComponent("c168d696-3266-4138-9221-e4862307975a-5d254977d2bf-cc.json"))

        let found = ClaudeModelCatalog.read(cliVersion: "2.1.280", from: dir,
                                            settings: dir.appendingPathComponent("absent.json"))
        XCTAssertEqual(found.resolved(.opus)?.name, "Opus 5.5")
        XCTAssertNotNil(found.model(id: "claude-opus-5-5"))
    }

    func testNoCatalogueOnDiskIsNotAnError() {
        let missing = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("no-such-catalogue-\(UUID().uuidString)")
        XCTAssertFalse(ClaudeModelCatalog.read(from: missing).loaded)
    }

    /// The night run has to stop sending a depth the model does not take, and keep sending the one
    /// it does.
    func testANightRunDoesNotSendADepthToAModelWithoutOne() {
        var settings = AppSettings.fallback
        settings.claudeModel = .haiku
        let quiet = RunStrategy.standing.overridden(by: settings, claudeModels: claude())
        XCTAssertEqual(quiet.claudeModel, "haiku")
        XCTAssertEqual(quiet.claudeEffort, ClaudeModelCatalog.noDepth, "Haiku takes no --effort at all")
        // And it has to REACH the run as that word: an absent variable is filled in with `high`
        // by the engine's own config, which is how Haiku was launched at a depth it ignores.
        XCTAssertEqual(SupervisorClient.launchEnv(quiet)["SUPERVISOR_CLAUDE_EFFORT"],
                       ClaudeModelCatalog.noDepth)

        settings.claudeModel = ClaudeModelChoice(rawValue: "claude-opus-4-7")
        let deep = RunStrategy.standing.overridden(by: settings, claudeModels: claude())
        XCTAssertEqual(deep.claudeModel, "claude-opus-4-7")
        XCTAssertEqual(deep.claudeEffort, "high", "the per-task depth is still Bulava's to decide")
    }

    /// The per-task depth is decided before anyone knows which model will run it, and the model
    /// has the last word. Opus 4.6 does not take `xhigh`: sending one is not refused, it simply is
    /// not the level that runs, and the interface would be naming a depth nobody got.
    func testANightRunsDepthIsNarrowedToWhatThePinnedVersionTakes() {
        var settings = AppSettings.fallback
        settings.claudeModel = ClaudeModelChoice(rawValue: "claude-opus-4-6")

        var shortJob = BacklogTask(title: "j")
        shortJob.planSteps = ["one", "two", "three"]
        let decided = RunStrategy.decide(for: shortJob, projectIsBusy: false)
        XCTAssertEqual(decided.claudeEffort, "xhigh", "the task itself still asks for a step up")
        XCTAssertEqual(decided.overridden(by: settings, claudeModels: claude()).claudeEffort, "high",
                       "and the model takes it down to the deepest level it has")

        // A level the version does take is never touched.
        var research = BacklogTask(title: "r")
        research.type = .research
        XCTAssertEqual(RunStrategy.decide(for: research, projectIsBusy: false)
            .overridden(by: settings, claudeModels: claude()).claudeEffort, "medium")
    }

    /// `ultracode` is the CLI's own setting rather than a model's, and the CLI takes it on every
    /// model that thinks — including the previous versions. A model with no depth at all gets no
    /// flag, however long the plan was.
    func testTheDeepestSettingSurvivesOnAVersionThatThinksAndVanishesOnOneThatDoesNot() {
        var longJob = BacklogTask(title: "j")
        longJob.planSteps = ["one", "two", "three", "four", "five"]
        let decided = RunStrategy.decide(for: longJob, projectIsBusy: false)
        XCTAssertEqual(decided.claudeEffort, "ultracode")

        var settings = AppSettings.fallback
        settings.claudeModel = ClaudeModelChoice(rawValue: "claude-opus-4-6")
        XCTAssertEqual(decided.overridden(by: settings, claudeModels: claude()).claudeEffort, "ultracode")

        settings.claudeModel = .haiku
        XCTAssertEqual(decided.overridden(by: settings, claudeModels: claude()).claudeEffort,
                       ClaudeModelCatalog.noDepth)
    }

    /// Whatever the menu offers has to be exactly what the run sends. If narrowing could change a
    /// level a person picked, the setting would be a suggestion rather than a choice.
    func testEveryDepthTheMenuOffersIsSentUnchanged() {
        let found = claude()
        for model in [ClaudeModelChoice.opus, .fable,
                      ClaudeModelChoice(rawValue: "claude-opus-4-6"),
                      ClaudeModelChoice(rawValue: "claude-opus-4-7")] {
            for depth in found.levels(for: model) where depth != .auto {
                var settings = AppSettings.fallback
                settings.claudeModel = model
                settings.claudeEffort = depth
                let out = RunStrategy.standing.overridden(by: settings, claudeModels: found)
                XCTAssertEqual(out.claudeEffort, depth.rawValue,
                               "\(model.rawValue) offers \(depth.rawValue) and must send it")
            }
        }
    }

    /// A chat runs on the same narrowing as a night run, so the pill and the session agree: the
    /// composer used to be able to name a level the CLI was never going to run.
    func testAChatNamesTheDepthItActuallySends() {
        let found = claude()
        let old = ClaudeModelChoice(rawValue: "claude-opus-4-6")

        XCTAssertEqual(found.effort(.xhigh, for: old), .high, "Opus 4.6 has no xhigh")
        XCTAssertEqual(found.effortFlag(.xhigh, for: old), "high")
        XCTAssertEqual(found.depthLabel(.xhigh, for: old), String(localized: ClaudeEffortChoice.high.label))
        XCTAssertEqual(found.workerDepthLabel(.xhigh, for: old), String(localized: ClaudeEffortChoice.high.label))

        XCTAssertEqual(found.effortFlag(.auto, for: ClaudeModelChoice(rawValue: "claude-opus-4-7")), "xhigh")
        XCTAssertEqual(found.effortFlag(.max, for: .haiku), ClaudeModelCatalog.noDepth,
                       "no depth is a word the engine can act on, not an empty string")
    }

    /// `Automatic` means two different things, and only one of them can be named. A conversation
    /// has no task, so it resolves to the model's own default and the composer says which. A night
    /// worker's depth is chosen per task, so the settings row must not name a level the next run
    /// may not use.
    func testAutomaticIsNamedOnlyWhereItCanBe() {
        let found = claude()
        let pinned = ClaudeModelChoice(rawValue: "claude-opus-4-7")

        XCTAssertEqual(found.depthLabel(.auto, for: pinned),
                       String(format: String(localized: "Automatic · %@"),
                              String(localized: ClaudeEffortChoice.xhigh.label)),
                       "a chat resolves Automatic and can say so")
        XCTAssertEqual(found.workerDepthLabel(.auto, for: pinned),
                       String(localized: ClaudeEffortChoice.auto.label),
                       "a worker's Automatic is decided per task and names no level")

        // A chosen level says the same thing on both sides, and it is what the run gets.
        var settings = AppSettings.fallback
        settings.claudeModel = pinned
        settings.claudeEffort = .max
        XCTAssertEqual(found.workerDepthLabel(.max, for: pinned), String(localized: ClaudeEffortChoice.max.label))
        XCTAssertEqual(RunStrategy.standing.overridden(by: settings, claudeModels: found).claudeEffort, "max")

        // And a model with no depth says so on both sides rather than naming one.
        XCTAssertEqual(found.workerDepthLabel(.auto, for: .haiku), String(localized: "No depth setting"))
        XCTAssertEqual(found.depthLabel(.auto, for: .haiku), String(localized: "No depth setting"))
    }

    /// `Automatic` used to be a word with nothing behind it — the one choice in the menu that
    /// could not say what it does. The catalogue names the service's default in
    /// `model_selector_state`, and that is what answers when Bulava passes no `--model`.
    func testAutomaticNamesTheModelThatAnswersWithNoFlag() {
        let found = claude()
        XCTAssertEqual(found.automaticID, "claude-opus-4-6")
        XCTAssertEqual(found.resolved(.auto)?.name, "Opus 4.6")
        XCTAssertEqual(found.versionName(for: .auto), "Opus 4.6")

        // Still no `--model`: naming what will answer is not the same as pinning it.
        XCTAssertEqual(ClaudeModelChoice.auto.flagValue, "")

        // And the depths on offer are that model's: Opus 4.6 has no xhigh.
        XCTAssertEqual(found.levels(for: .auto).map(\.rawValue),
                       ["auto", "low", "medium", "high", "max", "ultracode"])
        // The selector state carries its own default for it, and that is the one the CLI uses.
        XCTAssertEqual(found.automaticLevel(for: .auto), .medium)
        XCTAssertEqual(found.effortFlag(.auto, for: .auto), "medium")
    }

    /// A person's own `settings.json` beats the service default — that setting IS what the CLI
    /// does with no `--model`, and `opus[1m]` is the same Opus asking for the long context.
    func testTheCLIsOwnSettingDecidesWhatAutomaticMeans() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("claude-auto-\(UUID().uuidString)")
        let cache = dir.appendingPathComponent("cache/model-catalog")
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let encoded = Data(claudeCatalogue.utf8).base64EncodedString()
        try Data(#"{"fetchedAt":2,"documentBytes":"\#(encoded)"}"#.utf8)
            .write(to: cache.appendingPathComponent("published-test.json"))

        let settings = dir.appendingPathComponent("settings.json")
        for (stored, expected) in [("opus[1m]", "Opus 5"), ("opus", "Opus 5"),
                                   ("claude-opus-4-7", "Opus 4.7")] {
            try Data(#"{"model":"\#(stored)"}"#.utf8).write(to: settings)
            let found = ClaudeModelCatalog.read(cliVersion: "2.1.269", from: cache, settings: settings)
            XCTAssertEqual(found.resolved(.auto)?.name, expected, "settings said \(stored)")
        }

        // A setting naming something this catalogue does not carry leaves the service default.
        try Data(#"{"model":"claude-from-the-future"}"#.utf8).write(to: settings)
        let fallen = ClaudeModelCatalog.read(cliVersion: "2.1.269", from: cache, settings: settings)
        XCTAssertEqual(fallen.resolved(.auto)?.name, "Opus 4.6")

        // No settings file at all is the same: the catalogue's own default answers.
        try FileManager.default.removeItem(at: settings)
        let bare = ClaudeModelCatalog.read(cliVersion: "2.1.269", from: cache, settings: settings)
        XCTAssertEqual(bare.resolved(.auto)?.name, "Opus 4.6")
    }

    /// And when the model that answers takes no depth, Automatic sends none either.
    func testAutomaticOnAModelWithNoDepthSendsNoEffort() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("claude-auto-haiku-\(UUID().uuidString)")
        let cache = dir.appendingPathComponent("cache/model-catalog")
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let encoded = Data(claudeCatalogue.utf8).base64EncodedString()
        try Data(#"{"fetchedAt":2,"documentBytes":"\#(encoded)"}"#.utf8)
            .write(to: cache.appendingPathComponent("published-test.json"))
        let settings = dir.appendingPathComponent("settings.json")
        try Data(#"{"model":"haiku"}"#.utf8).write(to: settings)

        let found = ClaudeModelCatalog.read(cliVersion: "2.1.269", from: cache, settings: settings)
        XCTAssertEqual(found.resolved(.auto)?.name, "Haiku 4.5")
        XCTAssertFalse(found.thinks(.auto))
        XCTAssertEqual(found.effortFlag(.auto, for: .auto), ClaudeModelCatalog.noDepth)
        XCTAssertEqual(found.depthLabel(.auto, for: .auto), String(localized: "No depth setting"))

        var appSettings = AppSettings.fallback
        appSettings.claudeModel = .auto
        let strategy = RunStrategy.standing.overridden(by: appSettings, claudeModels: found)
        XCTAssertEqual(strategy.claudeModel, "", "Automatic still passes no --model")
        XCTAssertEqual(strategy.claudeEffort, ClaudeModelCatalog.noDepth)
    }

    /// The composer's pill is the other place the choice is shown, and it has to name the version
    /// that will answer rather than the family that was picked — "Opus" was exactly the label that
    /// could not say which Opus.
    @MainActor func testTheComposerPillNamesTheVersionAndTheDepthItSends() {
        let app = AppModel()
        app.claudeModels = claude()

        app.settings.claudeModel = .opus
        app.settings.claudeEffort = .auto
        XCTAssertEqual(RunChoice.modelName(.claude, app), "Opus 5")
        XCTAssertEqual(RunChoice.depthName(.claude, app), String(localized: ClaudeEffortChoice.high.label))

        // A version tuned to a different default says that default, not a fixed one.
        app.settings.claudeModel = ClaudeModelChoice(rawValue: "claude-opus-4-7")
        XCTAssertEqual(RunChoice.modelName(.claude, app), "Opus 4.7")
        XCTAssertEqual(RunChoice.depthName(.claude, app), String(localized: ClaudeEffortChoice.xhigh.label))

        // A level the version does not take is shown as the one that will actually run.
        app.settings.claudeModel = ClaudeModelChoice(rawValue: "claude-opus-4-6")
        app.settings.claudeEffort = .xhigh
        XCTAssertEqual(RunChoice.depthName(.claude, app), String(localized: ClaudeEffortChoice.high.label))

        // And a model with no depth names none — an empty label, so the pill shows no gap.
        app.settings.claudeModel = .haiku
        XCTAssertEqual(RunChoice.modelName(.claude, app), "Haiku 4.5")
        XCTAssertEqual(RunChoice.depthName(.claude, app), "")

        // Nothing chosen is still the engine's own name: nobody knows what the subscription answers with.
        app.settings.claudeModel = .auto
        XCTAssertEqual(RunChoice.modelName(.claude, app), Engine.claude.name)
    }

    /// And a pinned version has to survive the trip to the session, the same as a family alias.
    func testAPinnedVersionReachesTheSession() {
        let env = SupervisorClient.chatEnv(contextFile: "/tmp/ctx", extraDirsFile: "/tmp/dirs",
                                           claudeEffort: "xhigh", claudeModel: "claude-opus-4-7")
        XCTAssertEqual(env["SUPERVISOR_CLAUDE_MODEL"], "claude-opus-4-7")
    }

    /// The fixtures above are a cut of the catalogue. This one reads the real file, on whatever
    /// machine the suite runs on, because the shape of that file is not Bulava's to decide: the
    /// CLI writes it, and a release that changes it would otherwise be found by a person choosing
    /// a model and getting nothing. Skipped where no CLI has ever run.
    func testTheCatalogueOnThisMachineParses() throws {
        let found = ClaudeModelCatalog.read()
        try XCTSkipUnless(found.loaded, "no Claude CLI catalogue on this machine")

        XCTAssertFalse(found.models.isEmpty)
        for candidate in found.models {
            XCTAssertEqual(ClaudeModelCatalog.safeID(candidate.id), candidate.id,
                           "\(candidate.id) would not survive a command line")
            XCTAssertFalse(candidate.name.isEmpty)
        }
        // Every family the menu offers has to resolve to something, or the label it shows is a
        // promise about a model nobody can name.
        for family in ClaudeModelChoice.families where found.aliases[family.rawValue] != nil {
            let resolved = try XCTUnwrap(found.resolved(family), "\(family.rawValue) resolves to nothing")
            XCTAssertNotNil(found.model(id: resolved.id), "an alias must point inside the catalogue")
            XCTAssertEqual(found.versionName(for: family), resolved.name)
            XCTAssertFalse(found.levels(for: family).isEmpty, "\(resolved.name) offers no depth at all")
        }
        XCTAssertNotNil(found.resolved(.opus), "the CLI has offered an Opus alias since before Bulava")
    }

    /// Choosing a model must not leave a depth behind that the model refuses. The CLI would warn
    /// and run at its own default while the composer went on naming the level nobody got.
    @MainActor func testChoosingAModelKeepsTheDepthPossible() {
        let app = AppModel()
        app.claudeModels = claude()

        app.settings.claudeEffort = .max
        app.chooseClaudeModel(.haiku)
        XCTAssertEqual(app.settings.claudeModel, .haiku)
        XCTAssertEqual(app.settings.claudeEffort, .auto, "Haiku takes no depth at all")

        app.settings.claudeEffort = .xhigh
        app.chooseClaudeModel(ClaudeModelChoice(rawValue: "claude-opus-4-6"))
        XCTAssertEqual(app.settings.claudeEffort, .auto, "Opus 4.6 does not take xhigh")

        app.settings.claudeEffort = .max
        app.chooseClaudeModel(.opus)
        XCTAssertEqual(app.settings.claudeEffort, .max, "a depth the model takes is left alone")
    }

    // MARK: - Codex

    private let catalogue = """
    {"client_version":"0.151.0","models":[
      {"slug":"gpt-reserve","display_name":"GPT-Reserve","visibility":"hide","priority":3,
       "default_reasoning_level":"medium",
       "supported_reasoning_levels":[{"effort":"low"},{"effort":"max"}]},
      {"slug":"gpt-5.6-sol","display_name":"GPT-5.6-Sol","visibility":"list","priority":6,
       "description":"Reliable agentic workhorse.","default_reasoning_level":"low",
       "supported_reasoning_levels":[{"effort":"low"},{"effort":"medium"},{"effort":"high"},
                                    {"effort":"xhigh"},{"effort":"max"},{"effort":"ultra"}]},
      {"slug":"gpt-5.4-mini","display_name":"GPT-5.4-Mini","visibility":"list","priority":23,
       "default_reasoning_level":"medium",
       "supported_reasoning_levels":[{"effort":"low"},{"effort":"medium"}]},
      {"slug":"bad slug; rm -rf /","display_name":"Nope","visibility":"list","priority":1,
       "supported_reasoning_levels":[{"effort":"low"}]}
    ]}
    """

    private func read() -> CodexModelCatalog {
        CodexModelCatalog.decode(Data(catalogue.utf8))
    }

    func testTheCatalogueIsReadInItsOwnOrder() {
        let found = read()
        XCTAssertTrue(found.loaded)
        XCTAssertEqual(found.models.map(\.slug), ["gpt-5.6-sol", "gpt-5.4-mini"])
        XCTAssertEqual(found.models.first?.displayName, "GPT-5.6-Sol")
    }

    /// `hide` is how the catalogue marks what is not a person's to pick — reserve capacity and the
    /// internal auto-reviewer.
    func testHiddenModelsAreNotOffered() {
        XCTAssertNil(read().model(slug: "gpt-reserve"))
    }

    /// A model id goes straight onto a command line. Anything that is not an id is dropped rather
    /// than quoted and hoped for.
    func testAnIdThatIsNotAnIdIsRefused() {
        XCTAssertNil(read().model(slug: "bad slug; rm -rf /"))
        XCTAssertNil(CodexModelCatalog.safeSlug("gpt-5; whoami"))
        XCTAssertNil(CodexModelCatalog.safeSlug(""))
        XCTAssertEqual(CodexModelCatalog.safeSlug(" gpt-5.6-sol "), "gpt-5.6-sol")
    }

    func testOnlyDepthsTheChosenModelAcceptsAreOffered() {
        let levels = read().levels(forSlug: "gpt-5.4-mini").map(\.rawValue)
        XCTAssertEqual(levels, ["auto", "low", "medium"],
                       "offering `max` to a model that refuses it kills the turn")
    }

    /// With no model named, every depth is offered except the one that only exists on the newest
    /// models — guessing `ultra` at a model that refuses it kills the turn, and there is nothing
    /// here to guess from.
    func testAutomaticModelOffersEveryDepthThatIsSafeToGuess() {
        let levels = read().levels(forSlug: "").map(\.rawValue)
        XCTAssertEqual(levels, ["auto", "low", "medium", "high", "xhigh", "max"])
        XCTAssertFalse(levels.contains("ultra"))
    }

    func testNoCatalogueMeansNothingIsTakenAway() {
        let none = CodexModelCatalog.empty
        XCTAssertFalse(none.loaded)
        XCTAssertEqual(none.levels(forSlug: "gpt-5.6-sol"), CodexModelCatalog.levelsWorthGuessing)
    }

    /// The depth `ultra` is real, and it is offered exactly where the catalogue says it exists.
    func testUltraIsOfferedOnlyToAModelThatTakesIt() {
        XCTAssertTrue(read().levels(forSlug: "gpt-5.6-sol").contains(.ultra))
        XCTAssertFalse(read().levels(forSlug: "gpt-5.4-mini").contains(.ultra))
    }

    /// `Automatic` is the model's own default depth, which the catalogue carries and which differs
    /// per model. One fixed level for all of them was the old answer, and it was wrong in both
    /// directions: too deep for the fast models, too shallow for the deliberate ones.
    func testAutomaticIsTheModelsOwnDefaultDepth() {
        let found = read()
        XCTAssertEqual(found.automaticLevel(forSlug: "gpt-5.6-sol"), .low)
        XCTAssertEqual(found.automaticLevel(forSlug: "gpt-5.4-mini"), .medium)
        XCTAssertEqual(found.effort(.auto, forSlug: "gpt-5.6-sol"), .low)
        XCTAssertEqual(found.effort(.high, forSlug: "gpt-5.6-sol"), .high,
                       "a chosen depth is never second-guessed")
    }

    /// A model nobody named, and a machine with no catalogue, both still have to name a depth.
    func testAutomaticFallsBackToTheConversationDefault() {
        XCTAssertEqual(read().automaticLevel(forSlug: ""), CodexEffortChoice.conversationDefault)
        XCTAssertEqual(CodexModelCatalog.empty.automaticLevel(forSlug: "gpt-5.6-sol"),
                       CodexEffortChoice.conversationDefault)
    }

    /// The catalogue's ids carry a capital letter after a hyphen; the service's own interface
    /// opens that hyphen up, and so does the app.
    func testTheModelIsNamedTheWayTheServiceNamesIt() {
        XCTAssertEqual(read().model(slug: "gpt-5.6-sol")?.shortLabel, "GPT-5.6 Sol")
        XCTAssertEqual(read().model(slug: "gpt-5.4-mini")?.shortLabel, "GPT-5.4 Mini")
    }

    func testAMalformedCatalogueIsIgnoredRatherThanCrashing() {
        XCTAssertFalse(CodexModelCatalog.decode(Data("not json".utf8)).loaded)
        XCTAssertFalse(CodexModelCatalog.decode(Data(#"{"models":"soon"}"#.utf8)).loaded)
    }

    // MARK: - What reaches the command line

    func testTheChosenCodexModelIsActuallyPassed() {
        let args = CodexChatRunner.arguments(threadID: nil, effort: "low", prompt: "hi",
                                             model: "gpt-5.6-sol")
        guard let flag = args.firstIndex(of: "-m") else { return XCTFail("expected -m") }
        XCTAssertEqual(args[flag + 1], "gpt-5.6-sol")

        // And it is a global flag, so it has to come before `resume`.
        let resuming = CodexChatRunner.arguments(threadID: "t1", effort: "low", prompt: "hi",
                                                 model: "gpt-5.6-sol")
        guard let m = resuming.firstIndex(of: "-m"),
              let resume = resuming.firstIndex(of: "resume") else { return XCTFail("expected both") }
        XCTAssertLessThan(m, resume)
    }

    func testAutomaticPassesNoModelAtAll() {
        XCTAssertFalse(CodexChatRunner.arguments(threadID: nil, effort: "low", prompt: "hi")
            .contains("-m"))
    }

    /// A chat's Claude session used to be started with no model and no depth at all: night runs
    /// got them, a conversation got the engine's fallback, and the composer's label was a claim
    /// about a flag nobody passed.
    func testAChatsClaudeSessionIsToldWhichModelAndDepthToRunOn() {
        let env = SupervisorClient.chatEnv(contextFile: "/tmp/ctx", extraDirsFile: "/tmp/dirs",
                                            claudeEffort: "max", claudeModel: "opus")
        XCTAssertEqual(env["SUPERVISOR_CLAUDE_EFFORT"], "max")
        XCTAssertEqual(env["SUPERVISOR_CLAUDE_MODEL"], "opus")

        let automatic = SupervisorClient.chatEnv(
            contextFile: "/tmp/ctx", extraDirsFile: "/tmp/dirs",
            claudeEffort: ClaudeModelCatalog.empty.effortFlag(.auto, for: .auto),
            claudeModel: ClaudeModelChoice.auto.flagValue)
        XCTAssertEqual(automatic["SUPERVISOR_CLAUDE_EFFORT"],
                       ClaudeEffortChoice.conversationDefault.rawValue,
                       "Automatic has to name a depth, or the label cannot say which one it is")
        XCTAssertNil(automatic["SUPERVISOR_CLAUDE_MODEL"],
                     "no model chosen means no --model, which is the subscription's own default")
    }

    func testAClaudeModelWithAShellInItNeverReachesTheSession() {
        let env = SupervisorClient.chatEnv(contextFile: "/tmp/ctx", extraDirsFile: "/tmp/dirs",
                                            claudeEffort: "high", claudeModel: "opus; whoami")
        XCTAssertNil(env["SUPERVISOR_CLAUDE_MODEL"])
    }

    func testAModelNameWithAShellInItNeverReachesTheCommandLine() {
        XCTAssertFalse(CodexChatRunner
            .arguments(threadID: nil, effort: "low", prompt: "hi", model: "gpt-5 && whoami")
            .contains("-m"))
    }
}
