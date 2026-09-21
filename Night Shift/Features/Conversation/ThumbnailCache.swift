import AppKit
import QuickLookThumbnailing

@MainActor
final class ThumbnailCache {
    static let shared = ThumbnailCache()

    private var images: [URL: NSImage] = [:]
    private var order: [URL] = []

    private let limit = 240

    func cached(_ url: URL) -> NSImage? { images[url] }

    func load(_ url: URL) async -> NSImage? {
        if let have = images[url] { return have }
        let decoded = await Task.detached(priority: .utility) { Self.thumbnail(of: url) }.value
        guard let decoded else { return nil }
        store(decoded, for: url)
        return decoded
    }

    @discardableResult
    func loadNow(_ url: URL) -> NSImage? {
        if let have = images[url] { return have }
        guard let decoded = Self.thumbnail(of: url) else { return nil }
        store(decoded, for: url)
        return decoded
    }

    private func store(_ image: NSImage, for url: URL) {
        images[url] = image
        order.removeAll { $0 == url }
        order.append(url)
        while order.count > limit, let oldest = order.first {
            order.removeFirst()
            images[oldest] = nil
        }
    }

    private nonisolated static func thumbnail(of url: URL) -> NSImage? {
        guard let source = NSImage(contentsOf: url) else { return nil }
        let target = NSSize(width: 208, height: 156)
        let thumb = NSImage(size: target)
        thumb.lockFocus()
        source.draw(in: NSRect(origin: .zero, size: target),
                    from: .zero, operation: .copy, fraction: 1)
        thumb.unlockFocus()
        return thumb
    }

    /// A picture of any file the system can draw — a PDF's first page, a document, a video frame.
    ///
    /// `NSImage(contentsOf:)` only understands image formats, so every other attachment used to
    /// render as a grey chip with a generic icon on it. QuickLook is what Finder and Mail use for
    /// exactly this, and it is the reason a PDF here now looks like the PDF it is.
    func preview(_ url: URL, size: CGSize = CGSize(width: 208, height: 156)) async -> NSImage? {
        if let have = images[url] { return have }
        if let image = await Task.detached(priority: .utility, operation: { Self.thumbnail(of: url) }).value {
            store(image, for: url)
            return image
        }
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let request = QLThumbnailGenerator.Request(
            fileAt: url, size: size,
            scale: NSScreen.main?.backingScaleFactor ?? 2,
            representationTypes: .all)
        let generated: NSImage? = await withCheckedContinuation { cont in
            QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { rep, _ in
                cont.resume(returning: rep.map { NSImage(cgImage: $0.cgImage, size: $0.contentRect.size) })
            }
        }
        if let generated { store(generated, for: url) }
        return generated
    }
}
