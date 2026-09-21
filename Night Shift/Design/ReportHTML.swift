import Foundation

nonisolated enum ReportHTML {

    static let css: String = """
        /* Light — the app's neutral field, and the brand lime deepened to hold ink contrast. */
        :root {
          color-scheme: light dark;
          --bg:#f6f6f7; --panel:#ffffff; --line:rgba(0,0,0,.075); --line-strong:rgba(0,0,0,.14);
          --text:#202023; --text-2:#626268; --text-3:#96969b;
          --accent:#4b7510; --accent-2:#3c5f0d; --green:#1f6b41;
          --brand:#c7f183; --brand-field:#16291c;
          --shadow:0 1px 2px rgba(43,43,46,.05), 0 10px 26px rgba(43,43,46,.07);
          --font:-apple-system,BlinkMacSystemFont,"SF Pro Text","SF Pro Display","Helvetica Neue",sans-serif;
        }
        /* Dark — neutral graphite, designed rather than inverted; the accent is the lime itself. */
        @media (prefers-color-scheme: dark) {
          :root {
            --bg:#19191a; --panel:#242426; --line:rgba(255,255,255,.075); --line-strong:rgba(255,255,255,.13);
            --text:#f2f2f3; --text-2:#b5b5bb; --text-3:#77777e;
            --accent:#b4e76d; --accent-2:#c7f183; --green:#69c58c;
            --shadow:0 1px 2px rgba(0,0,0,.2), 0 10px 26px rgba(0,0,0,.28);
          }
        }
        * { box-sizing:border-box; }
        html,body {
          margin:0; background:var(--bg); color:var(--text);
          font-family:var(--font); -webkit-font-smoothing:antialiased;
        }
        .wrap { max-width:940px; margin:0 auto; padding:54px 32px 80px; }

        header { margin-bottom:34px; }
        /* The mark keeps its own plate, exactly as it does in the app's sidebar: the lime
           needs something dark under it, and a logo that recolours itself is not a logo. */
        .brand { display:flex; align-items:center; gap:9px; margin:0 0 22px; }
        .brand .plate {
          width:24px; height:24px; border-radius:7px; background:var(--brand-field);
          display:flex; align-items:center; justify-content:center; flex:0 0 auto;
        }
        .brand .plate svg { display:block; color:var(--brand); }
        .brand .word {
          font-size:14px; font-weight:640; letter-spacing:-.36px; color:var(--text);
        }
        .brand .word em { font-style:normal; color:var(--text-3); }
        .eyebrow {
          font-size:10px; font-weight:700; letter-spacing:.8px; text-transform:uppercase;
          color:var(--accent-2); margin:0 0 12px;
        }
        h1 {
          font-size:31px; font-weight:600; letter-spacing:-1.1px; line-height:1.14;
          margin:0; max-width:24ch;
        }
        .summary {
          color:var(--text-2); font-size:15px; line-height:1.6; margin:15px 0 0; max-width:66ch;
        }

        .item { margin:0 0 34px; padding:0; }
        .pair { display:grid; gap:12px; }
        .pair.two { grid-template-columns:1fr 1fr; }
        .pair.one { grid-template-columns:1fr; }
        @media (max-width:760px) { .pair.two { grid-template-columns:1fr; } }

        /* A shot is a panel with a labelled header strip — the same shape the app's
           inline report card uses, so the two read as one thing. */
        .shot {
          background:var(--panel); border:1px solid var(--line); border-radius:12px;
          overflow:hidden; box-shadow:var(--shadow);
        }
        .shot-head {
          height:30px; display:flex; align-items:center; padding:0 11px;
          border-bottom:1px solid var(--line);
        }
        .tag {
          font-size:9.5px; font-weight:700; letter-spacing:.6px; text-transform:uppercase;
          color:var(--text-3);
        }
        .shot.after .tag { color:var(--accent-2); }
        .shot img { display:block; width:100%; height:auto; }
        figcaption { color:var(--text-2); font-size:12.5px; line-height:1.5; margin-top:11px; }

        .media { margin:0; }
        .media video {
          width:100%; height:auto; display:block; background:#000;
          border:1px solid var(--line); border-radius:12px; box-shadow:var(--shadow);
        }

        .note { color:var(--text); font-size:14.5px; line-height:1.68; margin:0 0 16px; max-width:70ch; }
        .empty { color:var(--text-3); font-size:14px; }

        /* The written report. It is the report — the frames illustrate it — so it is typeset
           to be read at length: real headings, real lists that keep their own numbers, real
           tables. It used to be rendered as flat paragraphs, which is why a worker with a
           structured account to give put it in a file beside the document instead. */
        .prose { max-width:70ch; }
        .prose h2 {
          font-size:19px; font-weight:620; letter-spacing:-.4px; line-height:1.25;
          margin:30px 0 10px; color:var(--text);
        }
        .prose h3 {
          font-size:15.5px; font-weight:650; letter-spacing:-.2px;
          margin:22px 0 8px; color:var(--text);
        }
        .prose h4 { font-size:14px; font-weight:650; margin:18px 0 6px; color:var(--text-2); }
        .prose p { color:var(--text); font-size:14.5px; line-height:1.68; margin:0 0 14px; }
        .prose ul, .prose ol { margin:0 0 15px; padding-left:22px; }
        .prose li { color:var(--text); font-size:14.5px; line-height:1.62; margin:0 0 6px; }
        .prose li::marker { color:var(--text-3); font-variant-numeric:tabular-nums; }
        .prose strong { font-weight:640; }
        .prose code {
          font-family:ui-monospace,SFMono-Regular,Menlo,monospace; font-size:12.5px;
          background:var(--bg); border:1px solid var(--line); border-radius:5px; padding:1px 4px;
        }
        .prose pre {
          background:var(--bg); border:1px solid var(--line); border-radius:10px;
          padding:12px 13px; overflow-x:auto; margin:0 0 16px;
        }
        .prose pre code { background:none; border:0; padding:0; font-size:12px; line-height:1.55; }
        .prose table.doc {
          border-collapse:collapse; width:100%; margin:0 0 18px; font-size:13px;
          background:var(--panel); border:1px solid var(--line); border-radius:10px; overflow:hidden;
        }
        .prose table.doc th, .prose table.doc td {
          text-align:left; padding:7px 10px; border-bottom:1px solid var(--line);
          vertical-align:top; color:var(--text);
        }
        .prose table.doc th { color:var(--text-2); font-weight:650; font-size:11.5px;
          letter-spacing:.3px; text-transform:uppercase; background:var(--bg); }
        .prose table.doc tr:last-child td { border-bottom:0; }
        .prose hr { border:0; border-top:1px solid var(--line); margin:22px 0; }
        .prose blockquote {
          margin:0 0 16px; padding:2px 0 2px 14px; border-left:2px solid var(--line-strong);
          color:var(--text-2);
        }

        /* One answer per thing he asked for: the item, the verdict, the proof under it. */
        .answers { margin:26px 0 0; }
        .answer { padding:0 0 6px; margin:0 0 26px; border-top:1px solid var(--line); }
        .answer > h2 {
          display:flex; align-items:baseline; gap:10px; flex-wrap:wrap;
          font-size:17px; font-weight:620; letter-spacing:-.35px; margin:16px 0 10px; color:var(--text);
        }
        .answer .num { flex:1 1 auto; min-width:0; }
        .answer .chip {
          flex:0 0 auto; font-size:9.5px; font-weight:700; letter-spacing:.7px; text-transform:uppercase;
          padding:3px 8px; border-radius:999px; border:1px solid var(--line-strong); color:var(--text-2);
          white-space:nowrap;
        }
        .answer.closed  .chip { color:var(--green);  border-color:color-mix(in srgb, var(--green) 45%, transparent); }
        .answer.partial .chip { color:var(--accent); border-color:color-mix(in srgb, var(--accent) 45%, transparent); }
        .answer.blocked .chip, .answer.notclosed .chip {
          color:#c2410c; border-color:rgba(194,65,12,.45);
        }
        @media (prefers-color-scheme: dark) {
          .answer.blocked .chip, .answer.notclosed .chip { color:#fb923c; border-color:rgba(251,146,60,.45); }
        }
        .answer .proof { margin-top:14px; }
        .answer .proof .item { margin:0 0 16px; }
        .answer .prose { max-width:70ch; }

        /* What the director has to decide. First thing on the page, because "what needs my
           attention here" was the question the whole document failed to answer. */
        .attn {
          margin:22px 0 0; padding:14px 16px; border-radius:12px;
          background:var(--panel); border:1px solid var(--line-strong); box-shadow:var(--shadow);
        }
        .attn .head {
          font-size:10px; font-weight:700; letter-spacing:.8px; text-transform:uppercase;
          color:var(--accent-2); margin:0 0 8px;
        }
        .attn ul { margin:0; padding-left:20px; }
        .attn li { color:var(--text); font-size:14px; line-height:1.6; margin:0 0 5px; }
        .attn li:last-child { margin-bottom:0; }

        footer {
          margin-top:44px; padding-top:18px; border-top:1px solid var(--line);
          color:var(--text-3); font-size:11px;
        }

        /* Print resolves to paper regardless of the viewer's theme. */
        @media print {
          :root {
            --bg:#ffffff; --panel:#ffffff; --line:rgba(0,0,0,.14); --text:#111113;
            --text-2:#4a4a52; --text-3:#7a7a82; --shadow:none;
          }
          html,body { background:#fff !important; -webkit-print-color-adjust:exact; print-color-adjust:exact; }
          .wrap { padding:24px 26px; max-width:none; }
          .item, .shot, .media { break-inside:avoid; page-break-inside:avoid; }
        }

"""

    static let brand: String = """
        <div class="brand">
          <span class="plate">\(BulavaGlyph.svg(size: 14))</span>
          <span class="word">bulava<em>.app</em></span>
        </div>
        """

    static func evidenceBody(_ m: ReportManifest, prefix: String = "") -> String {
        var body = ""

        if let v = m.video, !v.isEmpty {
            let poster = m.poster.map { " poster=\"\(attr(prefix + $0))\"" } ?? ""
            body += """
            <figure class="media">
              <video controls playsinline preload="metadata"\(poster)>
                <source src="\(attr(prefix + v))">
              </video>
            </figure>
            """
        }
        body += frames(m.items ?? [], prefix: prefix)
        return body
    }

    static func frames(_ items: [ReportManifest.Item], prefix: String = "") -> String {
        var body = ""
        for item in items {
            let caption = item.caption.flatMap { $0.isEmpty ? nil : $0 }
                .map { "<figcaption>\(esc($0))</figcaption>" } ?? ""
            let hasBefore = item.before?.isEmpty == false
            let hasAfter = item.after?.isEmpty == false
            guard hasBefore || hasAfter else { continue }
            var shots = ""
            if hasBefore {
                shots += """
                <div class="shot"><div class="shot-head"><span class="tag">Before</span></div>\
                <img src="\(attr(prefix + item.before!))" loading="lazy"></div>
                """
            }
            if hasAfter {
                shots += """
                <div class="shot after"><div class="shot-head"><span class="tag">After</span></div>\
                <img src="\(attr(prefix + item.after!))" loading="lazy"></div>
                """
            }
            let pairClass = (hasBefore && hasAfter) ? "pair two" : "pair one"
            body += "<figure class=\"item\"><div class=\"\(pairClass)\">\(shots)</div>\(caption)</figure>"
        }
        return body
    }

    static func sectionsBody(_ m: ReportManifest, prefix: String = "") -> String {
        let sections = m.sections ?? []
        guard !sections.isEmpty else { return "" }
        var out = "<div class=\"answers\">"
        for s in sections {
            let ref = s.ref?.trimmingCharacters(in: .whitespaces) ?? ""
            let title = s.title?.trimmingCharacters(in: .whitespaces) ?? ""
            let head = [ref.isEmpty ? nil : esc(ref), title.isEmpty ? nil : esc(title)]
                .compactMap { $0 }.joined(separator: ". ")
            out += "<section class=\"answer \(s.status.cssClass)\">"
            out += "<h2><span class=\"num\">\(head)</span>"
            out += "<span class=\"chip\">\(esc(s.status.label))</span></h2>"
            if let text = s.body, !text.isEmpty { out += prose(text) }

            let shots = frames(s.items ?? [], prefix: prefix)
            if !shots.isEmpty { out += "<div class=\"proof\">\(shots)</div>" }
            out += "</section>"
        }
        return out + "</div>"
    }

    static func attentionBlock(_ m: ReportManifest) -> String {
        let items = (m.attention ?? []).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !items.isEmpty else { return "" }
        let rows = items.map { "<li>\(inline(esc($0)))</li>" }.joined()
        return """
        <div class="attn">
          <p class="head">\(esc(String(localized: "Needs your decision")))</p>
          <ul>\(rows)</ul>
        </div>
        """
    }

    static func page(_ m: ReportManifest, fallbackTitle: String) -> String {
        let title = esc(m.title?.isEmpty == false ? m.title! : fallbackTitle)
        let summary = m.summary.flatMap { $0.isEmpty ? nil : $0 }.map(esc)

        let attention = attentionBlock(m)
        let answers = sectionsBody(m)
        let written = m.body.flatMap { $0.isEmpty ? nil : prose($0) } ?? ""

        var loose = m
        let claimed = Set((m.sections ?? []).flatMap { $0.items ?? [] }.compactMap { $0.after ?? $0.before })
        loose.items = (m.items ?? []).filter { item in
            guard let key = item.after ?? item.before else { return true }
            return !claimed.contains(key)
        }
        let evidence = evidenceBody(loose)
        var body = answers + written + evidence
        if body.isEmpty {
            body = "<p class=\"empty\">\(esc(String(localized: "This run left no written report and captured nothing.")))</p>"
        }
        body = attention + body

        return """
        <!doctype html>
        <html lang="en">
        <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <title>\(title)</title>
        <style>
        \(css)
        </style>
        </head>
        <body>
        <div class="wrap">
          <header>
            \(brand)
            <p class="eyebrow">Work finished · reviewed</p>
            <h1>\(title)</h1>
            \(summary.map { "<p class=\"summary\">\($0)</p>" } ?? "")
          </header>
          \(body)
          <footer>Produced by Bulava — a real before and after of the run.</footer>
        </div>
        </body>
        </html>
        """
    }

    static func prose(_ text: String) -> String {
        var out = ""
        var listKind: String?
        var paragraph: [String] = []
        var code: [String]?
        var table: [[String]]?

        func closeParagraph() {
            guard !paragraph.isEmpty else { return }

            out += "<p>" + inline(paragraph.map { esc($0) }.joined(separator: "<br>")) + "</p>"
            paragraph = []
        }
        func closeList() {
            guard let kind = listKind else { return }
            out += "</\(kind)>"
            listKind = nil
        }
        func closeTable() {
            guard let rows = table, !rows.isEmpty else { table = nil; return }
            let head = rows[0]
            let bodyRows = rows.dropFirst()
            var html = "<table class=\"doc\"><thead><tr>"
            html += head.map { "<th>\(inline(esc($0)))</th>" }.joined()
            html += "</tr></thead><tbody>"
            for row in bodyRows {
                html += "<tr>" + row.map { "<td>\(inline(esc($0)))</td>" }.joined() + "</tr>"
            }
            html += "</tbody></table>"
            out += html
            table = nil
        }
        func closeAll() { closeParagraph(); closeList(); closeTable() }

        for raw in text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)

            if line.hasPrefix("```") {
                if var open = code {
                    out += "<pre><code>" + open.map { esc($0) }.joined(separator: "\n") + "</code></pre>"
                    open.removeAll(); code = nil
                } else {
                    closeAll(); code = []
                }
                continue
            }
            if code != nil { code?.append(raw); continue }

            if line.isEmpty { closeAll(); continue }

            if line.hasPrefix("|"), line.hasSuffix("|"), line.count > 2 {
                let cells = line.dropFirst().dropLast().components(separatedBy: "|")
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                if cells.allSatisfy({ $0.allSatisfy { ch in ch == "-" || ch == ":" } && !$0.isEmpty }) { continue }
                closeParagraph(); closeList()
                table = (table ?? []) + [cells]
                continue
            }
            closeTable()

            if line.hasPrefix("#") {
                let hashes = line.prefix(while: { $0 == "#" }).count
                let body = line.dropFirst(hashes).trimmingCharacters(in: .whitespaces)
                guard !body.isEmpty else { continue }
                closeAll()

                let level = hashes <= 2 ? 2 : min(4, hashes)
                out += "<h\(level)>\(inline(esc(body)))</h\(level)>"
                continue
            }
            if line == "---" || line == "***" || line == "___" {
                closeAll(); out += "<hr>"; continue
            }
            if line.hasPrefix("> ") || line == ">" {
                closeAll()
                out += "<blockquote><p>\(inline(esc(String(line.dropFirst(1).trimmingCharacters(in: .whitespaces)))))</p></blockquote>"
                continue
            }

            if line.hasPrefix("- ") || line.hasPrefix("* ") || line.hasPrefix("• ") {
                closeParagraph()
                if listKind != "ul" { closeList(); out += "<ul>"; listKind = "ul" }
                out += "<li>\(inline(esc(String(line.dropFirst(2)))))</li>"
                continue
            }

            if let dot = line.firstIndex(of: "."), line.distance(from: line.startIndex, to: dot) <= 3,
               case let head = String(line[line.startIndex..<dot]), !head.isEmpty,
               head.allSatisfy(\.isNumber),
               line.index(after: dot) < line.endIndex, line[line.index(after: dot)] == " " {
                closeParagraph()
                if listKind != "ol" {
                    closeList()
                    out += "<ol start=\"\(Int(head) ?? 1)\">"
                    listKind = "ol"
                }
                let body = String(line[line.index(dot, offsetBy: 2)...])
                out += "<li>\(inline(esc(body)))</li>"
                continue
            }
            closeList()
            paragraph.append(line)
        }
        if let open = code, !open.isEmpty {
            out += "<pre><code>" + open.map { esc($0) }.joined(separator: "\n") + "</code></pre>"
        }
        closeAll()
        return out.isEmpty ? "" : "<div class=\"prose\">" + out + "</div>"
    }

    static func inline(_ escaped: String) -> String {
        var s = escaped

        s = replacePairs(s, delimiter: "`", open: "<code>", close: "</code>")
        s = replacePairs(s, delimiter: "**", open: "<strong>", close: "</strong>")

        if let re = try? NSRegularExpression(pattern: "(https?://[^\\s<)\"]+)") {
            let ns = s as NSString
            s = re.stringByReplacingMatches(in: s, range: NSRange(location: 0, length: ns.length),
                                            withTemplate: "<a href=\"$1\">$1</a>")
        }
        return s
    }

    private static func replacePairs(_ s: String, delimiter: String,
                                     open: String, close: String) -> String {
        let parts = s.components(separatedBy: delimiter)
        guard parts.count >= 3 else { return s }
        var out = parts[0]
        for i in 1..<parts.count {
            if i % 2 == 1 && i < parts.count - 1 {
                out += open + parts[i] + close
            } else if i % 2 == 1 {
                out += delimiter + parts[i]
            } else {
                out += parts[i]
            }
        }
        return out
    }

    static func paragraphs(_ text: String) -> String {
        text.replacingOccurrences(of: "\r\n", with: "\n")
            .components(separatedBy: "\n\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .map { "<p class=\"note\">\(esc($0).replacingOccurrences(of: "\n", with: "<br>"))</p>" }
            .joined()
    }

    // MARK: Escaping

    static func esc(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
         .replacingOccurrences(of: "<", with: "&lt;")
         .replacingOccurrences(of: ">", with: "&gt;")
    }

    static func attr(_ s: String) -> String {
        esc(s).replacingOccurrences(of: "\"", with: "&quot;")
    }
}
