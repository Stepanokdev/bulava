import Foundation

/// A site he signed in to in Bulava's browser.
///
/// Whether a run may use it while he is away is his to say per site: a console or an analytics
/// page usually yes, a bank or the accounting no. A site that is not open to such runs is closed in
/// the browser for them — in their client (`--blockedUrlPattern`) and by Bulava itself on every
/// page they attach to (`BrowserBroker`).
nonisolated struct BrowserSite: Codable, Equatable, Sendable, Identifiable {
    var id: UUID = UUID()
    /// What he typed, as a page to open for signing in.
    var url: String
    /// The site, without "www.": it covers its subdomains.
    var host: String
    /// Whether a run working without him may open it.
    var withoutMe: Bool = false
    var addedAt: Date = Date()
    var signedInAt: Date?

    /// A site from what he typed — a host or an address — or nil when it names none.
    static func make(from typed: String) -> BrowserSite? {
        var text = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !text.contains(" ") else { return nil }
        if !text.contains("://") { text = "https://" + text }
        guard let url = URL(string: text), let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme),
              let raw = url.host?.lowercased(), raw.contains("."), !raw.hasPrefix("."), !raw.hasSuffix(".") else { return nil }
        let host = raw.hasPrefix("www.") ? String(raw.dropFirst(4)) : raw
        return BrowserSite(url: url.absoluteString, host: host)
    }

    /// The site and every subdomain of it, as Chrome's URL patterns read it.
    static func pattern(for host: String) -> String { "*://{*.}?\(host)/*" }

    /// Whether `url` is on one of `hosts` or under it.
    static func covers(_ url: URL, anyOf hosts: [String]) -> Bool {
        guard let host = url.host?.lowercased() else { return false }
        return hosts.contains { host == $0 || host.hasSuffix("." + $0) }
    }
}
