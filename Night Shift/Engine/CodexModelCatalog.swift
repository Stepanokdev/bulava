import Foundation

/// Which Codex models exist, read from the CLI's own catalogue.
///
/// The app used to ask for a Codex model as free text — a box you type `gpt-5-codex` into, with
/// no way to know what the CLI would accept, and nothing to update when OpenAI ships something.
/// The CLI already keeps the answer: it refreshes `~/.codex/models_cache.json` from the service,
/// with each model's display name, its default reasoning level and exactly which levels it takes.
/// Reading that file means a model released this morning is in the menu this afternoon without a
/// release of Bulava.
///
/// Nothing here trusts the file blindly: only the fields that are needed are read, model ids are
/// filtered to the characters the CLI allows on a command line, and a machine with no cache (or a
/// cache from a version whose shape changed) falls back to `.automatic`, which passes no `-m` at
/// all and lets the CLI decide as it always did.
nonisolated struct CodexModel: Identifiable, Equatable, Sendable {

    /// The id passed to `codex -m`.
    var slug: String

    /// What the service calls it, e.g. "GPT-5.6-Sol".
    var displayName: String

    /// One line, as the service words it.
    var summary: String

    /// The reasoning levels this model accepts, in the order the catalogue lists them.
    var levels: [String]

    /// The level the service uses when nobody chooses.
    var defaultLevel: String

    /// Lower sorts first — the catalogue's own ordering.
    var priority: Int

    var id: String { slug }

    var label: String { displayName.isEmpty ? slug : displayName }

    /// The label as a person writes it: "GPT-6-Astra" is a catalogue id with a capital letter in
    /// it, and the service's own interface says "GPT-6 Astra". Only the hyphen before the codename
    /// is opened up — the version number keeps its own.
    var shortLabel: String {
        let name = label
        guard let cut = name.range(of: "-", options: .backwards),
              let first = name[cut.upperBound...].first, first.isUppercase else { return name }
        return name.replacingCharacters(in: cut, with: " ")
    }
}

nonisolated struct CodexModelCatalog: Equatable, Sendable {

    /// Models the CLI is willing to show a person, best first.
    var models: [CodexModel] = []

    /// True once a catalogue was actually read, so the UI can tell "none" from "not looked yet".
    var loaded = false

    static let empty = CodexModelCatalog()

    static var cacheURL: URL {
        let home = ProcessInfo.processInfo.environment["CODEX_HOME"].flatMap {
            $0.isEmpty ? nil : URL(fileURLWithPath: $0)
        } ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex")
        return home.appendingPathComponent("models_cache.json")
    }

    static func read(from url: URL? = nil) -> CodexModelCatalog {
        guard let data = try? Data(contentsOf: url ?? cacheURL) else { return .empty }
        return decode(data)
    }

    /// The catalogue as the CLI Bulava actually runs sees it.
    ///
    /// The cache file is shared by every Codex on the machine, and each one rewrites it with what
    /// the service offers ITS version — so with two installs the file flips between two lists
    /// depending on which ran last, and the Codex desktop app writes to it as well. `codex debug
    /// models` prints the catalogue for the binary that answers, which is the one every chat and
    /// run will start: what the menu offers is then what that CLI can take. It reads the same
    /// cache when it is fresh for its version and costs a tenth of a second; the file itself is
    /// the fallback for a CLI that has no such command.
    @MainActor static func load() async -> CodexModelCatalog {
        let probe = await Shell.run("codex debug models 2>/dev/null", timeout: 20)
        if probe.ok {
            let found = decode(Data(probe.stdout.utf8))
            if found.loaded, !found.models.isEmpty { return found }
        }
        return read()
    }

    static func decode(_ data: Data) -> CodexModelCatalog {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rows = root["models"] as? [[String: Any]] else { return .empty }

        var out: [CodexModel] = []
        for row in rows {
            guard let slug = row["slug"] as? String,
                  let safe = safeSlug(slug), !safe.isEmpty else { continue }
            // `hide` is how the catalogue marks the ones that are not a person's to pick —
            // internal reviewers and reserve capacity.
            guard (row["visibility"] as? String ?? "list") == "list" else { continue }

            let levels = (row["supported_reasoning_levels"] as? [[String: Any]] ?? [])
                .compactMap { $0["effort"] as? String }
                .filter { !$0.isEmpty }

            out.append(CodexModel(
                slug: safe,
                displayName: (row["display_name"] as? String) ?? safe,
                summary: (row["description"] as? String) ?? "",
                levels: levels,
                defaultLevel: (row["default_reasoning_level"] as? String) ?? "medium",
                priority: (row["priority"] as? NSNumber)?.intValue ?? Int.max))
        }
        out.sort {
            if $0.priority != $1.priority { return $0.priority < $1.priority }
            return $0.slug < $1.slug
        }
        return CodexModelCatalog(models: out, loaded: true)
    }

    func model(slug: String) -> CodexModel? { models.first { $0.slug == slug } }

    /// The depths to offer for the chosen model.
    ///
    /// A model that does not take `max` must not be offered `max`: the CLI rejects the config and
    /// the turn dies with a message nobody reads. When the catalogue is unavailable, or the model
    /// is "whatever the CLI defaults to", every level Bulava knows is offered — the old behaviour,
    /// which is the honest answer when nothing better is known.
    func levels(forSlug slug: String) -> [CodexEffortChoice] {
        guard !slug.isEmpty, let model = model(slug: slug), !model.levels.isEmpty else {
            return Self.levelsWorthGuessing
        }
        let allowed = Set(model.levels)
        let offered = CodexEffortChoice.allCases.filter { $0 == .auto || allowed.contains($0.rawValue) }
        // Automatic has to resolve to something the model takes, or the menu's safest-looking
        // entry is the one that fails.
        return offered.count > 1 ? offered : Self.levelsWorthGuessing
    }

    /// What to offer when nobody knows which model will answer.
    ///
    /// `ultra` is deliberately not in it: it exists only on the newest models, and the CLI rejects
    /// the config for one that does not take it — so it is offered where the catalogue says it is
    /// supported, and nowhere else.
    static let levelsWorthGuessing = CodexEffortChoice.allCases.filter { $0 != .ultra }

    /// The depth to actually send for this model when the choice is `Automatic`.
    ///
    /// The catalogue carries each model's own default — `low` for the fast ones, `medium` for the
    /// deliberate ones — and honouring it is what keeps "Automatic" from meaning one fixed depth
    /// for models that were tuned differently.
    func automaticLevel(forSlug slug: String) -> CodexEffortChoice {
        guard let model = model(slug: slug),
              let level = CodexEffortChoice(rawValue: model.defaultLevel),
              level != .auto,
              levels(forSlug: slug).contains(level) else { return CodexEffortChoice.conversationDefault }
        return level
    }

    /// The depth this choice sends, for this model. Never empty.
    func effort(_ choice: CodexEffortChoice, forSlug slug: String) -> CodexEffortChoice {
        choice == .auto ? automaticLevel(forSlug: slug) : choice
    }

    /// A model id is going onto a command line. Same allowance the run strategy uses.
    static func safeSlug(_ raw: String) -> String? {
        let allowed = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-")
        let clean = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty, clean.allSatisfy({ allowed.contains($0) }) else { return nil }
        return clean
    }
}
