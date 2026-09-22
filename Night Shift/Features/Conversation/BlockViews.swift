import SwiftUI
import AppKit
import QuickLookUI
import UniformTypeIdentifiers

// MARK: - Stack

struct BlockStack: View {
    let blocks: [ConversationBlock]

    let artifactBase: URL

    /// The entry these blocks belong to. Find's anchors are keyed by entry AND block, because a
    /// block id is only unique inside the message it came from.
    var entryID: UUID? = nil
    var productID: UUID? = nil
    var chatID: UUID? = nil

    private var tracesOpen: Bool {
        blocks.contains { $0.id == AppModel.trailHeadBlockID }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Self.grouped(blocks.renderable)) { group in
                switch group.content {
                case .single(let block):
                    BlockView(block: block, artifactBase: artifactBase, entryID: entryID,
                              productID: productID, chatID: chatID)
                case .trace(let activities):
                    ActivityTrace(activities: activities, startsOpen: tracesOpen)
                }
            }
        }
        .frame(maxWidth: Metrics.readingWidth, alignment: .leading)
    }

    static func grouped(_ blocks: [ConversationBlock]) -> [Group] {
        var out: [Group] = []
        var run: [BlockActivity] = []

        func flush() {
            guard !run.isEmpty else { return }

            if run.count <= 2 {
                out += run.map { Group(id: $0.toolCallID, content: .single(.activity($0))) }
            } else {
                out.append(Group(id: "trace-" + (run.first?.toolCallID ?? ""), content: .trace(run)))
            }
            run = []
        }

        for block in blocks {
            if block.kind == .activity, let activity = block.activity {
                run.append(activity)
            } else {
                flush()
                out.append(Group(id: block.id, content: .single(block)))
            }
        }
        flush()
        return out
    }

    struct Group: Identifiable {
        enum Content {
            case single(ConversationBlock)
            case trace([BlockActivity])
        }
        let id: String
        let content: Content
    }
}

private struct ActivityTrace: View {
    let activities: [BlockActivity]
    @State private var expanded: Bool

    init(activities: [BlockActivity], startsOpen: Bool = false) {
        self.activities = activities
        _expanded = State(initialValue: startsOpen)
    }

    private var running: BlockActivity? { activities.last { $0.status == .running } }
    private var failures: Int { activities.filter { $0.status == .failed }.count }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let running {

                ActivityBlock(activity: running)
            }
            Button { withAnimation(Motion.hover) { expanded.toggle() } } label: {
                HStack(spacing: 6) {
                    Image(systemName: expanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 8, weight: .semibold))
                    Text(summary)
                    if failures > 0 {

                        Text("· \(failures) failed")
                            .foregroundStyle(Palette.red)
                    }
                }
                .font(Typo.meta)
                .foregroundStyle(Palette.textFaint)
            }
            .buttonStyle(.plain)

            if expanded {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(activities, id: \.toolCallID) { ActivityBlock(activity: $0) }
                }
                .padding(.leading, 12)
            }
        }
        .padding(.leading, 2)
    }

    private var summary: String {
        let done = activities.count - (running == nil ? 0 : 1)

        return Fmt.count("%lld steps", done)
    }
}

struct BlockView: View {
    @Environment(\.findMark) private var findMark
    let block: ConversationBlock
    let artifactBase: URL
    var entryID: UUID? = nil
    var productID: UUID? = nil
    var chatID: UUID? = nil

    var body: some View {
        content
            // Every searchable block carries the anchor a find jump lands on, so the reader
            // arrives at the paragraph rather than at the top of a three-page answer.
            .modifier(FindAnchored(entryID: entryID, blockID: block.id))
    }

    @ViewBuilder private var content: some View {
        switch block.kind {
        case .markdown: MarkdownBlock(text: block.text, entryID: entryID, blockID: block.id,
                                      productID: productID, chatID: chatID)

                .accessibilityIdentifier("block-\(block.id)")
        case .activity: if let a = block.activity { ActivityBlock(activity: a) }
        case .consult:  if let a = block.activity {
                            ConsultBlock(activity: a, answer: block.text, blockID: block.id,
                                         entryID: entryID,
                                         productID: productID, chatID: chatID)
                        }
        case .file:     if let ref = block.artifacts.first { FileBlock(ref: ref, base: artifactBase) }
        case .gallery:  GalleryBlock(refs: block.artifacts, caption: block.text, base: artifactBase)
        case .error:    ErrorBlock(text: block.text, blockID: block.id, entryID: entryID)
        case .unknown:  UnknownBlock(block: block, entryID: entryID)
        }
    }

}

/// The scroll anchor, applied only where there is an entry to key it to.
private struct FindAnchored: ViewModifier {
    let entryID: UUID?
    let blockID: String

    func body(content: Content) -> some View {
        if let entryID {
            content.findAnchor(entry: entryID, block: blockID)
        } else {
            content
        }
    }
}

// MARK: - Prose

private struct MarkdownBlock: View {
    @Environment(AppModel.self) private var model
    @Environment(\.findMark) private var findMark
    let text: String

    var entryID: UUID? = nil
    var blockID: String? = nil
    let productID: UUID?
    let chatID: UUID?

    var body: some View {
        MarkdownProse(text: text, fileRoots: model.fileRoots(forProductID: productID, chatID: chatID),
                      openWeb: { model.webPreview = $0 },
                      find: entryID.flatMap {
                          findMark.prose(entry: $0, block: blockID, markdown: text)
                      })
    }
}

// MARK: - Activity

struct ActivityBlock: View {
    let activity: BlockActivity
    @Environment(\.motionEnabled) private var motionEnabled
    @State private var pulse = false

    private var tint: Color {
        switch activity.status {
        case .running: Palette.textFaint
        case .done:    Palette.textFaint
        case .failed:  Palette.red
        }
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            marker
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 5) {

                    let verb = String(localized: String.LocalizationValue(activity.verbKey))
                    let takesObject = verb.contains("%@")
                    Text(takesObject ? String(format: verb, activity.object ?? "") : verb)
                        .font(Typo.meta)
                        .foregroundStyle(tint)
                        .lineLimit(1)
                    if !takesObject, let object = activity.object, !object.isEmpty {
                        Text(object)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(Palette.textFaint)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
                if activity.status == .failed, let detail = activity.detail {
                    Text(detail)
                        .font(Typo.meta)
                        .foregroundStyle(Palette.red.opacity(0.9))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.leading, 2)
        .onAppear {
            guard motionEnabled, activity.status == .running else { return }
            withAnimation(Motion.breathe.repeatForever(autoreverses: true)) { pulse = true }
        }
    }

    @ViewBuilder private var marker: some View {
        switch activity.status {
        case .running:
            Circle().fill(Palette.accentEmphasis)
                .frame(width: 5, height: 5)
                .opacity(pulse ? 0.35 : 1)
                .padding(.top, 5)
        case .done:
            Image(systemName: "checkmark")
                .font(.system(size: 8, weight: .semibold))
                .foregroundStyle(Palette.textFaint)
                .frame(width: 5)
                .padding(.top, 3)
        case .failed:
            Image(systemName: "xmark")
                .font(.system(size: 8, weight: .semibold))
                .foregroundStyle(Palette.red)
                .frame(width: 5)
                .padding(.top, 3)
        }
    }
}

// MARK: - Another agent's own words

/// What Codex actually said, inside the turn where it was asked.
///
/// Before this, the whole exchange vanished: the call collapsed into "runs codex exec …" in the
/// step trace and the answer was discarded, so a review reached him only as Claude's paraphrase of
/// it — with no way to check the paraphrase. It is folded by default because an answer is often two
/// pages and the paraphrase above it is usually what he wants; the header says who was asked and
/// how long the answer is, so opening it is a decision rather than a gamble.
struct ConsultBlock: View {
    let activity: BlockActivity
    let answer: String
    var blockID: String? = nil
    var entryID: UUID? = nil
    var productID: UUID? = nil
    var chatID: UUID? = nil

    @Environment(AppModel.self) private var model
    @Environment(\.findMark) private var findMark
    @State private var fold = FoldedByDefault()

    private var agent: String { activity.object ?? "Codex" }
    private var running: Bool { activity.status == .running }
    private var failed: Bool { activity.status == .failed }

    /// Find opened this card to show what it had folded away. Its own `expanded` is left alone,
    /// so closing the search puts the card back exactly as the reader had it.
    private var openedByFind: Bool {
        guard let entryID, let blockID else { return false }
        return findMark.isActive(entry: entryID, block: blockID)
    }

    private var showing: Bool { fold.showing(findOpened: openedByFind) }

    private var findState: FindHighlight.State {
        guard let entryID, let blockID else { return .none }
        return findMark.state(entry: entryID, block: blockID,
                              text: ConversationFind.consultText(answer: answer,
                                                                 ask: activity.detail))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if showing, !running, !answer.isEmpty {
                MarkdownProse(text: answer,
                              fileRoots: model.fileRoots(forProductID: productID, chatID: chatID),
                              openWeb: { model.webPreview = $0 },
                              find: entryID.flatMap {
                                  findMark.prose(entry: $0, block: blockID, markdown: answer)
                              })
                    .padding(.horizontal, 11)
                    .padding(.bottom, 10)
                    .textSelection(.enabled)
            }
        }
        .background(RoundedRectangle(cornerRadius: Metrics.radiusPanel, style: .continuous)
            .fill(Palette.panel.opacity(0.6)))
        .overlay(alignment: .leading) {
            Capsule()
                .fill(failed ? Palette.red.opacity(0.55) : Palette.accent.opacity(0.45))
                .frame(width: 2)
                .padding(.vertical, 6)
        }
        .clipShape(RoundedRectangle(cornerRadius: Metrics.radiusPanel, style: .continuous))
        .findHighlight(findState)
        .onChange(of: openedByFind) { _, now in if now { fold.findArrived() } }
        .accessibilityIdentifier("consult-\(activity.toolCallID)")
    }

    private var header: some View {
        Button {
            guard !running, !answer.isEmpty else { return }
            withAnimation(Motion.expand) { fold.toggle(findOpened: openedByFind) }
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 7) {
                SpeakerAvatar(initial: String(agent.prefix(1)), isForeman: true)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(running
                             ? String(format: String(localized: "Asking %@…"), agent)
                             : String(format: String(localized: "%@ answered"), agent))
                            .font(Typo.meta)
                            .foregroundStyle(failed ? Palette.red : Palette.textSecondary)
                        if running { ProgressView().controlSize(.mini) }
                        if !running, !answer.isEmpty {
                            Text(Fmt.count("%lld lines", answer.split(separator: "\n").count))
                                .font(Typo.meta)
                                .monospacedDigit()
                                .foregroundStyle(Palette.textFaint)
                        }
                    }
                    if let ask = activity.detail, !ask.isEmpty, !showing {
                        Text(ask)
                            .font(Typo.meta)
                            .foregroundStyle(Palette.textFaint)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                }
                Spacer(minLength: 8)
                if !running, !answer.isEmpty {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(Palette.textFaint)
                        .rotationEffect(.degrees(showing ? 90 : 0))
                }
            }
            .padding(.horizontal, 11)
            .padding(.vertical, 9)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(Text(running ? "Waiting for the answer" : "Show what it said, word for word"))
    }
}

// MARK: - Files

private struct FileBlock: View {
    let ref: ArtifactRef
    let base: URL

    @State private var hovering = false
    private var url: URL? { ref.resolve(base: base) }

    var body: some View {
        Button { preview() } label: {
            HStack(spacing: 11) {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(Palette.panelMuted)
                    .frame(width: 36, height: 36)
                    .overlay(Image(systemName: symbol)
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(Palette.textSecondary))
                VStack(alignment: .leading, spacing: 2) {
                    Text(ref.displayName)
                        .font(Typo.step)
                        .foregroundStyle(Palette.text)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(subtitle)
                        .font(Typo.meta)
                        .foregroundStyle(Palette.textFaint)
                }
                Spacer(minLength: 8)
                Image(systemName: url == nil ? "exclamationmark.triangle" : "chevron.right")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Palette.textFaint)
                    .offset(x: hovering && url != nil ? 2 : 0)
            }
            .padding(11)
            .frame(maxWidth: 420, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: Metrics.radiusCard, style: .continuous)
                    .fill(Palette.panel)
                    .overlay(RoundedRectangle(cornerRadius: Metrics.radiusCard, style: .continuous)
                        .strokeBorder(Palette.line, lineWidth: 1)))
        }
        .buttonStyle(.plain)
        .disabled(url == nil)
        .onHover { h in withAnimation(Motion.hover) { hovering = h } }

        .modifier(DragOut(url: url))
        .contextMenu { if let url { fileActions(url) } }
    }

    private var symbol: String {
        switch ref.kind {
        case .image: "photo"
        case .video: "play.rectangle"
        case .archive: "doc.zipper"
        case .document: "doc.text"
        case .code: "chevron.left.forwardslash.chevron.right"
        case .log: "list.bullet.rectangle"
        case .other: "doc"
        }
    }

    private var subtitle: String {
        guard url != nil else {
            return String(localized: "This file is no longer where it was made")
        }
        let size = ref.byteSize.map { Fmt.bytes($0) }
        return [size, ref.kind == .archive ? nil : nil].compactMap { $0 }.joined(separator: " · ")
    }

    @ViewBuilder private func fileActions(_ url: URL) -> some View {
        Button("Preview") { preview() }
        Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
        Button("Open") { NSWorkspace.shared.open(url) }
    }

    private func preview() {
        guard let url else { return }
        QuickLookPresenter.shared.show([url], startingAt: 0)
    }
}

private struct DragOut: ViewModifier {
    let url: URL?

    func body(content: Content) -> some View {
        if let url {
            content.onDrag { NSItemProvider(contentsOf: url) ?? NSItemProvider() }
        } else {
            content
        }
    }
}

// MARK: - Gallery

private struct GalleryBlock: View {
    let refs: [ArtifactRef]
    let caption: String
    let base: URL

    private var urls: [URL] { refs.compactMap { $0.resolve(base: base) } }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            if !caption.isEmpty {
                Text(caption).font(Typo.meta).foregroundStyle(Palette.textFaint)
            }

            WrappingHStack(horizontalSpacing: 8, verticalSpacing: 8) {
                ForEach(urls.indices, id: \.self) { index in
                    Thumbnail(url: urls[index]) {
                        QuickLookPresenter.shared.show(urls, startingAt: index)
                    }
                }
            }
            .frame(maxWidth: 680, alignment: .leading)
            if urls.count < refs.count {
                Text("\(refs.count - urls.count) of these are no longer on disk")
                    .font(Typo.meta)
                    .foregroundStyle(Palette.textFaint)
            }
        }
    }
}

private struct Thumbnail: View {
    let url: URL
    let onTap: () -> Void

    @State private var image: NSImage?
    @State private var hovering = false

    var body: some View {
        Button(action: onTap) {
            ZStack {
                RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Palette.panelMuted)
                if let image = image ?? ThumbnailCache.shared.cached(url) {
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                } else {
                    Image(systemName: "photo")
                        .font(.system(size: 14))
                        .foregroundStyle(Palette.textFaint)
                }
            }
            .frame(width: 104, height: 78)
            .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous)
                .strokeBorder(Palette.line, lineWidth: 1))
            .scaleEffect(hovering ? 1.02 : 1)
        }
        .buttonStyle(.plain)
        .onHover { h in withAnimation(Motion.hover) { hovering = h } }
        .onDrag { NSItemProvider(contentsOf: url) ?? NSItemProvider() }

        .task(id: url) {
            image = await Task.detached(priority: .utility) {
                guard let source = NSImage(contentsOf: url) else { return nil as NSImage? }
                let target = NSSize(width: 208, height: 156)
                let thumb = NSImage(size: target)
                thumb.lockFocus()
                source.draw(in: NSRect(origin: .zero, size: target),
                            from: .zero, operation: .copy, fraction: 1)
                thumb.unlockFocus()
                return thumb
            }.value
        }
    }
}

// MARK: - Error

private struct ErrorBlock: View {
    @Environment(\.findMark) private var findMark
    let text: String
    var blockID: String? = nil
    var entryID: UUID? = nil

    /// Plain text the app draws itself, so the phrase is marked where it stands.
    private var shown: Text {
        guard let entryID, let blockID else { return Text(text) }
        return findMark.text(text, entry: entryID, block: blockID)
    }

    var body: some View {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 11))
                .foregroundStyle(Palette.red)
                .padding(.top, 2)
            shown
                .font(Typo.caption)
                .foregroundStyle(Palette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
            Spacer(minLength: 0)
        }
        .padding(11)
        .frame(maxWidth: 680, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: Metrics.radiusPanel, style: .continuous)
            .fill(Palette.redSoft))
    }
}

// MARK: - Unknown

private struct UnknownBlock: View {
    @Environment(\.findMark) private var findMark
    let block: ConversationBlock
    var entryID: UUID? = nil
    @State private var fold = FoldedByDefault()

    /// Find opened it to show the phrase; the card's own `expanded` is untouched, so closing the
    /// search folds it back the way the reader left it.
    private var openedByFind: Bool {
        guard let entryID else { return false }
        return findMark.isActive(entry: entryID, block: block.id)
    }

    private var showing: Bool { fold.showing(findOpened: openedByFind) }

    private var shown: Text {
        guard let entryID else { return Text(block.text) }
        return findMark.text(block.text, entry: entryID, block: block.id)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 7) {
                Image(systemName: "questionmark.square.dashed")
                    .font(.system(size: 11))
                    .foregroundStyle(Palette.textFaint)
                Text("Something this version cannot show yet")
                    .font(Typo.meta)
                    .foregroundStyle(Palette.textFaint)
                Spacer(minLength: 8)
                Button { withAnimation(Motion.hover) { fold.toggle(findOpened: openedByFind) } }
                    label: { showing ? Text("Hide") : Text("Show") }
                    .buttonStyle(.bulava(.quiet))
                Button("Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(block.text, forType: .string)
                }
                .buttonStyle(.bulava(.quiet))
            }
            if showing, !block.text.isEmpty {
                shown
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(Palette.textTertiary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(11)
        .frame(maxWidth: 680, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: Metrics.radiusPanel, style: .continuous)
            .fill(Palette.panelMuted))
        .onChange(of: openedByFind) { _, now in if now { fold.findArrived() } }
    }
}

// MARK: - Quick Look

@MainActor
final class QuickLookPresenter: NSObject, @preconcurrency QLPreviewPanelDataSource,
                                @preconcurrency QLPreviewPanelDelegate {
    static let shared = QuickLookPresenter()
    private var urls: [URL] = []

    func show(_ urls: [URL], startingAt index: Int) {
        guard !urls.isEmpty, let panel = QLPreviewPanel.shared() else { return }
        self.urls = urls
        panel.dataSource = self
        panel.delegate = self
        panel.reloadData()
        panel.currentPreviewItemIndex = min(max(0, index), urls.count - 1)
        panel.makeKeyAndOrderFront(nil)
    }

    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int { urls.count }

    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> (any QLPreviewItem)! {
        guard urls.indices.contains(index) else { return nil }
        return urls[index] as NSURL
    }
}
