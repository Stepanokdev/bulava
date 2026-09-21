import SwiftUI

/// Skills, arranged the way the question is actually asked.
///
/// The old panel listed everything the machine carries with one number beside each name, and the
/// number was a machine-wide total — 17 uses of `minimalist-ui` tells you nothing about whether
/// THIS product has ever wanted it. So there was no way to answer either of the two questions he
/// had: which of these belong to this project, and what did that number mean.
///
/// A screen rather than a floating window, beside Memory, for the same reason Memory is one: a
/// skill decided for one product is a fact about that product, and a corner of a window that has
/// to be summoned is not where anyone looks.
struct SkillsScreen: View {
    @Environment(AppModel.self) private var model

    @State private var inventory = SkillInventory.empty
    @State private var mcp = MCPInventory.empty
    @State private var loading = false
    @State private var query = ""
    @State private var busySkill: String?
    @State private var failure: String?
    @State private var pendingRemoval: InstalledSkill?

    /// Which product's skills are on screen. Nil means every project at once.
    @State private var focusID: UUID?

    /// Which of his skills this project has any business using, read off the repository.
    @State private var fits: [SkillFit] = []

    /// How often each skill was used in the focused project. Kept apart from `inventory` so the
    /// machine-wide pass landing later cannot erase it.
    @State private var useHere = SkillUseInProject.empty

    private var products: [Product] {
        model.products.products.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private var focus: Product? { focusID.flatMap { model.products.product(id: $0) } }

    /// The inventory as it applies to what the picker says.
    ///
    /// Every project is scanned — the global list is the same everywhere and pruning it is a
    /// machine-wide decision — but a project-scoped skill from ANOTHER repository is not this
    /// product's. Without this, the header read "77 installed" above the name of one product that
    /// has two.
    private var shown: SkillInventory {
        inventory.visible(forProjectPath: focusProjectPath).attributed(to: useHere)
    }

    private var focusProjectPath: String? {
        guard let focus, let id = focus.defaultProjectID,
              let project = model.projects.project(id: id) else { return nil }
        return project.path
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Hairline()
            if let failure, !failure.isEmpty {
                failureBanner(failure)
                Hairline()
            }
            body(for: shown)
        }
        .background(Palette.content)
        .task { await load() }
        .task(id: focusID) { await countForFocus() }
        .animation(Motion.standard, value: failure)
        .confirmationDialog(
            Text("Delete “\(pendingRemoval?.name ?? "")”?"),
            isPresented: Binding(get: { pendingRemoval != nil },
                                 set: { if !$0 { pendingRemoval = nil } }),
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                if let skill = pendingRemoval { pendingRemoval = nil; Task { await remove(skill) } }
            }
            Button("Keep", role: .cancel) { pendingRemoval = nil }
        } message: {
            Text("It is deleted from disk. Installing it again goes through the audit like any new skill.")
        }
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 11) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text("Skills")
                    .font(Typo.screenTitle)
                    .foregroundStyle(Palette.text)
                Spacer(minLength: 8)
                if loading { ProgressView().controlSize(.small) }
                Button { Task { await load(force: true) } } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.icon(size: 22, glyph: 11))
                    .help(Text("Read usage again"))
                    .disabled(loading)
            }
            focusPicker
            countsLine
            searchField
        }
        .padding(.horizontal, 18)
        .padding(.top, 16)
        .padding(.bottom, 12)
    }

    /// Which product he is asking about. "Every project" is a real answer, not a placeholder: the
    /// global list is what he prunes, and pruning is a machine-wide decision.
    private var focusPicker: some View {
        Picker("", selection: $focusID) {
            Text("Every project").tag(UUID?.none)
            ForEach(products) { product in
                Text(verbatim: product.name).tag(UUID?.some(product.id))
            }
        }
        .labelsHidden()
        .pickerStyle(.menu)
        .frame(maxWidth: 260, alignment: .leading)
        .disabled(products.isEmpty)
    }

    /// What the numbers mean, said once, where they are.
    private var countsLine: some View {
        WrappingHStack(horizontalSpacing: 14, verticalSpacing: 5) {
            if inventory.loaded {
                stat(Fmt.count("%lld installed", shown.skills.count), Palette.textSecondary)
            }
            if focus != nil, shown.transcriptsHere > 0 {
                stat(Fmt.count("%lld used here", shown.usedHere.count), Palette.textSecondary)
                stat(Fmt.count("read from %lld sessions of this product", shown.transcriptsHere),
                     Palette.textFaint)
            } else if shown.counted, shown.transcriptsScanned > 0 {
                stat(Fmt.count("read from %lld sessions", inventory.transcriptsScanned),
                     Palette.textFaint)
            }
            if shown.counted, !shown.unused.isEmpty {
                stat(Fmt.count("%lld never used anywhere", shown.unused.count), Palette.orange)
            }
        }
    }

    private func stat(_ text: String, _ tint: Color) -> some View {
        Text(text)
            .font(Typo.control)
            .monospacedDigit()
            .foregroundStyle(tint)
            .fixedSize()
    }

    private var searchField: some View {
        HStack(spacing: 7) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11))
                .foregroundStyle(Palette.textFaint)
            TextField("Filter by name", text: $query)
                .textFieldStyle(.plain)
                .font(Typo.body)
                .foregroundStyle(Palette.text)
            if !query.isEmpty {
                Button { query = "" } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.icon(size: 16, glyph: 9))
            }
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 6)
        .background(Palette.field, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).stroke(Palette.line, lineWidth: 1))
    }

    private func failureBanner(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 7) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 11))
                .foregroundStyle(Palette.orange)
            Text(SkillsPanelBody.plainMessage(text))
                .font(Typo.caption)
                .foregroundStyle(Palette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            Button { failure = nil } label: { Image(systemName: "xmark") }
                .buttonStyle(.icon(size: 18, glyph: 9))
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 10)
        .background(Palette.orangeSoft)
    }

    // MARK: - Sections

    @ViewBuilder private func body(for visible: SkillInventory) -> some View {
        if !visible.loaded {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Reading what is installed…")
                    .font(Typo.caption)
                    .foregroundStyle(Palette.textTertiary)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 14)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        } else if visible.skills.isEmpty {
            InviteState(systemImage: "sparkles",
                        title: Text("No skills installed."),
                        message: "Bulava installs what a project turns out to need, after an audit.")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: Metrics.sectionGap) {
                    if focus != nil { appliesHereSection }
                    if focus != nil { usedHereSection }
                    ownedByThisProduct
                    everywhereSection
                    pluginSection
                    calledButAbsent
                    caveat
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 16)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    /// What this project has any business using, and the one choice only he can make.
    ///
    /// His skills are global, so they are already loaded everywhere — nothing needs installing.
    /// What was missing is which of them applies here. Nothing picks an aesthetic: three of them
    /// each set a whole look, applying two at once is a defect, and which one a product wears is
    /// a brand decision.
    @ViewBuilder private var appliesHereSection: some View {
        if !fits.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                PanelTitle("Applies to this product") {
                    Text("\(fits.count)")
                        .font(Typo.panelMeta)
                        .monospacedDigit()
                        .foregroundStyle(Palette.textFaint)
                }
                PanelCard {
                    VStack(spacing: 0) {
                        ForEach(Array(fits.enumerated()), id: \.element.id) { index, fit in
                            if index > 0 { Hairline() }
                            HStack(alignment: .top, spacing: 9) {
                                Image(systemName: fit.needsHisChoice
                                      ? "questionmark.circle" : "checkmark.circle")
                                    .font(.system(size: 11))
                                    .foregroundStyle(fit.needsHisChoice
                                                     ? Palette.orange : Palette.textFaint)
                                    .frame(width: 18, height: 15)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(fit.skill)
                                        .font(Typo.panelRow)
                                        .foregroundStyle(Palette.textSecondary)
                                    Text(fit.because)
                                        .font(Typo.panelMeta)
                                        .foregroundStyle(Palette.textTertiary)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                                Spacer(minLength: 0)
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 8)
                        }
                    }
                }
                Text("Read off the repository, from the skills you already have — they are global, so they load here already. The ones marked with a question are a look, and only one of those can be right.")
                    .font(Typo.panelMeta)
                    .foregroundStyle(Palette.textFaint)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 6)
                    .padding(.top, 6)
            }
        }
    }

    /// What this product actually reaches for. The list he could not get before: it cuts across
    /// scope, because a global skill used by one product is that product's skill in practice.
    @ViewBuilder private var usedHereSection: some View {
        let rows = SkillLibraryContent.filter(shown.usedHere, query)
        if shown.transcriptsHere == 0 {
            section(title: "Used by this product", note: nil, rows: [], showsScope: true,
                    empty: "No sessions of this product on disk yet, so there is nothing to count.")
        } else if rows.isEmpty {
            section(title: "Used by this product", note: nil, rows: [], showsScope: true,
                    empty: "None of the installed skills has been used in this product's sessions.")
        } else {
            section(title: "Used by this product",
                    note: "Whatever scope they live in. This is what this product's work actually reaches for.",
                    rows: rows, showsScope: true, empty: nil)
        }
    }

    /// Installed INTO one project's own folder — the ones that are genuinely "just this project".
    @ViewBuilder private var ownedByThisProduct: some View {
        let all = shown.skills.filter { $0.scope == .project }
        let rows = SkillLibraryContent.filter(
            focusProjectPath.map { path in
                all.filter { Slug.canonicalPath($0.projectPath) == Slug.canonicalPath(path) }
            } ?? all, query)
        if !rows.isEmpty {
            section(title: "Installed in a project folder",
                    note: "These live in the project's own .claude/skills and load only there.",
                    rows: rows, showsScope: false, empty: nil)
        }
    }

    @ViewBuilder private var everywhereSection: some View {
        let rows = SkillLibraryContent.filter(shown.skills.filter { $0.scope == .global }, query)
        if !rows.isEmpty {
            section(title: "Loaded everywhere",
                    note: "Loaded in every project, so every one of them costs context in every session. These are the ones worth pruning.",
                    rows: rows, showsScope: false, empty: nil)
        }
    }

    @ViewBuilder private var pluginSection: some View {
        let rows = SkillLibraryContent.filter(shown.skills.filter { $0.scope == .plugin }, query)
        if !rows.isEmpty {
            section(title: "From plugins",
                    note: "These belong to their plugin — remove the plugin, not the skill.",
                    rows: rows, showsScope: false, empty: nil)
        }
    }

    /// Skills that were called and are not in any skills folder.
    ///
    /// Reworded, because the old heading said "not installed" and invited him to install
    /// something that is not missing: most of these are Claude Code's own built-in skills, which
    /// live inside the CLI and were never files on disk.
    @ViewBuilder private var calledButAbsent: some View {
        let rows = SkillLibraryContent.filterMissing(shown.missing, query)
        if !rows.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                PanelTitle("Called, but not in a skills folder") {
                    Text("\(rows.count)")
                        .font(Typo.panelMeta)
                        .monospacedDigit()
                        .foregroundStyle(Palette.textFaint)
                }
                PanelCard {
                    VStack(spacing: 0) {
                        ForEach(Array(rows.enumerated()), id: \.element.id) { index, skill in
                            if index > 0 { Hairline() }
                            HStack(spacing: 9) {
                                Image(systemName: "questionmark.folder")
                                    .font(.system(size: 11))
                                    .foregroundStyle(Palette.textFaint)
                                    .frame(width: 18)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(skill.name)
                                        .font(Typo.panelRow)
                                        .foregroundStyle(Palette.textSecondary)
                                    Text(missingLabel(skill))
                                        .font(Typo.panelMeta)
                                        .foregroundStyle(Palette.textFaint)
                                }
                                Spacer(minLength: 0)
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 8)
                        }
                    }
                }
                Text("Usually Claude Code's own built-in skills, which are inside the CLI rather than files on disk. Nothing to install.")
                    .font(Typo.panelMeta)
                    .foregroundStyle(Palette.textFaint)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 6)
                    .padding(.top, 6)
            }
        }
    }

    private func missingLabel(_ skill: MissingSkill) -> String {
        let uses = Fmt.count("%lld calls", skill.uses)
        guard let last = skill.lastUsed, !last.isEmpty else { return uses }
        return "\(uses) · \(last)"
    }

    @ViewBuilder private var caveat: some View {
        if shown.counted, shown.transcriptsScanned > 0 {
            Text("Counted from Claude Code's own transcripts — \(shown.transcriptsScanned) sessions. Transcripts keep what was kept, so “never used” means no record of use, not proof it is useless.")
                .font(Typo.panelMeta)
                .foregroundStyle(Palette.textFaint)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 6)
        }
    }

    @ViewBuilder
    private func section(title: LocalizedStringKey, note: LocalizedStringKey?,
                         rows: [InstalledSkill], showsScope: Bool,
                         empty: LocalizedStringKey?) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            PanelTitle(title) {
                Text("\(rows.count)")
                    .font(Typo.panelMeta)
                    .monospacedDigit()
                    .foregroundStyle(Palette.textFaint)
            }
            PanelCard {
                if rows.isEmpty, let empty {
                    Text(empty)
                        .font(Typo.panelMeta)
                        .foregroundStyle(Palette.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 9)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    VStack(spacing: 0) {
                        ForEach(Array(rows.enumerated()), id: \.element.id) { index, skill in
                            if index > 0 { Hairline() }
                            SkillRow(skill: skill, busy: busySkill == skill.id,
                                     counted: shown.counted, showsScope: showsScope,
                                     onRemove: { pendingRemoval = skill },
                                     onUpdate: { Task { await update(skill) } })
                        }
                    }
                }
            }
            if let note {
                Text(note)
                    .font(Typo.panelMeta)
                    .foregroundStyle(Palette.textFaint)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 6)
                    .padding(.top, 6)
            }
        }
    }

    // MARK: - Reading and changing

    private func load(force: Bool = false) async {
        guard !loading, force || !inventory.loaded else { return }
        loading = true
        // The product he was last looking at, not whichever happens to sort first. Opening Skills
        // from the sidebar leaves `route.productID` nil, so the screen used to land on an
        // alphabetical accident and answer a question nobody asked.
        if focusID == nil {
            focusID = model.route.productID ?? model.products.lastVisited?.id ?? products.first?.id
        }

        inventory = await model.skillInventory(fast: true)
        // The per-project count starts HERE, not after the machine-wide pass. It reads one
        // project's transcripts and needs nothing from the slow one — and it is the section he
        // actually came for, so making it wait forty seconds behind a total he did not ask about
        // put the useful part last.
        async let mine: Void = countForFocus()
        async let counted = model.skillInventory(fast: false)
        async let servers = model.mcpInventory(fast: false)
        let (withUses, withServers) = await (counted, servers)
        _ = await mine
        if withUses.loaded { inventory = withUses }
        if withServers.loaded { mcp = withServers }
        loading = false
    }

    /// Per-project counts and the fit list, read from that one project.
    ///
    /// The result is kept as its own state rather than folded into `inventory`, because the
    /// machine-wide pass replaces `inventory` when it lands and would wipe it. `shown` applies it
    /// on the way to the screen instead, so the two arrive in any order and neither loses.
    private func countForFocus() async {
        guard let path = focusProjectPath else { useHere = .empty; fits = []; return }
        let use = await Task.detached(priority: .utility) {
            SkillUseInProject.scan(projectPath: path)
        }.value
        // The focus may have changed while that ran; only apply it if it still matches.
        guard focusProjectPath == path else { return }
        useHere = use

        let installed = Set(shown.skills.map(\.name))
        let usedHere = Set(shown.usedHere.map(\.name))
        let found = await Task.detached(priority: .utility) {
            SkillFit.suggest(shape: SkillFit.shape(ofProjectAt: path),
                             installed: installed, usedHere: usedHere)
        }.value
        guard focusProjectPath == path else { return }
        fits = found
    }

    private func remove(_ skill: InstalledSkill) async {
        busySkill = skill.id; failure = nil
        let r = await model.removeSkill(skill, productID: focusID ?? model.route.productID)
        busySkill = nil
        if !r.ok { failure = r.message }
        await load(force: true)
    }

    private func update(_ skill: InstalledSkill) async {
        busySkill = skill.id; failure = nil
        let r = await model.updateSkill(skill, productID: focusID ?? model.route.productID)
        busySkill = nil
        if !r.ok { failure = r.message }
        await load(force: true)
    }
}
