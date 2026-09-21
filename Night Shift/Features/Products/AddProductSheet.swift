import SwiftUI
import UniformTypeIdentifiers

struct AddProductSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    let mode: ProductSheetMode

    @State private var name = ""
    @State private var brief = ""
    @State private var drafts: [DraftResource] = []
    @State private var dropTargeted = false
    @State private var scanning = 0
    @State private var expansions: [Expansion] = []
    @FocusState private var nameFocused: Bool

    private var target: Product? { model.products.product(id: mode.targetProductID) }
    private var isAddingToExisting: Bool { mode.targetProductID != nil }

    var body: some View {
        VStack(spacing: 0) {
            header
            Hairline()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if !isAddingToExisting { nameField; briefField }
                    resourceSection
                }
                .padding(18)
            }
            Hairline()
            footer
        }
        .frame(width: 520, height: 560)
        .background(Palette.content)
        .onAppear { if !isAddingToExisting { nameFocused = true } }
    }

    // MARK: - Header

    private var header: some View {
        HStack {
            Group {
                if isAddingToExisting {
                    Text("Add to \(target?.name ?? "")")
                } else {
                    Text("Add a product")
                }
            }
            .font(Typo.cardTitle)
            .foregroundStyle(Palette.text)
            Spacer()
            Button { dismiss() } label: { Image(systemName: "xmark") }
                .buttonStyle(.icon)
                .keyboardShortcut(.escape, modifiers: [])
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 13)
        .background(Palette.chrome)
    }

    // MARK: - Fields

    private var nameField: some View {
        VStack(alignment: .leading, spacing: 6) {
            Eyebrow("Name")
            TextField("For example, Narada", text: $name)
                .textFieldStyle(.plain)
                .font(Typo.body)
                .focused($nameFocused)
                .padding(.horizontal, 10)
                .frame(height: Metrics.fieldHeight)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Palette.field)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(Palette.lineStrong, lineWidth: 1)
                )
        }
    }

    private var briefField: some View {
        VStack(alignment: .leading, spacing: 6) {
            Eyebrow("What is it for")
            TextField("Goals, audience, anything Bulava should know before it starts",
                      text: $brief, axis: .vertical)
                .textFieldStyle(.plain)
                .font(Typo.body)
                .lineLimit(2...5)
                .padding(10)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Palette.field)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(Palette.lineStrong, lineWidth: 1)
                )
            Text("Sent at the start of every conversation about this product.")
                .font(Typo.panelMeta)
                .foregroundStyle(Palette.textFaint)
        }
    }

    // MARK: - Resources

    private var resourceSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Eyebrow("What it is made of")

            if !drafts.isEmpty {
                VStack(spacing: 0) {
                    ForEach($drafts) { $draft in
                        if draft.id != drafts.first?.id { Hairline() }
                        DraftRow(draft: $draft) {
                            drafts.removeAll { $0.id == draft.id }
                        }
                    }
                }
                .background(
                    RoundedRectangle(cornerRadius: Metrics.radiusPanel, style: .continuous)
                        .fill(Palette.panel)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: Metrics.radiusPanel, style: .continuous)
                        .strokeBorder(Palette.line, lineWidth: 1)
                )
            }

            dropZone
            if scanning > 0 { scanningNote }
            ForEach(expansions) { expansion in ExpansionNote(expansion: expansion) }
        }
    }

    private var scanningNote: some View {
        HStack(spacing: 6) {
            ProgressView().controlSize(.mini)
            Text("Looking at what is inside the folder…")
                .font(Typo.panelMeta)
                .foregroundStyle(Palette.textFaint)
        }
        .padding(.top, 2)
    }

    private var dropZone: some View {
        VStack(spacing: 7) {
            Image(systemName: "folder.badge.plus")
                .font(.system(size: 18, weight: .light))
                .foregroundStyle(dropTargeted ? Palette.accentEmphasis : Palette.textFaint)
            Text("Drop folders here, or choose them")
                .font(Typo.caption)
                .foregroundStyle(Palette.textTertiary)
            Button { _Concurrency.Task { await chooseFolders() } } label: { Text("Choose folders…") }
                .buttonStyle(.bulava())
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 20)
        .background(
            RoundedRectangle(cornerRadius: Metrics.radiusPanel, style: .continuous)
                .fill(dropTargeted ? Palette.accentSoft : Color.clear)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Metrics.radiusPanel, style: .continuous)
                .strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [4, 4]))
                .foregroundStyle(dropTargeted ? Palette.accent : Palette.lineStrong)
        )
        .animation(Motion.hover, value: dropTargeted)
        .onDrop(of: [UTType.fileURL], isTargeted: $dropTargeted) { providers in
            for provider in providers {
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    guard let url, url.isFileURL else { return }
                    _Concurrency.Task { @MainActor in await connect(path: url.path) }
                }
            }
            return true
        }
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: 8) {
            if !isAddingToExisting {
                Text("Connected folders can be changed by default. Mark anything shared as read-only.")
                    .font(Typo.panelMeta)
                    .foregroundStyle(Palette.textFaint)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            Button { dismiss() } label: { Text("Cancel") }
                .buttonStyle(.bulava(.quiet))
            Button { commit() } label: {
                Text(isAddingToExisting ? "Add" : "Create product")
            }
            .buttonStyle(.bulava(.primary))
            .disabled(!canCommit)
            .keyboardShortcut(.return, modifiers: .command)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private var canCommit: Bool {
        // Never while a folder is still being looked through: a workspace dropped a moment ago has
        // no repositories in the list yet, and confirming now would store the half of it that
        // happened to be ready and close the sheet on the rest.
        guard scanning == 0 else { return false }
        if isAddingToExisting { return !drafts.isEmpty }
        return !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    // MARK: - Actions

    private func chooseFolders() async {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.prompt = String(localized: "Connect")
        panel.message = String(localized: "Choose the folders this product is made of")
        guard panel.runModal() == .OK else { return }
        for url in panel.urls { await connect(path: url.path) }
    }

    /// Connect what the director actually picked.
    ///
    /// A folder holding repositories is a workspace, and its repositories are the projects. They
    /// are listed one by one here, exactly as if each had been chosen by hand — which is both what
    /// the director meant and the only shape the engine will run.
    private func connect(path: String) async {
        scanning += 1
        let connection = await WorkspaceScan.connection(for: path)
        scanning -= 1

        var added = 0
        for folder in connection.folders where !drafts.contains(where: { $0.path == folder.path }) {
            let kind = ProjectScanner.detect(path: folder.path).kind
            drafts.append(DraftResource(name: folder.name,
                                        path: folder.path,
                                        kind: kind == .unknown ? .folder : .repository,
                                        access: .workspace))
            added += 1
        }
        if connection.isExpansion {
            expansions.append(Expansion(container: connection.container ?? path,
                                        count: added,
                                        complete: connection.complete))
        }
        if name.isEmpty, !isAddingToExisting {
            // The workspace's own name, not the first repository's: it is the folder they picked.
            name = ((connection.container ?? connection.folders.first?.path ?? path) as NSString)
                .lastPathComponent
        }
    }

    /// Nothing is stored until the sheet is confirmed.
    ///
    /// Folders used to become `Project`s the moment they were dropped, so Cancel left them behind —
    /// harmless enough for one folder, and fifteen phantom projects once a workspace expands.
    private func commit() {
        let resources: [ProductResource] = drafts.map { draft in
            let project = model.projects.add(path: draft.path)
            model.enrichProjectGit(project.id)
            return ProductResource(name: draft.name, kind: draft.kind,
                                   access: draft.access, projectID: project.id)
        }
        if isAddingToExisting, let target {
            for resource in resources { model.products.addResource(resource, to: target.id) }
            model.toast = ToastMessage(
                text: String(format: String(localized: "Connected to %@"), target.name), kind: .success)
        } else {
            let product = model.products.add(name: name, resources: resources, brief: brief)
            model.open(product: product.id)
        }
        dismiss()
    }
}

// MARK: - What a workspace turned into

private struct Expansion: Identifiable {
    let id = UUID()
    var container: String
    var count: Int
    var complete: Bool
}

private struct ExpansionNote: View {
    let expansion: Expansion

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: "square.stack.3d.up")
                .font(.system(size: 10))
                .foregroundStyle(Palette.textFaint)
            VStack(alignment: .leading, spacing: 2) {
                Text(String(format: String(localized: "%1$@ holds %2$@ — connected each one on its own."),
                            (expansion.container as NSString).lastPathComponent,
                            String(format: String(localized: "%lld repositories"), expansion.count)))
                    .font(Typo.panelMeta)
                    .foregroundStyle(Palette.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
                if !expansion.complete {
                    Text("Could not look through all of it, so there may be more. Add the rest by hand.")
                        .font(Typo.panelMeta)
                        .foregroundStyle(Palette.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(.top, 2)
    }
}

// MARK: - Draft row

private struct DraftResource: Identifiable {
    let id = UUID()
    var name: String
    var path: String
    var kind: ResourceKind
    var access: ResourceAccess
}

private struct DraftRow: View {
    @Binding var draft: DraftResource
    let onRemove: () -> Void

    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: draft.kind.symbol)
                .font(.system(size: 11))
                .foregroundStyle(Palette.textFaint)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text(draft.name)
                    .font(Typo.panelRow)
                    .foregroundStyle(Palette.textSecondary)
                    .lineLimit(1)
                Text(displayPath)
                    .font(Typo.panelMeta)
                    .foregroundStyle(Palette.textFaint)
                    .lineLimit(1)
                    .truncationMode(.head)
            }
            Spacer(minLength: 6)
            Picker("", selection: $draft.access) {
                Text("Can edit").tag(ResourceAccess.workspace)
                Text("Ask before editing").tag(ResourceAccess.source)
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .frame(width: 108)
            Button(action: onRemove) { Image(systemName: "xmark") }
                .buttonStyle(.icon(size: 22, glyph: 9))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
    }

    private var displayPath: String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return draft.path.hasPrefix(home)
            ? "~" + draft.path.dropFirst(home.count)
            : draft.path
    }
}
