import SwiftUI

struct ProductInspector: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    @State private var snapshot = ChatInspectorSnapshot.empty
    @State private var loading = true
    @State private var selectedChange: SelectedChange?
    @State private var diffText = ""
    @State private var loadingDiff = false

    @State private var skillsExpanded = false
    @State private var skills = SkillInventory.empty

    private var projectSkills: SkillInventory {
        skills.belongingTo(projects: product.map { model.skillProjectPaths($0.id) } ?? [])
    }
    @State private var loadingSkills = false
    @State private var skillPendingRemoval: InstalledSkill?
    @State private var busySkill: String?

    @State private var skillFailure: String?

    private var product: Product? { model.selectedProduct }
    private var chatID: UUID? {
        product.flatMap { model.conversations.displayedChatID(for: $0.id) }
    }
    private var chat: Chat? { chatID.flatMap { model.conversations.chat(id: $0) } }

    var body: some View {
        ScrollViewReader { _ in
        ScrollView {
            if let product {
                Group {
                    if let selectedChange {
                        filePreview(selectedChange)
                    } else {
                        VStack(alignment: .leading, spacing: Metrics.sectionGap) {
                            resources(product)
                            if snapshot.changeCount > 0 { changes }
                            if let evidence = snapshot.evidence, shouldShow(evidence) {
                                verification(evidence)
                            }
                            if let chat, chat.session?.claudeSessionID != nil {
                                reports(chat)
                            }
                            if hasInstructions(product) { instructions(product) }
                            skillsSection(product)
                        }
                    }
                }
                .padding(.horizontal, 13)
                .padding(.vertical, 15)
            }
        }
        .scrollIndicators(.hidden)
        .background(Palette.chrome)
        .task(id: inspectionID) { await refreshLoop() }
        .task(id: product?.id) { if let product { await model.findWorkspaceResources(in: product) } }
        .task(id: selectedChange?.id) { await loadSelectedDiff() }
        .animation(Motion.standard, value: selectedChange?.id)
        .animation(Motion.snappy, value: snapshot.changeCount)
        }
    }

    private var inspectionID: String {
        (product?.id.uuidString ?? "none") + ":" + (chatID?.uuidString ?? "new")
    }

    private func refreshLoop() async {
        guard let product else { return }

        snapshot = .empty
        selectedChange = nil
        loading = true
        while !Task.isCancelled {
            let next = await model.chatInspectorSnapshot(productID: product.id, chatID: chatID)
            guard !Task.isCancelled else { return }
            snapshot = next
            loading = false
            try? await Task.sleep(for: .seconds(4))
        }
    }

    private func loadSelectedDiff() async {
        guard let selection = selectedChange else {
            diffText = ""
            loadingDiff = false
            return
        }
        loadingDiff = true
        diffText = ""
        let text = await model.chatInspectorDiff(projectPath: selection.project.project.path,
                                                 filePath: selection.change.path)
        guard !Task.isCancelled, selectedChange?.id == selection.id else { return }
        diffText = text
        loadingDiff = false
    }

    // MARK: - Project context

    private func resources(_ product: Product) -> some View {
        let resolved = model.resources(for: product)
        let primaryID = chat?.session?.primaryProjectID ?? product.defaultProjectID

        return VStack(alignment: .leading, spacing: 0) {
            PanelTitle("Project context") {
                if loading {
                    ProgressView()
                        .controlSize(.mini)
                        .frame(width: 20, height: 20)
                }
                Button { model.beginAddingResource(to: product.id) } label: { Image(systemName: "plus") }
                    .buttonStyle(.icon(size: 20, glyph: 10))
                    .help(Text("Add a resource"))
            }
            PanelCard {
                if resolved.isEmpty {
                    Text("Nothing connected yet. Add a folder, a repository or a site.")
                        .font(Typo.caption)
                        .foregroundStyle(Palette.textTertiary)
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    VStack(spacing: 0) {
                        ForEach(Array(resolved.enumerated()), id: \.element.id) { index, item in
                            if index > 0 { Hairline() }
                            ResourceRow(item: item, productID: product.id,
                                        isPrimary: item.project?.id == primaryID)
                            if let workspace = model.workspaceResources[item.id] {
                                WorkspaceRow(workspace: workspace,
                                             folderName: item.resource.name) {
                                    model.connectRepositoriesInside(resourceID: item.id,
                                                                    productID: product.id)
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    // MARK: - Skills

    private func skillsSection(_ product: Product) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            PanelTitle("Skills") {
                if loadingSkills {
                    ProgressView().controlSize(.mini).frame(width: 20, height: 20)
                } else if skills.loaded {
                    Text(skillsHeadline)
                        .font(Typo.panelMeta)
                        .foregroundStyle(projectSkills.unused.isEmpty ? Palette.textFaint : Palette.orange)
                }
                Button { openWindow(id: "skills") } label: { Image(systemName: "square.grid.2x2") }
                    .buttonStyle(.icon(size: 20, glyph: 10))
                    .help(Text("All skills on this machine"))
                Button { toggleSkills(product) } label: {
                    Image(systemName: skillsExpanded ? "chevron.down" : "chevron.right")
                }
                .buttonStyle(.icon(size: 20, glyph: 9))
                .help(Text(skillsExpanded ? "Hide skills" : "Show skills"))
            }
            if skillsExpanded {
                SkillsPanelBody(inventory: projectSkills,
                                loading: loadingSkills,
                                busySkill: busySkill,
                                failure: skillFailure,
                                onRemove: { skillPendingRemoval = $0 },
                                onUpdate: { skill in Task { await updateSkill(skill, product) } })
            }
        }
        .animation(Motion.standard, value: skillsExpanded)
        .confirmationDialog(
            Text("Delete “\(skillPendingRemoval?.name ?? "")”?"),
            isPresented: Binding(get: { skillPendingRemoval != nil },
                                 set: { if !$0 { skillPendingRemoval = nil } }),
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                if let skill = skillPendingRemoval {
                    skillPendingRemoval = nil
                    Task { await removeSkill(skill, product) }
                }
            }
            Button("Keep", role: .cancel) { skillPendingRemoval = nil }
        } message: {
            Text("It is deleted from disk. Installing it again goes through the audit like any new skill.")
        }
    }

    private var skillsHeadline: String {
        let scoped = projectSkills
        let total = scoped.skills.count
        guard !scoped.unused.isEmpty else { return "\(total)" }
        return "\(total) · \(scoped.unused.count) unused"
    }

    private func toggleSkills(_ product: Product) {
        skillsExpanded.toggle()
        guard skillsExpanded, !skills.loaded, !loadingSkills else { return }
        Task { await loadSkills(product) }
    }

    private func loadSkills(_ product: Product) async {
        loadingSkills = true
        skills = await model.skillInventory(fast: true)
        let counted = await model.skillInventory(fast: false)
        if counted.loaded { skills = counted }
        loadingSkills = false
    }

    private func removeSkill(_ skill: InstalledSkill, _ product: Product) async {
        busySkill = skill.id; skillFailure = nil
        let r = await model.removeSkill(skill, productID: product.id)
        busySkill = nil
        if !r.ok { skillFailure = r.message }
        await loadSkills(product)
    }

    private func updateSkill(_ skill: InstalledSkill, _ product: Product) async {
        busySkill = skill.id; skillFailure = nil
        let r = await model.updateSkill(skill, productID: product.id)
        busySkill = nil
        if !r.ok { skillFailure = r.message }
        await loadSkills(product)
    }

    // MARK: - Changes

    private var changes: some View {
        VStack(alignment: .leading, spacing: 0) {
            PanelTitle("Changes") {
                CountBadge(count: snapshot.changeCount)
            }
            PanelCard {
                VStack(spacing: 0) {
                    ForEach(Array(snapshot.changedProjects.enumerated()), id: \.element.id) { projectIndex, project in
                        if projectIndex > 0 { Hairline(color: Palette.lineStrong) }
                        if snapshot.changedProjects.count > 1 {
                            ChangeProjectHeader(project: project)
                            Hairline()
                        }
                        ForEach(Array(project.changes.prefix(20).enumerated()), id: \.element.id) { index, change in
                            if index > 0 { Hairline() }
                            Button {
                                selectedChange = SelectedChange(project: project, change: change)
                            } label: {
                                ChangeRow(change: change)
                            }
                            .buttonStyle(.row(radius: 0))
                        }
                        if project.changes.count > 20 {
                            Hairline()
                            Text(String(format: String(localized: "%lld more files"), project.changes.count - 20))
                                .font(Typo.panelMeta)
                                .foregroundStyle(Palette.textFaint)
                                .padding(.horizontal, 11)
                                .padding(.vertical, 8)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
            }
        }
    }

    // MARK: - Verification

    private func shouldShow(_ evidence: Evidence) -> Bool {
        evidence.overallStatus != .unknown || !evidence.criteria.isEmpty
    }

    private func verification(_ evidence: Evidence) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            PanelTitle("Verification") {
                StatusDot(color: criterionTint(evidence.overallStatus), size: 5)
            }
            PanelCard {
                VStack(spacing: 0) {
                    HStack(spacing: 8) {
                        Image(systemName: statusSymbol(evidence.overallStatus))
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(criterionTint(evidence.overallStatus))
                            .frame(width: 16)
                        Text(verificationHeadline(evidence))
                            .font(Typo.panelRow)
                            .foregroundStyle(Palette.textSecondary)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 9)

                    ForEach(evidence.criteria) { criterion in
                        Hairline()
                        HStack(alignment: .top, spacing: 8) {
                            Image(systemName: statusSymbol(criterion.status))
                                .font(.system(size: 9, weight: .semibold))
                                .foregroundStyle(criterionTint(criterion.status))
                                .frame(width: 16, height: 16)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(criterion.criterion)
                                    .font(Typo.panelRow)
                                    .foregroundStyle(Palette.textSecondary)
                                    .lineLimit(2)
                                if !criterion.note.isEmpty {
                                    Text(criterion.note)
                                        .font(Typo.panelMeta)
                                        .foregroundStyle(Palette.textFaint)
                                        .lineLimit(3)
                                }
                            }
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 8)
                    }
                }
            }
        }
    }

    private func verificationHeadline(_ evidence: Evidence) -> LocalizedStringKey {
        switch evidence.overallStatus {
        case .pass: "All checks passed"
        case .fail: "Checks need attention"
        case .inconclusive: "Checks are inconclusive"
        case .skipped: "Checks were skipped"
        case .unknown: "Verification result"
        }
    }

    private func statusSymbol(_ status: CriterionStatus) -> String {
        switch status {
        case .pass: "checkmark.circle.fill"
        case .fail: "xmark.circle.fill"
        case .inconclusive: "questionmark.circle.fill"
        case .skipped: "minus.circle.fill"
        case .unknown: "circle.dotted"
        }
    }

    private func criterionTint(_ status: CriterionStatus) -> Color {
        switch status {
        case .pass: Palette.green
        case .fail: Palette.red
        case .inconclusive: Palette.orange
        case .skipped, .unknown: Palette.textFaint
        }
    }

    // MARK: - Reports

    private func reports(_ chat: Chat) -> some View {
        let paths = chat.session?.reportPaths ?? []
        let generating = model.generatingChatReportIDs.contains(chat.id)
        let suggested = model.shouldOfferReport(for: chat.id)

        return VStack(alignment: .leading, spacing: 0) {
            PanelTitle("Reports") {
                if suggested { StatusDot(color: Palette.accentEmphasis, size: 5) }
                if !paths.isEmpty { CountBadge(count: paths.count) }
            }
            PanelCard {
                VStack(spacing: 0) {
                    Button { model.generateChatReport(chatID: chat.id) } label: {
                        HStack(alignment: .top, spacing: 9) {
                            if generating {
                                ProgressView()
                                    .controlSize(.small)
                                    .frame(width: 18, height: 18)
                            } else {
                                Image(systemName: "doc.badge.plus")
                                    .font(.system(size: 11, weight: .medium))
                                    .foregroundStyle(Palette.accentEmphasis)
                                    .frame(width: 18, height: 18)
                            }
                            VStack(alignment: .leading, spacing: 2) {
                                Text(generating ? String(localized: "Preparing…")
                                                : String(localized: "Create report"))
                                    .font(Typo.panelRow)
                                    .foregroundStyle(Palette.textSecondary)
                                Text("It will be saved in the project’s artifacts folder and ignored by Git.")
                                    .font(Typo.panelMeta)
                                    .foregroundStyle(Palette.textFaint)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 9)
                    }
                    .buttonStyle(.row(radius: 0))
                    // A report is one more turn in the chat's session; an archived chat is read only.
                    .disabled(generating || chat.archived)

                    ForEach(Array(paths.reversed().enumerated()), id: \.element) { index, path in
                        Hairline()
                        Button { model.openChatReport(path: path, title: chat.title) } label: {
                            HStack(spacing: 9) {
                                Image(systemName: "doc.richtext")
                                    .font(.system(size: 11))
                                    .foregroundStyle(Palette.accentEmphasis)
                                    .frame(width: 18)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(index == 0 ? String(localized: "Latest report") : String(localized: "Report"))
                                        .font(Typo.panelRow)
                                        .foregroundStyle(Palette.textSecondary)
                                    Text((path as NSString).lastPathComponent)
                                        .font(Typo.panelMeta)
                                        .foregroundStyle(Palette.textFaint)
                                        .lineLimit(1)
                                }
                                Spacer(minLength: 4)
                                Image(systemName: "chevron.right")
                                    .font(.system(size: 9, weight: .semibold))
                                    .foregroundStyle(Palette.textFaint)
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 8)
                        }
                        .buttonStyle(.row(radius: 0))
                    }
                }
            }
        }
    }

    // MARK: - Instructions

    private func hasInstructions(_ product: Product) -> Bool {
        !product.summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !product.brief.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func instructions(_ product: Product) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            PanelTitle("Instructions")
            PanelCard {
                VStack(alignment: .leading, spacing: 8) {
                    if !product.summary.isEmpty {
                        Text(product.summary)
                            .font(Typo.panelRow)
                            .foregroundStyle(Palette.textSecondary)
                    }
                    if !product.summary.isEmpty, !product.brief.isEmpty { Hairline() }
                    if !product.brief.isEmpty {
                        Text(product.brief)
                            .font(Typo.caption)
                            .lineSpacing(3)
                            .foregroundStyle(Palette.textTertiary)
                    }
                }
                .fixedSize(horizontal: false, vertical: true)
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    // MARK: - File preview

    private func filePreview(_ selection: SelectedChange) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Button { selectedChange = nil } label: { Image(systemName: "chevron.left") }
                    .buttonStyle(.icon(size: 24, glyph: 11))
                    .help(Text("Back"))
                Text(selection.change.filename)
                    .font(Typo.panelRow)
                    .foregroundStyle(Palette.text)
                    .lineLimit(1)
                Spacer(minLength: 4)
                Button {
                    model.openInEditor(fileURL(selection).path)
                } label: { Image(systemName: "arrow.up.forward.app") }
                .buttonStyle(.icon(size: 24, glyph: 11))
                .help(Text("Open in editor"))
                Button { model.revealInFinder(fileURL(selection).path) } label: {
                    Image(systemName: "folder")
                }
                .buttonStyle(.icon(size: 24, glyph: 11))
                .help(Text("Reveal in Finder"))
            }
            .padding(.horizontal, 2)

            PanelCard {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 7) {
                        ChangeKindPill(change: selection.change)
                        if let added = selection.change.added {
                            Text(verbatim: "+\(added)").foregroundStyle(Palette.green)
                        }
                        if let removed = selection.change.removed {
                            Text(verbatim: "−\(removed)").foregroundStyle(Palette.red)
                        }
                        Spacer(minLength: 0)
                    }
                    .font(Typo.panelMeta)

                    Text(selection.change.path)
                        .font(Typo.panelMeta)
                        .foregroundStyle(Palette.textFaint)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)

                    if loadingDiff {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text("Loading diff…")
                                .font(Typo.caption)
                                .foregroundStyle(Palette.textTertiary)
                        }
                        .frame(maxWidth: .infinity, minHeight: 110)
                    } else if diffText.isEmpty {
                        Text("No textual diff is available for this file.")
                            .font(Typo.caption)
                            .foregroundStyle(Palette.textTertiary)
                            .frame(maxWidth: .infinity, minHeight: 90, alignment: .center)
                    } else {
                        ScrollView([.horizontal, .vertical]) {
                            Text(diffText)
                                .font(Typo.mono(9.5))
                                .foregroundStyle(Palette.onTerminal)
                                .textSelection(.enabled)
                                .fixedSize(horizontal: true, vertical: true)
                                .padding(10)
                        }
                        .frame(height: 310)
                        .background(Palette.terminal)
                        .clipShape(RoundedRectangle(cornerRadius: Metrics.radiusControl,
                                                    style: .continuous))
                    }
                }
                .padding(11)
            }

            Text(selection.project.project.name)
                .font(Typo.panelMeta)
                .foregroundStyle(Palette.textFaint)
                .padding(.horizontal, 6)
        }
    }

    private func fileURL(_ selection: SelectedChange) -> URL {
        URL(fileURLWithPath: selection.project.project.path, isDirectory: true)
            .appendingPathComponent(selection.change.path)
    }
}

// MARK: - Rows

private struct ResourceRow: View {
    @Environment(AppModel.self) private var model
    let item: AppModel.ResolvedResource
    let productID: UUID
    let isPrimary: Bool

    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: item.resource.kind.symbol)
                .font(.system(size: 11))
                .foregroundStyle(Palette.textFaint)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.resource.name)
                    .font(Typo.panelRow)
                    .foregroundStyle(Palette.textSecondary)
                    .lineLimit(1)
                HStack(spacing: 4) {
                    if item.isLive { PulseDot(color: Palette.green, size: 5) }
                    if isPrimary {
                        Text("Primary")
                            .font(Typo.panelMeta)
                            .foregroundStyle(Palette.textFaint)
                    }
                    if let branch = model.branch(forProjectID: item.project?.id) {
                        if isPrimary { Text("·").foregroundStyle(Palette.textFaint) }
                        Image(systemName: "arrow.triangle.branch")
                            .font(.system(size: 8.5))
                            .foregroundStyle(Palette.textFaint)
                        Text(branch)
                            .font(Typo.panelMeta)
                            .foregroundStyle(Palette.textFaint)
                            .lineLimit(1)
                            .truncationMode(.tail)
                            .help(Text(branch))
                    } else if !isPrimary {
                        Text(LocalizedStringKey(item.resource.kind.labelKey))
                            .font(Typo.panelMeta)
                            .foregroundStyle(Palette.textFaint)
                    }
                }
            }
            Spacer(minLength: 4)
            AccessLock(readOnly: item.resource.access.isReadOnly) { access in
                model.products.setAccess(access, resourceID: item.id, productID: productID)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .help(Text(item.project?.path ?? item.resource.urlString ?? item.resource.name))
        .contextMenu {
            Picker("Access", selection: Binding(
                get: { item.resource.access },
                set: { model.products.setAccess($0, resourceID: item.id, productID: productID) }
            )) {
                Text("Can edit").tag(ResourceAccess.workspace)
                Text("Ask before editing").tag(ResourceAccess.source)
            }
            if let project = item.project {
                Divider()
                Button("Reveal in Finder") { model.revealInFinder(project.path) }
                Button("Open in editor") { model.openInEditor(project.path) }
            }
            Divider()
            Button("Disconnect", role: .destructive) {
                model.products.removeResource(item.id, from: productID)
            }
        }
    }
}

private struct ChangeProjectHeader: View {
    let project: ChatProjectInspection

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "folder")
                .font(.system(size: 9))
                .foregroundStyle(Palette.textFaint)
            Text(project.project.name)
                .font(Typo.tag)
                .foregroundStyle(Palette.textTertiary)
                .lineLimit(1)
            Spacer(minLength: 4)
            if let branch = project.branch {
                Text(branch)
                    .font(Typo.panelMeta)
                    .foregroundStyle(Palette.textFaint)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(Palette.panelMuted.opacity(0.6))
    }
}

private struct ChangeRow: View {
    let change: ChatFileChange

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: symbol)
                .font(.system(size: 9.5, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 17)
            VStack(alignment: .leading, spacing: 2) {
                Text(change.filename)
                    .font(Typo.panelRow)
                    .foregroundStyle(Palette.textSecondary)
                    .lineLimit(1)
                Text(directory)
                    .font(Typo.panelMeta)
                    .foregroundStyle(Palette.textFaint)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 4)
            if let added = change.added, added > 0 {
                Text(verbatim: "+\(added)").foregroundStyle(Palette.green)
            }
            if let removed = change.removed, removed > 0 {
                Text(verbatim: "−\(removed)").foregroundStyle(Palette.red)
            }
            if change.added == nil, change.removed == nil {
                Text(LocalizedStringKey(change.kind.labelKey))
                    .foregroundStyle(Palette.textFaint)
            }
        }
        .font(Typo.panelMeta)
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .help(Text(change.path))
    }

    private var directory: String {
        let parent = (change.path as NSString).deletingLastPathComponent
        return parent.isEmpty ? String(localized: "Project root") : parent
    }

    private var symbol: String {
        switch change.kind {
        case .added, .untracked: "plus.circle.fill"
        case .modified, .typeChanged: "pencil.circle.fill"
        case .deleted: "minus.circle.fill"
        case .renamed: "arrow.right.circle.fill"
        case .copied: "doc.on.doc.fill"
        case .conflicted: "exclamationmark.triangle.fill"
        case .unknown: "circle.fill"
        }
    }

    private var tint: Color {
        switch change.kind {
        case .added, .untracked, .copied: Palette.green
        case .modified, .renamed, .typeChanged: Palette.orange
        case .deleted, .conflicted: Palette.red
        case .unknown: Palette.textFaint
        }
    }
}

private struct ChangeKindPill: View {
    let change: ChatFileChange

    var body: some View {
        Text(LocalizedStringKey(change.kind.labelKey))
            .font(Typo.tag)
            .foregroundStyle(change.kind == .conflicted ? Palette.red : Palette.textSecondary)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(Capsule().fill(change.kind == .conflicted ? Palette.redSoft : Palette.panelRaised))
    }
}

private struct SelectedChange: Identifiable, Equatable {
    let project: ChatProjectInspection
    let change: ChatFileChange
    var id: String { project.project.path + "\u{0}" + change.path }
}

struct SkillsPanelBody: View {
    let inventory: SkillInventory

    var showsScope: Bool = false
    var loading: Bool = false
    var busySkill: String?
    var failure: String?
    var onRemove: (InstalledSkill) -> Void = { _ in }
    var onUpdate: (InstalledSkill) -> Void = { _ in }

    static func plainMessage(_ text: String) -> String {
        var s = text.trimmingCharacters(in: .whitespacesAndNewlines)
        for glyph in ["❌", "⚠️", "🚫", "⏸", "🗑"] where s.hasPrefix(glyph) {
            s = String(s.dropFirst(glyph.count)).trimmingCharacters(in: .whitespaces)
        }
        return s
    }

    var body: some View {
        PanelCard {
            VStack(spacing: 0) {
                if let failure, !failure.isEmpty {

                    HStack(alignment: .top, spacing: 7) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 10))
                            .foregroundStyle(Palette.orange)
                        Text(Self.plainMessage(failure))
                            .font(Typo.panelMeta)
                            .foregroundStyle(Palette.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .background(Palette.orange.opacity(0.10))
                    Hairline()
                }
                if loading && !inventory.loaded {

                    HStack(spacing: 8) {
                        ProgressView().controlSize(.mini)
                        Text("Reading how much each one gets used…")
                            .font(Typo.caption)
                            .foregroundStyle(Palette.textTertiary)
                    }
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                } else if inventory.loaded && inventory.skills.isEmpty {
                    Text("Nothing installed for this product yet. Bulava adds one when a project turns out to need it.")
                        .font(Typo.caption)
                        .foregroundStyle(Palette.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    ForEach(Array(inventory.skills.enumerated()), id: \.element.id) { index, skill in
                        if index > 0 { Hairline() }
                        SkillRow(skill: skill, busy: busySkill == skill.id,
                                 counted: inventory.counted, showsScope: showsScope,
                                 onRemove: { onRemove(skill) }, onUpdate: { onUpdate(skill) })
                    }
                    if inventory.counted, inventory.transcriptsScanned > 0,
                       inventory.skills.contains(where: { $0.uses == 0 }) {
                        Hairline()

                        Text("“Never used” means no record of use in \(inventory.transcriptsScanned) transcripts, not proof it is useless.")
                            .font(Typo.panelMeta)
                            .foregroundStyle(Palette.textFaint)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 8)
                    }
                }
            }
        }
    }
}

struct SkillRow: View {
    let skill: InstalledSkill
    let busy: Bool

    var counted: Bool = true

    var showsScope: Bool = true
    let onRemove: () -> Void
    let onUpdate: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: glyph)
                .font(.system(size: 11))
                .foregroundStyle(unusedTint.opacity(counted && skill.uses == 0 ? 0.75 : 1))
                .frame(width: 18, height: 15, alignment: .center)
            VStack(alignment: .leading, spacing: 2) {
                Text(skill.name)
                    .font(Typo.panelRow)
                    .foregroundStyle(Palette.textSecondary)
                    .lineLimit(1)
                if !skill.description.isEmpty {

                    Text(skill.description)
                        .font(Typo.panelMeta)
                        .foregroundStyle(Palette.textTertiary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                HStack(spacing: 4) {
                    if showsScope {
                        Text(scopeLabel)
                            .font(Typo.panelMeta)
                            .foregroundStyle(Palette.textFaint)
                        Text("·").foregroundStyle(Palette.textFaint)
                    }
                    Text(usageLabel)
                        .font(Typo.panelMeta)
                        .foregroundStyle(unusedTint)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 4)
            if busy {
                ProgressView().controlSize(.mini).frame(width: 20, height: 20)
            } else {
                if skill.canUpdate {
                    Button(action: onUpdate) { Image(systemName: "arrow.triangle.2.circlepath") }
                        .buttonStyle(.icon(size: 20, glyph: 10))
                        .help(Text("Update from its source — re-audited like a new skill"))
                }
                if skill.canRemove {
                    Button(action: onRemove) { Image(systemName: "trash") }
                        .buttonStyle(.icon(size: 20, glyph: 10))
                        .help(Text("Delete this skill"))
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .help(Text(tooltip))
    }

    private static func compact(_ n: Int) -> String {
        n >= 1000 ? String(format: "%.1fk", Double(n) / 1000) : "\(n)"
    }

    private var tooltip: String {
        var parts: [String] = [skill.name]
        if skill.uses == 0, skill.frontmatterSize > 0 {
            parts.append(String(format: String(localized: "%@ chars of context every session"),
                                "\(skill.frontmatterSize)"))
        }
        if let source = skill.source, !source.isEmpty { parts.append(source) }
        return parts.joined(separator: "\n")
    }

    private var glyph: String {
        switch skill.scope {
        case .project: "folder"
        case .global:  "globe"
        case .plugin:  "shippingbox"
        }
    }

    private var scopeLabel: LocalizedStringKey {
        switch skill.scope {
        case .project: "this product"
        case .global:  "everywhere"
        case .plugin:  "from a plugin"
        }
    }

    private var unusedTint: Color {
        (counted && skill.uses == 0) ? Palette.orange : Palette.textFaint
    }

    var usageLabelForTesting: String { usageLabel }

    private var usageLabel: String {
        guard counted else { return String(localized: "counting uses…") }

        // When the count is for ONE project, that is the number he is actually asking about, and
        // the machine-wide total goes beside it as context rather than instead of it.
        if let here = skill.usesHere {
            if here == 0 {
                let elsewhere = skill.uses
                return elsewhere > 0
                    ? String(format: String(localized: "not used here · %@ elsewhere"),
                             Self.compact(elsewhere))
                    : String(localized: "never used anywhere")
            }
            let mine = Fmt.count("%lld uses here", here)
            if let last = skill.lastUsedHere, !last.isEmpty { return "\(mine) · \(last)" }
            return mine
        }

        if skill.uses == 0 {
            let cost = skill.frontmatterSize
            return cost > 0
                ? String(format: String(localized: "never used · %@"), Self.compact(cost))
                : String(localized: "never used")
        }
        let uses = Fmt.count("%lld uses", skill.uses)
        guard let last = skill.lastUsed, !last.isEmpty else { return uses }
        return "\(uses) · \(last)"
    }
}

enum SkillRowProbe {
    static func usageLabel(_ skill: InstalledSkill, counted: Bool) -> String {
        SkillRow(skill: skill, busy: false, counted: counted,
                 onRemove: {}, onUpdate: {}).usageLabelForTesting
    }
}

// MARK: - A folder that turned out to be a workspace

/// Sits under the resource it is about, in the panel that already lists the product's folders:
/// the offer belongs next to the thing it would change, not in a banner over the whole screen.
private struct WorkspaceRow: View {
    let workspace: FolderConnection
    let folderName: String
    let onConnect: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(String(format: String(localized: "%1$@ is a folder holding %2$@. A run cannot start in it — Bulava does not lay a repository over other people's repositories."),
                        folderName,
                        String(format: String(localized: "%lld repositories"), workspace.folders.count)))
                .font(Typo.panelMeta)
                .foregroundStyle(Palette.textTertiary)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 2) {
                ForEach(workspace.folders.prefix(6)) { folder in
                    Text(folder.name)
                        .font(Typo.panelMeta)
                        .foregroundStyle(Palette.textFaint)
                        .lineLimit(1)
                        .truncationMode(.head)
                }
                if workspace.folders.count > 6 {
                    Text(String(format: String(localized: "and %lld more"), workspace.folders.count - 6))
                        .font(Typo.panelMeta)
                        .foregroundStyle(Palette.textFaint)
                }
            }

            if !workspace.complete {
                Text("Could not look through all of it, so there may be more.")
                    .font(Typo.panelMeta)
                    .foregroundStyle(Palette.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: 6) {
                Button(action: onConnect) { Text("Connect them separately") }
                    .buttonStyle(.bulava(.primary))
                Text("The folder stays on disk, untouched.")
                    .font(Typo.panelMeta)
                    .foregroundStyle(Palette.textFaint)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Palette.orangeSoft)
    }
}
