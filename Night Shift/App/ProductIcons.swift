import SwiftUI
import AppKit
import Observation

// MARK: - Cache

@MainActor
@Observable
final class ProductIcons {
    private(set) var thumbnails: [String: NSImage] = [:]
    private(set) var candidates: [UUID: [String]] = [:]

    @ObservationIgnored private var loading: Set<String> = []
    @ObservationIgnored private var unreadable: Set<String> = []

    func image(for path: String?) -> NSImage? {
        guard let path else { return nil }
        return thumbnails[path]
    }

    func prepare(_ path: String) async {
        guard thumbnails[path] == nil, !unreadable.contains(path), !loading.contains(path) else { return }
        loading.insert(path)
        let image = await ProjectIconScanner.thumbnail(at: path)
        loading.remove(path)
        if let image { thumbnails[path] = image } else { unreadable.insert(path) }
    }

    func discover(for productID: UUID, paths: [String], force: Bool = false) async -> [String] {
        if !force, let known = candidates[productID] { return known }
        let found = await ProjectIconScanner.candidatesOffTheMainActor(in: paths)
        candidates[productID] = found
        return found
    }
}

// MARK: - Model glue

extension AppModel {

    func iconSearchPaths(for product: Product) -> [String] {
        product.allProjectIDs.compactMap { projects.project(id: $0)?.path }
    }

    func adoptProductIconIfNeeded(_ productID: UUID) async {
        guard let product = products.product(id: productID), !product.iconScanned else { return }
        let found = await icons.discover(for: productID, paths: iconSearchPaths(for: product))
        products.adoptIcon(found.first, for: productID)
    }
}

// MARK: - The tile

struct ProductIconTile: View {
    @Environment(AppModel.self) private var model
    let product: Product
    var size: CGFloat = 18
    var selected: Bool = false

    var body: some View {
        Group {
            if let image = model.icons.image(for: product.iconPath) {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
                    .frame(width: size, height: size)
                    .clipShape(RoundedRectangle(cornerRadius: size * 0.28, style: .continuous))
            } else {
                Image(systemName: "folder")
                    .font(.system(size: size * 0.7, weight: .regular))
                    .foregroundStyle(selected ? Palette.accentEmphasis : Palette.textFaint)
                    .frame(width: size, height: size)
            }
        }
        .task(id: product.iconPath) {
            if let path = product.iconPath { await model.icons.prepare(path) }
        }
    }
}

// MARK: - The picker

struct ProductIconPicker: View {
    @Environment(AppModel.self) private var model
    let product: Product

    @State private var found: [String]?

    private let tile: CGFloat = 34
    private let columns = 5

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Eyebrow("Icons in this product")
            switch found {
            case .none:
                HStack(spacing: 7) {
                    ProgressView().controlSize(.small)
                    Text("Looking through its folders…")
                        .font(Typo.caption)
                        .foregroundStyle(Palette.textFaint)
                }
                .frame(height: tile)
            case .some(let paths) where paths.isEmpty:
                Text("Nothing in this product's folders looks like an icon.")
                    .font(Typo.caption)
                    .foregroundStyle(Palette.textFaint)
                    .fixedSize(horizontal: false, vertical: true)
            case .some(let paths):
                LazyVGrid(columns: Array(repeating: GridItem(.fixed(tile), spacing: 8), count: columns),
                          alignment: .leading, spacing: 8) {
                    ForEach(paths, id: \.self) { candidate($0) }
                }
            }
            if product.iconPath != nil {
                Hairline()
                Button {
                    model.products.setIcon(nil, for: product.id)
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "folder").font(.system(size: 10, weight: .medium))
                        Text("No icon").font(Typo.control)
                        Spacer(minLength: 0)
                    }
                    .foregroundStyle(Palette.textSecondary)
                    .padding(.horizontal, 6)
                    .frame(height: 24)
                }
                .buttonStyle(.row())
            }
        }
        .padding(12)
        .frame(width: CGFloat(columns) * tile + CGFloat(columns - 1) * 8 + 24)
        .task {

            found = await model.icons.discover(for: product.id,
                                               paths: model.iconSearchPaths(for: product),
                                               force: true)
        }
    }

    @ViewBuilder private func candidate(_ path: String) -> some View {
        let chosen = product.iconPath == path
        Button { model.products.setIcon(path, for: product.id) } label: {
            ZStack {
                RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Palette.panelRaised)
                if let image = model.icons.image(for: path) {
                    Image(nsImage: image)
                        .resizable()
                        .interpolation(.high)
                        .scaledToFit()
                        .padding(3)
                }
            }
            .frame(width: tile, height: tile)
            .overlay(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .strokeBorder(chosen ? Palette.accentEmphasis : Palette.line,
                                  lineWidth: chosen ? 2 : 1)
            )
        }
        .buttonStyle(.plain)
        .task(id: path) { await model.icons.prepare(path) }
        .help(Text(verbatim: shortened(path)))
    }

    private func shortened(_ path: String) -> String {
        let home = NSHomeDirectory()
        return path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
    }
}
