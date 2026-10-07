import SwiftUI
import AppKit

/// The cards in the window's top-right corner — where macOS itself puts what it has to say.
///
/// Newest on top. Only the cards take clicks: the rest of the layer lets them through, so the
/// conversation underneath stays usable while a card is up.
struct ToastStackView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.motionEnabled) private var motionEnabled

    var body: some View {
        VStack(alignment: .trailing, spacing: 8) {
            ForEach(model.toasts.reversed()) { toast in
                ToastCard(toast: toast)
                    .transition(motionEnabled
                                ? .asymmetric(insertion: .move(edge: .trailing).combined(with: .opacity),
                                              removal: .move(edge: .trailing).combined(with: .opacity))
                                : .opacity)
            }
        }
        .padding(.top, 12)
        .padding(.trailing, 14)
        .padding(.leading, 14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
        .animation(Motion.snappy, value: model.toasts)
    }
}

/// One card: what happened, all of it; what to do about it; and the technical part folded away.
struct ToastCard: View {
    @Environment(AppModel.self) private var model
    let toast: ToastMessage

    @State private var showsDetail = false
    @State private var hovering = false
    @State private var copied = false

    static let width: CGFloat = 368

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

    /// The headline is either the title or the text's first line; the body is whatever is left.
    /// Nothing is cut short — the reason a refusal gives is the part people need.
    private var headline: String {
        if let title = toast.title, !title.isEmpty { return title }
        return toast.text.split(whereSeparator: \.isNewline).first.map(String.init) ?? toast.text
    }

    private var bodyText: String? {
        if let title = toast.title, !title.isEmpty { return toast.text.isEmpty ? nil : toast.text }
        let lines = toast.text.split(whereSeparator: \.isNewline)
        guard lines.count > 1 else { return nil }
        return lines.dropFirst().joined(separator: "\n")
    }

    private var copyable: String {
        [toast.title, toast.text, toast.detail].compactMap { $0 }.filter { !$0.isEmpty }
            .joined(separator: "\n\n")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 10) {
                Group {
                    if toast.inProgress {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: symbol)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(tint)
                    }
                }
                .frame(width: 16, height: 16)
                .padding(.top, 1)

                VStack(alignment: .leading, spacing: 4) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(verbatim: headline)
                            .font(Typo.rowLabel)
                            .foregroundStyle(Palette.text)
                            .fixedSize(horizontal: false, vertical: true)
                            .textSelection(.enabled)
                        if toast.count > 1 {
                            Text(verbatim: "×\(toast.count)")
                                .font(Typo.badge)
                                .monospacedDigit()
                                .foregroundStyle(Palette.textSecondary)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1)
                                .background(Capsule().fill(Palette.panelMuted))
                                .accessibilityLabel(Text(String(format: String(localized: "%lld times"), toast.count)))
                        }
                    }
                    if let bodyText {
                        Text(verbatim: bodyText)
                            .font(Typo.caption)
                            .foregroundStyle(Palette.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .textSelection(.enabled)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                Button { close() } label: {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.icon(size: 20, glyph: 10, tint: Palette.textFaint))
                .opacity(hovering || toast.kind == .error ? 1 : 0.0)
                .help(Text("Close"))
                .accessibilityLabel(Text("Close"))
            }

            if let detail = toast.detail, !detail.isEmpty, showsDetail {
                ScrollView {
                    Text(verbatim: detail)
                        .font(Typo.mono(10))
                        .foregroundStyle(Palette.textSecondary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                }
                .frame(maxHeight: 160)
                .background(RoundedRectangle(cornerRadius: Metrics.radiusChip, style: .continuous)
                    .fill(Palette.panelMuted))
                .padding(.top, 9)
                .padding(.leading, 26)
                .transition(.opacity)
            }

            if !toast.actions.isEmpty || toast.detail?.isEmpty == false || toast.kind == .error {
                HStack(spacing: 6) {
                    ForEach(toast.actions) { action in
                        Button {
                            action.perform()
                            if !action.keepsCard { close() }
                        } label: { Text(verbatim: action.title) }
                        .buttonStyle(.bulava(action.primary ? .primary : .secondary))
                        .controlSize(.small)
                    }
                    Spacer(minLength: 4)
                    if toast.detail?.isEmpty == false {
                        Button {
                            withAnimation(Motion.expand) { showsDetail.toggle() }
                        } label: {
                            Text(showsDetail ? LocalizedStringKey("Hide details") : LocalizedStringKey("Details"))
                        }
                        .buttonStyle(.bulava(.quiet))
                    }
                    if toast.kind == .error {
                        Button { copy() } label: {
                            Label(copied ? String(localized: "Copied") : String(localized: "Copy"),
                                  systemImage: copied ? "checkmark" : "doc.on.doc")
                        }
                        .buttonStyle(.bulava(.quiet))
                        .help(Text("Copy the whole message, details included"))
                    }
                }
                .padding(.top, 10)
                .padding(.leading, 26)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 11)
        .frame(width: ToastCard.width, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: Metrics.radiusCard, style: .continuous)
                .fill(Palette.panel)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Metrics.radiusCard, style: .continuous)
                .strokeBorder(Palette.lineStrong, lineWidth: Metrics.hairline)
        )
        .floatingShadow()
        .onHover { hovering = $0 }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text(verbatim: [headline, bodyText].compactMap { $0 }.joined(separator: ". ")))
        .task(id: "\(toast.id)-\(toast.count)-\(hovering)") {
            // Good news leaves by itself — but not while the pointer is on it, being read.
            guard toast.dismissesItself, !hovering else { return }
            try? await Task.sleep(for: .seconds(4))
            if !Task.isCancelled { close() }
        }
        .onAppear {
            if toast.kind == .error {
                AccessibilityNotification.Announcement(headline).post()
            }
        }
    }

    private func close() {
        withAnimation(Motion.snappy) { model.dismissToast(toast.id) }
    }

    private func copy() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(copyable, forType: .string)
        copied = true
        Task {
            try? await Task.sleep(for: .seconds(1.5))
            copied = false
        }
    }
}
