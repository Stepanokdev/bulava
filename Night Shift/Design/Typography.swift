import SwiftUI

nonisolated enum Typo {

    // MARK: Document

    static let reportTitle   = Font.system(size: 31, weight: .semibold)

    static let reportLede    = Font.system(size: 15, weight: .regular)

    static let reportSection = Font.system(size: 17, weight: .semibold)

    // MARK: Screen

    static let screenTitle = Font.system(size: 24, weight: .semibold)

    static let inviteTitle = Font.system(size: 22, weight: .semibold)

    // MARK: Chrome

    static let brand       = Font.system(size: 16, weight: .semibold)

    static let toolbarTitle = Font.system(size: 14, weight: .semibold)

    // MARK: Cards

    static let cardTitle   = Font.system(size: 14, weight: .semibold)

    static let message     = Font.system(size: 13.5, weight: .regular)

    static let body        = Font.system(size: 13, weight: .regular)

    static let rowLabel    = Font.system(size: 13, weight: .medium)

    static let step        = Font.system(size: 12, weight: .regular)

    static let control     = Font.system(size: 11.5, weight: .medium)

    static let panelRow    = Font.system(size: 11.5, weight: .medium)

    static let caption     = Font.system(size: 11, weight: .regular)

    static let meta        = Font.system(size: 10.5, weight: .regular)

    static let panelMeta   = Font.system(size: 9.5, weight: .regular)

    static let tag         = Font.system(size: 9, weight: .semibold)

    static let badge       = Font.system(size: 10, weight: .semibold)

    // MARK: Diagnostics

    static func mono(_ size: CGFloat = 10.5) -> Font { .system(size: size, design: .monospaced) }
}

// MARK: - Composite styles

extension View {

    func reportTitleStyle() -> some View {
        font(Typo.reportTitle).tracking(-1.1).lineSpacing(2)
    }

    func screenTitleStyle() -> some View {
        font(Typo.screenTitle).tracking(-0.72)
    }

    func inviteTitleStyle() -> some View {
        font(Typo.inviteTitle).tracking(-0.55)
    }

    func reportSectionStyle() -> some View {
        font(Typo.reportSection).tracking(-0.34)
    }

    func reportLedeStyle() -> some View {
        font(Typo.reportLede).lineSpacing(6)
    }

    func messageStyle() -> some View {
        font(Typo.message).lineSpacing(5)
    }

    func cardTitleStyle() -> some View {
        font(Typo.cardTitle).tracking(-0.14)
    }

    func brandStyle() -> some View {
        font(Typo.brand).tracking(-0.32)
    }
}

// MARK: - Eyebrow

struct Eyebrow: View {
    private let text: LocalizedStringKey
    private let color: Color

    init(_ text: LocalizedStringKey, color: Color = Palette.textFaint) {
        self.text = text
        self.color = color
    }

    var body: some View {
        Text(text)
            .font(Typo.eyebrowFont)
            .tracking(0.72)
            .textCase(.uppercase)
            .foregroundStyle(color)
    }
}

extension Typo {

    static let eyebrowFont = Font.system(size: 10, weight: .semibold)
}
