import SwiftUI
import AppKit

struct MenuBarView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow

    private struct Glance: Identifiable {
        var id: UUID { product.id }
        let product: Product
        let state: WorkState
        let reports: Int
        let startedAt: Date?
    }

    // MARK: - Body

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header

            let needing = needsUser
            let live = working

            if !needing.isEmpty {
                divider
                section("Needs you") {
                    ForEach(needing) { glance in attentionRow(glance) }
                }
            }

            if !live.isEmpty {
                divider
                section("Working now") {
                    ForEach(live) { glance in runningRow(glance) }
                }
            }

            if needing.isEmpty && live.isEmpty {
                divider
                Text("Nothing needs you right now.")
                    .font(Typo.caption)
                    .foregroundStyle(Palette.textTertiary)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 2)
            }

            divider
            footer
        }
        .padding(12)
        .frame(width: 300)
        .background(Palette.panel)
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 9) {
            if model.activeInstances.isEmpty {
                StatusDot(color: Palette.textFaint, size: 6)
            } else {
                PulseDot(color: Palette.green, size: 7)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(model.activeInstances.isEmpty ? "Bulava is idle" : "Bulava is working")
                    .font(Typo.panelRow)
                    .foregroundStyle(Palette.text)
                Text(shiftSummary)
                    .font(Typo.panelMeta)
                    .foregroundStyle(Palette.textFaint)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 4)
    }

    private var shiftSummary: String {
        let running = model.activeInstances.count
        let queued = model.queue.pendingCount
        var parts: [String] = []
        if running > 0 {
            parts.append(String(format: String(localized: "%lld running"), running))
        }
        if queued > 0 {
            parts.append(String(format: String(localized: "%lld waiting"), queued))
        }
        if parts.isEmpty { return String(localized: "Nothing in flight") }
        return parts.joined(separator: " · ")
    }

    // MARK: - Sections

    private var divider: some View {
        Hairline().padding(.vertical, 10)
    }

    private func section<Content: View>(_ title: LocalizedStringKey,
                                        @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Eyebrow(title)
                .padding(.horizontal, 4)
                .padding(.bottom, 4)
            content()
        }
    }

    // MARK: - Rows

    private func attentionRow(_ glance: Glance) -> some View {
        Button { reveal(glance.product) } label: {
            HStack(spacing: 9) {
                ProductMonogram(initials: glance.product.initials, size: 21)
                VStack(alignment: .leading, spacing: 1) {
                    Text(glance.product.name)
                        .font(Typo.panelRow)
                        .foregroundStyle(Palette.text)
                        .lineLimit(1)
                    need(glance)
                        .font(Typo.panelMeta)
                        .foregroundStyle(tint(glance.state))
                        .lineLimit(1)
                }
                Spacer(minLength: 4)
                if glance.state == .reportReady, glance.reports > 0 {
                    CountBadge(count: glance.reports, accented: true)
                } else {
                    StatusDot(color: tint(glance.state))
                }
            }
            .padding(.horizontal, 4)
            .frame(minHeight: Metrics.rowHeight)
        }
        .buttonStyle(.row())
    }

    private func runningRow(_ glance: Glance) -> some View {
        Button { reveal(glance.product) } label: {
            HStack(spacing: 9) {
                ProductMonogram(initials: glance.product.initials, size: 21)
                VStack(alignment: .leading, spacing: 1) {
                    Text(glance.product.name)
                        .font(Typo.panelRow)
                        .foregroundStyle(Palette.text)
                        .lineLimit(1)
                    if glance.state == .running, let started = glance.startedAt {
                        ElapsedLabel(since: started, font: Typo.panelMeta, color: Palette.textFaint)
                    } else {
                        Text(LocalizedStringKey(glance.state.labelKey))
                            .font(Typo.panelMeta)
                            .foregroundStyle(Palette.textFaint)
                    }
                }
                Spacer(minLength: 4)
                if glance.state == .running {
                    PulseDot(color: Palette.green, size: 6)
                } else {
                    StatusDot(color: Palette.orange)
                }
            }
            .padding(.horizontal, 4)
            .frame(minHeight: Metrics.rowHeight)
        }
        .buttonStyle(.row())
    }

    private func need(_ glance: Glance) -> Text {
        if glance.state == .reportReady, glance.reports > 1 {
            return Text("\(glance.reports) ready to read")
        }
        return Text(LocalizedStringKey(glance.state.labelKey))
    }

    private func tint(_ state: WorkState) -> Color {
        switch state {
        case .needsAnswer: Palette.orange
        case .failed:      Palette.red
        case .reportReady: Palette.accentEmphasis
        case .paused:      Palette.orange
        case .running:     Palette.green
        default:           Palette.textFaint
        }
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: 8) {
            Button { openMainWindow() } label: { Text("Open Bulava") }
                .buttonStyle(.bulava(.primary))
            Spacer(minLength: 0)
            Button { NSApp.terminate(nil) } label: { Text("Quit") }
                .buttonStyle(.bulava(.quiet))
        }
    }

    // MARK: - Data

    private var glances: [Glance] {
        model.products.sorted.compactMap { product in
            guard let state = model.state(forProductID: product.id) else { return nil }
            return Glance(product: product,
                          state: state,
                          reports: model.reportsWaiting(forProductID: product.id),
                          startedAt: model.liveInstance(forProductID: product.id)?.startedAt)
        }
    }

    private var needsUser: [Glance] {

        let order: [WorkState] = [.needsAnswer, .partial, .failed, .reportReady]
        return glances
            .filter { order.contains($0.state) }
            .sorted { (order.firstIndex(of: $0.state) ?? 9) < (order.firstIndex(of: $1.state) ?? 9) }
            .prefix(5)
            .map { $0 }
    }

    private var working: [Glance] {
        glances
            .filter { $0.state == .running || $0.state == .paused }
            .prefix(4)
            .map { $0 }
    }

    // MARK: - Cross-scene navigation

    private func reveal(_ product: Product) {
        openMainWindow()
        model.open(product: product.id)
    }

    /// Bring back the window that is already there; open one only when there is none. Every press
    /// of "Open Bulava" used to add a window, and every window started its own copy of the app's
    /// machinery — which from the outside looks exactly like several Bulavas running at once.
    private func openMainWindow() {
        MainWindow.reveal { openWindow(id: "main") }
    }
}
