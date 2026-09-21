import SwiftUI
import AppKit

// MARK: - Color construction

extension Color {
    nonisolated init(hex: UInt32, alpha: Double = 1) {
        let r = Double((hex >> 16) & 0xFF) / 255
        let g = Double((hex >> 8) & 0xFF) / 255
        let b = Double(hex & 0xFF) / 255
        self.init(.sRGB, red: r, green: g, blue: b, opacity: alpha)
    }

    nonisolated static func theme(light: NSColor, dark: NSColor) -> Color {
        Color(nsColor: NSColor(name: nil, dynamicProvider: { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
        }))
    }

    nonisolated static func theme(light l: UInt32, dark d: UInt32, alpha: Double = 1) -> Color {
        theme(light: .ns(l, alpha), dark: .ns(d, alpha))
    }
}

extension NSColor {
    nonisolated static func ns(_ hex: UInt32, _ a: Double = 1) -> NSColor {
        NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
                green: CGFloat((hex >> 8) & 0xFF) / 255,
                blue: CGFloat(hex & 0xFF) / 255, alpha: CGFloat(a))
    }
}

// MARK: - Palette

nonisolated enum Palette {

    // MARK: Surfaces

    static let window        = Color.theme(light: 0xE7E7E8, dark: 0x171718)

    static let content       = Color.theme(light: 0xF6F6F7, dark: 0x19191A)

    static let chrome        = Color.theme(light: 0xE6E6E8, dark: 0x272729)

    static let chromeSunken  = Color.theme(light: 0xDDDDE0, dark: 0x2D2D2F)

    static let panel         = Color.theme(light: 0xFFFFFF, dark: 0x242426)

    static let panelMuted    = Color.theme(light: 0xEFEFF1, dark: 0x2B2B2E)

    static let panelRaised   = Color.theme(light: 0xE6E6E8, dark: 0x323235)

    static let field         = Color.theme(light: 0xFFFFFF, dark: 0x29292C)

    static let panelOnChrome = Color.theme(light: 0xFFFFFF, dark: 0x2E2E31)

    // MARK: Interaction

    static let hover         = Color.theme(light: .ns(0x000000, 0.045), dark: .ns(0xFFFFFF, 0.055))

    static let selected      = Color.theme(light: .ns(0x4B7510, 0.13), dark: .ns(0xC7F183, 0.15))

    static let selectedBorder = Color.theme(light: .ns(0x3C5F0D, 0.24), dark: .ns(0xC7F183, 0.32))

    // MARK: Text

    static let text          = Color.theme(light: 0x202023, dark: 0xF2F2F3)
    static let textSecondary = Color.theme(light: 0x626268, dark: 0xB5B5BB)

    static let textTertiary  = Color.theme(light: 0x64646B, dark: 0x92929A)

    static let textFaint     = Color.theme(light: 0x7C7C84, dark: 0x7C7C83)

    // MARK: Hairlines

    static let line          = Color.theme(light: .ns(0x000000, 0.075), dark: .ns(0xFFFFFF, 0.075))
    static let lineStrong    = Color.theme(light: .ns(0x000000, 0.14),  dark: .ns(0xFFFFFF, 0.13))

    // MARK: Brand

    static let brandLime     = Color(hex: 0xC7F183)

    static let brandField    = Color(hex: 0x16291C)

    // MARK: Accent

    static let accent        = Color.theme(light: 0x4B7510, dark: 0xB4E76D)

    static let accentEmphasis = Color.theme(light: 0x3C5F0D, dark: 0xC7F183)

    static let accentSoft    = Color.theme(light: .ns(0x4B7510, 0.10), dark: .ns(0xC7F183, 0.13))

    static let onAccent      = Color.theme(light: 0xFFFFFF, dark: 0x16291C)

    // MARK: Semantic

    static let green         = Color.theme(light: 0x1F6B41, dark: 0x69C58C)
    static let greenSoft     = Color.theme(light: .ns(0x1F6B41, 0.09), dark: .ns(0x69C58C, 0.12))
    static let orange        = Color.theme(light: 0x8A4E12, dark: 0xE8A45D)
    static let orangeSoft    = Color.theme(light: .ns(0x8A4E12, 0.09), dark: .ns(0xE8A45D, 0.13))
    static let red           = Color.theme(light: 0xA83B36, dark: 0xEF7770)
    static let redSoft       = Color.theme(light: .ns(0xA83B36, 0.09), dark: .ns(0xEF7770, 0.12))
    static let blue          = Color.theme(light: 0x3475BB, dark: 0x70A9F4)
    static let blueSoft      = Color.theme(light: .ns(0x3475BB, 0.09), dark: .ns(0x70A9F4, 0.12))

    static let track         = Color.theme(light: .ns(0x000000, 0.07), dark: .ns(0xFFFFFF, 0.07))

    static let terminal      = Color.theme(light: 0x1A1A1C, dark: 0x111112)

    static let onTerminal    = Color(hex: 0xD5D5DA)
    static let onTerminalDim = Color(hex: 0x9A9AA2)

    // MARK: Shadows

    static func shadow(_ opacity: Double) -> Color {
        .theme(light: .ns(0x2B2B2E, opacity * 0.5), dark: .ns(0x000000, opacity))
    }
}

// MARK: - Metrics

nonisolated enum Metrics {

    static let composerRestingHeight: CGFloat = 24

    static let radiusModal: CGFloat   = 14
    static let radiusCard: CGFloat    = 12
    static let radiusPanel: CGFloat   = 10
    static let radiusControl: CGFloat = 7
    static let radiusChip: CGFloat    = 6
    static let radiusBadge: CGFloat   = 5

    static let minimumWindowWidth: CGFloat  = 1_020
    static let minimumWindowHeight: CGFloat = 560
    static let sidebarMinWidth: CGFloat  = 184
    static let sidebarWidth: CGFloat   = 248
    static let inspectorWidth: CGFloat = 292

    static let conversationColumnIdealWidth: CGFloat = 700

    static let readingWidth: CGFloat   = 760

    static let controlHeight: CGFloat  = 29
    static let fieldHeight: CGFloat    = 36
    static let rowHeight: CGFloat      = 34
    static let iconButton: CGFloat     = 30

    static let gutter: CGFloat      = 16
    static let cardPadding: CGFloat = 15
    static let sectionGap: CGFloat  = 18
    static let hairline: CGFloat    = 1
}

// MARK: - Elevation

extension View {

    func restingShadow() -> some View {
        shadow(color: Palette.shadow(0.07), radius: 10, x: 0, y: 4)
    }

    func floatingShadow() -> some View {
        self.shadow(color: Palette.shadow(0.06), radius: 2, x: 0, y: 1)
            .shadow(color: Palette.shadow(0.17), radius: 26, x: 0, y: 12)
    }

    func modalShadow() -> some View {
        self.shadow(color: Palette.shadow(0.10), radius: 3, x: 0, y: 1)
            .shadow(color: Palette.shadow(0.34), radius: 60, x: 0, y: 26)
    }
}
