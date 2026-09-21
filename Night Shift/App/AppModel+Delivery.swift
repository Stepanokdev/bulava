import Foundation

extension AppModel {

    func postDelivery(for task: BacklogTask, productID: UUID) {
        guard !deliveredArtifacts.contains(task.id) else { return }
        let key = task.reportKey
        let directory = settings.paths.reportDir(task8: key)
        let blocks = Self.deliveryBlocks(runID: key, directory: directory,
                                         manifest: Self.manifest(in: directory))
        guard !blocks.isEmpty else { return }
        deliveredArtifacts.insert(task.id)

        var entry = ConversationEntry(productID: productID, kind: .foreman,
                                      text: Self.deliveryCaption(blocks), blocks: blocks,
                                      taskID: task.id)
        entry.chatID = conversations.currentChatID(for: productID)
        conversations.append(entry)
    }

    func postDelivery(forItem item: WorkItem, productID: UUID) {
        guard !deliveredArtifacts.contains(item.id) else { return }

        var blocks: [ConversationBlock] = []
        var gallery: [ArtifactRef] = []
        for part in deliveredParts(of: item) {
            let key = part.reportKey
            let directory = settings.paths.reportDir(task8: key)
            let name = partName(part, in: item)
            for block in Self.deliveryBlocks(runID: key, directory: directory,
                                             manifest: Self.manifest(in: directory)) {
                switch block.kind {
                case .gallery:
                    gallery += block.artifacts
                case .file:

                    guard var ref = block.artifacts.first else { continue }
                    ref.displayName = name.isEmpty ? ref.displayName : name + " · " + ref.displayName
                    blocks.append(.file(id: key + "/" + block.id, ref))
                default:
                    continue
                }
            }
        }
        if !gallery.isEmpty {
            blocks.insert(.gallery(id: "gallery", gallery,
                                   caption: Fmt.count("%lld frames", gallery.count)), at: 0)
        }
        guard !blocks.isEmpty else { return }
        deliveredArtifacts.insert(item.id)

        var entry = ConversationEntry(productID: productID, kind: .foreman,
                                      text: Self.deliveryCaption(blocks), blocks: blocks,
                                      taskID: item.id)
        entry.chatID = conversations.currentChatID(for: productID)
        conversations.append(entry)
    }

    nonisolated static func deliveryBlocks(runID: String, directory: URL,
                                           manifest: ReportManifest?) -> [ConversationBlock] {
        let names = relativeFiles(in: directory)
        guard !names.isEmpty else { return [] }

        var blocks: [ConversationBlock] = []

        let ordered = manifestOrder(manifest) ?? []
        let images = orderedNames(names.filter { ArtifactRef.Kind.of($0) == .image },
                                  preferring: ordered)
        if !images.isEmpty {
            blocks.append(.gallery(id: "gallery",
                                   images.map { ArtifactRef(runID: runID, relativePath: $0) },
                                   caption: caption(for: manifest, count: images.count)))
        }

        let order: [ArtifactRef.Kind] = [.video, .archive, .document, .code, .log, .other]
        for kind in order {
            for name in names.filter({ ArtifactRef.Kind.of($0) == kind }).sorted() {
                let ref = ArtifactRef(runID: runID, relativePath: name,
                                      byteSize: size(of: directory.appendingPathComponent(name)))
                blocks.append(.file(id: name, ref))
            }
        }
        return blocks
    }

    nonisolated static func relativeFiles(in directory: URL, depth: Int = 4) -> [String] {
        let fm = FileManager.default
        var out: [String] = []

        func walk(_ url: URL, prefix: String, remaining: Int) {
            guard remaining > 0,
                  let names = try? fm.contentsOfDirectory(atPath: url.path) else { return }
            for name in names.sorted() {
                if skipped.contains(name) || name.hasPrefix(".") { continue }
                let child = url.appendingPathComponent(name)
                let relative = prefix.isEmpty ? name : prefix + "/" + name
                var isDirectory: ObjCBool = false
                guard fm.fileExists(atPath: child.path, isDirectory: &isDirectory) else { continue }
                if isDirectory.boolValue {
                    walk(child, prefix: relative, remaining: remaining - 1)
                } else if !ignored(name) {
                    out.append(relative)
                }
            }
        }
        walk(directory, prefix: "", remaining: depth)

        return out.count > Self.deliveryCeiling ? Array(out.prefix(Self.deliveryCeiling)) : out
    }

    private nonisolated static let skipped: Set<String> = ["report.html", "report.json", "__pycache__"]

    private nonisolated static func ignored(_ name: String) -> Bool {
        name.hasSuffix(".DS_Store") || name.hasSuffix(".tmp") || name.hasSuffix(".part")
    }

    nonisolated static let deliveryCeiling = 60

    nonisolated static func manifest(in directory: URL) -> ReportManifest? {
        guard let data = try? Data(contentsOf: directory.appendingPathComponent("report.json"))
        else { return nil }
        return try? JSONDecoder().decode(ReportManifest.self, from: data)
    }

    private nonisolated static func manifestOrder(_ manifest: ReportManifest?) -> [String]? {
        guard let items = manifest?.items, !items.isEmpty else { return nil }
        return items.flatMap { [$0.before, $0.after].compactMap { $0 } }
    }

    private nonisolated static func orderedNames(_ names: [String], preferring order: [String]) -> [String] {
        let known = order.filter(names.contains)
        let rest = names.filter { !known.contains($0) }.sorted()
        return known + rest
    }

    private nonisolated static func caption(for manifest: ReportManifest?, count: Int) -> String {
        if manifest?.format == .photos, (manifest?.items?.count ?? 0) > 0 {
            return String(localized: "Before and after")
        }
        return Fmt.count("%lld frames", count)
    }

    private nonisolated static func size(of url: URL) -> Int? {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.size]) as? Int
    }

    nonisolated static func deliveryCaption(_ blocks: [ConversationBlock]) -> String {
        let frames = blocks.first { $0.kind == .gallery }?.artifacts.count ?? 0
        let files = blocks.filter { $0.kind == .file }.count
        var parts: [String] = []
        if frames > 0 { parts.append(Fmt.count("%lld frames", frames)) }
        if files > 0 { parts.append(Fmt.count("%lld files", files)) }
        guard !parts.isEmpty else { return "" }
        return String(format: String(localized: "What the work produced: %@"),
                      parts.joined(separator: ", "))
    }
}
