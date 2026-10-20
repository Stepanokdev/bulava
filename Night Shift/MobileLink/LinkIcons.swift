import AppKit
import CryptoKit
import ImageIO
import UniformTypeIdentifiers

/// A product's icon as the phone is sent it: a small PNG, whatever the Mac's own icon file is.
///
/// The Mac's icon is whatever `ProjectIconScanner` found in the product's folders — a 1.5 MB PNG,
/// an `.icns`, an SVG, a PDF — and the phone decodes PNG and JPEG. So it is drawn once into a
/// 128-pixel PNG and kept under a name that changes with the source file. The reference the phone
/// is given changes with it too: the phone keeps pictures by reference, and a new icon sent under
/// the old one went on showing the old picture until the app was killed.
@MainActor
enum LinkIcons {
    static let side = 128

    static var folder: URL { AppSupport.root.appendingPathComponent("phone-icons", isDirectory: true) }

    /// The PNG for one product's icon, drawn when it is not there yet, and the revision it is kept
    /// under. Nil when the file cannot be read as a picture — the phone shows the initials then.
    static func png(for productID: UUID, path: String) -> (url: URL, revision: String)? {
        let attributes = try? FileManager.default.attributesOfItem(atPath: path)
        let size = (attributes?[.size] as? NSNumber)?.int64Value ?? 0
        let modified = Int((attributes?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0)
        let revision = SHA256.hash(data: Data("\(path)|\(size)|\(modified)".utf8))
            .prefix(5).map { String(format: "%02x", $0) }.joined()
        let prefix = productID.uuidString.lowercased() + "-"
        let url = folder.appendingPathComponent(prefix + revision + ".png")
        if FileManager.default.fileExists(atPath: url.path) { return (url, revision) }
        guard let data = render(path) else { return nil }
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        guard (try? data.write(to: url, options: .atomic)) != nil else { return nil }
        // The drawings of this product's earlier icons are of no use to anyone any more.
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        for name in names where name.hasPrefix(prefix) && name != url.lastPathComponent {
            try? FileManager.default.removeItem(at: folder.appendingPathComponent(name))
        }
        return (url, revision)
    }

    /// A square PNG of the picture, fitted inside `side` pixels on a transparent ground.
    static func render(_ path: String) -> Data? {
        let url = URL(fileURLWithPath: path)
        var image: CGImage?
        if let source = CGImageSourceCreateWithURL(url as CFURL, nil) {
            image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: side,
            ] as CFDictionary)
        }
        if image == nil, let picture = NSImage(contentsOf: url), picture.isValid, picture.size.width > 0 {
            // SVG and PDF, which ImageIO does not draw: AppKit does.
            var rect = NSRect(x: 0, y: 0, width: side, height: side)
            image = picture.cgImage(forProposedRect: &rect, context: nil, hints: nil)
        }
        guard let image else { return nil }
        let scale = min(CGFloat(side) / CGFloat(image.width), CGFloat(side) / CGFloat(image.height), 1)
        let w = max(1, Int((CGFloat(image.width) * scale).rounded()))
        let h = max(1, Int((CGFloat(image.height) * scale).rounded()))
        guard let context = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        guard let drawn = context.makeImage() else { return nil }
        let out = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(out, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, drawn, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return out as Data
    }
}
