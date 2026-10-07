import SwiftUI
import AppKit

// MARK: - Bringing one in

/// Import from GitHub: an address, then what the download turned out to be — and only then the
/// choice to add it. Nothing is added by pasting.
struct PipelineImportSheet: View {
    @Environment(AppModel.self) private var model
    let close: () -> Void

    private enum Stage: Equatable {
        case address
        case fetching
        case preview(PipelineImportPreview)
        case installing(PipelineImportPreview)
    }

    @State private var stage: Stage = .address
    @State private var source = ""
    @State private var subfolder = ""
    @State private var candidates: [String] = []
    @State private var failure: String?
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Import a pipeline").font(Typo.cardTitle).foregroundStyle(Palette.text)
                Text("From a GitHub repository somebody shared. It is downloaded into a quarantine, every prompt is read by the audit, and it arrives switched off until you have read it.")
                    .font(Typo.caption)
                    .foregroundStyle(Palette.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(20)
            Hairline()
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    content
                    if let failure {
                        Text(verbatim: failure)
                            .font(Typo.caption)
                            .foregroundStyle(Palette.red)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            Hairline()
            buttons.padding(16)
        }
        .frame(width: 520, height: 520)
        .background(Palette.panel)
    }

    @ViewBuilder private var content: some View {
        switch stage {
        case .address:
            VStack(alignment: .leading, spacing: 6) {
                Text("Repository").font(Typo.meta).foregroundStyle(Palette.textTertiary)
                TextField("owner/repository or https://github.com/…", text: $source)
                    .textFieldStyle(.roundedBorder)
                    .focused($focused)
                    .onSubmit(fetch)
                Text("Folder inside it, if it holds several").font(Typo.meta).foregroundStyle(Palette.textTertiary)
                    .padding(.top, 6)
                TextField(String("pipelines/research"), text: $subfolder)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(fetch)
            }
            .onAppear { focused = true }
            if !candidates.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("This repository holds several. Which one?")
                        .font(Typo.caption).foregroundStyle(Palette.textSecondary)
                    ForEach(candidates, id: \.self) { c in
                        Button { subfolder = c; fetch() } label: {
                            HStack {
                                Image(systemName: "folder")
                                Text(verbatim: c)
                                Spacer()
                            }
                            .font(Typo.panelRow)
                            .padding(.horizontal, 8)
                            .frame(height: 28)
                        }
                        .buttonStyle(.row())
                    }
                }
            }
        case .fetching:
            HStack(spacing: 10) {
                ProgressView().controlSize(.small)
                Text("Downloading and reading every prompt. When Codex is here it reads them too, which can take a minute or two.")
                    .font(Typo.caption)
                    .foregroundStyle(Palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        case .preview(let p), .installing(let p):
            ImportPreviewBody(preview: p)
        }
    }

    @ViewBuilder private var buttons: some View {
        HStack {
            Spacer()
            Button("Cancel") { cancel() }
                .buttonStyle(.bulava(.secondary))
                .keyboardShortcut(.cancelAction)
            switch stage {
            case .address, .fetching:
                Button("Download and check") { fetch() }
                    .buttonStyle(.bulava(.primary))
                    .keyboardShortcut(.defaultAction)
                    .disabled(stage == .fetching || source.trimmingCharacters(in: .whitespaces).isEmpty)
            case .preview(let p):
                Button("Add to my pipelines") { install(p) }
                    .buttonStyle(.bulava(.primary))
                    .keyboardShortcut(.defaultAction)
                    .disabled(p.rejected)
            case .installing:
                ProgressView().controlSize(.small)
            }
        }
    }

    private func fetch() {
        let src = source.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !src.isEmpty, stage != .fetching else { return }
        failure = nil
        candidates = []
        stage = .fetching
        Task {
            let result = await model.fetchPipelineForImport(src, path: subfolder.trimmingCharacters(in: .whitespacesAndNewlines))
            switch result {
            case .success(let p):
                stage = .preview(p)
            case .failure(let f):
                stage = .address
                switch f {
                case .badAddress: failure = String(localized: "That is not an address I can read. Use owner/repository or a github.com link.")
                case .notFound: failure = String(localized: "There is no pipeline.json there.")
                case .several(let list): candidates = list
                case .download(let why): failure = String(localized: "Could not download it: \(why)")
                case .rejected: failure = String(localized: "The audit rejected it.")
                case .other(let why): failure = why
                }
            }
        }
    }

    private func install(_ p: PipelineImportPreview) {
        stage = .installing(p)
        Task {
            switch await model.installImportedPipeline(p) {
            case .success(let id):
                close()
                model.openPipeline(id)
            case .failure(let f):
                stage = .preview(p)
                failure = f == .rejected ? String(localized: "The audit rejected it, so it cannot be added.")
                    : { if case .other(let w) = f { return w }; return String(localized: "It could not be added.") }()
            }
        }
    }

    private func cancel() {
        if case .preview(let p) = stage { Task { await model.discardImport(p) } }
        close()
    }
}

private struct ImportPreviewBody: View {
    let preview: PipelineImportPreview

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text(verbatim: preview.document.name).font(Typo.rowLabel).foregroundStyle(Palette.text)
                if !preview.document.localizedDescription.isEmpty {
                    Text(verbatim: preview.document.localizedDescription)
                        .font(Typo.caption).foregroundStyle(Palette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Text(verbatim: originLine)
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundStyle(Palette.textFaint)
                    .textSelection(.enabled)
            }

            verdictBlock

            if !preview.document.nodes.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Eyebrow("Steps")
                    Text(verbatim: preview.document.topologicalOrder().order
                        .compactMap { preview.document.node($0) }
                        .map { $0.title?.isEmpty == false ? $0.title! : $0.key }
                        .joined(separator: " → "))
                        .font(Typo.caption).foregroundStyle(Palette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            if !preview.skills.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Eyebrow("Skills it requires")
                    Text(verbatim: preview.skills.joined(separator: ", "))
                        .font(Typo.caption).foregroundStyle(Palette.textSecondary)
                }
            }
            if !preview.validation.issues.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Eyebrow("What the validator says")
                    ForEach(preview.validation.issues) { issue in
                        Label { Text(verbatim: issue.msg.local) } icon: {
                            Image(systemName: issue.isError ? "xmark.octagon" : "exclamationmark.triangle")
                        }
                        .font(Typo.caption)
                        .foregroundStyle(issue.isError ? Palette.red : Palette.orange)
                    }
                }
            }
            if !preview.ignored.isEmpty {
                Text(String(localized: "Left behind, because a pipeline is only data: \(preview.ignored.joined(separator: ", "))"))
                    .font(Typo.caption).foregroundStyle(Palette.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var originLine: String {
        var parts: [String] = []
        if let repo = preview.repo { parts.append(repo) }
        if let path = preview.path, !path.isEmpty { parts.append(path) }
        if let sha = preview.sha, !sha.isEmpty { parts.append("@" + sha.prefix(10)) }
        return parts.joined(separator: " ")
    }

    @ViewBuilder private var verdictBlock: some View {
        let (tint, wash, title): (Color, Color, String) = {
            switch preview.verdict {
            case "PASS": (Palette.green, Palette.greenSoft, String(localized: "The audit found nothing wrong"))
            case "REJECT": (Palette.red, Palette.redSoft, String(localized: "Rejected by the audit"))
            default: (Palette.orange, Palette.orangeSoft, String(localized: "Read the prompts before you switch it on"))
            }
        }()
        VStack(alignment: .leading, spacing: 5) {
            Text(verbatim: title).font(Typo.panelRow).foregroundStyle(tint)
            ForEach(preview.findings, id: \.self) { f in
                Text(verbatim: "· " + f).font(Typo.caption).foregroundStyle(Palette.textSecondary)
            }
            if preview.reviewVerdict == "SKIP" {
                Text("Codex did not read it: it is not available here. Only the static audit ran.")
                    .font(Typo.caption).foregroundStyle(Palette.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            } else if !preview.reviewNotes.isEmpty {
                Text(verbatim: preview.reviewNotes)
                    .font(Typo.caption).foregroundStyle(Palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: Metrics.radiusChip, style: .continuous).fill(wash))
    }
}

// MARK: - Putting one out

struct PipelineExportSheet: View {
    @Environment(AppModel.self) private var model
    let summary: PipelineSummary
    let close: () -> Void

    @State private var repository = ""
    @State private var isPrivate = false
    @State private var busy = false
    @State private var result: String?
    @State private var failure: String?
    @State private var published: URL?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Share “\(summary.displayName)”").font(Typo.cardTitle).foregroundStyle(Palette.text)
                Text("What leaves: the steps, their settings and prompts, and a readme. Your home folder in any path becomes ~, and a prompt that looks like it holds a key stops the export.")
                    .font(Typo.caption).foregroundStyle(Palette.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(alignment: .leading, spacing: 8) {
                Eyebrow("To a folder")
                Button { saveToFolder() } label: { Label("Save to a folder…", systemImage: "folder") }
                    .buttonStyle(.bulava(.secondary))
                    .disabled(busy)
            }

            Hairline()

            VStack(alignment: .leading, spacing: 8) {
                Eyebrow("To GitHub")
                Text("Creates a new repository under your GitHub account and pushes the pipeline to it. Uses the GitHub CLI you are signed in to.")
                    .font(Typo.caption).foregroundStyle(Palette.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 8) {
                    TextField("repository-name", text: $repository)
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 240)
                    Toggle("Private", isOn: $isPrivate)
                        .toggleStyle(.checkbox)
                        .font(Typo.caption)
                }
                Button { publish() } label: {
                    Label(isPrivate ? "Publish as a private repository" : "Publish as a public repository",
                          systemImage: "arrow.up.forward.app")
                }
                .buttonStyle(.bulava(.primary))
                .disabled(busy || !validRepository)
            }

            if busy { ProgressView().controlSize(.small) }
            if let result {
                Text(verbatim: result).font(Typo.caption).foregroundStyle(Palette.green)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
            if let published {
                Button { NSWorkspace.shared.open(published) } label: { Text(verbatim: published.absoluteString) }
                    .buttonStyle(.plain)
                    .foregroundStyle(Palette.accent)
                    .font(Typo.caption)
            }
            if let failure {
                Text(verbatim: failure).font(Typo.caption).foregroundStyle(Palette.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Spacer()
                Button("Done", action: close)
                    .buttonStyle(.bulava(.secondary))
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(20)
        .frame(width: 480)
        .background(Palette.panel)
        .onAppear { repository = "bulava-pipeline-" + summary.id }
    }

    private var validRepository: Bool {
        let r = repository.trimmingCharacters(in: .whitespaces)
        return !r.isEmpty && r.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || "-_.".contains($0)) }
    }

    private func saveToFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = String(localized: "Export here")
        panel.message = String(localized: "The pipeline is written into a new folder named after it.")
        guard panel.runModal() == .OK, let folder = panel.url else { return }
        busy = true; failure = nil; result = nil
        Task {
            switch await model.exportPipeline(summary.id, to: folder) {
            case .success(let dir):
                result = String(localized: "Saved to \(dir.path)")
                NSWorkspace.shared.activateFileViewerSelecting([dir])
            case .failure(let e):
                failure = e.text
            }
            busy = false
        }
    }

    private func publish() {
        busy = true; failure = nil; result = nil; published = nil
        Task {
            switch await model.publishPipeline(summary.id, repository: repository.trimmingCharacters(in: .whitespaces), isPrivate: isPrivate) {
            case .success(let url):
                published = url
                result = isPrivate
                    ? String(localized: "Published privately. People you give access to can import it in Bulava.")
                    : String(localized: "Published. Anyone with the link can import it in Bulava.")
            case .failure(let e):
                failure = e.text
            }
            busy = false
        }
    }
}
