import Foundation

nonisolated extension ReportHTML {

    struct ItemSection: Sendable {
        enum Outcome: String, Sendable {

            case delivered

            case failed

            case unfinished
        }

        struct Criterion: Sendable {
            var name: String
            var status: String
            var command: String
            var note: String
        }

        var number: Int
        var title: String
        var projectName: String
        var outcome: Outcome

        var stateLabel: String

        var gateBlocker: String?
        var summary: String?
        var manifest: ReportManifest?

        var assetPrefix: String
        var criteria: [Criterion]
        var evidenceOverall: String?
        var commits: [String]
        var filesChanged: Int
        var insertions: Int
        var deletions: Int
        var findings: [String]

        var absenceNote: String?
    }

    static func itemPage(title: String,
                         productName: String,
                         sections: [ItemSection],
                         deliveredCount: Int,
                         failedCount: Int,
                         unfinishedCount: Int,
                         missingCount: Int,
                         generatedAt: String) -> String {
        let heading = esc(title)
        let lede = esc(ledeText(total: sections.count, delivered: deliveredCount,
                                failed: failedCount, unfinished: unfinishedCount,
                                missing: missingCount))

        let contents = sections.map { section in
            let anchor = "s\(section.number)"
            return """
            <li><a href="#\(anchor)"><span class="toc-n">\(section.number)</span>\
            <span class="toc-t">\(esc(section.title))</span>\
            <span class="badge \(section.outcome.rawValue)">\(esc(section.stateLabel))</span></a></li>
            """
        }.joined()

        let body = sections.map { streamSection($0) }.joined()

        return """
        <!doctype html>
        <html lang="\(esc(LanguageBundle.currentCode))">
        <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <title>\(heading)</title>
        <style>
        \(css)
        \(itemCSS)
        </style>
        </head>
        <body>
        <div class="wrap">
          <header>
            \(brand)
            <p class="eyebrow">\(esc(String(localized: "One task · one report")))</p>
            <h1>\(heading)</h1>
            <p class="summary">\(lede)</p>
            <p class="context">\(esc(productName)) · \(esc(generatedAt))</p>
          </header>

          <nav class="toc">
            <p class="toc-h">\(esc(String(localized: "What is inside")))</p>
            <ol>\(contents)</ol>
          </nav>

          \(body)

          <footer>\(esc(String(localized: "Produced by Bulava. Every stream of this task is in this document — including the ones that did not work out.")))</footer>
        </div>
        </body>
        </html>
        """
    }

    // MARK: - Header text

    private static func ledeText(total: Int, delivered: Int, failed: Int,
                                 unfinished: Int, missing: Int) -> String {
        var parts: [String] = [
            String(format: String(localized: "%lld of %lld streams produced a result."),
                   delivered, total)
        ]
        if failed > 0 {
            parts.append(String(format: String(localized: "%lld failed — each one says why below."), failed))
        }
        if unfinished > 0 {
            parts.append(String(format: String(localized: "%lld had not finished when this was written."), unfinished))
        }
        if missing > 0 {
            parts.append(String(format: String(localized: "%lld more were asked for and never started."), missing))
        }
        return parts.joined(separator: " ")
    }

    // MARK: - One stream

    private static func streamSection(_ s: ItemSection) -> String {
        var blocks: [String] = []

        if let summary = s.summary, !summary.isEmpty {
            blocks.append("<p class=\"stream-summary\">\(esc(summary))</p>")
        }

        if let blocker = s.gateBlocker, !blocker.isEmpty {
            blocks.append("""
            <div class="gate"><span class="gate-h">\(esc(String(localized: "Not ready to accept")))</span>\
            <span class="gate-b">\(esc(blocker))</span></div>
            """)
        }

        if let manifest = s.manifest {
            let evidence = evidenceBody(manifest, prefix: s.assetPrefix)
            if !evidence.isEmpty { blocks.append(evidence) }
        }

        if let note = s.absenceNote, !note.isEmpty {
            blocks.append("<p class=\"empty\">\(esc(note))</p>")
        }

        if !s.criteria.isEmpty {
            let rows = s.criteria.map { c in
                """
                <tr><td class="crit">\(esc(c.name))</td>\
                <td><span class="st \(esc(c.status))">\(esc(statusLabel(c.status)))</span></td>\
                <td class="cmd"><code>\(esc(c.command))</code>\
                \(c.note.isEmpty ? "" : "<span class=\"crit-note\">\(esc(c.note))</span>")</td></tr>
                """
            }.joined()
            blocks.append("""
            <div class="evidence">
              <p class="block-h">\(esc(String(localized: "Machine checks")))\
              \(s.evidenceOverall.map { " · <span class=\"st \(esc($0))\">\(esc(statusLabel($0)))</span>" } ?? "")</p>
              <table>\(rows)</table>
            </div>
            """)
        }

        if s.filesChanged > 0 || !s.commits.isEmpty {
            let stat = s.filesChanged > 0
                ? "<p class=\"stat\">\(esc(String(format: String(localized: "%lld files changed, +%lld / −%lld"), s.filesChanged, s.insertions, s.deletions)))</p>"
                : ""
            let commits = s.commits.isEmpty ? "" :
                "<ul class=\"commits\">" + s.commits.map { "<li>\(esc($0))</li>" }.joined() + "</ul>"
            blocks.append("""
            <div class="changes"><p class="block-h">\(esc(String(localized: "Changes")))</p>\(stat)\(commits)</div>
            """)
        }

        if !s.findings.isEmpty {
            let list = s.findings.map { "<li>\(esc($0))</li>" }.joined()
            blocks.append("""
            <div class="findings"><p class="block-h">\(esc(String(localized: "Reviewer's notes")))</p>
            <ul>\(list)</ul></div>
            """)
        }

        return """
        <section class="stream" id="s\(s.number)">
          <div class="stream-head">
            <span class="stream-n">\(s.number)</span>
            <div class="stream-id">
              <h2>\(esc(s.title))</h2>
              <p class="where">\(esc(s.projectName))</p>
            </div>
            <span class="badge \(s.outcome.rawValue)">\(esc(s.stateLabel))</span>
          </div>
          \(blocks.joined())
        </section>
        """
    }

    private static func statusLabel(_ raw: String) -> String {
        switch raw {
        case "pass":         String(localized: "pass")
        case "fail":         String(localized: "fail")
        case "inconclusive": String(localized: "inconclusive")
        case "skipped":      String(localized: "not run")
        default:             String(localized: "unknown")
        }
    }

    // MARK: - Styles

    static let itemCSS = """
    .context { color:var(--text-3); font-size:11.5px; margin:14px 0 0; }

    .toc { margin:0 0 40px; padding:14px 4px 6px; border-top:1px solid var(--line-strong);
           border-bottom:1px solid var(--line); }
    .toc-h { font-size:10px; font-weight:700; letter-spacing:.8px; text-transform:uppercase;
             color:var(--text-3); margin:0 0 8px; }
    .toc ol { list-style:none; margin:0; padding:0; }
    .toc li { border-top:1px solid var(--line); }
    .toc li:first-child { border-top:none; }
    .toc a { display:flex; align-items:center; gap:11px; padding:8px 2px; text-decoration:none;
             color:var(--text); font-size:13.5px; }
    .toc a:hover .toc-t { text-decoration:underline; }
    .toc-n { color:var(--text-3); font-variant-numeric:tabular-nums; font-size:11.5px; min-width:14px; }
    .toc-t { flex:1; }

    .badge { font-size:9.5px; font-weight:700; letter-spacing:.5px; text-transform:uppercase;
             padding:3px 7px; border-radius:5px; white-space:nowrap; }
    .badge.delivered { color:var(--green); background:color-mix(in srgb, var(--green) 12%, transparent); }
    .badge.failed { color:#c0392f; background:rgba(192,57,47,.11); }
    .badge.unfinished { color:var(--text-2); background:var(--line); }
    @media (prefers-color-scheme: dark) {
      .badge.failed { color:#f08a80; background:rgba(240,138,128,.13); }
    }

    .stream { margin:0 0 46px; padding:0 0 6px; }
    .stream-head { display:flex; align-items:flex-start; gap:12px; margin:0 0 16px;
                   padding-bottom:11px; border-bottom:1px solid var(--line-strong); }
    .stream-n { font-size:12px; font-variant-numeric:tabular-nums; color:var(--text-3);
                padding-top:4px; min-width:15px; }
    .stream-id { flex:1; }
    .stream h2 { font-size:19px; font-weight:600; letter-spacing:-.4px; margin:0; }
    .where { color:var(--text-3); font-size:11.5px; margin:3px 0 0; }
    .stream-summary { color:var(--text-2); font-size:14px; line-height:1.62; margin:0 0 18px; max-width:70ch; }

    .gate { display:flex; flex-direction:column; gap:3px; margin:0 0 18px; padding:11px 13px;
            border-radius:9px; background:rgba(196,120,32,.09); border:1px solid rgba(196,120,32,.2); }
    .gate-h { font-size:10px; font-weight:700; letter-spacing:.6px; text-transform:uppercase; color:#a86a1c; }
    .gate-b { font-size:13px; line-height:1.5; color:var(--text-2); }
    @media (prefers-color-scheme: dark) { .gate-h { color:#e0a75c; } }

    .block-h { font-size:10px; font-weight:700; letter-spacing:.7px; text-transform:uppercase;
               color:var(--text-3); margin:0 0 9px; }
    .evidence, .changes, .findings { margin:0 0 20px; }
    .evidence table { width:100%; border-collapse:collapse; font-size:12.5px; }
    .evidence td { padding:7px 9px; border-top:1px solid var(--line); vertical-align:top; }
    .evidence tr:first-child td { border-top:none; }
    .crit { font-weight:500; width:26%; }
    .cmd { color:var(--text-3); }
    .cmd code { font-family:ui-monospace,SFMono-Regular,Menlo,monospace; font-size:11.5px; }
    .crit-note { display:block; margin-top:3px; color:var(--text-2); }
    .st { font-size:10px; font-weight:700; text-transform:uppercase; letter-spacing:.4px; }
    .st.pass { color:var(--green); }
    .st.fail { color:#c0392f; }
    .st.inconclusive, .st.unknown, .st.skipped { color:var(--text-3); }
    @media (prefers-color-scheme: dark) { .st.fail { color:#f08a80; } }

    .stat { font-size:12.5px; color:var(--text-2); margin:0 0 7px; font-variant-numeric:tabular-nums; }
    .commits, .findings ul { margin:0; padding-left:17px; }
    .commits li, .findings li { font-size:12.5px; line-height:1.55; color:var(--text-2); margin:0 0 3px; }

    @media print {
      .stream { break-inside:auto; }
      .stream-head { break-after:avoid; }
      .toc a { color:#111113; }
    }
    """
}
