import SwiftUI

struct RootView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        shell
    }

    private var shell: some View {
        NavigationSplitView(columnVisibility: Binding(
            get: { model.sidebarVisibility },
            set: { model.sidebarVisibility = $0 }
        )) {
            SidebarView()
                .navigationSplitViewColumnWidth(min: Metrics.sidebarMinWidth,
                                                ideal: Metrics.sidebarWidth,
                                                max: 300)
        } detail: {
            detailColumn

                .navigationSplitViewColumnWidth(min: 320,
                                                ideal: Metrics.conversationColumnIdealWidth)
                .toolbar { toolbarContent }
        }

        .toolbar(model.fullScreenSurfacePresented ? .hidden : .visible, for: .windowToolbar)
        .navigationTitle(model.fullScreenSurfacePresented ? "" : navigationTitle)
        .navigationSubtitle(model.fullScreenSurfacePresented ? "" : navigationSubtitle)
        .background(Palette.window)
        .resolveMotionPreference()
        .modifier(TransientSurfaces())
    }

    private var detailColumn: some View {
        GeometryReader { geometry in
            let showsInspector = model.inspectorShown && model.route.productID != nil
            let inspectorWidth = showsInspector ? Metrics.inspectorWidth : 0

            ZStack(alignment: .trailing) {
                DetailSurface()
                    .frame(width: max(0, geometry.size.width - inspectorWidth),
                           height: geometry.size.height)
                    .frame(maxWidth: .infinity, alignment: .leading)

                if showsInspector {
                    HStack(spacing: 0) {
                        Rectangle().fill(Palette.line).frame(width: 1)
                        ProductInspector()
                    }
                    .frame(width: Metrics.inspectorWidth, height: geometry.size.height)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
                }
            }
            .clipped()
            .animation(Motion.surface, value: showsInspector)
        }
    }

    private struct TransientSurfaces: ViewModifier {
        @Environment(AppModel.self) private var model

        func body(content: Content) -> some View {
            content
                .overlay(alignment: .bottom) { ToastLayer() }
                .overlay { if model.searchPresented { CommandPalette() } }
                .overlay { galleryLayer }
                .overlay { reportLayer }
                .sheet(item: Binding(get: { model.webPreview.map(IdentifiedURL.init) },
                                     set: { model.webPreview = $0?.url })) { item in
                    WebPreview(url: item.url) { model.webPreview = nil }
                }
                .modifier(Sheets())
                .animation(Motion.snappy, value: model.toast)
                .animation(Motion.surface, value: model.reportViewer)
        }

        @ViewBuilder private var galleryLayer: some View {
            if let item = model.workItems.item(id: model.variantGalleryItemID) {
                VariantGallery(item: item)
                    .ignoresSafeArea()
                    .transition(.opacity)
                    .zIndex(9)
            }
        }

        @ViewBuilder private var reportLayer: some View {
            if let viewer = model.reportViewer {
                ReportDocumentView(viewer: viewer)
                    .ignoresSafeArea()
                    .transition(.opacity)
                    .zIndex(10)
            }
        }
    }

    private struct Sheets: ViewModifier {
        @Environment(AppModel.self) private var model

        func body(content: Content) -> some View {
            content
                .sheet(item: Binding(get: { model.productSheet },
                                     set: { if $0 == nil { model.productSheet = nil } })) { mode in
                    AddProductSheet(mode: mode)
                }
                .sheet(item: Binding(get: { model.taskDetail },
                                     set: { if $0 == nil { model.taskDetailID = nil } })) { task in
                    TaskDiagnosticsSheet(task: task)
                }
                .sheet(item: Binding(get: { model.products.product(id: model.renamingProductID) },
                                     set: { if $0 == nil { model.renamingProductID = nil } })) { product in
                    RenameProductSheet(product: product)
                }
                .sheet(item: Binding(get: { model.renamingChatID.flatMap { model.conversations.chat(id: $0) } },
                                     set: { if $0 == nil { model.renamingChatID = nil } })) { chat in
                    RenameChatSheet(chat: chat)
                }
        }
    }

    private struct ToastLayer: View {
        @Environment(AppModel.self) private var model

        var body: some View {
            if let toast = model.toast {
                ToastView(toast: toast)
                    .padding(.bottom, 26)
                    .transition(.move(edge: .bottom).combined(with: .opacity))

                    .onTapGesture {
                        withAnimation(Motion.snappy) {
                            if model.toast?.id == toast.id { model.toast = nil }
                        }
                    }
                    .task(id: toast.id) {
                        guard toast.kind != .error else { return }
                        try? await _Concurrency.Task.sleep(for: .seconds(3.2))
                        withAnimation(Motion.snappy) {
                            if model.toast?.id == toast.id { model.toast = nil }
                        }
                    }
            }
        }
    }

    // MARK: - Title

    private var navigationTitle: String {
        switch model.route {
        case .product: model.selectedProduct?.name ?? String(localized: "Bulava")
        case .products: String(localized: "Products")
        case .skills: String(localized: "Skills")
        case .preflight: String(localized: "Ready to work")
        }
    }

    private var navigationSubtitle: String {
        guard let productID = model.route.productID else { return "" }
        return model.directPhase(for: model.conversations.currentChatID(for: productID)).label
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder private var toolbarContent: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            Button {
                model.searchPresented = true
            } label: {
                Image(systemName: "magnifyingglass")
            }
            .buttonStyle(.icon)
            .help(Text("Go to a product, chat or report (⌘K)"))

            if model.route.productID != nil {
                ProductMenu()
            }

            Button {
                model.settings.appearance = model.settings.appearance.next
            } label: {
                Image(systemName: model.settings.appearance.icon)
            }
            .buttonStyle(.icon)
            .help(Text("Switch appearance"))

            Button {
                withAnimation(Motion.surface) { model.inspectorShown.toggle() }
            } label: {
                Image(systemName: "sidebar.trailing")
            }
            .buttonStyle(.icon)
            .disabled(model.route.productID == nil)
            .help(Text("Show or hide project context"))
        }
    }

}

// MARK: - Detail routing

private struct DetailSurface: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        ZStack {
            Palette.content.ignoresSafeArea()
            switch model.route {
            case .product(let id):
                if model.products.product(id: id) != nil {
                    ConversationView(productID: id)
                        .id(id)
                } else {
                    AllProductsView()
                }
            case .products:
                AllProductsView()
            case .skills:
                SkillsScreen()
            case .preflight:
                PreflightView()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Product menu

private struct ProductMenu: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Menu {
            if let product = model.selectedProduct {
                Button("Rename…") { model.beginRenaming(product) }
                Button(product.pinned ? "Unpin" : "Pin to top") {
                    model.products.togglePin(product.id)
                }
                Divider()
                ForEach(model.resources(for: product)) { resolved in
                    if let project = resolved.project {
                        Menu(resolved.resource.name) {
                            Button("Reveal in Finder") { model.revealInFinder(project.path) }
                            Button("Open in editor") { model.openInEditor(project.path) }
                            Divider()
                            Picker("Access", selection: Binding(
                                get: { resolved.resource.access },
                                set: { model.products.setAccess($0, resourceID: resolved.id, productID: product.id) }
                            )) {
                                Text("Can edit").tag(ResourceAccess.workspace)
                                Text("Ask before editing").tag(ResourceAccess.source)
                            }
                            Divider()
                            Picker("Accepting work", selection: Binding(
                                get: { project.deliveryMode },
                                set: { model.projects.setDelivery(project.id, $0) }
                            )) {
                                Text("Merges locally").tag(DeliveryMode.personal)
                                Text("Opens a pull request").tag(DeliveryMode.client)
                                Text("Prototype — merges locally").tag(DeliveryMode.prototype)
                                Text("Research — no merge").tag(DeliveryMode.research)
                            }
                        }
                    }
                }
                Divider()
                Button("Add a resource…") { model.beginAddingResource(to: product.id) }
                Button("Check readiness…") { model.openPreflight() }
                Divider()
                Button("Remove product", role: .destructive) { model.removeProduct(product) }
            }
        } label: {
            Image(systemName: "ellipsis")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .frame(width: Metrics.iconButton)
        .help(Text("Product actions"))
    }
}

// MARK: - Toast

struct ToastView: View {
    let toast: ToastMessage

    private var tint: Color {
        switch toast.kind {
        case .success: Palette.green
        case .error: Palette.red
        case .info: Palette.blue
        }
    }

    private var symbol: String {
        switch toast.kind {
        case .success: "checkmark.circle.fill"
        case .error: "exclamationmark.triangle.fill"
        case .info: "info.circle.fill"
        }
    }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(tint)
            Text(toast.text)
                .font(Typo.control)
                .foregroundStyle(Palette.text)
                .lineLimit(2)
            if toast.kind == .error {
                Text("Click to dismiss")
                    .font(Typo.panelMeta)
                    .foregroundStyle(Palette.textFaint)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(
            Capsule(style: .continuous)
                .fill(Palette.panel)
                .overlay(Capsule(style: .continuous).strokeBorder(Palette.lineStrong, lineWidth: 1))
        )
        .floatingShadow()
        .frame(maxWidth: 480)
    }
}

// MARK: - Sheet helper

private extension View {

    func sheet<Item, Content: View>(item: Binding<Item?>,
                                    @ViewBuilder content: @escaping (Item) -> Content) -> some View {
        sheet(isPresented: Binding(
            get: { item.wrappedValue != nil },
            set: { if !$0 { item.wrappedValue = nil } }
        )) {
            if let value = item.wrappedValue { content(value) }
        }
    }
}

#Preview { RootView().environment(AppModel()) }

private struct IdentifiedURL: Identifiable {
    let url: URL
    var id: String { url.absoluteString }
}
