import SwiftUI

/// Every pipeline a message can go through: the built-in ones, which cannot be changed, and his
/// own — copies he made, ones he described to the chat, ones he imported.
struct PipelineLibraryScreen: View {
    @Environment(AppModel.self) private var model
    @State private var loading = true
    @State private var naming: NamingRequest?
    @State private var pendingDelete: PipelineSummary?
    @State private var importing = false
    @State private var exporting: PipelineSummary?
    @State private var failure: String?

    private var builtin: [PipelineSummary] { model.pipelineLibrary.filter(\.isBuiltin) }
    private var own: [PipelineSummary] {
        model.pipelineLibrary.filter { !$0.isBuiltin }
            .sorted { ($0.updated ?? 0) > ($1.updated ?? 0) }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Hairline()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: Metrics.sectionGap) {
                    if let failure {
                        Text(verbatim: failure)
                            .font(Typo.caption)
                            .foregroundStyle(Palette.red)
                            .padding(.horizontal, 6)
                    }
                    section("Yours", own) { ownEmpty }
                    section("Built in", builtin) { EmptyView() }
                }
                .padding(18)
                .frame(maxWidth: 860, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .background(Palette.content)
        .task {
            await model.loadPipelineLibrary()
            loading = false
        }
        .sheet(item: $naming) { request in
            PipelineNameSheet(request: request) { name, wish in
                naming = nil
                Task { await finish(request, name: name, wish: wish) }
            } cancel: { naming = nil }
        }
        .sheet(isPresented: $importing) {
            PipelineImportSheet { importing = false }
        }
        .sheet(item: $exporting) { summary in
            PipelineExportSheet(summary: summary) { exporting = nil }
        }
        .confirmationDialog(Text("Delete “\(pendingDelete?.displayName ?? "")”?"),
                            isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
                            titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                if let target = pendingDelete {
                    pendingDelete = nil
                    Task { if !(await model.deletePipeline(target.id)) { failure = String(localized: "Could not delete it.") } }
                }
            }
            Button("Keep", role: .cancel) { pendingDelete = nil }
        } message: {
            Text("Chats and automations that used it go back to the default. A run already under way finishes on its own copy.")
        }
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text("Pipelines")
                    .screenTitleStyle()
                    .foregroundStyle(Palette.text)
                if loading {
                    ProgressView().controlSize(.small)
                }
                Spacer(minLength: 8)
                Button { importing = true } label: { Label("Import", systemImage: "square.and.arrow.down") }
                    .buttonStyle(.bulava(.secondary))
                Button { naming = .new } label: { Label("New pipeline", systemImage: "plus") }
                    .buttonStyle(.bulava(.primary))
                    .keyboardShortcut("n", modifiers: [.command, .option, .shift])
            }
            Text("What a message goes through before and after the worker has it. The built-in ones cannot be changed: duplicate one to make it yours.")
                .font(Typo.caption)
                .foregroundStyle(Palette.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 18)
        .padding(.top, 16)
        .padding(.bottom, 12)
    }

    private var ownEmpty: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Nothing of your own yet.")
                .font(Typo.rowLabel)
                .foregroundStyle(Palette.text)
            Text("Duplicate a built-in pipeline and change it, describe the one you need to the chat in its editor, or import one somebody shared on GitHub.")
                .font(Typo.caption)
                .foregroundStyle(Palette.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func section<Empty: View>(_ title: LocalizedStringKey, _ items: [PipelineSummary],
                                      @ViewBuilder empty: () -> Empty) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            PanelTitle(title)
            PanelCard {
                if items.isEmpty {
                    empty()
                } else {
                    VStack(spacing: 0) {
                        ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                            if index > 0 { Hairline() }
                            PipelineRow(summary: item,
                                        isDefault: model.pipelineID(forChat: nil) == item.id,
                                        uses: uses(of: item.id),
                                        duplicate: { naming = .duplicate(item) },
                                        export: { exporting = item },
                                        delete: { pendingDelete = item })
                        }
                    }
                }
            }
        }
    }

    private func uses(of id: String) -> Int {
        model.conversations.chats.filter { !$0.archived && $0.pipelineID == id }.count
            + model.automations.automations.filter { $0.pipelineID == id }.count
    }

    private func finish(_ request: NamingRequest, name: String, wish: String) async {
        let result: Result<String, PipelineToolError>
        switch request {
        case .new: result = await model.createPipeline(name: name)
        case .duplicate(let source): result = await model.duplicatePipeline(source.id, name: name)
        }
        switch result {
        case .success(let id):
            failure = nil
            if !wish.isEmpty { model.pendingPipelineRequests[id] = wish }
            model.openPipeline(id)
        case .failure(let error):
            failure = error.text
        }
    }
}

// MARK: - One row

private struct PipelineRow: View {
    @Environment(AppModel.self) private var model
    let summary: PipelineSummary
    let isDefault: Bool
    let uses: Int
    let duplicate: () -> Void
    let export: () -> Void
    let delete: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Button { model.openPipeline(summary.id) } label: {
                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 7) {
                        Text(verbatim: summary.displayName)
                            .font(Typo.rowLabel)
                            .foregroundStyle(Palette.text)
                        if isDefault { tag("Default", tint: Palette.accentEmphasis, wash: Palette.accentSoft) }
                        if summary.isImported { tag("Imported", tint: Palette.blue, wash: Palette.blueSoft) }
                        if summary.armed == false { tag("Off until you check it", tint: Palette.orange, wash: Palette.orangeSoft) }
                    }
                    if let d = summary.localizedDescription, !d.isEmpty {
                        Text(verbatim: d)
                            .font(Typo.caption)
                            .foregroundStyle(Palette.textSecondary)
                            .lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    HStack(spacing: 6) {
                        ForEach(summary.guarantees ?? []) { g in
                            Text(verbatim: g.t.local)
                                .font(Typo.panelMeta)
                                .foregroundStyle(g.tone == "ok" ? Palette.green : Palette.orange)
                                .padding(.horizontal, 6)
                                .frame(height: 17)
                                .background(Capsule(style: .continuous)
                                    .fill(g.tone == "ok" ? Palette.greenSoft : Palette.orangeSoft))
                        }
                    }
                    Text(verbatim: meta)
                        .font(Typo.panelMeta)
                        .foregroundStyle(problemCount > 0 || summary.broken != nil ? Palette.red : Palette.textFaint)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Menu {
                Button("Open") { model.openPipeline(summary.id) }
                Button("Make a copy…", action: duplicate)
                if !isDefault {
                    Button("Use for new chats") { model.settings.defaultPipelineID = summary.id == model.builtinChatPipeline ? nil : summary.id }
                }
                if !summary.isBuiltin {
                    Button("Share…", action: export)
                    Divider()
                    Button("Delete pipeline…", role: .destructive, action: delete)
                }
            } label: {
                Image(systemName: "ellipsis")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help(Text("More"))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }

    private var problemCount: Int { summary.errors ?? 0 }

    private var meta: String {
        if let broken = summary.broken { return String(localized: "Cannot be read: \(broken)") }
        var parts = [String(localized: "\(summary.nodes ?? 0) steps")]
        if problemCount > 0 { parts.append(String(localized: "\(problemCount) problems to fix before it can run")) }
        if uses > 0 { parts.append(String(localized: "used in \(uses) places")) }
        return parts.joined(separator: " · ")
    }

    private func tag(_ text: LocalizedStringKey, tint: Color, wash: Color) -> some View {
        Text(text)
            .font(Typo.tag)
            .textCase(.uppercase)
            .tracking(0.4)
            .foregroundStyle(tint)
            .padding(.horizontal, 6)
            .frame(height: 16)
            .background(Capsule(style: .continuous).fill(wash))
    }
}

// MARK: - Naming a new one

enum NamingRequest: Identifiable {
    case new
    case duplicate(PipelineSummary)

    var id: String {
        switch self {
        case .new: "new"
        case .duplicate(let s): "dup:" + s.id
        }
    }
}

struct PipelineNameSheet: View {
    let request: NamingRequest
    /// The name, and what he wants it to do — which the chat in the editor then builds.
    let done: (String, String) -> Void
    let cancel: () -> Void
    @State private var name = ""
    @State private var wish = ""
    @FocusState private var focused: Bool

    private var title: LocalizedStringKey {
        switch request {
        case .new: "New pipeline"
        case .duplicate: "Duplicate pipeline"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(title).font(Typo.cardTitle).foregroundStyle(Palette.text)
            VStack(alignment: .leading, spacing: 6) {
                Text("Name").font(Typo.meta).foregroundStyle(Palette.textTertiary)
                TextField("", text: $name)
                    .textFieldStyle(.roundedBorder)
                    .focused($focused)
                    .onSubmit(submit)
            }
            if case .new = request {
                VStack(alignment: .leading, spacing: 6) {
                    Text("What should it do? (optional)").font(Typo.meta).foregroundStyle(Palette.textTertiary)
                    TextEditor(text: $wish)
                        .font(Typo.body)
                        .frame(height: 84)
                        .scrollContentBackground(.hidden)
                        .padding(6)
                        .background(RoundedRectangle(cornerRadius: Metrics.radiusControl, style: .continuous).fill(Palette.field))
                        .overlay(RoundedRectangle(cornerRadius: Metrics.radiusControl, style: .continuous).strokeBorder(Palette.line, lineWidth: 1))
                    Text("Describe it in your own words and Bulava builds the steps. Leave it empty to start from the chat message alone.")
                        .font(Typo.caption)
                        .foregroundStyle(Palette.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            HStack {
                Spacer()
                Button("Cancel", action: cancel)
                    .buttonStyle(.bulava(.secondary))
                    .keyboardShortcut(.cancelAction)
                Button(action: submit) {
                    switch request {
                    case .new: Text("Create")
                    case .duplicate: Text("Duplicate")
                    }
                }
                .buttonStyle(.bulava(.primary))
                .keyboardShortcut(.defaultAction)
                .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 400)
        .background(Palette.panel)
        .onAppear {
            if case .duplicate(let s) = request {
                name = String(localized: "\(s.displayName) — copy")
            }
            focused = true
        }
    }

    private func submit() {
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return }
        done(clean, wish.trimmingCharacters(in: .whitespacesAndNewlines))
    }
}
