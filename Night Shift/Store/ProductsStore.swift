import SwiftUI
import Observation

@MainActor
@Observable
final class ProductsStore {
    private(set) var products: [Product] = []

    private let file: JSONFile<[Product]>
    private let migrationFlag: JSONFile<Bool>
    private let summaryCleanupFlag: JSONFile<Bool>

    init(fileURL: URL = AppSupport.file("products.json"),
         migrationURL: URL = AppSupport.file("products-adopted.json"),
         summaryCleanupURL: URL = AppSupport.file("products-summaries-cleaned.json")) {
        file = JSONFile<[Product]>(url: fileURL)
        migrationFlag = JSONFile<Bool>(url: migrationURL)

        summaryCleanupFlag = JSONFile<Bool>(url: summaryCleanupURL)
        products = file.load() ?? []
    }

    private func persist() { file.save(products) }

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

    func remove(_ id: UUID) {
        products.removeAll { $0.id == id }
        persist()
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
