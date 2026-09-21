import AppKit
import ImageIO

nonisolated enum ProjectIconScanner {

    private static let skipped: Set<String> = [
        "node_modules", "build", ".build", "DerivedData", "Pods", "Carthage",
        "dist", "out", "target", "vendor", "venv", "__pycache__", "coverage",
        ".next", ".nuxt", ".gradle", ".yarn", ".cache", ".terraform",
    ]

    private static let extensions: Set<String> = [
        "png", "icns", "ico", "svg", "pdf", "jpg", "jpeg", "webp",
    ]

    private static let hints = ["icon", "logo", "mark", "brand", "favicon", "launcher", "glyph"]

    private static let maxDepth = 4
    private static let maxDirectories = 320
    private static let minBytes = 256
    private static let maxBytes = 6 << 20

    static func candidates(in roots: [String], limit: Int = 12) -> [String] {
        var scored: [(path: String, score: Int)] = []
        for root in roots { collect(root: root, into: &scored) }
        var seen = Set<String>()
        return scored
            .sorted { $0.score == $1.score ? $0.path < $1.path : $0.score > $1.score }
            .filter { seen.insert($0.path).inserted }
            .prefix(limit)
            .map(\.path)
    }

    @concurrent
    static func candidatesOffTheMainActor(in roots: [String], limit: Int = 12) async -> [String] {
        candidates(in: roots, limit: limit)
    }

    // MARK: - The walk

    private static func collect(root: String, into scored: inout [(path: String, score: Int)]) {
        let fm = FileManager.default
        var isDirectory: ObjCBool = false
        guard fm.fileExists(atPath: root, isDirectory: &isDirectory), isDirectory.boolValue else { return }

        var queue: [(url: URL, depth: Int)] = [(URL(fileURLWithPath: root), 0)]
        var visited = 0
        while !queue.isEmpty, visited < maxDirectories {
            let (dir, depth) = queue.removeFirst()
            visited += 1
            let entries = (try? fm.contentsOfDirectory(
                at: dir,
                includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey],
                options: [.skipsHiddenFiles])) ?? []

            if dir.lastPathComponent.hasSuffix(".appiconset") {
                if let best = largest(in: entries) { scored.append((best, 100 - depth)) }
                continue
            }

            for entry in entries {
                if entry.hasDirectoryPath {
                    guard depth < maxDepth, !skipped.contains(entry.lastPathComponent) else { continue }
                    queue.append((entry, depth + 1))
                } else if let score = score(for: entry, depth: depth) {
                    scored.append((entry.path, score))
                }
            }
        }
    }

    private static func score(for file: URL, depth: Int) -> Int? {
        let ext = file.pathExtension.lowercased()
        guard extensions.contains(ext), let size = bytes(of: file),
              size >= minBytes, size <= maxBytes else { return nil }

        let name = file.deletingPathExtension().lastPathComponent.lowercased()
        var score: Int
        if ext == "icns" {
            score = 95
        } else if name.hasPrefix("appicon") || name.hasPrefix("app-icon")
                    || name.hasPrefix("icon") || name.hasPrefix("logo") {
            score = 80
        } else if hints.contains(where: name.contains) {
            score = 65
        } else {
            return nil
        }

        if name.contains("favicon") || ext == "ico" { score -= 25 }
        return score - depth * 3
    }

    private static func largest(in entries: [URL]) -> String? {
        entries
            .filter { extensions.contains($0.pathExtension.lowercased()) }
            .compactMap { url -> (String, Int)? in
                guard let size = bytes(of: url), size >= minBytes, size <= maxBytes else { return nil }
                return (url.path, size)
            }
            .max { $0.1 < $1.1 }?.0
    }

    private static func bytes(of file: URL) -> Int? {
        try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize
    }

    // MARK: - Drawing one

    @concurrent
    static func thumbnail(at path: String, maxPixel: Int = 128) async -> NSImage? {
        let url = URL(fileURLWithPath: path)
        let side = CGFloat(maxPixel) / 2
        if let source = CGImageSourceCreateWithURL(url as CFURL, nil),
           let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, [
               kCGImageSourceCreateThumbnailFromImageAlways: true,
               kCGImageSourceCreateThumbnailWithTransform: true,
               kCGImageSourceThumbnailMaxPixelSize: maxPixel,
           ] as CFDictionary) {
            return NSImage(cgImage: cg, size: NSSize(width: side, height: side))
        }
        guard let source = NSImage(contentsOf: url), source.isValid, source.size.width > 0 else { return nil }
        let target = NSSize(width: side, height: side)
        let thumb = NSImage(size: target)
        thumb.lockFocus()
        source.draw(in: NSRect(origin: .zero, size: target), from: .zero, operation: .copy, fraction: 1)
        thumb.unlockFocus()
        return thumb
    }
}
