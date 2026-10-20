import SwiftUI
import Observation

@MainActor
@Observable
final class ProductsStore {
    private(set) var products: [Product] = []
    /// Products taken off the list, kept so the removal can be undone — by the button on the
    /// notice, or by adding the same folder again. A click on "Remove product" used to throw away
    /// the product's history at once, while its run carried on unseen: 14 Oct a working chat was
    /// recovered only by editing the app's files by hand.
    private(set) var removed: [RemovedProduct] = []

    nonisolated struct RemovedProduct: Codable, Equatable, Sendable {
        var product: Product
        var removedAt: Date
    }

    private let file: JSONFile<[Product]>
    private let removedFile: JSONFile<[RemovedProduct]>
    private let migrationFlag: JSONFile<Bool>
    private let summaryCleanupFlag: JSONFile<Bool>

    init(fileURL: URL = AppSupport.file("products.json"),
         migrationURL: URL = AppSupport.file("products-adopted.json"),
         summaryCleanupURL: URL = AppSupport.file("products-summaries-cleaned.json"),
         removedURL: URL? = nil) {
        file = JSONFile<[Product]>(url: fileURL)
        migrationFlag = JSONFile<Bool>(url: migrationURL)
        // Named after the products' own file — `products.json` → `products-removed.json` — so a store
        // opened on another file keeps its own list.
        removedFile = JSONFile<[RemovedProduct]>(
            url: removedURL ?? URL(fileURLWithPath: fileURL.deletingPathExtension().path + "-removed.json"))

        summaryCleanupFlag = JSONFile<Bool>(url: summaryCleanupURL)
        products = file.load() ?? []
        removed = removedFile.load() ?? []
    }

    private func persist() { file.save(products) }
    private func persistRemoved() { removedFile.save(removed) }

    // MARK: - Adoption

    func adoptProjectsIfNeeded(from projects: ProjectsStore) {
        guard migrationFlag.load() != true else { return }
        defer { migrationFlag.save(true) }
        guard !projects.projects.isEmpty else { return }

        for project in projects.sorted where product(forProjectID: project.id) == nil {
            let resource = ProductResource(
                name: project.name,
                kind: project.kind == .unknown ? .folder : .repository,
                access: .workspace,
                projectID: project.id)

            products.append(Product(
                name: project.name,
                resources: [resource],
                pinned: project.pinned,
                addedAt: project.addedAt,
                brief: project.notes))
        }
        persist()
    }

    func clearGeneratedSummariesOnce() {
        guard summaryCleanupFlag.load() != true else { return }
        defer { summaryCleanupFlag.save(true) }
        let generated = Set(ProjectKind.allCases.map(\.label))
        var changed = false
        for i in products.indices where generated.contains(products[i].summary) {
            products[i].summary = ""
            changed = true
        }
        if changed { persist() }
    }

    // MARK: - Lookups

    func product(id: UUID?) -> Product? {
        guard let id else { return nil }
        return products.first { $0.id == id }
    }

    func product(forProjectID id: UUID) -> Product? {
        products.first { $0.writableProjectIDs.contains(id) }
            ?? products.first { $0.allProjectIDs.contains(id) }
    }

    func product(forProjectPath path: String, projects: ProjectsStore) -> Product? {
        guard let project = projects.project(path: path) else { return nil }
        return product(forProjectID: project.id)
    }

    var sorted: [Product] {
        products.filter(\.pinned) + products.filter { !$0.pinned }
    }

    /// The order his lists show them in, on the Mac and on the phone alike: pinned first, then the
    /// one he worked in last — so a chat he has just started is at the top, whichever product it is
    /// in. Products never worked in keep the order they were added in, below the rest.
    var byRecentWork: [Product] {
        sorted.enumerated().sorted { a, b in
            if a.element.pinned != b.element.pinned { return a.element.pinned }
            let x = a.element.lastWorkedAt ?? .distantPast, y = b.element.lastWorkedAt ?? .distantPast
            if x != y { return x > y }
            return a.offset < b.offset
        }.map(\.element)
    }

    // MARK: - Mutations

    @discardableResult
    func add(name: String, resources: [ProductResource] = [], brief: String = "") -> Product {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let product = Product(name: trimmed.isEmpty ? String(localized: "Untitled product") : trimmed,
                              resources: resources,
                              brief: brief)
        products.append(product)
        persist()
        return product
    }

    func remove(_ id: UUID, at date: Date = Date()) {
        guard let product = products.first(where: { $0.id == id }) else { return }
        products.removeAll { $0.id == id }
        removed.removeAll { $0.product.id == id }
        removed.append(RemovedProduct(product: product, removedAt: date))
        persist()
        persistRemoved()
    }

    /// Puts a removed product back exactly as it was — same id, so its chats are its own again.
    @discardableResult
    func restore(_ id: UUID) -> Product? {
        guard let entry = removed.first(where: { $0.product.id == id }) else { return nil }
        removed.removeAll { $0.product.id == id }
        if !products.contains(where: { $0.id == id }) { products.append(entry.product) }
        persist()
        persistRemoved()
        return entry.product
    }

    /// Removed products that worked in any of these folders.
    func removedProducts(sharingProjects projectIDs: Set<UUID>) -> [Product] {
        removed.map(\.product).filter { !Set($0.allProjectIDs).isDisjoint(with: projectIDs) }
    }

    func forgetRemoved(_ id: UUID) {
        guard removed.contains(where: { $0.product.id == id }) else { return }
        removed.removeAll { $0.product.id == id }
        persistRemoved()
    }

    /// Lets go of products removed before `date`, and says which, so their chats can go as well.
    func expireRemoved(before date: Date) -> [UUID] {
        let gone = removed.filter { $0.removedAt < date }.map(\.product.id)
        guard !gone.isEmpty else { return [] }
        removed.removeAll { gone.contains($0.product.id) }
        persistRemoved()
        return gone
    }

    func update(_ product: Product) {
        guard let i = products.firstIndex(where: { $0.id == product.id }) else { return }
        products[i] = product
        persist()
    }

    func rename(_ id: UUID, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let i = products.firstIndex(where: { $0.id == id }) else { return }
        products[i].name = trimmed
        persist()
    }

    func togglePin(_ id: UUID) {
        guard let i = products.firstIndex(where: { $0.id == id }) else { return }
        products[i].pinned.toggle()
        persist()
    }

    // MARK: Face

    func setIcon(_ path: String?, for id: UUID) {
        guard let i = products.firstIndex(where: { $0.id == id }) else { return }
        products[i].iconPath = path
        products[i].iconScanned = true
        persist()
    }

    func adoptIcon(_ path: String?, for id: UUID) {
        guard let i = products.firstIndex(where: { $0.id == id }), !products[i].iconScanned else { return }
        products[i].iconScanned = true
        products[i].iconPath = path
        persist()
    }

    func touch(_ id: UUID) {
        guard let i = products.firstIndex(where: { $0.id == id }) else { return }

        let last = products[i].lastOpenedAt
        products[i].lastOpenedAt = Date()
        guard last == nil || Date().timeIntervalSince(last!) >= 3600 else { return }
        persist()
    }

    func worked(_ id: UUID) {
        guard let i = products.firstIndex(where: { $0.id == id }) else { return }
        products[i].lastWorkedAt = Date()
        products[i].lastOpenedAt = Date()
        persist()
    }

    var lastVisited: Product? {
        products.filter { $0.lastOpenedAt != nil }
            .max { ($0.lastOpenedAt ?? .distantPast) < ($1.lastOpenedAt ?? .distantPast) }
    }

    // MARK: Resources

    func addResource(_ resource: ProductResource, to productID: UUID) {
        guard let i = products.firstIndex(where: { $0.id == productID }) else { return }

        if let pid = resource.projectID,
           let existing = products[i].resources.firstIndex(where: { $0.projectID == pid }) {
            products[i].resources[existing].name = resource.name
        } else {
            products[i].resources.append(resource)
        }
        persist()
    }

    func removeResource(_ resourceID: UUID, from productID: UUID) {
        guard let i = products.firstIndex(where: { $0.id == productID }) else { return }
        products[i].resources.removeAll { $0.id == resourceID }
        persist()
    }

    func setAccess(_ access: ResourceAccess, resourceID: UUID, productID: UUID) {
        guard let i = products.firstIndex(where: { $0.id == productID }),
              let j = products[i].resources.firstIndex(where: { $0.id == resourceID }) else { return }
        products[i].resources[j].access = access
        persist()
    }

    // MARK: Description

    func setBrief(_ text: String, for productID: UUID) {
        guard let i = products.firstIndex(where: { $0.id == productID }) else { return }
        products[i].brief = text
        persist()
    }

    func setSummary(_ text: String, for productID: UUID) {
        guard let i = products.firstIndex(where: { $0.id == productID }) else { return }
        products[i].summary = text
        persist()
    }
}
