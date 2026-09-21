import SwiftUI

struct SidebarView: View {
    @Environment(AppModel.self) private var model
    @Environment(UpdateController.self) private var updates

    @AppStorage("sidebar.products.collapsed") private var productsCollapsed = false

    var body: some View {
        VStack(spacing: 0) {
            brand
            searchField
            destinations
            productList
            footer
        }
        .background(Palette.chrome)
    }

    // MARK: - Brand

    private var brand: some View {
        Button { model.openProducts() } label: {
            HStack(spacing: 10) {
                BrandMark()
                // Beside the name on the same baseline, not under it: this qualifies the product,
                // it is not a second line of chrome. Small and faint enough to read as a footnote
                // to the wordmark rather than as part of it.
                HStack(alignment: .firstTextBaseline, spacing: 5) {
                    HStack(spacing: 0) {
                        Text(verbatim: "bulava").foregroundStyle(Palette.text)
                        Text(verbatim: ".app").foregroundStyle(Palette.textFaint)
                    }
                    .brandStyle()
                    Text(verbatim: "beta")
                        .font(Typo.tag)
                        .tracking(0.4)
                        .foregroundStyle(Palette.textFaint)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(Palette.textFaint)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 7)
        }
        .buttonStyle(.row(selected: model.route == .products))
        .padding(.horizontal, 12)
        .padding(.top, 12)
        .padding(.bottom, 10)
        .help(Text("All products"))
    }

    // MARK: - Search

    private var searchField: some View {
        Button { model.searchPresented = true } label: {
            HStack(spacing: 7) {
                Image(systemName: "magnifyingglass").font(.system(size: 11, weight: .medium))
                Text("Find a product or chat").font(Typo.caption)
                Spacer(minLength: 4)
                KeyHint(keys: "⌘K")
            }
            .foregroundStyle(Palette.textFaint)
            .padding(.horizontal, 9)
            .frame(height: 31)
            .background(
                RoundedRectangle(cornerRadius: Metrics.radiusControl, style: .continuous)
                    .fill(Palette.chromeSunken.opacity(0.6))
            )
            .overlay(
                RoundedRectangle(cornerRadius: Metrics.radiusControl, style: .continuous)
                    .strokeBorder(Palette.line, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 12)
        .padding(.bottom, 12)
    }

    // MARK: - Destinations

    private var destinations: some View {
        VStack(spacing: 1) {
            Button { model.openSkills() } label: {
                HStack(spacing: Rail.gap) {
                    Image(systemName: "sparkles")
                        .font(.system(size: 13, weight: .regular))
                        .foregroundStyle(model.route == .skills ? Palette.text : Palette.textSecondary)
                        .frame(width: Rail.glyph, height: Rail.glyph)
                    Text("Skills")
                        .font(model.route == .skills ? Typo.rowLabel.weight(.semibold) : Typo.rowLabel)
                        .foregroundStyle(Palette.text)
                        .lineLimit(1)
                    Spacer(minLength: 6)
                }
                .padding(.horizontal, Rail.inset)
                .frame(minHeight: 30)
            }
            .buttonStyle(.row(selected: model.route == .skills))
            .help(Text("Which skills this machine carries, and which ones each product uses (⇧⌘S)"))
        }
        .padding(.horizontal, 8)
        .padding(.bottom, 10)
    }

    // MARK: - Products

    private var productList: some View {
        ScrollView {
            LazyVStack(spacing: 1) {
                sectionHeader
                if !productsCollapsed {
                    ForEach(model.products.sorted) { product in
                        ProductGroup(product: product)
                    }
                }
            }
            .padding(.horizontal, 8)
            .padding(.bottom, 12)
        }
        .scrollIndicators(.hidden)
    }

    private var sectionHeader: some View {
        HStack(spacing: 0) {
            Button {
                withAnimation(Motion.standard) { productsCollapsed.toggle() }
            } label: {
                HStack(spacing: 4) {
                    Text("Products")
                    Image(systemName: "chevron.down")
                        .font(.system(size: 8, weight: .bold))
                        .rotationEffect(.degrees(productsCollapsed ? -90 : 0))
                }
                .font(Typo.rowLabel)
                .foregroundStyle(Palette.textFaint)
                .padding(.horizontal, 6)
                .frame(height: 26)
            }
            .buttonStyle(.row())
            Spacer(minLength: 0)
            Button { model.beginNewProduct() } label: {
                Image(systemName: "plus")
            }
            .buttonStyle(.icon(size: 24, glyph: 12, tint: Palette.textFaint))
            .help(Text("Add a product (⇧⌘N)"))
        }
        .padding(.bottom, 2)
    }

    // MARK: - Footer

    @ViewBuilder private var limits: some View {
        let claude = model.capacity.claude
        let codex = model.capacity.codex
        if claude.present || codex.present {
            if model.settings.limitsCollapsed {
                limitsFolded(claude: claude, codex: codex)
            } else {
                VStack(alignment: .leading, spacing: 13) {
                    limitsHeader
                    if claude.present { engine("Claude", claude) }
                    if codex.present { engine("Codex", codex) }
                }
                .padding(.horizontal, 12)
                .padding(.top, 10)
                .padding(.bottom, 4)
            }
        }
    }

    private var limitsHeader: some View {
        Button {
            withAnimation(Motion.hover) { model.settings.limitsCollapsed = true }
        } label: {
            HStack(spacing: 5) {
                Text("Limits")
                    .font(Typo.panelMeta)
                    .foregroundStyle(Palette.textFaint)
                Spacer(minLength: 0)
                Image(systemName: "chevron.up")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(Palette.textFaint)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(Text("Fold the limits"))
    }

    @ViewBuilder private func limitsFolded(claude: UsageSnapshot, codex: UsageSnapshot) -> some View {
        Button {
            withAnimation(Motion.hover) { model.settings.limitsCollapsed = false }
        } label: {
            HStack(spacing: 8) {
                if claude.present { foldedEngine("Claude", claude) }
                if claude.present, codex.present {
                    Text(verbatim: "·").font(Typo.panelMeta).foregroundStyle(Palette.textFaint)
                }
                if codex.present { foldedEngine("Codex", codex) }
                Spacer(minLength: 0)
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(Palette.textFaint)
            }
            .padding(.horizontal, 12)
            .padding(.top, 9)
            .padding(.bottom, 3)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(Text("Show the limits"))
    }

    @ViewBuilder private func foldedEngine(_ name: String, _ usage: UsageSnapshot) -> some View {
        HStack(spacing: 4) {
            Text(name)
                .font(Typo.panelMeta)
                .foregroundStyle(Palette.textSecondary)
            if let used = tightest(usage) {
                let tint = switch UsagePressure(usedPercent: Double(used)) {
                case .comfortable: Palette.text
                case .tight:       Palette.orange
                case .nearlyOut:   Palette.red
                }

                Text(verbatim: "\(used)%")
                    .font(Typo.panelMeta.weight(.semibold))
                    .foregroundStyle(tint)
            } else {
                Text(verbatim: "—")
                    .font(Typo.panelMeta)
                    .foregroundStyle(Palette.textFaint)
            }
        }
        .lineLimit(1)
        .fixedSize()
    }

    private func tightest(_ usage: UsageSnapshot) -> Int? {
        let used = [window(usage.fiveHour), usage.sevenDay.flatMap(window)]
            .compactMap { $0?.used }
        return used.max()
    }

    @ViewBuilder private func engine(_ name: String, _ usage: UsageSnapshot) -> some View {
        let stale = usage.updatedAt.map { Date().timeIntervalSince($0) > 1800 } ?? true
        let five = window(usage.fiveHour)
        let seven = usage.sevenDay.flatMap(window)
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 6) {
                Text(name)
                    .font(Typo.panelRow)
                    .foregroundStyle(Palette.text)
                Spacer(minLength: 0)
                if stale, let taken = usage.updatedAt {
                    Text(Fmt.ago(taken))
                        .font(Typo.panelMeta)
                        .foregroundStyle(Palette.textFaint)
                        .lineLimit(1)
                }
            }
            if let five { meter(String(localized: "Session"), five, stale: stale) }
            if let seven { meter(String(localized: "Weekly"), seven, stale: stale) }
            if five == nil, seven == nil {
                Text("Not known yet — it fills in when something runs")
                    .font(Typo.panelMeta)
                    .foregroundStyle(Palette.textFaint)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    @ViewBuilder private func meter(_ label: String, _ w: (used: Int, reset: String?),
                                    stale: Bool) -> some View {
        let pressure = UsagePressure(usedPercent: Double(w.used))
        let tint = switch pressure {
        case .comfortable: Palette.accent
        case .tight:       Palette.orange
        case .nearlyOut:   Palette.red
        }
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 4) {
                Text(label)
                    .font(Typo.panelMeta)
                    .foregroundStyle(Palette.textSecondary)
                Spacer(minLength: 4)
                Text(String(format: String(localized: "%lld%% used"), w.used))
                    .font(Typo.panelMeta.weight(.semibold))

                    .foregroundStyle(pressure == .comfortable ? Palette.text : tint)
                    .lineLimit(1)
                    .fixedSize()
            }
            HStack(spacing: 8) {
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Palette.track)
                        Capsule()
                            .fill(tint)
                            .frame(width: max(2, geo.size.width * CGFloat(w.used) / 100))
                    }
                }
                .frame(height: 4)
                .opacity(stale ? 0.45 : 1)
                HStack(spacing: 2.5) {
                    if w.reset != nil {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 8, weight: .semibold))
                        Text(w.reset ?? "")
                            .font(Typo.panelMeta)
                            .lineLimit(1)
                    }
                }
                .foregroundStyle(Palette.textFaint)
                .frame(width: 62, alignment: .trailing)
                .help(w.reset.map { Text(String(format: String(localized: "resets in %@"), $0)) }
                    ?? Text(verbatim: ""))
            }
        }
    }

    private func window(_ w: UsageWindow?) -> (used: Int, reset: String?)? {
        guard let w, w.usedPercent > 0 || w.resetsAt != nil else { return nil }
        if let resets = w.resetsAt, resets <= Date() { return nil }
        return (used: min(100, max(0, Int(w.usedPercent.rounded()))),
                reset: Fmt.resetsCompact(w.resetsAt))
    }

    private var footer: some View {
        VStack(spacing: 0) {
            Hairline()
            updateRow
            limits
            HStack(spacing: 9) {
                if model.activeInstances.isEmpty {
                    StatusDot(color: Palette.textFaint, size: 6)
                } else {
                    PulseDot(color: Palette.green, size: 7)
                }
                VStack(alignment: .leading, spacing: 1) {
                    Text(model.activeInstances.isEmpty
                         ? String(localized: "Night Shift is idle")
                         : String(localized: "Night Shift is working"))
                        .font(Typo.panelRow)
                        .foregroundStyle(Palette.text)
                    Text(shiftSummary)
                        .font(Typo.panelMeta)
                        .foregroundStyle(Palette.textFaint)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                SettingsLink {
                    Image(systemName: "gearshape")
                }
                .buttonStyle(.icon(size: 26, glyph: 13))
                .help(Text("Settings (⌘,)"))
                .accessibilityIdentifier("open.settings")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
        }
    }

    /// Only here when there is genuinely a new version. A button that does nothing most of the
    /// time teaches people to ignore that corner of the window.
    @ViewBuilder private var updateRow: some View {
        if let version = updates.availableVersion {
            Button { updates.checkForUpdates() } label: {
                HStack(spacing: 8) {
                    Image(systemName: "arrow.down.circle.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(Palette.accentEmphasis)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(String(format: String(localized: "Bulava %@ is available"), version))
                            .font(Typo.panelRow)
                            .foregroundStyle(Palette.text)
                            .lineLimit(1)
                        // Two lines, because one does not hold it at any sidebar width: the
                        // sentence was arriving as "Update and restart — the run that…", which
                        // cuts off exactly the half that says it is safe to press.
                        Text("Update and restart — a run in progress survives it")
                            .font(Typo.panelMeta)
                            .foregroundStyle(Palette.textFaint)
                            .lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .background(Palette.accentEmphasis.opacity(0.10))
            Hairline()
        }
    }

    private var shiftSummary: String {
        let running = model.activeInstances.count
        var parts: [String] = []
        if running > 0 {
            parts.append(String(format: String(localized: "%lld running"), running))
        }
        if parts.isEmpty { return String(localized: "Nothing in flight") }
        return parts.joined(separator: " · ")
    }
}

// MARK: - Brand mark

struct BrandMark: View {
    var size: CGFloat = 24

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.3, style: .continuous)
            .fill(Palette.brandField)
            .frame(width: size, height: size)
            .overlay(
                BulavaMark()
                    .fill(Palette.brandLime)
                    .frame(height: size * 0.6)
                    .padding(.bottom, size * 0.02)
            )
    }
}

struct BulavaMark: Shape {
    nonisolated func path(in rect: CGRect) -> Path { Path(BulavaGlyph.cgPath(in: rect)) }
}

// MARK: - The rail

private enum Rail {
    static let inset: CGFloat = 9
    static let glyph: CGFloat = 18
    static let gap: CGFloat = 9
    static var text: CGFloat { inset + glyph + gap }

    static let controls: CGFloat = 48
}

// MARK: - One product and its threads

private struct ProductGroup: View {
    @Environment(AppModel.self) private var model
    let product: Product
    @State private var expanded = false

    private static let visible = 5

    var body: some View {
        let chats = model.conversations.chats(for: product.id)
        let current = model.conversations.currentChatID(for: product.id)

        let open = model.route.productID == product.id ? current : nil
        let shown = shownChats(chats, current: current)
        let shownIDs = Set(shown.map(\.id))
        let folded = chats.filter { !shownIDs.contains($0.id) }
        VStack(spacing: 1) {
            ProductRow(product: product, foldedChats: folded)
            ForEach(shown) { chat in
                ChatRow(chat: chat, selected: chat.id == open)
            }
            if !folded.isEmpty || (expanded && chats.count > Self.visible) {
                more(folded: folded.count)
            }
        }
        .padding(.bottom, 8)

        .task(id: product.id) { await model.adoptProductIconIfNeeded(product.id) }
    }

    private func shownChats(_ chats: [Chat], current: UUID?) -> [Chat] {
        guard !expanded, chats.count > Self.visible else { return chats }
        var shown = Array(chats.prefix(Self.visible))
        if let current, !shown.contains(where: { $0.id == current }),
           let open = chats.first(where: { $0.id == current }) {
            shown[shown.count - 1] = open
        }
        return shown
    }

    private func more(folded: Int) -> some View {
        Button { withAnimation(Motion.standard) { expanded.toggle() } } label: {
            HStack(spacing: 0) {
                Text(expanded ? "Show less" : "Show more")
                Spacer(minLength: 0)
            }
            .font(Typo.body)
            .foregroundStyle(Palette.textFaint)
            .padding(.leading, Rail.text)
            .padding(.trailing, Rail.inset)
            .frame(minHeight: 26)
        }
        .buttonStyle(.row())
        .help(Text(expanded
                   ? String(localized: "Fold the older threads away")
                   : String(format: String(localized: "%lld more in this product"), folded)))
    }
}

// MARK: - Product row

private struct ProductRow: View {
    @Environment(AppModel.self) private var model
    let product: Product

    let foldedChats: [Chat]

    @State private var hovering = false
    @State private var choosingIcon = false

    private var selected: Bool { model.route == .product(product.id) }

    var body: some View {
        Button { model.open(product: product.id) } label: {
            HStack(spacing: Rail.gap) {

                Color.clear.frame(width: Rail.glyph, height: Rail.glyph)
                Text(product.name)
                    .font(selected ? Typo.rowLabel.weight(.semibold) : Typo.rowLabel)
                    .foregroundStyle(Palette.text)
                    .lineLimit(1)
                Spacer(minLength: hovering ? Rail.controls : 6)
            }
            .padding(.horizontal, Rail.inset)
            .frame(minHeight: 30)
        }

        .buttonStyle(.row(selected: selected && model.conversations.chats(for: product.id).isEmpty))
        .overlay(alignment: .leading) { icon }
        .overlay(alignment: .trailing) { trailing }
        .onHover { hovering = $0 }
        .contextMenu { actions }
    }

    private var icon: some View {
        Button { choosingIcon = true } label: {
            ProductIconTile(product: product, size: Rail.glyph, selected: selected)
        }
        .buttonStyle(.plain)
        .padding(.leading, Rail.inset)
        .popover(isPresented: $choosingIcon, arrowEdge: .trailing) {
            ProductIconPicker(product: product)
        }
        .help(Text("Choose an icon from this product's folders"))
    }

    @ViewBuilder private var trailing: some View {
        HStack(spacing: 1) {
            if hovering {
                Menu { actions } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Palette.textSecondary)
                        .frame(width: 22, height: 22)
                        .contentShape(Rectangle())
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help(Text("Product actions"))
                Button { model.newChat(in: product.id) } label: {
                    Image(systemName: "square.and.pencil")
                }
                .buttonStyle(.icon(size: 22, glyph: 11, tint: Palette.textSecondary))
                .help(Text("New chat (⌘N)"))
            } else {
                folded
            }
        }
        .padding(.trailing, hovering ? 3 : Rail.inset)
    }

    @ViewBuilder private var actions: some View {
        Button("New chat") { model.newChat(in: product.id) }
        Button(product.pinned ? "Unpin" : "Pin to top") { model.products.togglePin(product.id) }
        Button("Rename…") { model.beginRenaming(product) }
        Divider()
        Button("Remove product", role: .destructive) { model.removeProduct(product) }
    }

    @ViewBuilder private var folded: some View {
        let phases = foldedChats.map { model.directPhase(for: $0.id) }
        if phases.contains(where: \.wantsAttention) {
            StatusDot(color: phases.contains(where: \.isFailure) ? Palette.red : Palette.orange)
        } else if phases.contains(where: \.isActive) {
            PulseDot(color: Palette.green, size: 6)
        } else if phases.contains(.ready) {
            StatusDot(color: Palette.accent, size: 6)
        } else if product.pinned {
            Image(systemName: "pin.fill")
                .font(.system(size: 8))
                .foregroundStyle(Palette.textFaint)
        }
    }
}

// MARK: - Chat row

private struct ChatRow: View {
    @Environment(AppModel.self) private var model
    let chat: Chat
    let selected: Bool

    @State private var hovering = false

    var body: some View {
        Button { model.openChat(chat) } label: {
            HStack(spacing: 0) {
                Text(chat.title)
                    .font(Typo.body)
                    .foregroundStyle(selected ? Palette.text : Palette.textSecondary)
                    .lineLimit(1)
                Spacer(minLength: hovering ? Rail.controls : 8)
            }
            .padding(.leading, Rail.text)
            .padding(.trailing, Rail.inset)
            .frame(minHeight: 28)
        }
        .buttonStyle(.row(selected: selected))
        .overlay(alignment: .trailing) { trailing }
        .onHover { hovering = $0 }
        .contextMenu {
            Button(chat.pinned ? "Unpin" : "Pin to top") { model.conversations.togglePinned(chat.id) }
            Button("Rename…") { model.beginRenamingChat(chat) }
            Divider()

            Button("Archive") { model.archiveChat(chat) }
        }
        .help(Text(chat.title))
    }

    @ViewBuilder private var trailing: some View {
        HStack(spacing: 1) {
            if hovering {
                Button { model.conversations.togglePinned(chat.id) } label: {
                    Image(systemName: chat.pinned ? "pin.fill" : "pin")
                }
                .buttonStyle(.icon(size: 22, glyph: 10,
                                   tint: chat.pinned ? Palette.accentEmphasis : Palette.textSecondary))
                .help(Text(chat.pinned ? "Unpin" : "Pin to top"))
                Button { model.archiveChat(chat) } label: {
                    Image(systemName: "archivebox")
                }
                .buttonStyle(.icon(size: 22, glyph: 10, tint: Palette.textSecondary))
                .help(Text("Archive"))
            } else {
                if chat.pinned {
                    Image(systemName: "pin.fill")
                        .font(.system(size: 8))
                        .foregroundStyle(Palette.textFaint)
                }
                indicator
            }
        }
        .padding(.trailing, hovering ? 3 : Rail.inset)
    }

    @ViewBuilder private var indicator: some View {
        let phase = model.directPhase(for: chat.id)
        if phase.wantsAttention {
            StatusDot(color: phase.isFailure ? Palette.red : Palette.orange)
        } else if phase.isActive {
            PulseDot(color: Palette.green, size: 6)
        } else if phase == .ready {
            StatusDot(color: Palette.accent, size: 6)
        }
    }
}
