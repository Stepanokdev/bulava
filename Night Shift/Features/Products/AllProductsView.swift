import SwiftUI

struct AllProductsView: View {
    @Environment(AppModel.self) private var model

    private var products: [Product] { model.products.sorted }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                header
                if products.isEmpty {
                    empty
                } else {
                    grid
                }
            }
            .frame(maxWidth: 900, alignment: .leading)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 30)
            .padding(.top, 30)
            .padding(.bottom, 60)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text("Products").screenTitleStyle().foregroundStyle(Palette.text)
            Text("Pick a product to open its Night Shift chats.")
                .font(Typo.body)
                .foregroundStyle(Palette.textTertiary)
        }
        .padding(.bottom, 24)
    }

    private var grid: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 260), spacing: 12)], spacing: 12) {
            ForEach(products) { product in
                ProductCard(product: product)
            }
            AddCard()
        }
    }

    private var empty: some View {
        InviteState(
            systemImage: "square.grid.2x2",
            title: Text("Nothing connected yet"),
            message: "A product is whatever you actually ship — an app, a site, a backend, or all three at once. Connect the folders and Bulava will work out the rest.")
        .padding(.vertical, 50)
        .overlay(alignment: .bottom) {
            Button { model.beginNewProduct() } label: { Text("Add your first product") }
                .buttonStyle(.bulava(.primary))
        }
    }
}

// MARK: - Card

private struct ProductCard: View {
    @Environment(AppModel.self) private var model
    let product: Product

    @State private var hovering = false

    private var state: WorkState? { model.state(forProductID: product.id) }
    private var reports: Int { model.reportsWaiting(forProductID: product.id) }

    var body: some View {
        Button { model.open(product: product.id) } label: {
            Card(fill: hovering ? Palette.panelMuted : Palette.panel,
                 border: hovering ? Palette.selectedBorder : Palette.line) {
                VStack(alignment: .leading, spacing: 0) {
                    HStack(spacing: 10) {
                        ProductMonogram(initials: product.initials, selected: false, size: 32)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(product.name)
                                .font(Typo.cardTitle)
                                .foregroundStyle(Palette.text)
                                .lineLimit(1)
                            statusLine
                        }
                        Spacer(minLength: 4)
                        if product.pinned {
                            Image(systemName: "pin.fill")
                                .font(.system(size: 9))
                                .foregroundStyle(Palette.textFaint)
                        }
                    }

                    if !summaryText.isEmpty {
                        Text(summaryText)
                            .font(Typo.caption)
                            .lineSpacing(3)
                            .foregroundStyle(Palette.textTertiary)
                            .lineLimit(3)
                            .multilineTextAlignment(.leading)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.top, 13)
                    }

                    Spacer(minLength: 10)
                    Hairline().padding(.top, 10)
                    HStack(spacing: 0) {
                        Text(resourceCount)
                        Spacer(minLength: 8)
                        Text(reportCount)
                    }
                    .font(Typo.panelMeta)
                    .foregroundStyle(Palette.textFaint)
                    .padding(.top, 9)
                }
                .padding(15)
                .frame(minHeight: 128, alignment: .topLeading)
            }
        }
        .buttonStyle(.plain)
        .onHover { isHovering in withAnimation(Motion.hover) { hovering = isHovering } }
        .contextMenu {
            Button(product.pinned ? "Unpin" : "Pin to top") { model.products.togglePin(product.id) }
            Button("Rename…") { model.beginRenaming(product) }
            Divider()
            ForEach(model.resources(for: product)) { resolved in
                if let project = resolved.project {
                    Button("Reveal \(resolved.resource.name)") { model.revealInFinder(project.path) }
                }
            }
            Divider()
            Button("Remove product", role: .destructive) { model.removeProduct(product) }
        }
    }

    @ViewBuilder private var statusLine: some View {
        HStack(spacing: 5) {
            if reports > 0 {
                Circle().fill(Palette.accent).frame(width: 5, height: 5)
                Text("\(reports) ready to read")
            } else if let state {
                Circle().fill(dotColor(state)).frame(width: 5, height: 5)
                Text(LocalizedStringKey(state.labelKey))
            } else {
                Text("Idle")
            }
        }
        .font(Typo.meta)
        .foregroundStyle(Palette.textFaint)
    }

    private func dotColor(_ state: WorkState) -> Color {
        switch state {
        case .running:     Palette.green
        case .needsAnswer: Palette.orange
        case .reportReady: Palette.green
        case .failed:      Palette.red
        case .paused:      Palette.orange
        default:           Palette.textFaint
        }
    }

    private var summaryText: String {
        if !product.summary.isEmpty { return product.summary }
        return product.brief
    }

    private var resourceCount: String {
        String(format: String(localized: "%lld resources"), product.resources.count)
    }

    private var reportCount: String {
        let count = model.history(for: product.id).count
        return String(format: String(localized: "%lld finished"), count)
    }
}

// MARK: - Add card

private struct AddCard: View {
    @Environment(AppModel.self) private var model
    @State private var hovering = false

    var body: some View {
        Button { model.beginNewProduct() } label: {
            VStack(spacing: 9) {
                Image(systemName: "plus")
                    .font(.system(size: 17, weight: .light))
                Text("Add a product").font(Typo.control)
            }
            .foregroundStyle(hovering ? Palette.accentEmphasis : Palette.textFaint)
            .frame(maxWidth: .infinity)
            .frame(minHeight: 128)
            .background(
                RoundedRectangle(cornerRadius: Metrics.radiusCard, style: .continuous)
                    .strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [4, 4]))
                    .foregroundStyle(hovering ? Palette.selectedBorder : Palette.line)
            )
        }
        .buttonStyle(.plain)
        .onHover { isHovering in withAnimation(Motion.hover) { hovering = isHovering } }
    }
}
