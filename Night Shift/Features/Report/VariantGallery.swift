import SwiftUI

struct VariantGallery: View {
    @Environment(AppModel.self) private var model
    let item: WorkItem

    @State private var selected: UUID?

    private var tasks: [BacklogTask] { model.streamTasks(of: item) }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Hairline()
            if item.missingVariants > 0 { shortfallBanner }
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 280), spacing: 14)], spacing: 14) {
                    ForEach(Array(item.streams.enumerated()), id: \.element.id) { index, stream in
                        VariantTile(item: item, stream: stream, number: index + 1)
                    }
                }
                .padding(24)
            }
        }
        .background(Palette.content)
    }

    private var toolbar: some View {
        HStack(spacing: 10) {
            Button { model.variantGalleryItemID = nil } label: { Image(systemName: "xmark") }
                .buttonStyle(.icon)
                .keyboardShortcut(.escape, modifiers: [])

            VStack(alignment: .leading, spacing: 1) {
                Eyebrow("Variants")
                Text(item.title)
                    .font(Typo.cardTitle)
                    .foregroundStyle(Palette.text)
                    .lineLimit(1)
            }
            Spacer(minLength: 12)

            VStack(alignment: .trailing, spacing: 1) {
                Text(String(format: String(localized: "%lld of %lld finished"), finishedCount, item.streams.count))
                    .font(Typo.meta)
                    .foregroundStyle(Palette.textFaint)
                if failedCount > 0 {
                    Text(String(format: String(localized: "%lld failed"), failedCount))
                        .font(Typo.panelMeta)
                        .foregroundStyle(Palette.red)
                }
            }
        }
        .padding(.leading, 84)
        .padding(.trailing, 16)
        .padding(.vertical, 11)
        .background(Palette.chrome)
    }

    private var finishedCount: Int { model.deliveredStreamCount(item) }
    private var failedCount: Int { model.failedStreamCount(item) }

    private var shortfallBanner: some View {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: "exclamationmark.circle.fill")
                .font(.system(size: 11))
                .foregroundStyle(Palette.orange)
            Text(String(format: String(localized: "You asked for %lld — %lld were shaped and are shown here. The rest were never started."),
                        item.requestedVariants ?? item.streams.count, item.streams.count))
                .font(Typo.caption)
                .foregroundStyle(Palette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 11)
        .background(Palette.orangeSoft)
        .overlay(alignment: .bottom) { Hairline() }
    }
}

// MARK: - Tile

private struct VariantTile: View {
    @Environment(AppModel.self) private var model
    let item: WorkItem
    let stream: WorkItem.Stream
    let number: Int

    @State private var manifest: ReportManifest?
    @State private var hovering = false

    private var task: BacklogTask? { model.backlog.task(id: stream.id) }
    private var state: WorkState? {
        task.map { model.workState(of: $0) }
    }

    var body: some View {
        Card(fill: hovering ? Palette.panelMuted : Palette.panel,
             border: hovering ? Palette.selectedBorder : Palette.line) {
            VStack(alignment: .leading, spacing: 0) {
                preview
                Hairline()
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 7) {
                        Text("\(number)")
                            .font(.system(size: 11, weight: .semibold))
                            .monospacedDigit()
                            .foregroundStyle(Palette.textFaint)
                            .frame(minWidth: 14)
                        Text(stream.title)
                            .font(Typo.panelRow)
                            .foregroundStyle(Palette.text)
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                    }
                    stateLine
                    actions
                }
                .padding(13)
            }
        }
        .onHover { h in withAnimation(Motion.hover) { hovering = h } }
        .task(id: stream.id) {
            guard let task else { return }
            manifest = await model.reportManifest(for: task)
        }
    }

    @ViewBuilder private var preview: some View {
        ZStack {
            Rectangle().fill(Palette.panelMuted)
            if let manifest, manifest.hasContent {
                VStack(spacing: 6) {
                    Image(systemName: manifest.format == .video ? "play.rectangle" : "photo.on.rectangle.angled")
                        .font(.system(size: 20, weight: .light))
                        .foregroundStyle(Palette.accentEmphasis)
                    Text(manifest.summary ?? stream.title)
                        .font(Typo.panelMeta)
                        .foregroundStyle(Palette.textTertiary)
                        .lineLimit(2)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 12)
                }
            } else {
                VStack(spacing: 6) {
                    Image(systemName: emptyGlyph)
                        .font(.system(size: 18, weight: .light))
                        .foregroundStyle(state == .failed ? Palette.red : Palette.textFaint)
                    Text(emptyLabel)
                        .font(Typo.panelMeta)
                        .foregroundStyle(state == .failed ? Palette.red : Palette.textFaint)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 12)
                }
            }
        }
        .frame(height: 132)
    }

    private var emptyGlyph: String {
        switch state {
        case .running: "hourglass"
        case .failed:  "xmark.octagon"
        default:       "square.dashed"
        }
    }

    private var emptyLabel: LocalizedStringKey {
        switch state {
        case .running: "still being built"
        case .failed:  "this direction did not work"
        default:       "nothing captured yet"
        }
    }

    private var stateLine: some View {
        HStack(spacing: 5) {
            Circle().fill(dot).frame(width: 5, height: 5)
            Text(LocalizedStringKey(state?.labelKey ?? "Planned"))
                .font(Typo.panelMeta)
                .foregroundStyle(Palette.textFaint)
        }
    }

    private var dot: Color {
        switch state {
        case .reportReady, .done: Palette.green
        case .running:            Palette.green
        case .failed:             Palette.red
        case .needsAnswer, .paused: Palette.orange
        default:                  Palette.textFaint
        }
    }

    @ViewBuilder private var actions: some View {
        if let task {
            HStack(spacing: 6) {

                if state == .reportReady || state == .done || manifest?.hasContent == true {
                    Button { model.openReport(task) } label: { Text("Open") }
                        .buttonStyle(.bulava(state == .failed ? .secondary : .primary))
                }
                Button { model.openTaskDetail(task) } label: { Text("Details") }
                    .buttonStyle(.bulava(.quiet))
                Spacer(minLength: 0)
            }
        }
    }
}
