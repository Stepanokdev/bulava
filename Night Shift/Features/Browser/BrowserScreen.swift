import SwiftUI

/// Bulava's browser, as a section of its own in the sidebar — beside Automations and Pipelines,
/// not a row buried in Settings.
///
/// Which sites a run may reach while he is away is a standing decision he comes back to, the same
/// kind of thing as an automation or a pipeline; Settings is for switches set once. The screen is
/// the switch (on or off), the short word on what the browser is, and then the existing
/// `AccountBrowserSection` — the live state, who holds it now, and the signed-in sites.
struct BrowserScreen: View {
    @Environment(AppModel.self) private var model

    private var enabled: Binding<Bool> {
        Binding(get: { model.settings.accountBrowserEnabled },
                set: { model.settings.accountBrowserEnabled = $0 })
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Hairline()
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Text("Runs work in a Chrome of Bulava's own: you sign in to sites there once, and runs use them without asking you — several at once, each in its own tabs. Runs that need no sign-in get a throwaway browser. Off, runs use the browser your own Claude setup gives them.")
                        .font(Typo.panelRow)
                        .foregroundStyle(Palette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if model.settings.accountBrowserEnabled {
                        AccountBrowserSection(browser: model.browser)
                    }
                }
                .frame(maxWidth: Metrics.readingWidth, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 18)
                .padding(.vertical, 16)
            }
            .scrollIndicators(.automatic)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Palette.content)
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text("Bulava's browser")
                .font(Typo.screenTitle)
                .foregroundStyle(Palette.text)
            Spacer(minLength: 8)
            Toggle("", isOn: enabled)
                .toggleStyle(.switch)
                .labelsHidden()
                .help(Text("Turn Bulava's own browser on or off"))
        }
        .padding(.horizontal, 18)
        .padding(.top, 16)
        .padding(.bottom, 12)
    }
}
