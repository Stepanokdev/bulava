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
    /// When Bulava last opened it in the background to see whether he is still signed in — which
    /// also keeps a sign-in that lasts while it is used — and whether it asked to sign in again.
    var checkedAt: Date?
    var signedOut: Bool = false

    enum CodingKeys: String, CodingKey { case id, url, host, withoutMe, addedAt, signedInAt, checkedAt, signedOut }

    init(id: UUID = UUID(), url: String, host: String, withoutMe: Bool = false, addedAt: Date = Date(),
         signedInAt: Date? = nil, checkedAt: Date? = nil, signedOut: Bool = false) {
        self.id = id; self.url = url; self.host = host; self.withoutMe = withoutMe; self.addedAt = addedAt
        self.signedInAt = signedInAt; self.checkedAt = checkedAt; self.signedOut = signedOut
    }

    /// Lists written before a field existed still read.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        url = try c.decode(String.self, forKey: .url)
        host = try c.decode(String.self, forKey: .host)
        withoutMe = try c.decodeIfPresent(Bool.self, forKey: .withoutMe) ?? false
        addedAt = try c.decodeIfPresent(Date.self, forKey: .addedAt) ?? Date()
        signedInAt = try c.decodeIfPresent(Date.self, forKey: .signedInAt)
        checkedAt = try c.decodeIfPresent(Date.self, forKey: .checkedAt)
        signedOut = try c.decodeIfPresent(Bool.self, forKey: .signedOut) ?? false
    }

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

    /// Where a page he is not signed in to sends a browser: a sign-in page, on the site or at its
    /// identity provider. `opened` is the address Bulava opened; `landed` is where the page ended up.
    static func asksToSignIn(opened: URL, landed: URL) -> Bool {
        let path = landed.path.lowercased()
        let words = ["login", "log-in", "signin", "sign-in", "sign_in", "logon", "/auth", "sso", "oauth", "authorize"]
        let onSignInPath = words.contains { path.contains($0) }
        guard let site = opened.host?.lowercased(), let host = landed.host?.lowercased() else { return false }
        let base = site.hasPrefix("www.") ? String(site.dropFirst(4)) : site
        if covers(landed, anyOf: [base]) { return onSignInPath && !opened.path.lowercased().contains(path) }
        let providers = ["accounts.google.com", "idmsa.apple.com", "appleid.apple.com", "login.microsoftonline.com",
                         "login.live.com", "github.com", "auth0.com", "okta.com"]
        return onSignInPath || providers.contains { host == $0 || host.hasSuffix("." + $0) }
    }

    /// Whether `url` is on one of `hosts` or under it.
    static func covers(_ url: URL, anyOf hosts: [String]) -> Bool {
        guard let host = url.host?.lowercased() else { return false }
        return hosts.contains { host == $0 || host.hasSuffix("." + $0) }
    }
}
