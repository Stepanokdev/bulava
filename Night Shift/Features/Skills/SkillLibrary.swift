import SwiftUI

struct SkillLibrary: View {
    @Environment(AppModel.self) private var model
    @State private var inventory = SkillInventory.empty
    @State private var mcp = MCPInventory.empty
    @State private var loading = false
    @State private var query = ""
    @State private var busySkill: String?
    @State private var failure: String?
    @State private var pendingRemoval: InstalledSkill?

    private var productID: UUID? { model.route.productID ?? model.products.products.first?.id }

    var body: some View {
        VStack(spacing: 0) {
            header
            Hairline()
            if let failure, !failure.isEmpty {
                failureBanner(failure)
                Hairline()
            }
            SkillLibraryContent(inventory: inventory, mcp: mcp, loading: loading, query: query,
                                busySkill: busySkill,
                                onRemove: { pendingRemoval = $0 },
                                onUpdate: { skill in Task { await update(skill) } })
        }
        .background(Palette.content)
        .task { await load() }
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

    // MARK: - What the machine is carrying

    private var header: some View {
        VStack(alignment: .leading, spacing: 11) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text("Skills & MCP")
                    .font(Typo.screenTitle)
                    .foregroundStyle(Palette.text)
                Spacer(minLength: 8)
                if loading { ProgressView().controlSize(.small) }
                Button { Task { await load(force: true) } } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.icon(size: 22, glyph: 11))
                    .help(Text("Read usage again"))
                    .disabled(loading)
            }
            SkillStats(inventory: inventory, mcp: mcp)
            searchField
        }
        .padding(.horizontal, 18)
        .padding(.top, 16)
        .padding(.bottom, 12)
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

    // MARK: - Doing something about it

    private func load(force: Bool = false) async {
        guard !loading, force || !inventory.loaded else { return }
        loading = true
        inventory = await model.skillInventory(fast: true)

        async let counted = model.skillInventory(fast: false)
        async let servers = model.mcpInventory(fast: false)
        let (withUses, withServers) = await (counted, servers)
        if withUses.loaded { inventory = withUses }
        if withServers.loaded { mcp = withServers }
        loading = false
    }

    private func remove(_ skill: InstalledSkill) async {
        busySkill = skill.id; failure = nil
        let r = await model.removeSkill(skill, productID: productID)
        busySkill = nil
        if !r.ok { failure = r.message }
        await load(force: true)
    }

    private func update(_ skill: InstalledSkill) async {
        busySkill = skill.id; failure = nil
        let r = await model.updateSkill(skill, productID: productID)
        busySkill = nil
        if !r.ok { failure = r.message }
        await load(force: true)
    }
}

struct SkillStats: View {
    let inventory: SkillInventory
    var mcp: MCPInventory = .empty

    var body: some View {

        WrappingHStack(horizontalSpacing: 14, verticalSpacing: 5) {
            if inventory.loaded {
                stat(Fmt.count("%lld installed", inventory.skills.count), Palette.textSecondary)
            }

            if inventory.counted, !inventory.unused.isEmpty {
                stat(Fmt.count("%lld never used", inventory.unused.count), Palette.orange)
                stat(String(format: String(localized: "%@ of context each session"), contextCost),
                     Palette.orange)
            }
            if mcp.loaded {
                stat(Fmt.count("%lld servers", mcp.servers.count), Palette.textSecondary)
                if !mcp.unhealthy.isEmpty {
                    stat(Fmt.count("%lld need attention", mcp.unhealthy.count), Palette.orange)
                }
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

    private var contextCost: String {
        let n = inventory.unusedFrontmatter
        return n >= 1000 ? String(format: "%.1fk", Double(n) / 1000) : "\(n)"
    }
}

struct SkillLibraryContent: View {
    let inventory: SkillInventory
    var mcp: MCPInventory = .empty
    var loading: Bool = false
    var query: String = ""
    var busySkill: String?
    var onRemove: (InstalledSkill) -> Void = { _ in }
    var onUpdate: (InstalledSkill) -> Void = { _ in }

    static func filterMissing(_ skills: [MissingSkill], _ query: String) -> [MissingSkill] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return skills }
        return skills.filter { $0.name.localizedCaseInsensitiveContains(q) }
    }

    static func filter(_ skills: [InstalledSkill], _ query: String) -> [InstalledSkill] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return skills }
        return skills.filter { $0.name.localizedCaseInsensitiveContains(q) }
    }

    private var visible: [InstalledSkill] { Self.filter(inventory.skills, query) }

    private var visibleServers: [MCPServer] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return mcp.servers }
        return mcp.servers.filter {
            $0.name.localizedCaseInsensitiveContains(q) || $0.description.localizedCaseInsensitiveContains(q)
        }
    }

    private var servers: some View {
        VStack(alignment: .leading, spacing: 0) {
            PanelTitle("MCP servers") {
                Text("\(visibleServers.count)")
                    .font(Typo.panelMeta)
                    .monospacedDigit()
                    .foregroundStyle(Palette.textFaint)
            }
            PanelCard {
                VStack(spacing: 0) {
                    ForEach(Array(visibleServers.enumerated()), id: \.element.id) { index, server in
                        if index > 0 { Hairline() }
                        MCPRow(server: server, counted: mcp.counted)
                    }
                }
            }
            Text("Connected for every project. Bulava never shows their keys or headers.")
                .font(Typo.panelMeta)
                .foregroundStyle(Palette.textFaint)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 6)
                .padding(.top, 6)
        }
    }

    @ViewBuilder var body: some View {

        if !inventory.loaded && mcp.servers.isEmpty {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Reading how much each one gets used…")
                    .font(Typo.caption)
                    .foregroundStyle(Palette.textTertiary)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 14)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        } else if inventory.loaded && inventory.skills.isEmpty && mcp.servers.isEmpty {
            InviteState(systemImage: "sparkles",
                        title: Text("No skills installed."),
                        message: "Bulava installs what a project turns out to need, after an audit.")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if visible.isEmpty && visibleServers.isEmpty {
            InviteState(systemImage: "magnifyingglass",
                        title: Text("Nothing matches that."),
                        message: "Try a shorter piece of the name.")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: Metrics.sectionGap) {
                    ForEach(SkillGroup.all, id: \.scope) { group in
                        let rows = visible.filter { $0.scope == group.scope }
                        if !rows.isEmpty { section(group, rows) }
                    }
                    missing
                    caveat
                    if !visibleServers.isEmpty {
                        servers
                    } else if !mcp.loaded && loading && query.isEmpty {

                        VStack(alignment: .leading, spacing: 0) {
                            PanelTitle("MCP servers") { EmptyView() }
                            PanelCard {
                                HStack(spacing: 8) {
                                    ProgressView().controlSize(.mini)
                                    Text("Asking each server whether it answers…")
                                        .font(Typo.caption)
                                        .foregroundStyle(Palette.textTertiary)
                                    Spacer(minLength: 0)
                                }
                                .padding(.horizontal, 10)
                                .padding(.vertical, 9)
                            }
                        }
                    }
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 16)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private func section(_ group: SkillGroup, _ rows: [InstalledSkill]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            PanelTitle(group.title) {
                Text("\(rows.count)")
                    .font(Typo.panelMeta)
                    .monospacedDigit()
                    .foregroundStyle(Palette.textFaint)
            }
            PanelCard {
                VStack(spacing: 0) {
                    ForEach(Array(rows.enumerated()), id: \.element.id) { index, skill in
                        if index > 0 { Hairline() }

                        SkillRow(skill: skill, busy: busySkill == skill.id,
                                 counted: inventory.counted, showsScope: false,
                                 onRemove: { onRemove(skill) }, onUpdate: { onUpdate(skill) })
                    }
                }
            }
            if let note = group.note {
                Text(note)
                    .font(Typo.panelMeta)
                    .foregroundStyle(Palette.textFaint)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 6)
                    .padding(.top, 6)
            }
        }
    }

    @ViewBuilder private var missing: some View {
        let rows = SkillLibraryContent.filterMissing(inventory.missing, query)
        if !rows.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                PanelTitle("Called, but not installed") {
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
                Text("Either a plugin that is gone, or something deleted while it was still being used.")
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
        if inventory.transcriptsScanned > 0, !inventory.unused.isEmpty {
            Text("“Never used” means no record of use in \(inventory.transcriptsScanned) transcripts, not proof it is useless.")
                .font(Typo.panelMeta)
                .foregroundStyle(Palette.textFaint)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 6)
        }
    }
}

nonisolated struct SkillGroup {
    var scope: InstalledSkill.Scope
    var title: LocalizedStringKey
    var note: LocalizedStringKey?

    static var all: [SkillGroup] { [
        .init(scope: .global, title: "Loaded everywhere",
              note: "Loaded in every project. These are the ones worth pruning."),
        .init(scope: .project, title: "Installed for one product",
              note: "Bulava installed these after an audit, for a project that needed them."),
        .init(scope: .plugin, title: "From plugins",
              note: "These belong to their plugin — remove the plugin, not the skill."),
    ] }
}

struct MCPRow: View {
    let server: MCPServer
    var counted: Bool = true

    var body: some View {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: glyph)
                .font(.system(size: 11))
                .foregroundStyle(healthTint)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(server.name)
                        .font(Typo.panelRow)
                        .foregroundStyle(Palette.textSecondary)
                        .lineLimit(1)
                    if server.health != .connected {
                        Text(healthLabel)
                            .font(Typo.tag)
                            .textCase(.uppercase)
                            .foregroundStyle(healthTint)
                    }
                }
                if !server.description.isEmpty {
                    Text(server.description)
                        .font(Typo.panelMeta)
                        .foregroundStyle(Palette.textTertiary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                HStack(spacing: 4) {
                    Text(scopeLabel)
                        .font(Typo.panelMeta)
                        .foregroundStyle(Palette.textFaint)
                    Text("·").foregroundStyle(Palette.textFaint)
                    Text(usageLabel)
                        .font(Typo.panelMeta)
                        .foregroundStyle(counted && server.uses == 0 ? Palette.orange : Palette.textFaint)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)

        .help(Text(server.target.isEmpty ? server.name : server.target))
    }

    private var glyph: String {
        switch server.health {
        case .connected: server.isRemote ? "cloud" : "terminal"
        case .failed:    "exclamationmark.triangle"
        case .needsAuth: "key"
        case .unknown:   "questionmark.circle"
        }
    }

    private var healthTint: Color {
        switch server.health {
        case .connected: Palette.textFaint
        case .failed:    Palette.red
        case .needsAuth, .unknown: Palette.orange
        }
    }

    private var healthLabel: LocalizedStringKey {
        switch server.health {
        case .failed:    "not connecting"
        case .needsAuth: "needs sign-in"
        case .unknown:   "unknown"
        case .connected: ""
        }
    }

    private var scopeLabel: LocalizedStringKey {
        switch server.scope {
        case .account:   "from your account"
        case .user:      "everywhere"
        case .project:   "one project"
        case .unknown:   "configured elsewhere"
        }
    }

    private var usageLabel: String {
        guard counted else { return String(localized: "counting uses…") }
        if server.uses == 0 { return String(localized: "never used") }
        let uses = Fmt.count("%lld calls", server.uses)
        guard let last = server.lastUsed, !last.isEmpty else { return uses }
        return "\(uses) · \(last)"
    }
}
