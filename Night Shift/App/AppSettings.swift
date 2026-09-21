import SwiftUI
import AppKit
import CryptoKit

nonisolated enum AppAppearance: String, Codable, CaseIterable, Identifiable {
    case system, light, dark
    var id: String { rawValue }
    var colorScheme: ColorScheme? {
        switch self { case .system: nil; case .light: .light; case .dark: .dark }
    }
    var label: String {
        switch self { case .system: "System"; case .light: "Light"; case .dark: "Dark" }
    }
    var icon: String {
        switch self { case .system: "circle.lefthalf.filled"; case .light: "sun.max"; case .dark: "moon.stars" }
    }

    var next: AppAppearance {
        switch self { case .system: .light; case .light: .dark; case .dark: .system }
    }

    @MainActor func apply() {
        NSApp?.appearance = switch self {
        case .system: nil
        case .light:  NSAppearance(named: .aqua)
        case .dark:   NSAppearance(named: .darkAqua)
        }
    }
}

nonisolated enum ReportWriter: String, Codable, CaseIterable, Identifiable, Sendable {
    case codex, claude
    var id: String { rawValue }
    var label: String {
        switch self {
        case .codex:  String(localized: "Codex — the independent reviewer")
        case .claude: String(localized: "Claude — the one that did the work")
        }
    }
}

nonisolated enum AppLanguage: String, Codable, CaseIterable, Identifiable {
    case system, en, uk, ru
    var id: String { rawValue }

    var localeIdentifier: String? {
        switch self { case .system: nil; case .en: "en"; case .uk: "uk"; case .ru: "ru" }
    }

    var reportLanguageName: String {
        switch self {
        case .system, .en: "English"
        case .uk: "Ukrainian"
        case .ru: "Russian"
        }
    }
    var label: String {
        switch self {
        case .system: "System"
        case .en: "English"
        case .uk: "Українська"
        case .ru: "Русский"
        }
    }
}

/// The language dictation is decoded in.
///
/// Its own setting, and that is the whole point. It used to be derived from the interface
/// language, and when that was "System" it fell through to `Locale.current` — `en_US` on this Mac.
/// Ukrainian speech then went to the English recogniser, which does not fail: it returns confident
/// English nonsense. What he speaks and what the app is displayed in are different questions.
nonisolated enum DictationLanguage: String, Codable, CaseIterable, Identifiable, Sendable {
    case interface
    case uk, ru, en

    var id: String { rawValue }

    /// The ISO code to decode with, given what the interface is set to.
    func code(interface: AppLanguage) -> String {
        switch self {
        case .interface:
            // Still never `Locale.current`: an app displayed in English is not a claim about what
            // its owner speaks, and guessing is what produced English text from Ukrainian speech.
            return interface.localeIdentifier ?? "en"
        case .uk: return "uk"
        case .ru: return "ru"
        case .en: return "en"
        }
    }

    var label: String {
        switch self {
        case .interface: "Same as the app"
        case .uk:        "Українська"
        case .ru:        "Русский"
        case .en:        "English"
        }
    }
}

/// Which Claude does the work.
///
/// Two kinds of answer live in one value. A family — `opus`, `sonnet`, `fable`, `haiku` — is the
/// CLI's own alias for "the newest one of these", so the day a new Opus ships the choice already
/// points at it. A pinned id — `claude-opus-4-7` — is a specific version, which is what anyone
/// needs the moment a new release changes how their work goes and they want the previous one back.
///
/// Which versions exist is not compiled in: `ClaudeModelCatalog` reads the CLI's own catalogue, so
/// the menu knows what "Opus" resolves to today and which older versions are still runnable.
nonisolated struct ClaudeModelChoice: RawRepresentable, Codable, Hashable, Identifiable, Sendable {

    /// `auto`, a family alias, or a model id straight from the catalogue.
    var rawValue: String

    init(rawValue: String) { self.rawValue = rawValue }

    var id: String { rawValue }

    static let auto = ClaudeModelChoice(rawValue: "auto")
    static let fable = ClaudeModelChoice(rawValue: "fable")
    static let opus = ClaudeModelChoice(rawValue: "opus")
    static let sonnet = ClaudeModelChoice(rawValue: "sonnet")
    static let haiku = ClaudeModelChoice(rawValue: "haiku")

    /// The family aliases, newest-first the way the CLI lists them.
    static let families: [ClaudeModelChoice] = [.fable, .opus, .sonnet, .haiku]

    /// What can be chosen without a catalogue: automatic, and the four families. Versions come
    /// from the catalogue and are added to this in the menus.
    static let allCases: [ClaudeModelChoice] = [.auto] + families

    var isAutomatic: Bool { self == .auto }

    var isFamily: Bool { Self.families.contains(self) }

    /// True for a specific version — `claude-opus-4-7` — rather than a family or automatic.
    var isPinnedVersion: Bool { !isAutomatic && !isFamily }

    /// The value handed to `--model`. Empty means "don't pass one" — the subscription's default.
    var flagValue: String { self == .auto ? "" : rawValue }

    /// The family name, for the four aliases. A pinned version is named by the catalogue, which
    /// knows "claude-opus-4-7" is called "Opus 4.7"; nothing here can.
    var label: String {
        switch self {
        case .auto:   "Automatic"
        case .fable:  "Fable"
        case .opus:   "Opus"
        case .sonnet: "Sonnet"
        case .haiku:  "Haiku"
        default:      rawValue
        }
    }

    var help: String {
        switch self {
        case .auto:   "Whatever your subscription answers with by default."
        case .fable:  "The newest Fable. Long, careful work."
        case .opus:   "The newest Opus. The strongest for real changes."
        case .sonnet: "The newest Sonnet. Quick and even-handed."
        case .haiku:  "The newest Haiku. Fastest and cheapest."
        default:      "A pinned version. It stays on this model when a newer one ships."
        }
    }

    /// Settings written by earlier builds named a model in shorthand that was never a model id.
    /// Those become the family they belonged to. A real id is now a choice in its own right and is
    /// kept as one — throwing it away would silently move someone off the version they picked.
    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        switch raw {
        case "opus5":   self = .opus
        case "sonnet5": self = .sonnet
        case "haiku45": self = .haiku
        default:
            // Anything that could not go on a command line is not a model name, whatever else it
            // is. Automatic is the safe reading of it.
            guard raw == Self.auto.rawValue || ClaudeModelCatalog.safeID(raw) != nil else {
                self = .auto
                return
            }
            self = ClaudeModelChoice(rawValue: raw)
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(rawValue)
    }
}

nonisolated enum ClaudeEffortChoice: String, Codable, CaseIterable, Identifiable, Sendable {
    case auto, low, medium, high, xhigh, max, ultracode

    var id: String { rawValue }
    var flagValue: String { self == .auto ? "" : rawValue }

    /// What `Automatic` falls back to when nothing better is known.
    ///
    /// Night work decides per task; a conversation has no task to decide from, and the engine's
    /// own fallback is `high`. With a catalogue, `ClaudeModelCatalog.automaticLevel` knows better
    /// still — the chosen model's own default — and this is what answers before it is read.
    static let conversationDefault: ClaudeEffortChoice = .high

    var label: String {
        switch self {
        case .auto:      "Automatic"
        case .low:       "Low"
        case .medium:    "Medium"
        case .high:      "High"
        case .xhigh:     "Very high"
        case .max:       "Maximum"
        case .ultracode: "Ultracode"
        }
    }

    var help: String {
        switch self {
        case .auto:      "Bulava picks per task — deepest for a multi-step night job, lighter for research."
        case .low:       "Fastest and cheapest. For small, well-defined changes."
        case .medium:    "A middle setting. Reading and reviewing work."
        case .high:      "Solid thinking on real changes."
        case .xhigh:     "More thinking, more time and quota."
        case .max:       "As deep as the CLI goes on a single call."
        case .ultracode: "The deepest setting, and the slowest. What an overnight job wants."
        }
    }
}

/// Which engines answer a message.
///
/// The switch for this is OUT of the interface for now — he asked for it: working with Claude
/// alone or Codex alone is a capability he does not want offered yet, and every conversation is
/// Claude working with Codex reviewing. The mode is kept whole rather than torn out, because the
/// decision was "not now", not "never": the delivery paths for each engine are still here and
/// still used (`usesClaude`, `usesCodex`, `reviewsWork`), and bringing the switch back is a
/// matter of un-commenting one section of `RunControl` and dropping the pin in `init(from:)`.
nonisolated enum ChatEngineMode: String, Codable, CaseIterable, Identifiable, Sendable {

    case claudeAndCodex

    case claude

    case codex

    var id: String { rawValue }

    var label: String {
        switch self {
        case .claudeAndCodex: "Claude + Codex"
        case .claude:         "Claude only"
        case .codex:          "Codex only"
        }
    }

    var help: String {
        switch self {
        case .claudeAndCodex: "Claude works, Codex reviews and can send it back. Slower, and the result is verified."
        case .claude:         "No review gate. Fast, and nothing checks the work but you."
        case .codex:          "Talk to Codex directly, in its own thread. Claude is not involved."
        }
    }

    var reviewsWork: Bool { self == .claudeAndCodex }

    /// Which engine pipeline a message from this mode goes through.
    ///
    /// Only the mode where both engines are involved pays for two independent positions. Claude
    /// alone takes the plain route — the one the engine has always had — and Codex alone never
    /// reaches the supervisor at all.
    var messagePipeline: String { self == .claudeAndCodex ? "adaptive-peer" : "plain" }

    /// What the engine should call collaboration for a run started from this mode. It decides
    /// whether the worker's prompt offers the consultation channel at all.
    var collaborationMode: String { self == .claudeAndCodex ? "adaptive_peer" : "legacy" }

    var usesClaude: Bool { self != .codex }

    var usesCodex: Bool { self != .claude }
}

/// Which engine actually answers a message, and therefore whether the supervisor is involved at all.
///
/// Pulled out of `AppModel.deliver` so it can be stated as a fact rather than asserted in prose.
/// The claim that matters: a Codex-only chat never reaches `worker-send.sh`, so it can never pay
/// for an adaptive preflight, be queued for preparation, or be taken back out of a queue it was
/// never in — it talks to its own process in its own thread.
nonisolated enum ChatRoute: Equatable, Sendable {
    /// Codex answers directly, in its own thread. Nothing supervised happens.
    case codex
    /// Claude answers through the supervised session. `standIn` is set when this was meant to be
    /// Codex's turn and Codex had no quota left — the thread is told so rather than shown an error.
    case claude(standIn: CodexStandIn.Reason?)

    static func decide(mode: ChatEngineMode, standIn: CodexStandIn.Reason?) -> ChatRoute {
        guard mode == .codex else { return .claude(standIn: nil) }
        if let standIn { return .claude(standIn: standIn) }
        return .codex
    }

    /// Whether this route goes through the engine — the only route that can prepare anything.
    var usesSupervisor: Bool {
        if case .claude = self { return true }
        return false
    }
}

nonisolated enum CodexEffortChoice: String, Codable, CaseIterable, Identifiable, Sendable {
    case auto, low, medium, high, xhigh, max, ultra

    var id: String { rawValue }

    /// What `Automatic` actually sends for a message in a conversation.
    ///
    /// Empty used to mean "send nothing and let the CLI decide", and what the CLI decides is
    /// whatever `~/.codex/config.toml` says — which on this machine is `xhigh`. So the lightest
    /// setting in the menu was `Automatic`, and it was the heaviest thing the app could do:
    /// roughly sixteen thousand input tokens of reasoning depth for "what does this file do".
    /// Automatic now names a value, and the menu shows which one.
    static let conversationDefault: CodexEffortChoice = .medium

    /// The effort to send. Never empty: an unset effort is not neutral, it is the global default.
    var flagValue: String {
        self == .auto ? Self.conversationDefault.rawValue : rawValue
    }

    var label: String {
        switch self {
        case .auto:   "Automatic"
        case .low:    "Low"
        case .medium: "Medium"
        case .high:   "High"
        case .xhigh:  "Very high"
        case .max:    "Maximum"
        case .ultra:  "Ultra"
        }
    }

    /// The label as the composer shows it, so `Automatic` is never a mystery depth.
    var menuLabel: String {
        self == .auto
            ? String(format: String(localized: "Automatic · %@"),
                     String(localized: Self.conversationDefault.label))
            : String(localized: label)
    }

    var help: String {
        switch self {
        case .auto:   "Medium for a conversation. Night work picks its own depth per task."
        case .low:    "Fastest and cheapest. Reading, small answers, quick checks."
        case .medium: "A middle setting, and the one a conversation wants."
        case .high:   "Real thinking on a real change."
        case .xhigh:  "More thinking, noticeably more of the weekly quota."
        case .max:    "The deepest Codex goes. Expensive — keep it for the hard ones."
        case .ultra:  "Deeper than Maximum, and only the newest models take it."
        }
    }
}

nonisolated struct AppSettings: Codable, Equatable {
    var stateDirPath: String
    var orchestratorHomePath: String?
    var pollSeconds: Double
    var appearance: AppAppearance = .system
    var interfaceLanguage: AppLanguage = .system
    var reportLanguage: AppLanguage = .system

    var reportWriter: ReportWriter = .codex

    var askUserEnabled: Bool = true
    var askUserWaitMinutes: Int = 60

    var foremanLive: Bool = true

    var limitsCollapsed: Bool = true

    var chatMode: ChatEngineMode = .claudeAndCodex

    // MARK: What the work runs on

    var claudeModel: ClaudeModelChoice = .auto
    var claudeEffort: ClaudeEffortChoice = .auto
    var codexEffort: CodexEffortChoice = .auto

    var codexModel: String = ""

    /// Whether Bulava will drive other apps' interfaces when a worker asks it to.
    ///
    /// macOS's own Accessibility grant is the real gate — without it nothing here works at all.
    /// This is the second lock, the one he can turn without opening System Settings, and it
    /// answers refusals rather than falling silent so a worker is never left waiting on nothing.
    var workersMayDriveApps: Bool = true

    /// Whether Claude answers in Codex's place, by itself, when Codex has no weekly quota left.
    ///
    /// Off, and the default changed on purpose. It was on because the alternative looked like an
    /// error where an answer should be — but the answer it produced came from an engineer nobody
    /// had asked for, and the same reflex in the engine shipped a night's work past a review that
    /// never happened. With it off the thread says Codex is out and puts the substitution on a
    /// button, which costs one press and is the difference between a choice and a surprise.
    ///
    /// Changing the default was not enough on its own: every machine that had already run this app
    /// has `true` written in its settings file, and a new default does not reach a value that is
    /// already stored. `standInMigrated` is how the stored one is retired exactly once — see the
    /// decoder.
    var claudeStandsInForCodex: Bool = false

    /// Whether the stored `claudeStandsInForCodex` has been through the one-time retirement above.
    ///
    /// Recorded rather than inferred, so that turning the substitution back ON is a choice that
    /// survives the next launch. Without it the migration would fire every time and the setting
    /// could never be enabled at all.
    var standInMigrated: Bool = true

    /// What he speaks when he dictates. Separate from the interface language on purpose.
    var dictationLanguage: DictationLanguage = .interface

    static var defaultStateDirPath: String {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/supervisor").path
    }

    static var fallback: AppSettings {
        AppSettings(stateDirPath: defaultStateDirPath,
                    orchestratorHomePath: OrchestratorHome.detect()?.path,
                    pollSeconds: 4)
    }

    var paths: SupervisorPaths {
        if let env = ProcessInfo.processInfo.environment["SUPERVISOR_STATE_DIR"], !env.isEmpty {
            return SupervisorPaths(stateDir: URL(fileURLWithPath: env))
        }
        return SupervisorPaths(stateDir: URL(fileURLWithPath: stateDirPath))
    }
    var orchestratorHomeURL: URL? { orchestratorHomePath.map { URL(fileURLWithPath: $0) } }

    // MARK: Persistence

    private static let key = "com.nightshift.settings.v1"

    /// Where settings live.
    ///
    /// A UI test launches the SAME bundle, so it shares this app's defaults domain — and one
    /// did: a test's `stateDirPath` (a scratchpad fixture, long since deleted) was still the
    /// live setting weeks later, which pointed the whole app at a directory that no longer
    /// existed. A test launch is recognisable by `BULAVA_STATE_DIR`, which already redirects
    /// every other store, and gets its own suite so it cannot write over his.
    static var store: UserDefaults {
        guard let fixture = ProcessInfo.processInfo.environment["BULAVA_STATE_DIR"],
              !fixture.isEmpty else { return .standard }
        // A stable digest, not `hashValue`: Swift seeds string hashing per process, so that
        // named a different suite on every launch and left another plist in ~/Library/Preferences
        // behind each test run.
        let digest = SHA256.hash(data: Data(fixture.utf8))
        let name = "com.nightshift.settings.fixture."
            + digest.map { String(format: "%02x", $0) }.joined().prefix(16)
        return UserDefaults(suiteName: name) ?? .standard
    }

    static func load() -> AppSettings {
        guard let data = store.data(forKey: key),
              let s = try? JSONDecoder().decode(AppSettings.self, from: data) else { return .fallback }
        return s.healed()
    }

    /// The state directory as it is written on disk, which is not always what the app is using:
    /// `healed()` corrects a dead pointer in memory during `init`, where nothing persists it, and
    /// the app then relaunches itself for the interface language. `start()` compares the two and
    /// saves once, on the process that stays — otherwise the stale path remains the answer to
    /// "where is Bulava looking?" for anyone who checks.
    static func storedStateDirPath() -> String? {
        guard let data = store.data(forKey: key),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return object["stateDirPath"] as? String
    }

    /// Settings that cannot be true any more, put back to what they should be.
    ///
    /// A state directory that does not exist is not a preference — it is a dead pointer, and
    /// every screen fed from the engine goes blank behind it with nothing on screen saying why.
    /// Only the default is ever substituted, and only when the configured path is gone: a
    /// deliberately chosen directory that exists is left exactly alone.
    func healed() -> AppSettings {
        var out = self
        let configured = stateDirPath.trimmingCharacters(in: .whitespacesAndNewlines)
        if configured.isEmpty
            || (configured != Self.defaultStateDirPath
                && !FileManager.default.fileExists(atPath: configured)) {
            out.stateDirPath = Self.defaultStateDirPath
        }
        return out
    }

    func save() {
        if let data = try? JSONEncoder().encode(self) {
            Self.store.set(data, forKey: Self.key)
        }
    }
}

nonisolated extension AppSettings {

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        stateDirPath = try c.decode(String.self, forKey: .stateDirPath)
        orchestratorHomePath = try c.decodeIfPresent(String.self, forKey: .orchestratorHomePath)
        pollSeconds = try c.decodeIfPresent(Double.self, forKey: .pollSeconds) ?? 4
        appearance = try c.decodeIfPresent(AppAppearance.self, forKey: .appearance) ?? .system
        interfaceLanguage = try c.decodeIfPresent(AppLanguage.self, forKey: .interfaceLanguage) ?? .system
        reportLanguage = try c.decodeIfPresent(AppLanguage.self, forKey: .reportLanguage) ?? .system
        reportWriter = (try? c.decodeIfPresent(ReportWriter.self, forKey: .reportWriter)) ?? .codex
        askUserEnabled = try c.decodeIfPresent(Bool.self, forKey: .askUserEnabled) ?? true
        askUserWaitMinutes = try c.decodeIfPresent(Int.self, forKey: .askUserWaitMinutes) ?? 60
        foremanLive = try c.decodeIfPresent(Bool.self, forKey: .foremanLive) ?? true
        limitsCollapsed = try c.decodeIfPresent(Bool.self, forKey: .limitsCollapsed) ?? true
        // PINNED while the mode switch is out of the interface: the stored value is deliberately
        // not read. Anyone who had chosen "Codex only" before this change would otherwise stay in
        // it with no way back — no review gate, and no control on screen to explain why. The key
        // is still WRITTEN, so his last choice is waiting there if the switch comes back.
        chatMode = .claudeAndCodex
        claudeModel = (try? c.decodeIfPresent(ClaudeModelChoice.self, forKey: .claudeModel)) ?? .auto
        claudeEffort = (try? c.decodeIfPresent(ClaudeEffortChoice.self, forKey: .claudeEffort)) ?? .auto
        codexEffort = (try? c.decodeIfPresent(CodexEffortChoice.self, forKey: .codexEffort)) ?? .auto
        codexModel = (try? c.decodeIfPresent(String.self, forKey: .codexModel)) ?? ""
        dictationLanguage = (try? c.decodeIfPresent(DictationLanguage.self,
                                                    forKey: .dictationLanguage)) ?? .interface
        // The stored `true` is retired here, once.
        //
        // Every install that predates this change has the old default written down, and a decoder
        // that merely falls back to `false` never looks at it — so on exactly the machines this
        // was written for, Claude would have gone on answering in Codex's place by itself. The
        // migration flag is written back on the next save, so a deliberate re-enable sticks.
        standInMigrated = (try? c.decodeIfPresent(Bool.self, forKey: .standInMigrated)) ?? false
        let storedStandIn = (try? c.decodeIfPresent(Bool.self, forKey: .claudeStandsInForCodex)) ?? false
        claudeStandsInForCodex = standInMigrated ? storedStandIn : false
        standInMigrated = true
        workersMayDriveApps = (try? c.decodeIfPresent(Bool.self,
                                                      forKey: .workersMayDriveApps)) ?? true
    }
}
