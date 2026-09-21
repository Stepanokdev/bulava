import SwiftUI
import Observation

@MainActor
@Observable
final class WorkItemStore {
    private(set) var items: [WorkItem] = []

    private let file: JSONFile<[WorkItem]>

    init(fileURL: URL = AppSupport.file("work-items.json")) {
        file = JSONFile<[WorkItem]>(url: fileURL)
        items = file.load() ?? []
    }

    private func persist() { file.save(items) }

    // MARK: - Reads

    func item(id: UUID?) -> WorkItem? {
        guard let id else { return nil }
        return items.first { $0.id == id }
    }

    func item(forStreamID id: UUID) -> WorkItem? {
        items.first { $0.streamIDs.contains(id) }
    }

    func items(forProductID id: UUID) -> [WorkItem] {
        items.filter { $0.productID == id }
    }

    nonisolated static func precedes(_ a: WorkItem, _ b: WorkItem) -> Bool {
        if a.priority != b.priority { return a.priority < b.priority }
        switch (a.dueBy, b.dueBy) {
        case let (x?, y?) where x != y: return x < y
        case (_?, nil): return true
        case (nil, _?): return false
        default: return a.createdAt < b.createdAt
        }
    }

    var sorted: [WorkItem] { items.sorted(by: Self.precedes) }

    // MARK: - Writes

    @discardableResult
    func add(_ item: WorkItem) -> WorkItem {
        items.append(item)
        persist()
        return item
    }

    func update(_ item: WorkItem) {
        guard let i = items.firstIndex(where: { $0.id == item.id }) else { return }
        items[i] = item
        persist()
    }

    func remove(_ id: UUID) {
        items.removeAll { $0.id == id }
        persist()
    }

    func removeStream(_ streamID: UUID) {
        guard let i = items.firstIndex(where: { $0.streamIDs.contains(streamID) }) else { return }
        items[i].streams.removeAll { $0.id == streamID }
        for j in items[i].streams.indices {
            items[i].streams[j].dependsOn.removeAll { $0 == streamID }
        }
        items[i].preemptedStreamIDs.removeAll { $0 == streamID }
        if items[i].streams.isEmpty { items.remove(at: i) }
        persist()
    }

    func setPriority(_ priority: WorkPriority, for id: UUID) {
        guard let i = items.firstIndex(where: { $0.id == id }) else { return }
        items[i].priority = priority
        persist()
    }

    func setDeadline(_ date: Date?, for id: UUID) {
        guard let i = items.firstIndex(where: { $0.id == id }) else { return }
        items[i].dueBy = date
        persist()
    }

    func markReportAnnounced(_ id: UUID, at date: Date = Date()) {
        guard let i = items.firstIndex(where: { $0.id == id }),
              items[i].reportAnnouncedAt == nil else { return }
        items[i].reportAnnouncedAt = date
        persist()
    }

    func markPreempted(_ streamID: UUID, in itemID: UUID) {
        guard let i = items.firstIndex(where: { $0.id == itemID }),
              !items[i].preemptedStreamIDs.contains(streamID) else { return }
        items[i].preemptedStreamIDs.append(streamID)
        persist()
    }

    func clearPreempted(_ streamID: UUID) {
        guard let i = items.firstIndex(where: { $0.streamIDs.contains(streamID) }),
              items[i].preemptedStreamIDs.contains(streamID) else { return }
        items[i].preemptedStreamIDs.removeAll { $0 == streamID }
        persist()
    }
}
