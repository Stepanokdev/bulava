import SwiftUI
import Observation
import UniformTypeIdentifiers

@MainActor
@Observable
final class CaptureStore {
    private(set) var items: [CaptureItem] = []
    private let file = JSONFile<[CaptureItem]>(url: AppSupport.file("capture.json"))

    init() { items = file.load() ?? [] }
    private func persist() { file.save(items) }

    var inbox: [CaptureItem] {
        items.filter { $0.status == .inbox }.sorted { $0.createdAt > $1.createdAt }
    }
    var inboxCount: Int { items.filter { $0.status == .inbox }.count }

    func add(_ item: CaptureItem) { items.insert(item, at: 0); persist() }

    func update(_ item: CaptureItem) {
        guard let idx = items.firstIndex(where: { $0.id == item.id }) else { return }
        items[idx] = item; persist()
    }

    func remove(_ id: UUID) {
        if let item = items.first(where: { $0.id == id }) { deleteAttachments(of: item) }
        items.removeAll { $0.id == id }; persist()
    }

    func dismiss(_ id: UUID) {
        guard let idx = items.firstIndex(where: { $0.id == id }) else { return }
        items[idx].status = .dismissed; persist()
    }

    func markCompiled(_ id: UUID, taskID: UUID) {
        guard let idx = items.firstIndex(where: { $0.id == id }) else { return }
        items[idx].status = .compiled
        items[idx].linkedTaskID = taskID
        persist()
    }

    // MARK: Attachments

    func importFile(from source: URL) -> Attachment? {
        let kind = attachmentKind(for: source)
        let id = UUID()
        let ext = source.pathExtension
        let destName = ext.isEmpty ? id.uuidString : "\(id.uuidString).\(ext)"
        let dest = AppSupport.attachments.appendingPathComponent(destName)
        do {
            if FileManager.default.fileExists(atPath: dest.path) { try FileManager.default.removeItem(at: dest) }
            try FileManager.default.copyItem(at: source, to: dest)
        } catch { return nil }
        return Attachment(id: id, kind: kind, filename: source.lastPathComponent, relativePath: destName)
    }

    func writeData(_ data: Data, filename: String, kind: AttachmentKind, duration: Double? = nil) -> Attachment? {
        let id = UUID()
        let ext = (filename as NSString).pathExtension
        let destName = ext.isEmpty ? id.uuidString : "\(id.uuidString).\(ext)"
        let dest = AppSupport.attachments.appendingPathComponent(destName)
        guard (try? data.write(to: dest, options: .atomic)) != nil else { return nil }
        return Attachment(id: id, kind: kind, filename: filename, relativePath: destName, durationSeconds: duration)
    }

    func url(for attachment: Attachment) -> URL? {
        guard let rel = attachment.relativePath else { return nil }
        return AppSupport.attachments.appendingPathComponent(rel)
    }

    private func deleteAttachments(of item: CaptureItem) {
        for a in item.attachments {
            if let u = url(for: a) { try? FileManager.default.removeItem(at: u) }
        }
    }

    private func attachmentKind(for url: URL) -> AttachmentKind {
        if let type = UTType(filenameExtension: url.pathExtension) {
            if type.conforms(to: .image) { return .image }
            if type.conforms(to: .audio) { return .audio }
        }
        return .file
    }
}
