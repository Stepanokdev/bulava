import SwiftUI

// MARK: - Surfaces

struct Card<Content: View>: View {
    private var radius: CGFloat
    private var fill: Color
    private var border: Color
    private var content: Content

    init(radius: CGFloat = Metrics.radiusCard,
         fill: Color = Palette.panel,
         border: Color = Palette.lineStrong,
         @ViewBuilder content: () -> Content) {
        self.radius = radius
        self.fill = fill
        self.border = border
        self.content = content()
    }

    var body: some View {
        content
            .background(RoundedRectangle(cornerRadius: radius, style: .continuous).fill(fill))
            .overlay(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .strokeBorder(border, lineWidth: Metrics.hairline)
            )
            .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
            .restingShadow()
    }
}

struct PanelCard<Content: View>: View {
    private var content: Content
    init(@ViewBuilder content: () -> Content) { self.content = content() }

    var body: some View {
        content
            .background(
                RoundedRectangle(cornerRadius: Metrics.radiusPanel, style: .continuous)
                    .fill(Palette.panelOnChrome)
            )
            .overlay(
                RoundedRectangle(cornerRadius: Metrics.radiusPanel, style: .continuous)
                    .strokeBorder(Palette.line, lineWidth: Metrics.hairline)
            )
            .clipShape(RoundedRectangle(cornerRadius: Metrics.radiusPanel, style: .continuous))
    }
}

struct Hairline: View {
    var color: Color = Palette.line
    var body: some View { Rectangle().fill(color).frame(height: Metrics.hairline) }
}

// MARK: - Buttons

enum ButtonRole2 {
    case primary, secondary, quiet, danger
}

struct BulavaButtonStyle: ButtonStyle {
    var role: ButtonRole2 = .secondary
    @State private var hovering = false
    @Environment(\.isEnabled) private var enabled
    @Environment(\.motionEnabled) private var motionEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Typo.control)
            .foregroundStyle(label(pressed: configuration.isPressed))
            .padding(.horizontal, role == .primary ? 13 : 11)
            .frame(height: Metrics.controlHeight)
            .background(
                RoundedRectangle(cornerRadius: Metrics.radiusControl, style: .continuous)
                    .fill(fill(pressed: configuration.isPressed))
            )
            .overlay(
                RoundedRectangle(cornerRadius: Metrics.radiusControl, style: .continuous)
                    .strokeBorder(border, lineWidth: Metrics.hairline)
            )
            .opacity(enabled ? 1 : 0.4)
            .scaleEffect(motionEnabled && configuration.isPressed ? 0.97 : 1)
            .animation(Motion.hover, value: configuration.isPressed)
            .animation(Motion.hover, value: hovering)
            .onHover { hovering = $0 }
    }

    private func fill(pressed: Bool) -> Color {
        switch role {
        case .primary:
            return pressed ? Palette.accentEmphasis : (hovering ? Palette.accentEmphasis : Palette.accent)
        case .secondary:
            return pressed ? Palette.panelRaised : (hovering ? Palette.panelRaised : Palette.panelMuted)
        case .quiet, .danger:
            return hovering ? Palette.hover : .clear
        }
    }

    private func label(pressed: Bool) -> Color {
        switch role {
        case .primary: return Palette.onAccent
        case .secondary: return hovering ? Palette.text : Palette.textSecondary
        case .quiet: return hovering ? Palette.text : Palette.textSecondary
        case .danger: return Palette.red
        }
    }

    private var border: Color {
        switch role {
        case .primary: return .clear
        case .secondary: return Palette.lineStrong
        case .quiet, .danger: return Palette.line
        }
    }
}

extension ButtonStyle where Self == BulavaButtonStyle {
    static func bulava(_ role: ButtonRole2 = .secondary) -> BulavaButtonStyle {
        BulavaButtonStyle(role: role)
    }
}

struct IconButtonStyle: ButtonStyle {
    var size: CGFloat = Metrics.iconButton
    var glyphSize: CGFloat = 15
    var tint: Color = Palette.textSecondary
    @State private var hovering = false
    @Environment(\.motionEnabled) private var motionEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: glyphSize, weight: .regular))
            .foregroundStyle(hovering ? Palette.text : tint)
            .frame(width: size, height: size)
            .background(
                RoundedRectangle(cornerRadius: Metrics.radiusControl, style: .continuous)
                    .fill(hovering ? Palette.hover : .clear)
            )
            .scaleEffect(motionEnabled && configuration.isPressed ? 0.92 : 1)
            .animation(Motion.hover, value: configuration.isPressed)
            .animation(Motion.hover, value: hovering)
            .onHover { hovering = $0 }
            .contentShape(Rectangle())
    }
}

extension ButtonStyle where Self == IconButtonStyle {
    static var icon: IconButtonStyle { IconButtonStyle() }
    static func icon(size: CGFloat = Metrics.iconButton,
                     glyph: CGFloat = 15,
                     tint: Color = Palette.textSecondary) -> IconButtonStyle {
        IconButtonStyle(size: size, glyphSize: glyph, tint: tint)
    }
}

struct RowButtonStyle: ButtonStyle {
    var selected: Bool = false
    var radius: CGFloat = Metrics.radiusControl
    @State private var hovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .fill(selected ? Palette.selected : (hovering ? Palette.hover : .clear))
            )
            .overlay(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .strokeBorder(selected ? Palette.selectedBorder : .clear, lineWidth: Metrics.hairline)
            )
            .contentShape(Rectangle())
            .animation(Motion.hover, value: hovering)
            .animation(Motion.hover, value: selected)
            .onHover { hovering = $0 }
    }
}

extension ButtonStyle where Self == RowButtonStyle {
    static func row(selected: Bool = false, radius: CGFloat = Metrics.radiusControl) -> RowButtonStyle {
        RowButtonStyle(selected: selected, radius: radius)
    }
}

// MARK: - Status

struct StatusDot: View {
    var color: Color = Palette.green
    var size: CGFloat = 6

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: size, height: size)
            .padding(size / 2)
            .background(Circle().fill(color.opacity(0.16)))
    }
}

struct PulseDot: View {
    var color: Color = Palette.green
    var size: CGFloat = 8
    @Environment(\.motionEnabled) private var motionEnabled
    @State private var expanded = false

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: size, height: size)
            .overlay(
                Circle()
                    .stroke(color, lineWidth: 1.5)
                    .scaleEffect(expanded ? 2.4 : 1)
                    .opacity(expanded ? 0 : 0.5)
            )
            .onAppear {
                guard motionEnabled else { return }
                withAnimation(Motion.breathe.repeatForever(autoreverses: false)) { expanded = true }
            }
    }
}

struct StatePill: View {
    var text: LocalizedStringKey
    var systemImage: String
    var tint: Color
    var wash: Color

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: systemImage).font(.system(size: 9, weight: .semibold))
            Text(text).font(Typo.meta)
        }
        .foregroundStyle(tint)
        .padding(.horizontal, 9)
        .frame(height: 23)
        .background(Capsule(style: .continuous).fill(wash))
        .fixedSize()
    }
}

struct CountBadge: View {
    var count: Int
    var accented: Bool = false

    var body: some View {
        Text("\(count)")
            .font(Typo.badge)
            .monospacedDigit()
            .foregroundStyle(accented ? Palette.accentEmphasis : Palette.textSecondary)
            .padding(.horizontal, 5)
            .frame(minWidth: 18, minHeight: 18)
            .background(Capsule(style: .continuous).fill(accented ? Palette.accentSoft : Palette.panelRaised))
    }
}

struct AccessLock: View {
    var readOnly: Bool
    var change: (ResourceAccess) -> Void

    var body: some View {
        Menu {
            Picker("Access", selection: Binding(get: { readOnly ? ResourceAccess.source : .workspace },
                                                set: { change($0) })) {
                Text("Can edit").tag(ResourceAccess.workspace)
                Text("Ask before editing").tag(ResourceAccess.source)
            }
            .pickerStyle(.inline)
        } label: {
            Image(systemName: readOnly ? "lock.fill" : "lock.open")
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(readOnly ? Palette.orange : Palette.textFaint)
                .frame(width: 22, height: 20)
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(Text(readOnly ? "Ask before editing — click to change" : "Can edit — click to change"))
    }
}

// MARK: - Identity

struct ProductMonogram: View {
    var initials: String
    var selected: Bool = false
    var size: CGFloat = 21

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.29, style: .continuous)
            .fill(selected
                  ? AnyShapeStyle(LinearGradient(colors: [Palette.accentEmphasis, Palette.accent],
                                                 startPoint: .topLeading, endPoint: .bottomTrailing))
                  : AnyShapeStyle(Palette.panelRaised))
            .frame(width: size, height: size)
            .overlay(
                Text(initials)
                    .font(.system(size: size * 0.46, weight: .bold))
                    .foregroundStyle(selected ? Palette.onAccent : Palette.textSecondary)
            )
    }
}

struct SpeakerAvatar: View {
    var initial: String
    var isForeman: Bool

    var body: some View {
        RoundedRectangle(cornerRadius: 6, style: .continuous)
            .fill(isForeman ? Palette.accentSoft : Palette.panelRaised)
            .frame(width: 18, height: 18)
            .overlay(
                Text(initial)
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(isForeman ? Palette.accentEmphasis : Palette.textSecondary)
            )
    }
}

// MARK: - Labels

struct PanelTitle<Trailing: View>: View {
    private var text: LocalizedStringKey
    private var trailing: Trailing

    init(_ text: LocalizedStringKey, @ViewBuilder trailing: () -> Trailing = { EmptyView() }) {
        self.text = text
        self.trailing = trailing()
    }

    var body: some View {
        HStack(spacing: 6) {
            Eyebrow(text)
            Spacer(minLength: 4)
            trailing
        }
        .frame(minHeight: 20)
        .padding(.horizontal, 6)
    }
}

struct KeyHint: View {
    var keys: String

    var body: some View {
        Text(keys)
            .font(.system(size: 10, weight: .medium))
            .foregroundStyle(Palette.textFaint)
            .padding(.horizontal, 4)
            .padding(.vertical, 1)
            .background(
                RoundedRectangle(cornerRadius: 4, style: .continuous).fill(Palette.hover)
            )
    }
}

// MARK: - Meter

struct Meter: View {
    var fraction: Double
    var tint: Color = Palette.accent

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Palette.track)
                Capsule()
                    .fill(tint)
                    .frame(width: max(4, geo.size.width * min(max(fraction, 0), 1)))
            }
        }
        .frame(height: 4)
    }
}

// MARK: - Responsive flow

struct WrappingHStack: Layout {
    var horizontalSpacing: CGFloat = 8
    var verticalSpacing: CGFloat = 8

    var maximumUnproposedWidth: CGFloat = 328

    func sizeThatFits(proposal: ProposedViewSize,
                     subviews: Subviews,
                     cache: inout ()) -> CGSize {
        arranged(in: proposedWidth(proposal.width), subviews: subviews).size
    }

    func placeSubviews(in bounds: CGRect,
                       proposal: ProposedViewSize,
                       subviews: Subviews,
                       cache: inout ()) {
        let result = arranged(in: bounds.width, subviews: subviews)
        for (index, origin) in result.origins.enumerated() {
            subviews[index].place(at: CGPoint(x: bounds.minX + origin.x,
                                              y: bounds.minY + origin.y),
                                  anchor: .topLeading,
                                  proposal: .unspecified)
        }
    }

    private func arranged(in availableWidth: CGFloat, subviews: Subviews)
        -> (size: CGSize, origins: [CGPoint]) {
        guard !subviews.isEmpty else { return (.zero, []) }

        let width = max(0, availableWidth)
        let sizes = subviews.map { $0.sizeThatFits(.unspecified) }
        var origins: [CGPoint] = []
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        var usedWidth: CGFloat = 0

        for size in sizes {
            let nextX = x == 0 ? 0 : x + horizontalSpacing
            if nextX > 0, nextX + size.width > width {
                x = 0
                y += rowHeight + verticalSpacing
                rowHeight = 0
            } else {
                x = nextX
            }

            origins.append(CGPoint(x: x, y: y))
            x += size.width
            usedWidth = max(usedWidth, min(x, width))
            rowHeight = max(rowHeight, size.height)
        }

        return (CGSize(width: usedWidth, height: y + rowHeight), origins)
    }

    private func proposedWidth(_ value: CGFloat?) -> CGFloat {
        guard let value, value.isFinite else { return maximumUnproposedWidth }
        return value
    }
}

// MARK: - Elapsed time

struct ElapsedLabel: View {
    let since: Date
    var font: Font = Typo.caption
    var color: Color = Palette.textFaint

    var body: some View {
        TimelineView(.periodic(from: since, by: 1)) { ctx in
            Text(Fmt.elapsed(ctx.date.timeIntervalSince(since)))
                .font(font)
                .monospacedDigit()
                .foregroundStyle(color)
        }
    }
}

struct CountdownLabel: View {
    let until: Date
    var font: Font = Typo.caption
    var color: Color = Palette.textFaint

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { ctx in
            Text(text(at: ctx.date))
                .font(font)
                .monospacedDigit()
                .foregroundStyle(color)
        }
    }

    private func text(at now: Date) -> String {
        guard until.timeIntervalSince(now) > 0 else { return String(localized: "any moment now") }
        guard let left = Fmt.resetsCompact(until) else { return Fmt.clock(until) }
        return "\(Fmt.clock(until)) · \(left)"
    }
}

// MARK: - Empty state

struct InviteState: View {
    var systemImage: String
    var title: Text
    var message: LocalizedStringKey

    var body: some View {
        VStack(spacing: 0) {
            RoundedRectangle(cornerRadius: 15, style: .continuous)
                .fill(Palette.accentSoft)
                .frame(width: 52, height: 52)
                .overlay(
                    Image(systemName: systemImage)
                        .font(.system(size: 22, weight: .light))
                        .foregroundStyle(Palette.accentEmphasis)
                )
                .padding(.bottom, 17)

            title
                .inviteTitleStyle()
                .foregroundStyle(Palette.text)
                .padding(.bottom, 8)

            Text(message)
                .font(Typo.body)
                .lineSpacing(4)
                .foregroundStyle(Palette.textTertiary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
        }
        .frame(maxWidth: .infinity)
    }
}
