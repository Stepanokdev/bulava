import SwiftUI
import WebKit

struct ReportWebView: NSViewRepresentable {
    let url: URL

    var onMake: ((WKWebView) -> Void)? = nil

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        let web = WKWebView(frame: .zero, configuration: config)
        web.underPageBackgroundColor = .clear
        web.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())

        DispatchQueue.main.async { [onMake] in onMake?(web) }
        return web
    }

    func updateNSView(_ web: WKWebView, context: Context) {
        if web.url?.standardizedFileURL != url.standardizedFileURL {
            web.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
        }
    }
}

// MARK: - Inline preview

struct ReportSection: View {
    @Environment(AppModel.self) private var model
    let task: BacklogTask

    @State private var manifest: ReportManifest?
    @State private var loading = true
    private var preparing: Bool { model.preparingReport.contains(task.id) }

    var body: some View {

        VStack(alignment: .leading, spacing: 0) {
            Color.clear.frame(width: 0, height: 0)
            if let m = manifest {
                loaded(m)
            } else if !loading, task.wantsReport {

                pendingState
            }
        }
        .task(id: task.id) {
            loading = true
            manifest = await model.reportManifest(for: task)
            loading = false
        }
    }

    // MARK: Loaded

    private func loaded(_ m: ReportManifest) -> some View {
        Card {
            VStack(alignment: .leading, spacing: 0) {
                header(m)
                content(m)
                actionRow
            }
        }
    }

    private func header(_ m: ReportManifest) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 5) {
                Image(systemName: kindGlyph(m.format))
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(Palette.accentEmphasis)
                Eyebrow(kindEyebrow(m.format), color: Palette.accentEmphasis)
                Spacer(minLength: 0)
            }
            if let title = m.title, !title.isEmpty {
                Text(title)
                    .cardTitleStyle()
                    .foregroundStyle(Palette.text)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text("Result report")
                    .cardTitleStyle()
                    .foregroundStyle(Palette.text)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 15)
        .padding(.top, 14)
        .padding(.bottom, 12)
    }

    @ViewBuilder private func content(_ m: ReportManifest) -> some View {
        let items = m.format == .photos ? (m.items ?? []) : []
        let notes = m.format == .notes ? noteBody(m) : nil
        let hasVideo = m.format == .video && !(m.video ?? "").isEmpty
        let hasSummary = !(m.summary ?? "").isEmpty

        if hasSummary || notes != nil || !items.isEmpty || hasVideo {
            VStack(spacing: 0) {
                Hairline()
                VStack(alignment: .leading, spacing: 12) {
                    if let summary = m.summary, !summary.isEmpty {
                        Text(summary)
                            .font(Typo.body)
                            .lineSpacing(4)
                            .foregroundStyle(Palette.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    if let notes {
                        Text(notes)
                            .font(Typo.step)
                            .lineSpacing(4)
                            .foregroundStyle(Palette.textTertiary)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                        pair(item)
                    }
                    if hasVideo { videoChip(m) }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 15)
                .padding(.vertical, 12)
            }
        }
    }

    private var actionRow: some View {
        VStack(spacing: 0) {
            Hairline()
            HStack(spacing: 7) {
                Spacer(minLength: 0)
                Button { model.openReport(task) } label: {
                    Label {
                        Text(preparing ? "Opening…" : "Open full report")
                    } icon: {
                        Image(systemName: "rectangle.expand.vertical")
                    }
                    .labelStyle(.titleAndIcon)
                }
                .buttonStyle(.bulava(.primary))
                .disabled(preparing)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 9)
        }
    }

    // MARK: Before / after

    @ViewBuilder private func pair(_ item: ReportManifest.Item) -> some View {
        let shots = shots(for: item)
        if !shots.isEmpty {
            VStack(alignment: .leading, spacing: 7) {
                if let caption = item.caption, !caption.isEmpty {
                    Text(caption)
                        .font(Typo.meta)
                        .foregroundStyle(Palette.textFaint)
                        .fixedSize(horizontal: false, vertical: true)
                }
                HStack(alignment: .top, spacing: 10) {
                    ForEach(shots) { shot in
                        shotPanel(shot)
                    }
                }
            }
        }
    }

    private struct Shot: Identifiable {
        let id: Int
        let label: LocalizedStringKey
        let image: NSImage
    }

    private func shots(for item: ReportManifest.Item) -> [Shot] {
        var out: [Shot] = []
        if let img = image(item.before) { out.append(Shot(id: 0, label: "Before", image: img)) }
        if let img = image(item.after) { out.append(Shot(id: 1, label: "After", image: img)) }
        return out
    }

    private func image(_ name: String?) -> NSImage? {
        guard let name, !name.isEmpty else { return nil }
        let url = model.settings.paths.reportDir(task8: task.reportKey).appendingPathComponent(name)
        return NSImage(contentsOf: url)
    }

    private func shotPanel(_ shot: Shot) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                Eyebrow(shot.label)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 9)
            .frame(height: 22)

            Hairline()

            Image(nsImage: shot.image)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(maxWidth: .infinity)
                .frame(maxHeight: 340)
        }
        .frame(maxWidth: .infinity, alignment: .top)
        .background(
            RoundedRectangle(cornerRadius: Metrics.radiusPanel, style: .continuous)
                .fill(Palette.panelMuted)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Metrics.radiusPanel, style: .continuous)
                .strokeBorder(Palette.line, lineWidth: Metrics.hairline)
        )
        .clipShape(RoundedRectangle(cornerRadius: Metrics.radiusPanel, style: .continuous))
    }

    // MARK: Video

    private func videoChip(_ m: ReportManifest) -> some View {
        HStack(spacing: 10) {
            if let poster = image(m.poster) {
                Image(nsImage: poster)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: 54, height: 34)
                    .clipShape(RoundedRectangle(cornerRadius: Metrics.radiusChip, style: .continuous))
                    .overlay(
                        Image(systemName: "play.fill")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(Palette.onAccent)
                            .shadow(color: Palette.shadow(0.5), radius: 2, x: 0, y: 0)
                    )
            } else {
                Image(systemName: "play.rectangle")
                    .font(.system(size: 14))
                    .foregroundStyle(Palette.textSecondary)
                    .frame(width: 22)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text("Recorded demo")
                    .font(Typo.control)
                    .foregroundStyle(Palette.text)
                Text(m.video ?? "")
                    .font(Typo.meta)
                    .foregroundStyle(Palette.textFaint)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: Metrics.radiusPanel, style: .continuous)
                .fill(Palette.panelMuted)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Metrics.radiusPanel, style: .continuous)
                .strokeBorder(Palette.line, lineWidth: Metrics.hairline)
        )
    }

    // MARK: Pending

    private var pendingState: some View {
        HStack(alignment: .firstTextBaseline, spacing: 7) {
            Image(systemName: "camera.viewfinder")
                .font(.system(size: 11))
                .foregroundStyle(Palette.textFaint)
            Text("A result report was asked for — it appears here when the worker finishes.")
                .font(Typo.caption)
                .foregroundStyle(Palette.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 5)
    }

    // MARK: Labels

    private func kindEyebrow(_ f: ReportManifest.Format) -> LocalizedStringKey {
        switch f {
        case .video:  "Recorded demo"
        case .photos: "Before & after"
        case .notes:  "Written report"
        }
    }

    private func kindGlyph(_ f: ReportManifest.Format) -> String {
        switch f {
        case .video:  "play.rectangle"
        case .photos: "photo.on.rectangle"
        case .notes:  "doc.text"
        }
    }

    private func noteBody(_ m: ReportManifest) -> String? {
        guard let text = m.body, !text.isEmpty, text != m.summary else { return nil }
        return text
    }
}
