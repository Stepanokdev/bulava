import Foundation

/// Which Claude models exist, read from the CLI's own catalogue.
///
/// The picker offered families — `opus`, `sonnet`, `fable`, `haiku` — and a family alias is a good
/// default: it follows the newest model without a release of Bulava. What it could not do is
/// answer "which Opus is that?", or let anyone stay on the previous one after a new release
/// changed how it works.
///
/// The CLI already keeps the answer. It refreshes `~/.claude/cache/model-catalog/published-*.json`
/// from the service: every model it will run, the version each family alias resolves to, the
/// reasoning levels each model takes and its own default level. Reading that file is exactly what
/// the Codex side already does with `~/.codex/models_cache.json`, and it means a model released
/// this morning is in the menu this afternoon.
///
/// Nothing here trusts the file blindly. Only the fields that are needed are read, model ids are
/// filtered to what may go on a command line, models the subscription cannot reach are dropped,
/// and a machine with no catalogue falls back to the families — which is where this started, and
/// is the honest answer when nothing better is known.
nonisolated struct ClaudeModel: Identifiable, Equatable, Sendable {

    /// The id passed to `claude --model`, e.g. `claude-opus-5`.
    var id: String

    /// What the service calls it: "Opus 5".
    var name: String

    /// The family's own name: "Opus".
    var familyName: String

    /// One line, as the service words it.
    var summary: String

    /// The family alias this model belongs to — `opus`, `sonnet`, `fable`, `haiku`.
    var family: String

    /// True for the models the CLI puts in its own main list; the rest are previous versions,
    /// still offered, but not what anybody should land on by accident.
    var isCurrent: Bool

    /// The reasoning levels this model takes, in the catalogue's order.
    var levels: [String]

    /// The level the service uses when nobody chooses.
    var defaultLevel: String

    /// Whether depth means anything at all here. Haiku 4.5 has no reasoning levels — the catalogue
    /// says `thinking: none` — so sending it `--effort` is a flag about nothing.
    var thinks: Bool

    /// The CLI version this model needs. A model the installed CLI has never heard of is not shown.
    var minimumCLIVersion: String

    /// Lower sorts first — the catalogue's own ordering.
    var priority: Int
}

nonisolated struct ClaudeModelCatalog: Equatable, Sendable {

    /// The models a person may pick, in the catalogue's own order.
    var models: [ClaudeModel] = []

    /// Which model each family alias resolves to right now: `opus` → `claude-opus-5`. This is the
    /// whole reason the menu can say what "Opus" means instead of leaving it a mystery.
    var aliases: [String: String] = [:]

    /// The model that answers when no `--model` is passed at all.
    ///
    /// Two things decide it, and the local one wins: the CLI's own `settings.json` carries the
    /// model a person chose for themselves (`opus`, `opus[1m]`, a full id), and the catalogue
    /// carries the service's default in `model_selector_state`. Without this, "Automatic" was a
    /// word with nothing behind it — the one choice in the menu that could not say what it does.
    var automaticID: String = ""

    /// The depth that same model runs at by default, as the catalogue's selector state gives it.
    var automaticDepth: String = ""

    /// True once a catalogue was actually read, so the UI can tell "none" from "not looked yet".
    var loaded = false

    static let empty = ClaudeModelCatalog()

    // MARK: - Where it lives

    static var configDirectory: URL {
        ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"].flatMap {
            $0.isEmpty ? nil : URL(fileURLWithPath: $0)
        } ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude")
    }

    static var cacheDirectory: URL { configDirectory.appendingPathComponent("cache/model-catalog") }

    /// Where the CLI keeps the model a person chose for themselves.
    static var settingsFile: URL { configDirectory.appendingPathComponent("settings.json") }

    /// Read the newest catalogue on disk.
    ///
    /// The directory holds catalogues in two shapes, and a machine can have both. `published-*.json`
    /// is the whole service document, one file per source, beside `published-floor.json`, which is
    /// a bookkeeping record rather than a catalogue. CLI 2.1.280 stopped refreshing those and
    /// writes `<account>-<org>-cc.json` instead: just this surface's selector, per account. Opus
    /// 5.5 arrived only in the second shape, so reading the first alone kept the menu on the
    /// models of a fortnight earlier. Every file is tried, and the freshest `fetchedAt` wins — a
    /// machine that has talked to more than one endpoint, or run more than one CLI, still gets the
    /// current answer.
    static func read(cliVersion: String = "", from directory: URL? = nil,
                     settings settingsFile: URL? = nil) -> ClaudeModelCatalog {
        let dir = directory ?? cacheDirectory
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else {
            return .empty
        }
        var best: (stamp: Double, catalogue: ClaudeModelCatalog)?
        for name in names where name.hasSuffix(".json") {
            guard name != "published-floor.json",
                  let data = try? Data(contentsOf: dir.appendingPathComponent(name)) else { continue }
            let found = decode(data, cliVersion: cliVersion)
            guard found.loaded else { continue }
            let stamp = (try? JSONSerialization.jsonObject(with: data))
                .flatMap { ($0 as? [String: Any])?["fetchedAt"] as? NSNumber }?.doubleValue ?? 0
            if best == nil || stamp > best!.stamp { best = (stamp, found) }
        }
        guard var catalogue = best?.catalogue else { return .empty }

        // A model named in the CLI's own settings is what actually answers with no `--model`, and
        // it beats the catalogue's default. `opus[1m]` is that alias asking for the long context;
        // the model behind it is still Opus.
        if let data = try? Data(contentsOf: settingsFile ?? Self.settingsFile),
           let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let chosen = root["model"] as? String,
           let id = catalogue.settle(chosen) {
            catalogue.automaticID = id
            catalogue.automaticDepth = catalogue.stateDepths[id]
                ?? catalogue.model(id: id)?.defaultLevel ?? catalogue.automaticDepth
        }
        return catalogue
    }

    /// Decode any of the shapes the CLI keeps: the older cache file (whose `documentBytes` carries
    /// the service document in base64), that document itself, or the newer per-account file whose
    /// `catalog` carries this surface's selector directly. Tests read the documents; the app reads
    /// the files.
    static func decode(_ data: Data, cliVersion: String = "") -> ClaudeModelCatalog {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return .empty
        }
        if let encoded = root["documentBytes"] as? String {
            guard let inner = Data(base64Encoded: encoded) else { return .empty }
            return decode(inner, cliVersion: cliVersion)
        }
        // CLI 2.1.280 on: `{version: 2, fetchedAt, catalog: {surface, config, state}}` — the same
        // selector the document nests under `surfaces.cc`, with the nesting taken away.
        if let catalog = root["catalog"] as? [String: Any] {
            guard (catalog["surface"] as? String ?? "cc") == "cc",
                  let config = catalog["config"] as? [String: Any] else { return .empty }
            return decode(config: config, state: catalog["state"] as? [String: Any],
                          cliVersion: cliVersion)
        }
        guard let surfaces = root["surfaces"] as? [String: Any],
              let cc = surfaces["cc"] as? [String: Any],
              let configs = cc["model_selector_config"] as? [[String: Any]],
              let config = configs.first(where: { $0["id"] as? String == "cc" }) ?? configs.first
        else { return .empty }

        let states = (cc["model_selector_state"] as? [[String: Any]]) ?? []
        return decode(config: config,
                      state: states.first { $0["id"] as? String == "cc" } ?? states.first,
                      cliVersion: cliVersion)
    }

    /// One surface's selector — its models and the state the CLI starts from — whichever file it
    /// came out of.
    ///
    /// The two shapes do not carry the same fields. The document gives each model a `runtime`
    /// (family, levels, default level), says who may run it in `offered_on`, and names what each
    /// family alias resolves to. The per-account file drops all three, because it is already the
    /// answer for one account: the levels are the model's own `effort_options`, its default is
    /// the one badged "Default", and the alias is the family's newest model in the main list —
    /// which is what the document's own alias table says today for every family.
    private static func decode(config: [String: Any], state: [String: Any]?,
                               cliVersion: String) -> ClaudeModelCatalog {
        guard let rows = config["models"] as? [[String: Any]] else { return .empty }

        // What the CLI runs when nobody names a model. `thinking_by_model` carries each model's
        // own default depth, which is what `Automatic` then means for depth as well.
        let stateModel = (state?["model"] as? String).flatMap(safeID) ?? ""
        var stateDepths: [String: String] = [:]
        for row in (state?["thinking_by_model"] as? [[String: Any]]) ?? [] {
            guard let id = (row["id"] as? String).flatMap(safeID),
                  let effort = (row["thinking"] as? [String: Any])?["effort"] as? String,
                  !effort.isEmpty else { continue }
            stateDepths[id] = effort
        }

        var out: [ClaudeModel] = []
        for (index, row) in rows.enumerated() {
            guard let raw = row["id"] as? String, let id = safeID(raw) else { continue }

            // `offered_on` is where the catalogue says who can actually run this. Opus 4.1 is
            // listed there for Bedrock and Vertex only: offering it on a subscription would be a
            // menu entry that fails the moment it is chosen.
            let offered = (row["offered_on"] as? [String]) ?? []
            guard offered.isEmpty || offered.contains("first_party") else { continue }

            // A model newer than the installed CLI is not a choice, it is a broken run. When the
            // CLI version is unknown, nothing is filtered — guessing would take away models that
            // work.
            if !cliVersion.isEmpty, let needs = row["min_claude_code_version"] as? String,
               isVersion(cliVersion, olderThan: needs) { continue }

            let runtime = (row["runtime"] as? [String: Any]) ?? [:]
            let thinkingRow = (row["thinking"] as? [String: Any]) ?? [:]
            let thinking = thinkingRow["type"] as? String ?? ""
            let options = (thinkingRow["effort_options"] as? [[String: Any]]) ?? []
            let levels = ((runtime["effort_levels"] as? [String])
                          ?? options.compactMap { $0["id"] as? String }).filter { !$0.isEmpty }
            let badged = options.first { $0["badge"] != nil }?["id"] as? String
            let shortName = (row["short_name"] as? String) ?? (row["name"] as? String) ?? id

            out.append(ClaudeModel(
                id: id,
                name: (row["name"] as? String) ?? id,
                familyName: shortName,
                summary: (row["description"] as? String) ?? "",
                family: (runtime["family"] as? String) ?? shortName.lowercased(),
                isCurrent: (row["section"] as? String ?? "main") == "main",
                levels: levels,
                defaultLevel: (runtime["default_effort"] as? String) ?? badged
                    ?? stateDepths[id] ?? "high",
                thinks: thinking != "none" && !levels.isEmpty,
                minimumCLIVersion: (row["min_claude_code_version"] as? String) ?? "",
                priority: index))
        }
        guard !out.isEmpty else { return .empty }

        var aliases: [String: String] = [:]
        if let table = config["provider_alias_targets"] as? [String: Any] {
            for (alias, target) in table {
                // `per_provider` names what each hosting provider resolves the alias to; Bulava
                // runs the CLI on a subscription, so `default` is the one that answers here.
                guard let id = ((target as? [String: Any])?["default"] as? String).flatMap(safeID),
                      out.contains(where: { $0.id == id }) else { continue }
                aliases[alias] = id
            }
        } else {
            // No table: the family's first model in the catalogue's own order, which puts the main
            // list ahead of the older versions. `short_name` is the family as the service names
            // it — "Opus", "Fable" — and the alias is that word in lower case.
            for family in ClaudeModelChoice.families {
                let named = out.filter { $0.familyName.lowercased() == family.rawValue }
                if let pick = named.first(where: \.isCurrent) ?? named.first {
                    aliases[family.rawValue] = pick.id
                }
            }
        }

        var catalogue = ClaudeModelCatalog(models: out, aliases: aliases, loaded: true)

        // The service's default, which a person's own setting overrides — `read` supplies that.
        catalogue.automaticID = catalogue.settle(stateModel) ?? ""
        catalogue.automaticDepth = stateDepths[catalogue.automaticID]
            ?? (state?["thinking"] as? [String: Any])?["effort"] as? String ?? ""
        catalogue.stateDepths = stateDepths
        return catalogue
    }

    /// Every model's own default depth as the selector state gives it, which is not always the
    /// same as the catalogue row's: Opus 4.7 is listed at `xhigh` in both, and a future model may
    /// differ in one.
    var stateDepths: [String: String] = [:]

    /// Turn whatever names a model — a full id, a family alias, an alias with a context variant
    /// like `opus[1m]` — into an id this catalogue carries.
    func settle(_ raw: String) -> String? {
        let name = raw.split(separator: "[").first.map(String.init) ?? raw
        guard let clean = Self.safeID(name) else { return nil }
        if model(id: clean) != nil { return clean }
        return aliases[clean]
    }

    // MARK: - Looking things up

    func model(id: String) -> ClaudeModel? { models.first { $0.id == id } }

    /// The models the CLI lists first — today's Fable, Opus, Sonnet and Haiku.
    var current: [ClaudeModel] { models.filter(\.isCurrent) }

    /// Previous versions, still runnable. Kept apart in the menu so nobody lands on one by
    /// accident, and there for the times a new release changes something mid-project.
    var older: [ClaudeModel] { models.filter { !$0.isCurrent } }

    /// The model a choice actually runs on: a pinned version is itself, a family is whatever the
    /// catalogue says that alias points at today, and `Automatic` is nobody's to know.
    func resolved(_ choice: ClaudeModelChoice) -> ClaudeModel? {
        guard !choice.isAutomatic else { return model(id: automaticID) }
        if let pinned = model(id: choice.rawValue) { return pinned }
        guard let id = aliases[choice.rawValue] else { return nil }
        return model(id: id)
    }

    /// What to write next to a family so "Opus" stops being a question — "Opus 5" today, whatever
    /// it resolves to tomorrow. Nil when there is nothing to add.
    func versionName(for choice: ClaudeModelChoice) -> String? {
        guard !choice.isPinnedVersion, let found = resolved(choice) else { return nil }
        return found.name
    }

    /// The name to show for a choice the menu has to display: the catalogue's name for anything it
    /// knows, and the stored id for a model chosen on a machine whose catalogue has moved on.
    func label(for choice: ClaudeModelChoice) -> String {
        if choice.isAutomatic { return String(localized: "Automatic") }
        if choice.isFamily { return String(localized: choice.label) }
        return model(id: choice.rawValue)?.name ?? choice.rawValue
    }

    // MARK: - Depth

    /// Does depth mean anything for this choice? Haiku 4.5 has no reasoning levels at all, and a
    /// depth slider over a model that ignores it is a control that lies.
    func thinks(_ choice: ClaudeModelChoice) -> Bool {
        guard let found = resolved(choice) else { return true }
        return found.thinks
    }

    /// The depths to offer for the chosen model.
    ///
    /// A level the model does not take is not a harmless setting: the CLI warns and quietly runs at
    /// the default, so the label in the composer would be a claim about something that never
    /// happened. When nothing is known — no catalogue, or `Automatic` — every level Bulava knows
    /// is offered, which is the old behaviour.
    func levels(for choice: ClaudeModelChoice) -> [ClaudeEffortChoice] {
        guard let found = resolved(choice) else { return ClaudeEffortChoice.allCases }
        guard found.thinks else { return [.auto] }
        let allowed = Set(found.levels)
        let offered = ClaudeEffortChoice.allCases.filter {
            // `ultracode` is Bulava's deepest setting and the CLI takes it on any model that
            // thinks; the catalogue lists the service's own levels and never mentions it.
            $0 == .auto || $0 == .ultracode || allowed.contains($0.rawValue)
        }
        return offered.count > 1 ? offered : ClaudeEffortChoice.allCases
    }

    /// The depth to actually send when the choice is `Automatic`.
    ///
    /// The catalogue carries each model's own default, and they differ — Opus 4.7 defaults to
    /// `xhigh` where Opus 5 defaults to `high`. Honouring it is what keeps "Automatic" from
    /// meaning one fixed depth for models that were tuned differently.
    func automaticLevel(for choice: ClaudeModelChoice) -> ClaudeEffortChoice {
        guard let found = resolved(choice), found.thinks else {
            return ClaudeEffortChoice.conversationDefault
        }
        // The selector state carries the depth the CLI itself starts a model at; the catalogue row
        // carries the service's. They agree today, and where they do not, the one the CLI will use
        // is the honest answer.
        let named = (choice.isAutomatic ? automaticDepth : "")
        let raw = named.isEmpty ? (stateDepths[found.id] ?? found.defaultLevel) : named
        guard let level = ClaudeEffortChoice(rawValue: raw), level != .auto,
              levels(for: choice).contains(level) else { return ClaudeEffortChoice.conversationDefault }
        return level
    }

    /// The depth this choice sends, for this model. Never `.auto`, and never a level the model
    /// does not take — the same narrowing a night run gets, so what is shown is what is sent.
    func effort(_ depth: ClaudeEffortChoice, for choice: ClaudeModelChoice) -> ClaudeEffortChoice {
        ClaudeEffortChoice(rawValue: supportedEffort(depth.rawValue, for: choice))
            ?? automaticLevel(for: choice)
    }

    /// The word that means "this model takes no depth — send no flag at all".
    ///
    /// An empty string cannot say it. The engine fills an empty `SUPERVISOR_CLAUDE_EFFORT` with
    /// `high` (`supervisor/config.sh`), so "leave it out" and "nobody said" looked identical by
    /// the time the run started, and Haiku was launched at `--effort high` while the settings row
    /// promised no effort at all. A value the engine can see is what carries the intent across.
    static let noDepth = "none"

    /// What goes on the command line. `none` for a model with no depth to set, so `--effort` is
    /// left off entirely rather than sent to something that ignores it.
    func effortFlag(_ depth: ClaudeEffortChoice, for choice: ClaudeModelChoice) -> String {
        supportedEffort(depth.rawValue, for: choice)
    }

    /// The depth a run will actually be given, once the model has had its say.
    ///
    /// Night work decides depth per task — `ultracode` for a long plan, `medium` for research —
    /// and that decision is made before anyone knows which model will run it. Opus 4.6 does not
    /// take `xhigh`: handing it one is not refused, it is simply not the level that runs, so the
    /// interface would name a depth nobody got. An unsupported level steps DOWN to the deepest one
    /// the model does take, rather than to the model's default, because a task Bulava judged deep
    /// should not come back shallow.
    ///
    /// `ultracode` is not in any model's list — it is the CLI's own setting, and the CLI takes it
    /// on every model that thinks — so it survives this untouched.
    func supportedEffort(_ raw: String, for choice: ClaudeModelChoice) -> String {
        guard thinks(choice) else { return Self.noDepth }
        guard !raw.isEmpty, raw != Self.noDepth else { return Self.noDepth }
        guard let wanted = ClaudeEffortChoice(rawValue: raw), wanted != .auto else {
            return automaticLevel(for: choice).rawValue
        }
        let offered = levels(for: choice)
        if offered.contains(wanted) { return wanted.rawValue }

        let ladder = ClaudeEffortChoice.allCases
        guard let reach = ladder.firstIndex(of: wanted) else {
            return automaticLevel(for: choice).rawValue
        }
        for candidate in ladder[..<reach].reversed() where candidate != .auto && offered.contains(candidate) {
            return candidate.rawValue
        }
        return automaticLevel(for: choice).rawValue
    }

    /// The depth as a worker's settings row words it.
    ///
    /// `Automatic` means something different on each side, and the difference matters: a
    /// conversation has no task, so it resolves to the model's own default and the composer can
    /// name it. A night worker's depth is decided per task — deepest for a long plan, lighter for
    /// research — so naming one level here would be a claim about a run that has not been thought
    /// about yet.
    func workerDepthLabel(_ depth: ClaudeEffortChoice, for choice: ClaudeModelChoice) -> String {
        guard thinks(choice) else { return String(localized: "No depth setting") }
        guard depth != .auto else { return String(localized: depth.label) }
        return String(localized: effort(depth, for: choice).label)
    }

    /// The depth as the interface words it: a chosen level by name, `Automatic` resolved to the
    /// level it will actually send, and a plain statement for a model where depth is not a setting
    /// at all. A control that reads "Automatic" and means five different things is the thing this
    /// replaces.
    func depthLabel(_ depth: ClaudeEffortChoice, for choice: ClaudeModelChoice) -> String {
        guard thinks(choice) else { return String(localized: "No depth setting") }
        guard depth == .auto else { return String(localized: effort(depth, for: choice).label) }
        return String(format: String(localized: "Automatic · %@"),
                      String(localized: automaticLevel(for: choice).label))
    }

    // MARK: - Guards

    /// A model id is going onto a command line. Same allowance the Codex side uses.
    static func safeID(_ raw: String) -> String? {
        let allowed = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-")
        let clean = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty, clean.allSatisfy({ allowed.contains($0) }) else { return nil }
        return clean
    }

    /// Plain numeric version compare — "2.1.9" is older than "2.1.251", which a string compare
    /// gets backwards.
    static func isVersion(_ have: String, olderThan want: String) -> Bool {
        let a = have.split(separator: ".").map { Int($0.prefix(while: \.isNumber)) ?? 0 }
        let b = want.split(separator: ".").map { Int($0.prefix(while: \.isNumber)) ?? 0 }
        for i in 0..<max(a.count, b.count) {
            let l = i < a.count ? a[i] : 0
            let r = i < b.count ? b[i] : 0
            if l != r { return l < r }
        }
        return false
    }
}
