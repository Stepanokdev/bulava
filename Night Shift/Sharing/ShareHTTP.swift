import Foundation

/// The share server's whole decision about one request, without a socket: what was asked, what
/// is answered. `ShareServer` only moves bytes; everything that keeps a folder on this Mac from
/// leaking happens here, where a test can reach it.
nonisolated enum ShareHTTP {

    struct Request: Equatable, Sendable {
        var method: String
        var target: String
        var headers: [String: String]   // lowercased names

        func header(_ name: String) -> String? { headers[name.lowercased()] }
    }

    struct Response: Equatable, Sendable {
        var status: Int
        var headers: [(String, String)]
        /// Bytes to send, or a file range to stream.
        var body: Body

        enum Body: Equatable, Sendable {
            case data(Data)
            case file(path: String, offset: Int64, length: Int64)
            case none
        }

        static func == (a: Response, b: Response) -> Bool {
            a.status == b.status && a.body == b.body && a.headers.map { "\($0.0):\($0.1)" } == b.headers.map { "\($0.0):\($0.1)" }
        }

        func header(_ name: String) -> String? {
            headers.first { $0.0.lowercased() == name.lowercased() }?.1
        }
    }

    /// Who may be named in `Host`: this Mac's own addresses and name, and the port it listens on.
    /// Anything else is a page that pointed some other name at this Mac (DNS rebinding) and is
    /// refused before a path is even looked at.
    struct Hosts: Sendable {
        var names: Set<String>
        var port: UInt16

        func allows(_ host: String?) -> Bool {
            guard let host, !host.isEmpty, host.count < 300 else { return false }
            var name = host.lowercased()
            var port: UInt16 = 80
            if name.hasPrefix("[") {
                guard let close = name.firstIndex(of: "]") else { return false }
                let rest = name[name.index(after: close)...]
                name = String(name[name.index(after: name.startIndex)..<close])
                if rest.hasPrefix(":") { guard let p = UInt16(rest.dropFirst()) else { return false }; port = p }
                else if !rest.isEmpty { return false }
            } else if let colon = name.lastIndex(of: ":") {
                guard let p = UInt16(name[name.index(after: colon)...]) else { return false }
                port = p
                name = String(name[..<colon])
            }
            if let percent = name.firstIndex(of: "%") { name = String(name[..<percent]) }   // IPv6 scope
            if name.hasSuffix(".") { name.removeLast() }
            return port == self.port && names.contains(name)
        }
    }

    // MARK: Parsing

    /// The request line and headers, or nil when what came is not one.
    static func parse(_ head: Data) -> Request? {
        guard let text = String(data: head, encoding: .utf8) ?? String(data: head, encoding: .isoLatin1) else { return nil }
        var lines = text.components(separatedBy: "\r\n")
        guard !lines.isEmpty else { return nil }
        let first = lines.removeFirst().split(separator: " ", omittingEmptySubsequences: true)
        guard first.count == 3, first[2].hasPrefix("HTTP/1.") else { return nil }
        var headers: [String: String] = [:]
        for line in lines where !line.isEmpty {
            guard let colon = line.firstIndex(of: ":") else { return nil }
            let name = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            // Two Hosts is a request built to confuse, not one a browser sends.
            if name == "host", headers["host"] != nil { return nil }
            headers[name] = value
        }
        return Request(method: String(first[0]), target: String(first[1]), headers: headers)
    }

    // MARK: Answering

    static func respond(_ request: Request, hosts: Hosts, link: (String) -> ShareLink?) -> Response {
        guard request.method == "GET" || request.method == "HEAD" else {
            return page(405, String(localized: "Only reading is allowed here."), extra: [("Allow", "GET, HEAD")])
        }
        guard hosts.allows(request.header("host")) else {
            return page(421, String(localized: "This address is not one Bulava answers to."))
        }
        let (rawPath, query) = split(request.target)
        guard let path = decode(rawPath) else { return page(400, String(localized: "That address is not a valid one.")) }

        // `/s/<token>/…` — or a page's own root-relative request (`/assets/app.js`), which belongs
        // to the share the page came from: its Referer says which. Builds put assets at the root
        // by default, and without this a site opened through a link loses every one of them.
        var parts = path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        if parts.count >= 3, parts[0].isEmpty, parts[1] == "s" {
            parts.removeFirst(2)
        } else if let token = refererToken(request, hosts: hosts), link(token)?.scope == .site {
            parts = [token] + parts.dropFirst()
        } else {
            return page(404, String(localized: "Nothing is shared at this address. A link from Bulava opens what it was made for."))
        }
        let token = parts.removeFirst()
        guard let share = link(token) else {
            return page(404, String(localized: "This link was removed in Bulava, or never existed."))
        }
        let rest = parts.joined(separator: "/")
        if rest.isEmpty {
            return redirect(to: share.path)
        }
        return serve(share, rest, query: query, request: request)
    }

    private static func serve(_ share: ShareLink, _ rest: String, query: String?, request: Request) -> Response {
        let components = rest.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        // A trailing slash is a folder; anything hidden, empty or climbing is refused outright.
        let named = components.last == "" ? Array(components.dropLast()) : components
        guard !named.isEmpty, !named.contains(where: { $0.isEmpty || $0.hasPrefix(".") }) else {
            return page(404, String(localized: "Nothing is shared at this address."))
        }
        let wanted = named.joined(separator: "/")
        if share.scope == .file, wanted != share.entry {
            return page(404, String(localized: "This link opens one file only."))
        }
        let root = URL(fileURLWithPath: share.root).standardizedFileURL
        let candidate = root.appendingPathComponent(wanted).standardizedFileURL
        // No symlink anywhere inside the share: what is resolved must be exactly what was asked.
        guard ShareRules.inside(candidate, root), candidate.resolvingSymlinksInPath().path == candidate.path else {
            return page(404, String(localized: "Nothing is shared at this address."))
        }
        var isDirectory: ObjCBool = false
        let fm = FileManager.default
        if fm.fileExists(atPath: candidate.path, isDirectory: &isDirectory) {
            if isDirectory.boolValue {
                for index in ["index.html", "index.htm"] where fm.fileExists(atPath: candidate.appendingPathComponent(index).path) {
                    return redirect(to: "/s/\(share.token)/" + (named + [index]).map(ShareLink.encode).joined(separator: "/"))
                }
                return page(404, String(localized: "Nothing is shared at this address."))
            }
            return file(candidate, name: named.last!, query: query, request: request)
        }
        // A site's own route (`/settings`, `/report/2`) for a page that draws it itself: the site's
        // page answers, the way a host of a single-page app does.
        if share.scope == .site, !(named.last?.contains(".") ?? true),
           (request.header("accept") ?? "").contains("text/html"),
           ShareRules.siteExtensions.contains((share.entry as NSString).pathExtension.lowercased()) {
            return file(share.entryURL, name: share.entry, query: nil, request: request)
        }
        return page(404, String(localized: "That file is not there any more. It may have been moved or deleted on the Mac."))
    }

    private static func file(_ url: URL, name: String, query: String?, request: Request) -> Response {
        let ext = url.pathExtension.lowercased()
        let head = request.method == "HEAD"
        var headers = base

        // A note reads as a page, unless its own text is asked for.
        if ext == "md" || ext == "markdown", query?.contains("raw=1") != true {
            let text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
            let html = Data(MarkdownHTML.page(title: name, markdown: text).utf8)
            headers += [("Content-Type", "text/html; charset=utf-8"), ("Content-Length", "\(html.count)")]
            return Response(status: 200, headers: headers, body: head ? .none : .data(html))
        }

        guard let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value else {
            return page(404, String(localized: "That file is not there any more. It may have been moved or deleted on the Mac."))
        }
        let type = mime(ext)
        headers.append(("Content-Type", type))
        headers.append(("Accept-Ranges", "bytes"))
        if !type.hasPrefix("text/html") {
            headers.append(("Content-Disposition", "inline; filename*=UTF-8''" + ShareLink.encode(name)))
        }

        if let range = request.header("range") {
            guard let (start, end) = byteRange(range, size: size) else {
                headers.append(("Content-Range", "bytes */\(size)"))
                return Response(status: 416, headers: headers, body: .none)
            }
            headers.append(("Content-Range", "bytes \(start)-\(end)/\(size)"))
            headers.append(("Content-Length", "\(end - start + 1)"))
            return Response(status: 206, headers: headers,
                            body: head ? .none : .file(path: url.path, offset: start, length: end - start + 1))
        }
        headers.append(("Content-Length", "\(size)"))
        return Response(status: 200, headers: headers, body: head ? .none : .file(path: url.path, offset: 0, length: size))
    }

    /// One range, `bytes=a-b`, `bytes=a-` or `bytes=-n`. Several ranges are answered as the first.
    static func byteRange(_ header: String, size: Int64) -> (Int64, Int64)? {
        guard header.hasPrefix("bytes="), size > 0 else { return nil }
        let spec = header.dropFirst(6).split(separator: ",").first.map(String.init) ?? ""
        let pieces = spec.split(separator: "-", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
        guard pieces.count == 2 else { return nil }
        if pieces[0].isEmpty {
            guard let n = Int64(pieces[1]), n > 0 else { return nil }
            return (max(0, size - n), size - 1)
        }
        guard let start = Int64(pieces[0]), start < size else { return nil }
        let end = pieces[1].isEmpty ? size - 1 : min(Int64(pieces[1]) ?? -1, size - 1)
        guard end >= start else { return nil }
        return (start, end)
    }

    // MARK: Pieces

    private static let base: [(String, String)] = [
        ("Cache-Control", "no-store"),
        ("X-Content-Type-Options", "nosniff"),
        // Same-origin, not "no-referrer": a site's root-relative requests find their share by it.
        ("Referrer-Policy", "same-origin"),
        ("Connection", "close"),
    ]

    private static func split(_ target: String) -> (String, String?) {
        // An absolute form (`GET http://host/path`) is read for its path only.
        var t = target
        if let scheme = t.range(of: "://"), let slash = t[scheme.upperBound...].firstIndex(of: "/") { t = String(t[slash...]) }
        if let hash = t.firstIndex(of: "#") { t = String(t[..<hash]) }
        guard let q = t.firstIndex(of: "?") else { return (t, nil) }
        return (String(t[..<q]), String(t[t.index(after: q)...]))
    }

    /// Percent-decoded once, and refused if that leaves anything a path should never hold.
    static func decode(_ raw: String) -> String? {
        guard raw.hasPrefix("/"), let decoded = raw.removingPercentEncoding else { return nil }
        guard !decoded.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7F }),
              !decoded.contains("\\") else { return nil }
        return decoded
    }

    private static func refererToken(_ request: Request, hosts: Hosts) -> String? {
        guard let referer = request.header("referer"), let url = URL(string: referer),
              let host = url.host else { return nil }
        let named = url.port.map { "\(host.contains(":") ? "[\(host)]" : host):\($0)" } ?? host
        guard hosts.allows(named) else { return nil }
        let parts = url.path.split(separator: "/").map(String.init)
        guard parts.count >= 2, parts[0] == "s" else { return nil }
        return parts[1]
    }

    private static func redirect(to path: String) -> Response {
        Response(status: 302, headers: base + [("Location", path), ("Content-Length", "0")], body: .none)
    }

    /// A short page in the director's own look, for everything that is not a file.
    static func page(_ status: Int, _ text: String, extra: [(String, String)] = []) -> Response {
        let html = """
        <!doctype html><html lang="uk"><head><meta charset="utf-8">\
        <meta name="viewport" content="width=device-width, initial-scale=1"><title>Bulava</title>\
        <style>:root{color-scheme:dark light}body{margin:0;min-height:100vh;display:grid;place-items:center;\
        background:#08080a;color:#f4f4f6;font:16px/1.5 -apple-system,system-ui,sans-serif;padding:24px}\
        @media (prefers-color-scheme: light){body{background:#f6f6f3;color:#17181a}}\
        p{max-width:28em;text-align:center}b{display:block;font-size:13px;letter-spacing:.14em;\
        text-transform:uppercase;opacity:.6;margin-bottom:8px}</style></head>\
        <body><p><b>Bulava</b>\(MarkdownHTML.escape(text))</p></body></html>
        """
        let data = Data(html.utf8)
        return Response(status: status,
                        headers: base + extra + [("Content-Type", "text/html; charset=utf-8"), ("Content-Length", "\(data.count)")],
                        body: .data(data))
    }

    static func mime(_ ext: String) -> String {
        switch ext {
        case "html", "htm": "text/html; charset=utf-8"
        case "css": "text/css; charset=utf-8"
        case "js", "mjs": "text/javascript; charset=utf-8"
        case "json", "map": "application/json; charset=utf-8"
        case "webmanifest": "application/manifest+json"
        case "txt", "log", "md", "markdown": "text/plain; charset=utf-8"
        case "csv": "text/csv; charset=utf-8"
        case "xml": "application/xml; charset=utf-8"
        case "svg": "image/svg+xml"
        case "png": "image/png"
        case "jpg", "jpeg": "image/jpeg"
        case "gif": "image/gif"
        case "webp": "image/webp"
        case "avif": "image/avif"
        case "ico": "image/x-icon"
        case "woff": "font/woff"
        case "woff2": "font/woff2"
        case "ttf": "font/ttf"
        case "otf": "font/otf"
        case "wasm": "application/wasm"
        case "pdf": "application/pdf"
        case "mp4", "m4v": "video/mp4"
        case "mov": "video/quicktime"
        case "webm": "video/webm"
        case "mp3": "audio/mpeg"
        case "m4a": "audio/mp4"
        case "wav": "audio/wav"
        case "zip": "application/zip"
        case "xlsx": "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet"
        case "docx": "application/vnd.openxmlformats-officedocument.wordprocessingml.document"
        case "pptx": "application/vnd.openxmlformats-officedocument.presentationml.presentation"
        default: "application/octet-stream"
        }
    }
}
