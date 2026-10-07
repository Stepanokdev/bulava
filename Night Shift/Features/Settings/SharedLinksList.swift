import SwiftUI

/// What is shared with the phone right now, and a way to take each back.
///
/// A link is a key to a folder on this Mac for anyone on the same Wi-Fi who has it, so every one
/// is listed by what it opens and where it came from, and can be removed on its own — or all at
/// once. Removed, it answers nothing from that moment.
struct SharedLinksList: View {
    let shares: ShareCenter

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Shared with the phone")
                    .font(Typo.panelRow)
                    .foregroundStyle(Palette.text)
                Spacer()
                Button(role: .destructive) { shares.revokeAll() } label: { Text("Remove all") }
                    .buttonStyle(.bulava(.quiet))
            }
            ForEach(shares.store.links.sorted { $0.createdAt > $1.createdAt }.prefix(30)) { link in
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(link.title)
                            .font(Typo.panelRow)
                            .foregroundStyle(Palette.text)
                            .lineLimit(1)
                        Text(location(of: link))
                            .font(Typo.mono(10.5))
                            .foregroundStyle(Palette.textFaint)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    Spacer(minLength: 8)
                    Button { shares.revoke(link.token) } label: { Text("Remove") }
                        .buttonStyle(.bulava(.quiet))
                        .accessibilityLabel(Text("Remove the link to \(link.title)"))
                }
            }
        }
        .padding(.vertical, 6)
    }

    private func location(of link: ShareLink) -> String {
        let path = link.entryURL.path
        if let project = link.project, path.hasPrefix(project + "/") {
            return URL(fileURLWithPath: project).lastPathComponent + "/" + path.dropFirst(project.count + 1)
        }
        return path
    }
}
