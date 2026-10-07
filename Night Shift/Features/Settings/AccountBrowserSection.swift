import SwiftUI

/// Bulava's browser in Settings: what state it is in, who has it, and the sites he signed in to —
/// each with "Sign in", and whether a run may use it while he is away.
struct AccountBrowserSection: View {
    @Environment(AppModel.self) private var model
    let browser: AccountBrowser

    @State private var typed = ""
    @State private var problem: String?
    @State private var confirmTaking: BrowserSite??

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            status
            if browser.enabled {
                if !browser.sites.isEmpty {
                    VStack(spacing: 0) {
                        ForEach(browser.sites) { site in
                            row(site)
                            if site.id != browser.sites.last?.id { Hairline() }
                        }
                    }
                    .background(RoundedRectangle(cornerRadius: Metrics.radiusPanel, style: .continuous).fill(Palette.field))
                    .overlay(RoundedRectangle(cornerRadius: Metrics.radiusPanel, style: .continuous)
                        .strokeBorder(Palette.line, lineWidth: Metrics.hairline))
                }
                addSite
            }
        }
        .padding(.vertical, 6)
        .confirmationDialog(Text("Take the browser back?"), isPresented: Binding(
            get: { confirmTaking != nil }, set: { if !$0 { confirmTaking = nil } })) {
            Button { if let pick = confirmTaking { confirmTaking = nil; open(pick, force: true) } } label: { Text("Sign in anyway") }
            Button(role: .cancel) { confirmTaking = nil } label: { Text("Wait") }
        } message: {
            Text(String(format: String(localized: "“%@” is using it right now. Signing in stops its work in the browser; it can ask again afterwards."),
                        browser.lease?.run.title ?? ""))
        }
    }

    // MARK: Parts

    @ViewBuilder private var status: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Circle().fill(statusColor).frame(width: 7, height: 7)
            Text(statusText)
                .font(Typo.caption)
                .foregroundStyle(Palette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            switch browser.mode {
            case .signingIn:
                Button { browser.finishSigningIn() } label: { Text("Done signing in") }
                    .buttonStyle(.bulava(.primary))
            case .working where browser.lease != nil:
                Button { browser.endLease() } label: { Text("Take it back") }
                    .buttonStyle(.bulava(.quiet))
            default:
                EmptyView()
            }
        }
    }

    private var statusText: String {
        guard browser.chrome != nil else {
            return String(localized: "Google Chrome is not installed. Runs keep the browser they had until it is.")
        }
        guard browser.enabled else { return String(localized: "Off: runs use whatever browser your own Claude setup gives them.") }
        switch browser.mode {
        case .signingIn:
            return String(localized: "Signing in. Sign in to the site in the window that opened, then press “Done signing in” or quit that Chrome.")
        case .working:
            if let lease = browser.lease {
                let time = DateFormatter.localizedString(from: lease.since, dateStyle: .none, timeStyle: .short)
                return String(format: String(localized: "“%@” is using it since %@. Other runs wait or work without it."),
                              lease.run.title, time)
            }
            return String(localized: "Open and free. The next run that needs a signed-in site gets it.")
        case .idle:
            return String(localized: "Ready. It opens when a run first needs a signed-in site; runs that need no sign-in get a throwaway browser of their own.")
        }
    }

    private var statusColor: Color {
        guard browser.enabled else { return Palette.textFaint }
        switch browser.mode {
        case .signingIn: return Palette.orange
        case .working: return browser.lease != nil ? Palette.accent : Palette.green
        case .idle: return Palette.green
        }
    }

    private func row(_ site: BrowserSite) -> some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(site.host)
                    .font(Typo.panelRow)
                    .foregroundStyle(Palette.text)
                Text(site.signedInAt.map {
                    String(format: String(localized: "Signed in %@"),
                           DateFormatter.localizedString(from: $0, dateStyle: .medium, timeStyle: .none))
                } ?? String(localized: "Not signed in yet"))
                    .font(Typo.panelMeta)
                    .foregroundStyle(Palette.textFaint)
            }
            Spacer(minLength: 8)
            Toggle(isOn: Binding(get: { site.withoutMe }, set: { browser.setWithoutMe(site.id, $0) })) {
                Text("Without me")
                    .font(Typo.caption)
                    .foregroundStyle(Palette.textSecondary)
            }
            .toggleStyle(.switch)
            .controlSize(.mini)
            .help(Text("On: night runs and automations may use this site while you are away. Off: only a chat you are in may."))
            Button { open(site) } label: { Text("Sign in") }
                .buttonStyle(.bulava(.quiet))
                .disabled(browser.mode == .signingIn)
            Button { browser.removeSite(site.id) } label: { Image(systemName: "xmark") }
                .buttonStyle(.icon(size: 24, glyph: 10))
                .help(Text("Remove from the list. What you signed in to stays in the browser until you sign out there."))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
    }

    private var addSite: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                TextField(String(localized: "A site to sign in to, e.g. play.google.com/console"), text: $typed)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(add)
                Button { add() } label: { Text("Sign in") }
                    .buttonStyle(.bulava())
                    .disabled(typed.trimmingCharacters(in: .whitespaces).isEmpty || browser.mode == .signingIn)
            }
            if let problem {
                Text(problem).font(Typo.panelMeta).foregroundStyle(Palette.orange)
            }
            Text("A site you add is closed to runs without you until you turn on “Without me”. Your own Chrome is never touched: runs in Bulava no longer reach it.")
                .font(Typo.panelMeta)
                .foregroundStyle(Palette.textFaint)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func add() {
        guard let site = browser.addSite(typed) else {
            problem = String(localized: "That is not a site's address.")
            return
        }
        problem = nil
        typed = ""
        open(site)
    }

    private func open(_ site: BrowserSite?, force: Bool = false) {
        if browser.lease != nil, !force { confirmTaking = .some(site); return }
        Task { await browser.signIn(site) }
    }
}
