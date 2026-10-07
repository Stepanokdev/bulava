import SwiftUI
import CoreImage.CIFilterBuiltins

/// "On the phone": the link to a shared page as a code the phone's camera reads, and as text to copy.
///
/// The page is open on the Mac through the share server; the same thing opens on the phone over
/// the home Wi-Fi. The code carries the Mac's Bonjour name, which outlives a new address from the
/// router; the addresses follow underneath for a network that does not pass Bonjour names.
struct PhoneHandoffButton: View {
    let urls: [URL]
    let title: String
    @State private var shown = false

    var body: some View {
        Button { shown.toggle() } label: { Image(systemName: "iphone") }
            .buttonStyle(.icon(size: 26, glyph: 12))
            .help(Text("Open on the phone"))
            .disabled(urls.isEmpty)
            .popover(isPresented: $shown, arrowEdge: .bottom) { PhoneHandoff(urls: urls, title: title) }
    }
}

struct PhoneHandoff: View {
    let urls: [URL]
    let title: String
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Open on the phone")
                .font(Typo.cardTitle)
                .foregroundStyle(Palette.text)
            Text("Point the phone's camera at the code. It opens on the same Wi-Fi as this Mac.")
                .font(Typo.panelMeta)
                .foregroundStyle(Palette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            if let first = urls.first, let code = Self.code(first.absoluteString) {
                Image(nsImage: code)
                    .interpolation(.none)
                    .resizable()
                    .frame(width: 180, height: 180)
                    .padding(10)
                    .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.white))
                    .frame(maxWidth: .infinity)
                    .accessibilityLabel(Text("A code with the link to \(title)"))
            }
            ForEach(urls, id: \.self) { url in
                Text(url.absoluteString)
                    .font(Typo.mono(10.5))
                    .foregroundStyle(Palette.textSecondary)
                    .textSelection(.enabled)
                    .lineLimit(2)
                    .truncationMode(.middle)
            }
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(urls.first?.absoluteString ?? "", forType: .string)
                copied = true
            } label: { Text(copied ? "Copied" : "Copy the link") }
                .buttonStyle(.bulava())
        }
        .padding(16)
        .frame(width: 260)
    }

    /// A QR code, crisp at any size.
    static func code(_ text: String) -> NSImage? {
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
}
