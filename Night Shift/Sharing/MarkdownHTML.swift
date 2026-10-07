import Foundation

/// Markdown made into a page a phone can read, for the share server (`ShareServer`).
///
/// An agent's notes, plans and reports are Markdown, and a phone shows a `.md` file as a wall of
/// raw text. This renders the part of Markdown those files actually use — headings, paragraphs,
/// lists (nested), tables with alignment, fenced code, quotes, rules, emphasis, inline code,
/// links and images — into one self-contained page.
///
/// Nothing in the source reaches the page as markup: every character is escaped, raw HTML
/// included, and a link or image keeps its address only when it is http(s), mailto or relative to
/// the file. A note can therefore never run a script on the phone that opens it.
nonisolated enum MarkdownHTML {

    // MARK: Page

    static func page(title: String, markdown: String) -> String {
        """
        <!doctype html>
        <html lang="uk"><head><meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover">
        <title>\(escape(title))</title>
        <style>\(style)</style>
        </head><body><main><article>
        \(body(markdown))
        </article></main></body></html>
        """
    }

    private static let style = """
    :root{--bg:#08080a;--panel:#121316;--panel-2:#17181c;--line:rgba(255,255,255,.08);--tx:#f4f4f6;--tx-2:#a3a3ac;\
    --lime:#b4e76d;--lime-line:rgba(180,231,109,.28);--font:-apple-system,BlinkMacSystemFont,"SF Pro Text",system-ui,sans-serif;\
    --mono:"SF Mono",ui-monospace,Menlo,monospace;color-scheme:dark}
    @media (prefers-color-scheme: light){:root{--bg:#f6f6f3;--panel:#fff;--panel-2:#f3f3ef;--line:rgba(20,22,18,.1);\
    --tx:#17181a;--tx-2:#55565c;--lime:#4f7d17;--lime-line:rgba(90,140,30,.32);color-scheme:light}}
    *{box-sizing:border-box}html{-webkit-text-size-adjust:100%}
    body{margin:0;background:var(--bg);color:var(--tx);font:16px/1.6 var(--font);-webkit-font-smoothing:antialiased;overflow-x:hidden}
    main{max-width:760px;margin:0 auto;padding:20px 16px 64px}
    article{background:var(--panel);border:1px solid var(--line);border-radius:18px;padding:20px 18px}
    h1,h2,h3,h4,h5,h6{line-height:1.2;letter-spacing:-.02em;margin:26px 0 10px}
    h1{font-size:clamp(26px,6.6vw,34px);margin-top:0}h2{font-size:21px;padding-top:16px;border-top:1px solid var(--line)}
    h3{font-size:17px}p,li,td{color:var(--tx-2)}strong{color:var(--tx)}
    a{color:var(--lime);text-decoration:none;border-bottom:1px solid var(--lime-line);word-break:break-word}
    code{font:13px/1.45 var(--mono);background:var(--panel-2);border:1px solid var(--line);border-radius:6px;padding:1px 5px;word-break:break-word}
    pre{overflow-x:auto;background:var(--panel-2);border:1px solid var(--line);border-radius:12px;padding:12px 14px}
    pre code{border:0;padding:0;background:none;white-space:pre;word-break:normal}
    blockquote{margin:14px 0;padding:2px 14px;border-left:2px solid var(--lime-line)}
    .tbl{overflow-x:auto;margin:14px 0}table{border-collapse:collapse;min-width:100%;font-size:14px}
    th,td{text-align:left;vertical-align:top;padding:8px 10px;border-bottom:1px solid var(--line)}
    th{background:var(--panel-2);color:var(--tx)}hr{border:0;border-top:1px solid var(--line);margin:22px 0}
    img{max-width:100%;height:auto;border-radius:10px}ul,ol{padding-left:22px}li{margin:4px 0}
    """

    // MARK: Blocks

    /// The body of a page: block elements, in order.
    static func body(_ markdown: String) -> String {
        let lines = markdown.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .components(separatedBy: "\n")
        var out: [String] = []
        var i = 0
        var paragraph: [String] = []

        func flushParagraph() {
            guard !paragraph.isEmpty else { return }
            let joined = paragraph.enumerated().map { index, line -> String in
                let hard = line.hasSuffix("  ") || line.hasSuffix("\\")
                let text = inline(line.trimmingCharacters(in: .whitespaces).trimmingSuffix("\\"))
                return index < paragraph.count - 1 && hard ? text + "<br>" : text
            }.joined(separator: "\n")
            out.append("<p>\(joined)</p>")
            paragraph = []
        }

        while i < lines.count {
            let line = lines[i]
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if trimmed.isEmpty { flushParagraph(); i += 1; continue }

            // Fenced code.
            if let fence = fenceMarker(trimmed) {
                flushParagraph()
                let lang = String(trimmed.dropFirst(fence.count)).trimmingCharacters(in: .whitespaces)
                var code: [String] = []
                i += 1
                while i < lines.count, !lines[i].trimmingCharacters(in: .whitespaces).hasPrefix(fence) {
                    code.append(lines[i]); i += 1
                }
                i += 1   // the closing fence, or the end
                let cls = lang.isEmpty ? "" : " class=\"language-\(escape(String(lang.prefix(24))))\""
                out.append("<pre><code\(cls)>\(escape(code.joined(separator: "\n")))</code></pre>")
                continue
            }

            // Heading.
            if let (level, text) = heading(trimmed) {
                flushParagraph()
                out.append("<h\(level)>\(inline(text))</h\(level)>")
                i += 1; continue
            }

            // Rule.
            if isRule(trimmed) { flushParagraph(); out.append("<hr>"); i += 1; continue }

            // Quote: the quoted lines, rendered as blocks of their own.
            if trimmed.hasPrefix(">") {
                flushParagraph()
                var quoted: [String] = []
                while i < lines.count, lines[i].trimmingCharacters(in: .whitespaces).hasPrefix(">") {
                    var q = lines[i].trimmingCharacters(in: .whitespaces).dropFirst()
                    if q.hasPrefix(" ") { q = q.dropFirst() }
                    quoted.append(String(q)); i += 1
                }
                out.append("<blockquote>\(body(quoted.joined(separator: "\n")))</blockquote>")
                continue
            }

            // Table: a row of cells over a delimiter row.
            if trimmed.contains("|"), i + 1 < lines.count,
               let aligns = delimiterRow(lines[i + 1].trimmingCharacters(in: .whitespaces)) {
                flushParagraph()
                let head = cells(trimmed)
                var rows: [[String]] = []
                i += 2
                while i < lines.count {
                    let row = lines[i].trimmingCharacters(in: .whitespaces)
                    guard !row.isEmpty, row.contains("|") else { break }
                    rows.append(cells(row)); i += 1
                }
                out.append(table(head: head, aligns: aligns, rows: rows))
                continue
            }

            // List.
            if listItem(line) != nil {
                flushParagraph()
                var block: [String] = []
                while i < lines.count {
                    let l = lines[i]
                    if l.trimmingCharacters(in: .whitespaces).isEmpty {
                        // A blank line inside a list continues it only if more of the list follows.
                        if i + 1 < lines.count, let next = listItem(lines[i + 1]), let first = listItem(block[0]),
                           next.indent > first.indent || next.ordered == first.ordered {
                            i += 1; continue
                        }
                        if i + 1 < lines.count, listItem(lines[i + 1]) == nil, lines[i + 1].hasPrefix("  ") {
                            i += 1; continue
                        }
                        break
                    }
                    if listItem(l) == nil, !l.hasPrefix(" "), !l.hasPrefix("\t"), !block.isEmpty,
                       heading(l.trimmingCharacters(in: .whitespaces)) != nil || isRule(l.trimmingCharacters(in: .whitespaces)) {
                        break
                    }
                    block.append(l); i += 1
                }
                out.append(list(block))
                continue
            }

            paragraph.append(line)
            i += 1
        }
        flushParagraph()
        return out.joined(separator: "\n")
    }

    private static func fenceMarker(_ line: String) -> String? {
        if line.hasPrefix("```") { return "```" }
        if line.hasPrefix("~~~") { return "~~~" }
        return nil
    }

    private static func heading(_ line: String) -> (Int, String)? {
        let hashes = line.prefix { $0 == "#" }.count
        guard (1...6).contains(hashes) else { return nil }
        let rest = line.dropFirst(hashes)
        guard rest.isEmpty || rest.first == " " else { return nil }
        var text = rest.trimmingCharacters(in: .whitespaces)
        while text.hasSuffix("#") { text.removeLast() }
        return (hashes, text.trimmingCharacters(in: .whitespaces))
    }

    private static func isRule(_ line: String) -> Bool {
        let compact = line.replacingOccurrences(of: " ", with: "")
        guard compact.count >= 3, let c = compact.first, "-*_".contains(c) else { return false }
        return compact.allSatisfy { $0 == c }
    }

    // MARK: Lists

    private struct Item { var indent: Int; var ordered: Bool; var start: Int; var text: String }

    private static func listItem(_ line: String) -> Item? {
        let indent = line.prefix { $0 == " " || $0 == "\t" }.reduce(0) { $0 + ($1 == "\t" ? 4 : 1) }
        let rest = line.drop { $0 == " " || $0 == "\t" }
        if let first = rest.first, "-*+".contains(first), rest.dropFirst().first == " " {
            return Item(indent: indent, ordered: false, start: 1, text: String(rest.dropFirst(2)))
        }
        let digits = rest.prefix { $0.isNumber }
        if !digits.isEmpty, digits.count <= 9 {
            let after = rest.dropFirst(digits.count)
            if let mark = after.first, mark == "." || mark == ")", after.dropFirst().first == " " {
                return Item(indent: indent, ordered: true, start: Int(digits) ?? 1, text: String(after.dropFirst(2)))
            }
        }
        return nil
    }

    /// A list and the lists inside it, by indentation. Lines that are not items continue the item
    /// above them.
    private static func list(_ lines: [String]) -> String {
        var items: [Item] = []
        for line in lines {
            if let item = listItem(line) {
                items.append(item)
            } else if !items.isEmpty {
                items[items.count - 1].text += " " + line.trimmingCharacters(in: .whitespaces)
            }
        }
        var index = 0
        var html = ""
        while index < items.count { html += render(&index, items, indent: items[index].indent) }
        return html
    }

    private static func render(_ index: inout Int, _ items: [Item], indent: Int) -> String {
        guard index < items.count else { return "" }
        let ordered = items[index].ordered
        let open = ordered ? (items[index].start == 1 ? "<ol>" : "<ol start=\"\(items[index].start)\">") : "<ul>"
        var html = open
        while index < items.count, items[index].indent >= indent {
            // Another kind of list at this level is a list of its own.
            if items[index].indent == indent, items[index].ordered != ordered { break }
            if items[index].indent > indent {
                // Deeper than this level: a list inside the item just written.
                let nested = render(&index, items, indent: items[index].indent)
                if html.hasSuffix("</li>") { html.removeLast(5); html += nested + "</li>" } else { html += nested }
                continue
            }
            html += "<li>\(task(inline(items[index].text)))</li>"
            index += 1
        }
        return html + (ordered ? "</ol>" : "</ul>")
    }

    /// `[ ]` and `[x]` at the start of an item, as the boxes they mean.
    private static func task(_ html: String) -> String {
        if html.hasPrefix("[ ] ") { return "☐ " + html.dropFirst(4) }
        if html.hasPrefix("[x] ") || html.hasPrefix("[X] ") { return "☑ " + html.dropFirst(4) }
        return html
    }

    // MARK: Tables

    private enum Align { case none, left, center, right }

    private static func delimiterRow(_ line: String) -> [Align]? {
        let parts = cells(line)
        guard !parts.isEmpty, line.contains("-") else { return nil }
        var aligns: [Align] = []
        for p in parts {
            let t = p.trimmingCharacters(in: .whitespaces)
            guard !t.isEmpty, t.allSatisfy({ $0 == "-" || $0 == ":" }), t.contains("-") else { return nil }
            switch (t.hasPrefix(":"), t.hasSuffix(":")) {
            case (true, true): aligns.append(.center)
            case (true, false): aligns.append(.left)
            case (false, true): aligns.append(.right)
            default: aligns.append(.none)
            }
        }
        return aligns
    }

    /// The cells of a table row; `\|` is a pipe inside a cell, and a pipe inside backticks too.
    private static func cells(_ line: String) -> [String] {
        var row = line
        if row.hasPrefix("|") { row.removeFirst() }
        if row.hasSuffix("|"), !row.hasSuffix("\\|") { row.removeLast() }
        var out: [String] = []
        var current = ""
        var inCode = false
        var escaped = false
        for ch in row {
            if escaped { current.append(ch); escaped = false; continue }
            if ch == "\\" { escaped = true; current.append(ch); continue }
            if ch == "`" { inCode.toggle() }
            if ch == "|", !inCode { out.append(current.trimmingCharacters(in: .whitespaces)); current = ""; continue }
            current.append(ch)
        }
        out.append(current.trimmingCharacters(in: .whitespaces))
        return out.map { $0.replacingOccurrences(of: "\\|", with: "|") }
    }

    private static func table(head: [String], aligns: [Align], rows: [[String]]) -> String {
        func cell(_ tag: String, _ text: String, _ column: Int) -> String {
            let align = column < aligns.count ? aligns[column] : .none
            let style: String
            switch align {
            case .center: style = " style=\"text-align:center\""
            case .right: style = " style=\"text-align:right\""
            default: style = ""
            }
            return "<\(tag)\(style)>\(inline(text))</\(tag)>"
        }
        let columns = head.count
        var html = "<div class=\"tbl\"><table><thead><tr>"
        html += head.enumerated().map { cell("th", $1, $0) }.joined()
        html += "</tr></thead><tbody>"
        for row in rows {
            let padded = Array(row.prefix(columns)) + Array(repeating: "", count: max(0, columns - row.count))
            html += "<tr>" + padded.enumerated().map { cell("td", $1, $0) }.joined() + "</tr>"
        }
        return html + "</tbody></table></div>"
    }

    // MARK: Inline

    /// One line of text: code spans first (nothing inside them is Markdown), then images, links,
    /// emphasis and the rest — every character escaped on the way.
    static func inline(_ text: String) -> String {
        var out = ""
        var rest = Substring(text)
        while !rest.isEmpty {
            // Code span.
            if rest.first == "`" {
                let ticks = rest.prefix { $0 == "`" }
                let after = rest.dropFirst(ticks.count)
                if let close = after.range(of: String(ticks)) {
                    out += "<code>" + escape(String(after[..<close.lowerBound]).trimmingCharacters(in: .whitespaces)) + "</code>"
                    rest = after[close.upperBound...]
                    continue
                }
                out += escape(String(ticks)); rest = after; continue
            }
            // Image or link.
            if rest.hasPrefix("!["), let (html, used) = link(rest.dropFirst(), image: true) {
                out += html; rest = rest.dropFirst(1 + used); continue
            }
            if rest.first == "[", let (html, used) = link(rest, image: false) {
                out += html; rest = rest.dropFirst(used); continue
            }
            // Autolink.
            if rest.first == "<", let close = rest.firstIndex(of: ">") {
                let target = String(rest[rest.index(after: rest.startIndex)..<close])
                if let safe = safeURL(target), target.contains("://") || target.hasPrefix("mailto:") {
                    out += "<a href=\"\(escape(safe))\">\(escape(target))</a>"
                    rest = rest[rest.index(after: close)...]
                    continue
                }
            }
            // Emphasis.
            if let (html, used) = emphasis(rest) { out += html; rest = rest.dropFirst(used); continue }
            // Escaped punctuation.
            if rest.first == "\\", let next = rest.dropFirst().first, "\\`*_{}[]()#+-.!|~<>".contains(next) {
                out += escape(String(next)); rest = rest.dropFirst(2); continue
            }
            out += escape(String(rest.first!))
            rest = rest.dropFirst()
        }
        return out
    }

    /// `[text](url "title")` from `s`, which starts at the `[`. Returns the markup and how many
    /// characters it used.
    private static func link(_ s: Substring, image: Bool) -> (String, Int)? {
        guard s.first == "[" else { return nil }
        var depth = 0
        var closeBracket: Substring.Index?
        var idx = s.startIndex
        while idx < s.endIndex {
            let ch = s[idx]
            if ch == "\\" { idx = s.index(after: idx); if idx < s.endIndex { idx = s.index(after: idx) }; continue }
            if ch == "[" { depth += 1 }
            if ch == "]" { depth -= 1; if depth == 0 { closeBracket = idx; break } }
            idx = s.index(after: idx)
        }
        guard let closeBracket, s.index(after: closeBracket) < s.endIndex, s[s.index(after: closeBracket)] == "(" else { return nil }
        let openParen = s.index(after: closeBracket)
        var parens = 0
        var closing: Substring.Index?
        var j = openParen
        while j < s.endIndex {
            if s[j] == "(" { parens += 1 }
            if s[j] == ")" { parens -= 1; if parens == 0 { closing = j; break } }
            j = s.index(after: j)
        }
        guard let closeParen = closing else { return nil }
        let label = String(s[s.index(after: s.startIndex)..<closeBracket])
        var inside = String(s[s.index(after: openParen)..<closeParen]).trimmingCharacters(in: .whitespaces)
        var title: String?
        if let quote = inside.firstIndex(of: "\""), inside.hasSuffix("\""), quote != inside.index(before: inside.endIndex) {
            title = String(inside[inside.index(after: quote)..<inside.index(before: inside.endIndex)])
            inside = String(inside[..<quote]).trimmingCharacters(in: .whitespaces)
        }
        if inside.hasPrefix("<"), inside.hasSuffix(">") { inside = String(inside.dropFirst().dropLast()) }
        let used = s.distance(from: s.startIndex, to: closeParen) + 1
        let titleAttr = title.map { " title=\"\(escape($0))\"" } ?? ""
        guard let url = safeURL(inside) else {
            // An address that is not allowed: the words stay, the link does not.
            return (image ? escape(label) : inline(label), used)
        }
        if image {
            return ("<img src=\"\(escape(url))\" alt=\"\(escape(label))\"\(titleAttr) loading=\"lazy\">", used)
        }
        return ("<a href=\"\(escape(url))\"\(titleAttr)>\(inline(label))</a>", used)
    }

    /// http(s), mailto, an anchor, or a path relative to the page. Never `javascript:`, `data:`,
    /// `file:` or any other scheme, and never a path that starts at the server's root.
    static func safeURL(_ raw: String) -> String? {
        let url = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !url.isEmpty, !url.contains(where: { $0.isNewline || $0 == "\0" }) else { return nil }
        let lower = url.lowercased()
        if lower.hasPrefix("http://") || lower.hasPrefix("https://") || lower.hasPrefix("mailto:") { return url }
        if url.hasPrefix("#") { return url }
        if url.hasPrefix("/") || url.hasPrefix("\\") { return nil }
        // Anything with a scheme before its first slash is a scheme we did not allow.
        if let colon = url.firstIndex(of: ":"), !url[..<colon].contains("/") { return nil }
        return url
    }

    /// `**strong**`, `*em*`, `_em_`, `__strong__` and `~~del~~`. Underscores inside a word are
    /// just underscores (`snake_case_name`).
    private static func emphasis(_ s: Substring) -> (String, Int)? {
        for (marker, tag) in [("**", "strong"), ("__", "strong"), ("~~", "del"), ("*", "em"), ("_", "em")] {
            guard s.hasPrefix(marker) else { continue }
            let after = s.dropFirst(marker.count)
            guard let first = after.first, !first.isWhitespace,
                  let close = after.range(of: marker) else { continue }
            let inner = after[..<close.lowerBound]
            guard !inner.isEmpty, inner.last?.isWhitespace == false else { continue }
            if marker.hasPrefix("_") {
                let next = after[close.upperBound...].first
                if let next, next.isLetter || next.isNumber { continue }
            }
            let used = marker.count + inner.count + marker.count
            return ("<\(tag)>\(inline(String(inner)))</\(tag)>", used)
        }
        return nil
    }

    static func escape(_ s: String) -> String {
        var out = ""
        out.reserveCapacity(s.count)
        for ch in s {
            switch ch {
            case "&": out += "&amp;"
            case "<": out += "&lt;"
            case ">": out += "&gt;"
            case "\"": out += "&quot;"
            case "'": out += "&#39;"
            default: out.append(ch)
            }
        }
        return out
    }
}

private extension String {
    nonisolated func trimmingSuffix(_ suffix: String) -> String {
        hasSuffix(suffix) ? String(dropLast(suffix.count)) : self
    }
}
