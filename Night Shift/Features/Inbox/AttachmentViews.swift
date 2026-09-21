import SwiftUI
import AVFoundation
import AppKit
import UniformTypeIdentifiers
import QuickLook
import QuickLookUI

/// One attached file, shown as what it is.
///
/// It used to be a 56pt square for images and a grey chip with a generic `doc` glyph for
/// everything else — so a PDF, a spreadsheet and a video were indistinguishable, and none of them
/// could be opened. A picture of the file, its name, its size, and a click that opens it is the
/// whole of what makes an attachment feel handled rather than swallowed.
struct AttachmentThumb: View {
    @Environment(AppModel.self) private var model
    let attachment: Attachment

    /// Compact in the composer's draft row, roomier inside a message.
    var compact = false

    @State private var thumbnail: NSImage?
    @State private var quickLook: URL?
    @State private var hovering = false

    private var url: URL? { model.capture.url(for: attachment) }

    var body: some View {
        switch attachment.kind {
        case .audio:
            AudioPlayButton(url: url, duration: attachment.durationSeconds)
        case .link:
            linkChip
        case .image, .file:
            card
        }
    }

    // MARK: - A file

    private var side: CGFloat { compact ? 38 : 46 }

    private var card: some View {
        Button { open() } label: {
            HStack(spacing: 9) {
                preview
                if !compact || thumbnail == nil {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(attachment.filename)
                            .font(Typo.panelRow)
                            .foregroundStyle(Palette.text)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Text(subtitle)
                            .font(Typo.panelMeta)
                            .foregroundStyle(Palette.textFaint)
                            .lineLimit(1)
                    }
                }
            }
            .padding(6)
            .frame(maxWidth: compact ? 210 : 260, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: Metrics.radiusChip, style: .continuous)
                    .fill(hovering ? Palette.panelRaised : Palette.panelMuted)
            )
            .overlay(
                RoundedRectangle(cornerRadius: Metrics.radiusChip, style: .continuous)
                    .strokeBorder(Palette.line, lineWidth: 1)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(Text(attachment.filename))
        .quickLookPreview($quickLook)
        .task(id: attachment.id) { await loadThumbnail() }
        .contextMenu {
            Button("Open") { open() }
            if let url {
                Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
            }
        }
    }

    @ViewBuilder private var preview: some View {
        ZStack {
            if let thumbnail {
                Image(nsImage: thumbnail)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                // The type's own icon, not a single generic sheet of paper: the system already
                // knows what a spreadsheet, an archive and a video look like.
                Image(nsImage: typeIcon)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .padding(side * 0.18)
            }
        }
        .frame(width: side, height: side)
        .background(Palette.panelRaised)
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .strokeBorder(Palette.line, lineWidth: 1)
        )
    }

    private var typeIcon: NSImage {
        if let url {
            return NSWorkspace.shared.icon(forFile: url.path)
        }
        let type = UTType(filenameExtension: (attachment.filename as NSString).pathExtension)
        return NSWorkspace.shared.icon(for: type ?? .data)
    }

    /// Kind and size, in that order — the two things you check before opening something.
    private var subtitle: String {
        var parts: [String] = []
        let ext = (attachment.filename as NSString).pathExtension.uppercased()
        if !ext.isEmpty { parts.append(ext) }
        if let url,
           let size = try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64,
           size > 0 {
            parts.append(ByteCountFormatter.string(fromByteCount: size, countStyle: .file))
        }
        return parts.isEmpty ? String(localized: "file") : parts.joined(separator: " · ")
    }

    private func loadThumbnail() async {
        guard let url, attachment.kind == .image || attachment.kind == .file else { return }
        thumbnail = await ThumbnailCache.shared.preview(url)
    }

    private func open() {
        guard let url, FileManager.default.fileExists(atPath: url.path) else {
            model.toast = ToastMessage(text: String(localized: "That file is no longer on disk"),
                                       kind: .error)
            return
        }
        // QuickLook inside the app, the way Finder's space bar behaves — not a hand-off to
        // whatever application happens to own the extension.
        quickLook = url
    }

    // MARK: - A link

    private var linkChip: some View {
        Button {
            if let raw = attachment.urlString, let link = URL(string: raw) { model.webPreview = link }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "link")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Palette.textSecondary)
                Text(attachment.urlString ?? attachment.filename)
                    .font(.system(size: 11))
                    .foregroundStyle(Palette.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 6)
            .frame(maxWidth: 220)
            .background(RoundedRectangle(cornerRadius: Metrics.radiusChip, style: .continuous)
                .fill(Palette.panelRaised))
        }
        .buttonStyle(.plain)
        .help(Text(attachment.urlString ?? attachment.filename))
    }
}

struct AudioPlayButton: View {
    let url: URL?
    let duration: Double?
    @State private var player: AudioPlayer?
    @State private var playing = false

    var body: some View {
        Button {
            toggle()
        } label: {
            HStack(spacing: 7) {
                Image(systemName: playing ? "pause.fill" : "play.fill")
                    .font(.system(size: 11, weight: .semibold)).foregroundStyle(Palette.accentEmphasis)
                Image(systemName: "waveform").font(.system(size: 12)).foregroundStyle(Palette.textSecondary)
                if let duration { Text(durationText(duration)).font(Typo.mono(10.5)).foregroundStyle(Palette.textTertiary) }
            }
            .padding(.horizontal, 10).padding(.vertical, 7)
            .background(RoundedRectangle(cornerRadius: Metrics.radiusChip, style: .continuous)
                .fill(Palette.panelRaised))
        }
        .buttonStyle(.plain)
        .onDisappear { player?.stop() }
    }

    private func toggle() {
        guard let url else { return }
        if playing { player?.stop(); playing = false; return }
        let p = AudioPlayer(url: url) { playing = false }
        player = p
        if p.play() { playing = true }
    }

    private func durationText(_ d: Double) -> String {
        let s = Int(d.rounded()); return String(format: "%d:%02d", s / 60, s % 60)
    }
}

final class AudioPlayer: NSObject, AVAudioPlayerDelegate {
    private var player: AVAudioPlayer?
    private let onFinish: () -> Void
    init(url: URL, onFinish: @escaping () -> Void) {
        self.onFinish = onFinish
        super.init()
        player = try? AVAudioPlayer(contentsOf: url)
        player?.delegate = self
    }
    func play() -> Bool { player?.play() ?? false }
    func stop() { player?.stop() }
    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in onFinish() }
    }
}
