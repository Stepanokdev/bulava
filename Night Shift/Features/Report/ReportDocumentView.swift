import SwiftUI
import WebKit
import AppKit
import UniformTypeIdentifiers

struct ReportDocumentView: View {
    @Environment(AppModel.self) private var model
    let viewer: AppModel.ReportViewer

    @State private var web: WKWebView?
    @State private var exporting = false
    @State private var package: ReviewPackage?
    @State private var blocker: String?
    @State private var loading = true

    @State private var partID: UUID?

    private var item: WorkItem? { model.workItems.item(id: viewer.itemID) }
    private var parts: [BacklogTask] { item.map { model.deliveredParts(of: $0) } ?? [] }

    private var task: BacklogTask? {
        if let id = viewer.taskID { return model.backlog.task(id: id) }
        if let partID { return parts.first { $0.id == partID } }
        return parts.count == 1 ? parts.first : nil
    }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            if let blocker, !blocker.isEmpty { gateBanner(blocker) }
            ReportWebView(url: viewer.htmlURL) { web = $0 }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Palette.content)
        .task(id: viewer.htmlURL) { await load() }
        .task(id: task?.id) { await load() }
    }

    // MARK: - Toolbar

    private var toolbar: some View {
        HStack(spacing: 10) {
            Button { model.closeReport() } label: { Image(systemName: "xmark") }
                .buttonStyle(.icon)
                .keyboardShortcut(.escape, modifiers: [])
                .help(Text("Close"))

            VStack(alignment: .leading, spacing: 1) {
                Eyebrow(viewer.itemID != nil ? "One task · one report"
                                             : (viewer.isVideo ? "Recorded result" : "Result"))
                Text(viewer.title)

                    .accessibilityIdentifier("report-title")
                    .font(Typo.cardTitle)
                    .foregroundStyle(Palette.text)
                    .lineLimit(1)
            }

            Spacer(minLength: 12)

            if !viewer.isVideo {
                Button { exportPDF() } label: {
                    Text(exporting ? "Exporting…" : "Save as PDF")
                }
                .buttonStyle(.bulava(.quiet))
                .disabled(exporting || web == nil)
            }
            Button {
                NSWorkspace.shared.activateFileViewerSelecting([viewer.htmlURL.deletingLastPathComponent()])
            } label: { Image(systemName: "folder") }
                .buttonStyle(.icon)
                .help(Text("Reveal the report folder"))
            Button { NSWorkspace.shared.open(viewer.htmlURL) } label: {
                Image(systemName: "arrow.up.forward.app")
            }
            .buttonStyle(.icon)
            .help(Text("Open in a browser"))

            if let item, parts.count > 1 {
                Menu {
                    ForEach(parts) { part in
                        Button {
                            partID = part.id
                        } label: {
                            Text(model.partName(part, in: item)
                                 + (part.state == .merged ? " · " + String(localized: "accepted") : ""))
                        }
                    }
                } label: {
                    Text(task.map { t in
                        String(format: String(localized: "Part: %@"), model.partName(t, in: item))
                    } ?? String(localized: "Pick a part"))
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
            }

            if let task {
                ForEach(TaskPresentation.finalActions(for: task, package: package,
                                                      blocker: blocker, model: model)) { action in
                    Button {
                        action.perform(model)
                        if action.emphasis == .primary { model.closeReport() }
                    } label: {
                        Label { Text(action.titleKey) } icon: { Image(systemName: action.symbol) }
                            .labelStyle(.titleAndIcon)
                    }
                    .buttonStyle(.bulava(action.emphasis == .primary ? .primary : .secondary))
                    .disabled(action.disabledReason != nil)
                    .help(action.disabledReason.map { Text($0) } ?? Text(action.titleKey))
                }
            }
        }

        .padding(.leading, 84)
        .padding(.trailing, 16)
        .padding(.vertical, 11)
        .background(Palette.chrome)
        .overlay(alignment: .bottom) { Hairline() }
    }

    // MARK: - Gate

    private func gateBanner(_ reason: String) -> some View {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 11))
                .foregroundStyle(Palette.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text("Not ready to accept")
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(Palette.orange)
                Text(reason)
                    .font(Typo.caption)
                    .foregroundStyle(Palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            if let task {
                Button { model.verify(task: task) } label: { Text("Run the checks") }
                    .buttonStyle(.bulava())
                    .disabled(model.verifying.contains(task.id))
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 11)
        .background(Palette.orangeSoft)
        .overlay(alignment: .bottom) { Hairline() }
    }

    // MARK: - Loading

    private func load() async {
        guard let task else { loading = false; return }
        loading = true
        let loaded = await model.loadReview(for: task)
        package = loaded
        blocker = model.approvalBlocker(task: task, package: loaded)
        loading = false
    }

    // MARK: - PDF

    private func exportPDF() {
        guard let web else { return }
        exporting = true
        web.createPDF(configuration: WKPDFConfiguration()) { result in
            exporting = false
            guard case .success(let data) = result else {
                model.toast = ToastMessage(text: String(localized: "Could not render the PDF"), kind: .error)
                return
            }
            let panel = NSSavePanel()
            panel.allowedContentTypes = [.pdf]
            panel.nameFieldStringValue = "\(safeName(viewer.title)).pdf"
            guard panel.runModal() == .OK, let url = panel.url else { return }
            do {
                try data.write(to: url)
                model.toast = ToastMessage(text: String(localized: "Saved the PDF"), kind: .success)
            } catch {
                model.toast = ToastMessage(text: String(localized: "Could not save the PDF"), kind: .error)
            }
        }
    }

    private func safeName(_ s: String) -> String {
        let cleaned = s.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "/", with: "-")
        return cleaned.isEmpty ? "report" : String(cleaned.prefix(80))
    }
}
