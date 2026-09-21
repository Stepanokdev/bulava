import Foundation

nonisolated enum FilePathLinks {

    static let host = "bulava-file.invalid"

    static let scheme = "https"

    static func rewrite(_ text: String, roots: [URL]) -> String {
        guard !roots.isEmpty, !text.isEmpty else { return text }
        let canonicalRoots = roots.map { $0.standardizedFileURL.resolvingSymlinksInPath().path }
            .filter { !$0.isEmpty && $0 != "/" }
        guard !canonicalRoots.isEmpty else { return text }

        let text = rewriteMarkdownTargets(text, roots: canonicalRoots)

        var out = ""
        out.reserveCapacity(text.count + 64)
        var index = text.startIndex
        for span in candidates(in: text) {
            out += text[index..<span.range.lowerBound]
            if let url = resolve(span.path, roots: canonicalRoots),
               let link = link(for: url) {

                out += "[\(text[span.range])](\(link))"
            } else {
                out += text[span.range]
            }
            index = span.range.upperBound
        }
        out += text[index...]
        return out
    }

    struct Node {
        var range: Range<String.Index>
        var target: Range<String.Index>
        var title: Substring
    }

    static func nodes(in text: String) -> [Node] {
        var found: [Node] = []
        var i = text.startIndex
        while i < text.endIndex {
            guard let open = text[i...].firstIndex(of: "[") else { break }

            if open > text.startIndex, text[text.index(before: open)] == "\\" {
                i = text.index(after: open); continue
            }
            let start = (open > text.startIndex && text[text.index(before: open)] == "!")
                ? text.index(before: open) : open

            var depth = 0
            var close: String.Index? = nil
            var j = open
            while j < text.endIndex {
                if text[j] == "[", j == text.startIndex || text[text.index(before: j)] != "\\" { depth += 1 }
                else if text[j] == "]", j == text.startIndex || text[text.index(before: j)] != "\\" {
                    depth -= 1
                    if depth == 0 { close = j; break }
                }
                j = text.index(after: j)
            }
            guard let close, text.index(after: close) < text.endIndex,
                  text[text.index(after: close)] == "(",
                  let paren = text[text.index(after: close)...].firstIndex(of: ")") else {
                i = text.index(after: open); continue
            }

            let inner = text.index(close, offsetBy: 2)..<paren
            var targetEnd = inner.upperBound
            var title: Substring = ""
            if let quote = text[inner].firstIndex(where: { $0 == "\"" || $0 == "'" }) {
                targetEnd = quote
                title = text[quote..<inner.upperBound]
                while targetEnd > inner.lowerBound, text[text.index(before: targetEnd)] == " " {
                    targetEnd = text.index(before: targetEnd)
                }
            }
            found.append(Node(range: start..<text.index(after: paren),
                              target: inner.lowerBound..<targetEnd,
                              title: title))
            i = text.index(after: paren)
        }
        return found
    }

    static func rewriteMarkdownTargets(_ text: String, roots: [String]) -> String {
        var out = ""
        var index = text.startIndex
        for node in nodes(in: text) {
            out += text[index..<node.target.lowerBound]
            let target = String(text[node.target])
            if let url = resolve(target, roots: roots), let link = link(for: url) {
                out += link
            } else {
                out += target
            }
            out += text[node.target.upperBound..<node.range.upperBound]
            index = node.range.upperBound
        }
        out += text[index...]
        return out
    }

    static func isImage(_ url: URL) -> Bool {
        ["png", "jpg", "jpeg", "gif", "heic", "webp", "tiff", "bmp"]
            .contains(url.pathExtension.lowercased())
    }

    static func target(of url: URL, roots: [URL]) -> URL? {
        guard url.host?.lowercased() == host,
              let encoded = url.path.split(separator: "/").first.map(String.init),
              let data = Data(base64Encoded: padded(encoded)),
              let path = String(data: data, encoding: .utf8), !path.isEmpty else { return nil }
        let canonicalRoots = roots.map { $0.standardizedFileURL.resolvingSymlinksInPath().path }
            .filter { !$0.isEmpty && $0 != "/" }
        guard !canonicalRoots.isEmpty else { return nil }
        return contained(URL(fileURLWithPath: path), in: canonicalRoots)
    }

    // MARK: - Finding candidates

    struct Span { var range: Range<String.Index>; var path: String }

    static func candidates(in text: String) -> [Span] {
        var spans: [Span] = []

        let reserved = nodes(in: text).map(\.range)
        var i = text.startIndex

        while i < text.endIndex {
            let ch = text[i]
            if ch == "`" {
                guard let close = text[text.index(after: i)...].firstIndex(of: "`") else { break }
                let inner = text.index(after: i)..<close
                let body = String(text[inner])
                if looksLikePath(body) {

                    spans.append(Span(range: i..<text.index(after: close), path: body))
                }
                i = text.index(after: close)
                continue
            }
            if let node = reserved.first(where: { $0.contains(i) }) {
                i = node.upperBound
                continue
            }
            if ch == "/" || ch == "~" {

                var j = i
                while j < text.endIndex, !" \t\n\r\"'()[]{}<>,;".contains(text[j]) { j = text.index(after: j) }
                var end = j

                while end > i, ".:!?".contains(text[text.index(before: end)]) { end = text.index(before: end) }
                let body = String(text[i..<end])
                if looksLikePath(body), body.contains("/") {
                    spans.append(Span(range: i..<end, path: body))
                }
                i = j
                continue
            }
            i = text.index(after: i)
        }
        return spans
    }

    static func looksLikePath(_ s: String) -> Bool {
        guard s.count > 1, s.count < 4096 else { return false }
        guard s.hasPrefix("/") || s.hasPrefix("~/") || s.hasPrefix("./") || s.contains("/") else { return false }

        if s.contains("://") { return false }
        if s.contains(" / ") { return false }
        return true
    }

    // MARK: - Resolving

    static func resolve(_ raw: String, roots: [String]) -> URL? {
        var path = raw
        if path.hasPrefix("~") {
            path = NSString(string: path).expandingTildeInPath
        }
        guard path.hasPrefix("/") else {

            let matches = roots.map { URL(fileURLWithPath: $0).appendingPathComponent(path) }
                .filter { FileManager.default.fileExists(atPath: $0.path) }
            guard matches.count == 1 else { return nil }
            return contained(matches[0], in: roots)
        }
        return contained(URL(fileURLWithPath: path), in: roots)
    }

    private static func contained(_ url: URL, in roots: [String]) -> URL? {
        let resolved = url.standardizedFileURL.resolvingSymlinksInPath()
        guard FileManager.default.fileExists(atPath: resolved.path) else { return nil }
        for root in roots where resolved.path == root || resolved.path.hasPrefix(root + "/") {
            return resolved
        }
        return nil
    }

    // MARK: - Encoding

    static func link(for url: URL) -> String? {
        guard let data = url.path.data(using: .utf8) else { return nil }
        let encoded = data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        return "https://\(host)/\(encoded)"
    }

    private static func padded(_ s: String) -> String {
        var t = s.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while t.count % 4 != 0 { t += "=" }
        return t
    }
}
