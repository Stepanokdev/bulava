import SwiftUI
import CoreImage
import CoreImage.CIFilterBuiltins

/// The phone in the toolbar: whether one is paired and whether it is here right now, and — one
/// click away — the code that pairs a new one and the way to remove an old one.
///
/// The state is said in words wherever it is shown. A dot that is green or not cannot tell "no
/// phone" from "a phone that is asleep in another room", and those need different things done.
struct PhoneLinkButton: View {
    @Environment(AppModel.self) private var model
    @State private var open = false

    private var link: MobileLink { model.mobileLink }

    var body: some View {
        Button { open.toggle() } label: {
            Image(systemName: symbol)
                .overlay(alignment: .topTrailing) {
                    if let tint {
                        Circle().fill(tint)
                            .frame(width: 6, height: 6)
                            .offset(x: 3, y: -2)
                    }
                }
        }
        .buttonStyle(.icon)
        .help(Text(verbatim: PhoneLinkPanel.statusLine(link.status)))
        .accessibilityLabel(Text("Bulava on your phone"))
        .accessibilityValue(Text(verbatim: PhoneLinkPanel.statusLine(link.status)))
        .popover(isPresented: $open, arrowEdge: .bottom) {
            PhoneLinkPanel()
                .environment(model)
        }
    }

    private var symbol: String {
        switch link.status {
        case .noPhone: "iphone"
        case .offline: "iphone"
        case .connected: "iphone.radiowaves.left.and.right"
        case .unavailable: "iphone.slash"
        }
    }

    private var tint: Color? {
        switch link.status {
        case .connected: Palette.green
        case .unavailable: Palette.orange
        case .noPhone, .offline: nil
        }
    }
}

struct PhoneLinkPanel: View {
    @Environment(AppModel.self) private var model
    @State private var confirmingRemoval: PairedDevice?

    private var link: MobileLink { model.mobileLink }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(16)
            Hairline()
            pairing
                .padding(16)
            Hairline()
            download
                .padding(16)
            if !link.devices.devices.isEmpty {
                Hairline()
                phones
                    .padding(16)
            }
        }
        .frame(width: 372)
        .background(Palette.panel)
        .onAppear { link.beginPairing() }
        .onDisappear { link.endPairing() }
        .confirmationDialog(
            Text("Remove this phone?"),
            isPresented: Binding(get: { confirmingRemoval != nil }, set: { if !$0 { confirmingRemoval = nil } }),
            presenting: confirmingRemoval
        ) { device in
            Button(role: .destructive) { link.revoke(device.id) } label: { Text("Remove") }
            Button(role: .cancel) { confirmingRemoval = nil } label: { Text("Cancel") }
        } message: { device in
            Text(String(format: String(localized: "“%@” will be disconnected and will need a new code to pair again."),
                        device.name))
        }
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Bulava on your phone")
                .font(Typo.cardTitle)
                .foregroundStyle(Palette.text)
            HStack(spacing: 6) {
                switch link.status {
                case .connected: StatusDot(color: Palette.green, size: 5)
                case .unavailable: StatusDot(color: Palette.orange, size: 5)
                case .noPhone, .offline: EmptyView()
                }
                Text(verbatim: Self.statusLine(link.status))
                    .font(Typo.caption)
                    .foregroundStyle(Palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    static func statusLine(_ status: MobileLink.Status) -> String {
        switch status {
        case .noPhone:
            return String(localized: "No phone paired yet")
        case .offline:
            return String(localized: "Paired · no phone connected right now")
        case .connected(let names):
            return String(format: String(localized: "Connected: %@"), names.joined(separator: ", "))
        case .unavailable(let why):
            return String(format: String(localized: "The phone link is not working: %@"), why)
        }
    }

    // MARK: Pairing

    private var pairing: some View {
        VStack(alignment: .leading, spacing: 12) {
            Eyebrow("Pair a phone")
            qr.frame(maxWidth: .infinity)
            VStack(alignment: .leading, spacing: 6) {
                Text("Open Bulava on the phone and scan this code.")
                    .font(Typo.body)
                    .foregroundStyle(Palette.text)
                    .fixedSize(horizontal: false, vertical: true)
                Text("The phone and this Mac have to be on the same Wi-Fi. From another network the phone cannot reach the Mac, and that is on purpose.")
                    .font(Typo.caption)
                    .foregroundStyle(Palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                expiry
            }
        }
    }

    @ViewBuilder private var qr: some View {
        if let payload = link.pairingPayload, let image = Self.qrImage(payload.url) {
            Image(nsImage: image)
                .interpolation(.none)
                .resizable()
                .frame(width: 196, height: 196)
                .padding(10)
                .background(RoundedRectangle(cornerRadius: Metrics.radiusPanel, style: .continuous).fill(.white))
                .overlay(RoundedRectangle(cornerRadius: Metrics.radiusPanel, style: .continuous)
                    .strokeBorder(Palette.line, lineWidth: Metrics.hairline))
                .accessibilityLabel(Text("Pairing code"))
        } else {
            RoundedRectangle(cornerRadius: Metrics.radiusPanel, style: .continuous)
                .fill(Palette.panelMuted)
                .frame(width: 216, height: 216)
                .overlay {
                    if case .unavailable = link.status {
                        Image(systemName: "exclamationmark.triangle")
                            .foregroundStyle(Palette.orange)
                    } else {
                        ProgressView().controlSize(.small)
                    }
                }
        }
    }

    @ViewBuilder private var expiry: some View {
        if let payload = link.pairingPayload {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                let left = max(0, Int(payload.expiresAt.timeIntervalSince(context.date)))
                if left > 0 {
                    Text(String(format: String(localized: "Works once, for %@"),
                                String(format: "%d:%02d", left / 60, left % 60)))
                        .font(Typo.meta)
                        .monospacedDigit()
                        .foregroundStyle(Palette.textFaint)
                } else {
                    newCodeButton
                }
            }
        } else if case .unavailable = link.status {
            newCodeButton
        } else {
            newCodeButton
        }
    }

    private var newCodeButton: some View {
        Button { link.beginPairing() } label: { Text("New code") }
            .buttonStyle(.bulava(.secondary))
    }

    static func qrImage(_ text: String) -> NSImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage else { return nil }
        let scaled = output.transformed(by: CGAffineTransform(scaleX: 8, y: 8))
        let rep = NSCIImageRep(ciImage: scaled)
        let image = NSImage(size: rep.size)
        image.addRepresentation(rep)
        return image
    }

    // MARK: Download

    private var download: some View {
        VStack(alignment: .leading, spacing: 10) {
            Eyebrow("Get the app")
            Text("Install Bulava on the phone first, then scan the code above from inside the app.")
                .font(Typo.caption)
                .foregroundStyle(Palette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 6) {
                storeRow(symbol: "apple.logo", title: "iPhone", note: String(localized: "Public beta on TestFlight"))
                storeRow(symbol: "arrow.down.circle", title: "Android", note: String(localized: "Download the APK from bulava.app"))
                storeRow(symbol: "play.circle", title: "Google Play", note: String(localized: "Coming later"))
            }
            HStack(spacing: 8) {
                Link(destination: URL(string: LinkProtocol.downloadPage)!) {
                    Text("Open the download page")
                }
                .buttonStyle(.bulava(.secondary))
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(LinkProtocol.downloadPage, forType: .string)
                    model.toast = ToastMessage(text: String(localized: "Link copied"), kind: .success)
                } label: { Text("Copy link") }
                    .buttonStyle(.bulava(.quiet))
            }
        }
    }

    private func storeRow(symbol: String, title: String, note: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Palette.textSecondary)
                .frame(width: 16)
            Text(verbatim: title)
                .font(Typo.rowLabel)
                .foregroundStyle(Palette.text)
            Text(verbatim: note)
                .font(Typo.caption)
                .foregroundStyle(Palette.textFaint)
        }
    }

    // MARK: Phones

    private var phones: some View {
        VStack(alignment: .leading, spacing: 8) {
            Eyebrow("Paired phones")
            ForEach(link.devices.devices) { device in
                HStack(spacing: 10) {
                    Image(systemName: "iphone")
                        .font(.system(size: 13))
                        .foregroundStyle(Palette.textSecondary)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(verbatim: device.name)
                            .font(Typo.rowLabel)
                            .foregroundStyle(Palette.text)
                        Text(verbatim: presence(device))
                            .font(Typo.meta)
                            .foregroundStyle(link.isConnected(device.id) ? Palette.green : Palette.textFaint)
                    }
                    Spacer(minLength: 8)
                    Button { confirmingRemoval = device } label: { Text("Remove") }
                        .buttonStyle(.bulava(.quiet))
                }
            }
        }
    }

    private func presence(_ device: PairedDevice) -> String {
        let platform = device.platform == "ios" ? "iPhone" : device.platform == "android" ? "Android" : device.platform
        if link.isConnected(device.id) {
            return platform + " · " + String(localized: "Connected")
        }
        guard let seen = device.lastSeenAt else { return platform }
        if Date().timeIntervalSince(seen) < 60 { return platform + " · " + String(localized: "Last seen just now") }
        return platform + " · " + String(format: String(localized: "Last seen %@"), Fmt.ago(seen))
    }
}
