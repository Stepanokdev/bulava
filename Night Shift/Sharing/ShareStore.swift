import Foundation
import Observation

/// One thing shared with the phone over the home Wi-Fi: a site (its folder) or a single file.
nonisolated struct ShareLink: Codable, Equatable, Sendable, Identifiable {
    enum Scope: String, Codable, Sendable {
        /// The folder of a site: its page and everything it loads next to it.
        case site
        /// One file and nothing else.
        case file
    }

    /// 16 random bytes, base64url: the only way in. Never derived from the path.
    var token: String
    /// Absolute, symlinks resolved.
    var root: String
    /// Relative to `root`; what the link opens.
    var entry: String
    var scope: Scope
    var title: String
    /// The project folder it came from, for the list in Settings.
    var project: String?
    var createdAt: Date

    var id: String { token }
    var entryURL: URL { URL(fileURLWithPath: root).appendingPathComponent(entry) }

    /// The path part of its address: `/s/<token>/<entry>`, each component percent-encoded.
    var path: String {
        "/s/\(token)/" + entry.split(separator: "/").map { ShareLink.encode(String($0)) }.joined(separator: "/")
    }

    static func encode(_ component: String) -> String {
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: "/?#[]@!$&'()*+,;=")
        return component.addingPercentEncoding(withAllowedCharacters: allowed) ?? component
    }
}

/// Why something was not shared, in words for whoever asked.
nonisolated struct ShareRefusal: Error, Equatable, Sendable {
    var message: String
}

/// What may be shared, and how. Pure: given paths and the folders they may come from, it decides;
/// it touches nothing but the disk it reads.
///
/// A link is a key to a folder on this Mac, readable by anyone on the same Wi-Fi who has it, so the
/// rules are narrow on purpose:
/// - the thing must exist and be inside one of the folders the asker may share from — a project
///   folder Bulava knows — after every symlink is resolved;
/// - nothing on the way to it may be hidden (`.git`, `.env`, `.ssh`): hidden is where secrets live;
/// - a site is shared as its own folder, never as a whole project folder: an `index.html` lying in
///   the root of a repository shares that page alone, without the repository beside it;
/// - anything else is shared as itself, one file.
nonisolated enum ShareRules {

    /// Pages that bring a folder of their own.
    static let siteExtensions: Set<String> = ["html", "htm"]

    static func decide(_ path: URL, within roots: [URL]) -> Result<(root: URL, entry: String, scope: ShareLink.Scope), ShareRefusal> {
        let fm = FileManager.default
        let target = path.resolvingSymlinksInPath().standardizedFileURL
        var isDirectory: ObjCBool = false
        guard fm.fileExists(atPath: target.path, isDirectory: &isDirectory) else {
            return .failure(ShareRefusal(message: String(localized: "There is nothing at that path to share.")))
        }
        let resolvedRoots = roots.map { $0.resolvingSymlinksInPath().standardizedFileURL }
        guard let base = resolvedRoots.first(where: { inside(target, $0) || target.path == $0.path }) else {
            return .failure(ShareRefusal(message: String(localized: "Only what is inside a project folder Bulava knows can be shared.")))
        }
        let relative = String(target.path.dropFirst(base.path.count)).split(separator: "/")
        guard !relative.contains(where: { $0.hasPrefix(".") }) else {
            return .failure(ShareRefusal(message: String(localized: "Hidden files and folders are never shared.")))
        }

        if isDirectory.boolValue {
            guard target.path != base.path else {
                return .failure(ShareRefusal(message: String(localized: "A whole project folder is never shared. Put the result in a folder of its own, such as artifacts/.")))
            }
            for index in ["index.html", "index.htm"] where isFile(target.appendingPathComponent(index)) {
                return .success((target, index, .site))
            }
            return .failure(ShareRefusal(message: String(localized: "That folder has no index.html to open.")))
        }
        guard isFile(target) else {
            return .failure(ShareRefusal(message: String(localized: "Only ordinary files can be shared.")))
        }
        let folder = target.deletingLastPathComponent()
        let name = target.lastPathComponent
        if siteExtensions.contains(target.pathExtension.lowercased()), folder.path != base.path {
            return .success((folder, name, .site))
        }
        return .success((folder, name, .file))
    }

    static func inside(_ url: URL, _ root: URL) -> Bool {
        url.path.hasPrefix(root.path.hasSuffix("/") ? root.path : root.path + "/")
    }

    private static func isFile(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) && !isDirectory.boolValue
    }

    static func newToken() -> String {
        var bytes = [UInt8](repeating: 0, count: 16)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

/// The links, kept on disk (`share/links.json`, readable by this user only) so they survive a
/// restart: something shared stays open on the phone for as long as its file is there.
@MainActor
@Observable
final class ShareStore {
    private(set) var links: [ShareLink] = []
    let file: URL

    init(file: URL = AppSupport.file("share/links.json")) {
        self.file = file
        load()
    }

    /// The link for this thing, the same one every time it is shared again — with the same reach.
    func register(_ path: URL, within roots: [URL], title: String? = nil, project: URL? = nil) -> Result<ShareLink, ShareRefusal> {
        switch ShareRules.decide(path, within: roots) {
        case .failure(let refusal):
            return .failure(refusal)
        case .success(let (root, entry, scope)):
            if let known = links.first(where: { $0.root == root.path && $0.entry == entry && $0.scope == scope }) {
                return .success(known)
            }
            let link = ShareLink(token: ShareRules.newToken(), root: root.path, entry: entry, scope: scope,
                                 title: (title?.isEmpty == false ? title! : entry),
                                 project: project?.resolvingSymlinksInPath().path, createdAt: Date())
            links.append(link)
            save()
            return .success(link)
        }
    }

    func link(token: String) -> ShareLink? { links.first { $0.token == token } }

    func revoke(_ token: String) {
        links.removeAll { $0.token == token }
        save()
    }

    func revokeAll() {
        links = []
        save()
    }

    /// Links whose thing is gone are let go of the next time the list is read.
    func dropMissing() {
        let before = links.count
        links.removeAll { !FileManager.default.fileExists(atPath: $0.entryURL.path) }
        if links.count != before { save() }
    }

    private func load() {
        guard let data = try? Data(contentsOf: file) else { return }
        let decoder = JSONDecoder()
        links = (try? decoder.decode([ShareLink].self, from: data)) ?? []
    }

    private func save() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(links) else { return }
        let fm = FileManager.default
        try? fm.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true,
                                attributes: [.posixPermissions: 0o700])
        try? data.write(to: file, options: .atomic)
        try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }
}
