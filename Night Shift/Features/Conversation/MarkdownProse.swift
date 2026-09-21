import SwiftUI
import AppKit
import MarkdownUI

struct MarkdownProse: View {

    static let proseWidth: CGFloat = 680

    let text: String

    var fileRoots: [URL] = []

    var openWeb: ((URL) -> Void)? = nil

    var body: some View {
        Markdown(FilePathLinks.rewrite(text, roots: fileRoots))
            .markdownTheme(.bulava)

            .markdownImageProvider(LocalImageProvider(roots: fileRoots))
            .markdownInlineImageProvider(LocalImageProvider(roots: fileRoots))
            .textSelection(.enabled)
            .environment(\.openURL, OpenURLAction { url in

                if let target = FilePathLinks.target(of: url, roots: fileRoots) {
                    var isDirectory: ObjCBool = false
                    guard FileManager.default.fileExists(atPath: target.path, isDirectory: &isDirectory) else {
                        return .handled
                    }
                    if isDirectory.boolValue {
                        NSWorkspace.shared.activateFileViewerSelecting([target])
                    } else {
                        QuickLookPresenter.shared.show([target], startingAt: 0)
                    }
                    return .handled
                }
                let scheme = url.scheme?.lowercased()
                guard scheme == "http" || scheme == "https" else { return .discarded }

                guard let openWeb else { return .systemAction }
                openWeb(url)
                return .handled
            })
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: Self.proseWidth, alignment: .leading)
    }
}

// MARK: - The theme

extension Theme {

    static let bulava = Theme()
        .text {
            FontFamilyVariant(.normal)
            FontSize(13.5)
            ForegroundColor(Palette.textSecondary)
        }
        .code {
            FontFamilyVariant(.monospaced)
            FontSize(12)
            ForegroundColor(Palette.text)
            BackgroundColor(Palette.panelMuted)
        }
        .strong { FontWeight(.semibold); ForegroundColor(Palette.text) }
        .link { ForegroundColor(Palette.accent) }
        .heading1 { config in
            config.label
                .markdownMargin(top: 16, bottom: 6)
                .markdownTextStyle { FontSize(16); FontWeight(.semibold); ForegroundColor(Palette.text) }
        }
        .heading2 { config in
            config.label
                .markdownMargin(top: 14, bottom: 5)
                .markdownTextStyle { FontSize(14.5); FontWeight(.semibold); ForegroundColor(Palette.text) }
        }
        .heading3 { config in
            config.label
                .markdownMargin(top: 12, bottom: 4)
                .markdownTextStyle { FontSize(13.5); FontWeight(.semibold); ForegroundColor(Palette.text) }
        }
        .paragraph { config in
            config.label
                .relativeLineSpacing(.em(0.22))
                .markdownMargin(top: 0, bottom: 10)
        }
        .listItem { config in
            config.label.markdownMargin(top: 3)
        }
        .blockquote { config in
            HStack(spacing: 10) {
                Rectangle().fill(Palette.line).frame(width: 2)
                config.label.markdownTextStyle { ForegroundColor(Palette.textTertiary) }
            }
            .markdownMargin(top: 6, bottom: 10)
        }
        .codeBlock { config in

            config.label
                .relativeLineSpacing(.em(0.2))
                .markdownTextStyle { FontFamilyVariant(.monospaced); FontSize(11.5) }
                .fixedSize(horizontal: false, vertical: true)
                .padding(11)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Palette.panelMuted)
                .clipShape(RoundedRectangle(cornerRadius: Metrics.radiusControl, style: .continuous))
                .markdownMargin(top: 4, bottom: 12)
        }
        .table { config in

            config.label
                .fixedSize(horizontal: false, vertical: true)
                .markdownTableBorderStyle(.init(color: Palette.line,
                                                strokeStyle: .init(lineWidth: 1)))
                .frame(maxWidth: .infinity, alignment: .leading)
                .markdownMargin(top: 4, bottom: 12)
        }
        .tableCell { config in
            config.label
                .markdownTextStyle { if config.row == 0 { FontWeight(.semibold) } }
                .padding(.vertical, 5)
                .padding(.horizontal, 9)
        }
        .thematicBreak {
            Rectangle().fill(Palette.line).frame(height: 1).markdownMargin(top: 12, bottom: 12)
        }
}

// MARK: - Images: from this machine, in scope, or not at all

private struct LocalImageProvider: ImageProvider, InlineImageProvider {
    let roots: [URL]

    @ViewBuilder func makeImage(url: URL?) -> some View {
        if let url, let file = FilePathLinks.target(of: url, roots: roots),
           FilePathLinks.isImage(file), let image = NSImage(contentsOf: file) {
            Button { QuickLookPresenter.shared.show([file], startingAt: 0) } label: {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(maxWidth: MarkdownProse.proseWidth, maxHeight: 420)
                    .clipShape(RoundedRectangle(cornerRadius: Metrics.radiusControl, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: Metrics.radiusControl, style: .continuous)
                            .strokeBorder(Palette.line, lineWidth: 1)
                    )
            }
            .buttonStyle(.plain)
            .help(Text("Open in preview"))
        } else {

            Color.clear.frame(width: 0, height: 0)
        }
    }

    func image(with url: URL, label: String) async throws -> Image {
        guard let file = FilePathLinks.target(of: url, roots: roots),
              FilePathLinks.isImage(file), let image = NSImage(contentsOf: file) else {
            throw CancellationError()
        }
        return Image(nsImage: image)
    }
}
