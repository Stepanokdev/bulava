package com.stepanok.bulava.demo

/**
 * The reports the demo Mac hands out. Self-contained pages — styles and pictures inline — so they
 * render under the same "reach nothing" policy as a real report does.
 */
internal enum class DemoReportKind { Sync, Charts, Landing, VariantA, VariantB, Product, Generic, Questions }

internal object DemoReport {

    fun html(kind: DemoReportKind, title: String, product: String, t: DemoText): String {
        val body = StringBuilder()
        val summary = when (kind) {
            DemoReportKind.Sync -> t.syncReportSummary
            DemoReportKind.Charts -> t.chartsReportSummary
            DemoReportKind.Landing -> t.landingReportSummary
            DemoReportKind.VariantA, DemoReportKind.VariantB -> t.variantReportSummary
            DemoReportKind.Product -> t.productReportSummary
            DemoReportKind.Generic -> t.genericReportSummary
            DemoReportKind.Questions -> t.planLede
        }
        val eyebrow = if (kind == DemoReportKind.Questions) t.questionsForYou else t.reportEyebrow
        body.append("<p class=\"eyebrow\">").append(esc(eyebrow)).append("</p>")
        body.append("<h1>").append(esc(title)).append("</h1>")
        body.append("<p class=\"lede\">").append(esc(summary)).append("</p>")
        body.append("<p class=\"meta\">").append(esc(product)).append(" · ").append(esc(t.macName)).append("</p>")

        when (kind) {
            DemoReportKind.Sync -> {
                files(body, t, listOf("Sources/Sync/SyncEngine.swift" to "${t.modified} · +12 −3", "Tests/SyncEngineTests.swift" to "${t.added} · +41"))
                checks(body, t, listOf(t.checkLastExpense, t.checkOldTests + " · " + t.checkPassedCount))
                beforeAfter(body, t, listSvg(missingLast = true), listSvg(missingLast = false))
            }
            DemoReportKind.Charts -> {
                files(body, t, listOf("Sources/Charts/ChartsView.swift" to "${t.modified} · +9 −14", "Resources/Assets.xcassets" to "${t.modified} · 4 colours"))
                checks(body, t, listOf(t.checkOldTests + " · " + t.checkPassedCount))
                beforeAfter(body, t, chartSvg(readable = false), chartSvg(readable = true))
            }
            DemoReportKind.Landing -> {
                files(body, t, listOf("index.html" to "${t.modified} · −63 words"))
                body.append("<section class=\"ba\"><div><p class=\"label\">").append(esc(t.reportBefore)).append("</p><blockquote class=\"old\">")
                    .append(esc(t.landingBeforeCopy)).append("</blockquote></div><div><p class=\"label\">").append(esc(t.reportAfter))
                    .append("</p><blockquote>").append(esc(t.landingAfterCopy)).append("</blockquote></div></section>")
            }
            DemoReportKind.VariantA, DemoReportKind.VariantB -> {
                files(body, t, listOf("Sources/Onboarding/OnboardingView.swift" to t.modified))
                beforeAfter(body, t, onboardingSvg(steps = 0), onboardingSvg(steps = if (kind == DemoReportKind.VariantA) 1 else 3))
            }
            DemoReportKind.Product -> {
                body.append("<section><h2>").append(esc(t.reportInside)).append("</h2><ol class=\"inside\">")
                for ((name, state) in listOf(t.syncTask to t.statusReportReady, t.variantA to t.statusReportReady, t.variantB to t.statusReportReady, t.nextWidgets to t.statusNext)) {
                    body.append("<li><span>").append(esc(name)).append("</span><b>").append(esc(state)).append("</b></li>")
                }
                body.append("</ol></section>")
            }
            DemoReportKind.Generic -> {
                checks(body, t, listOf(t.checkOldTests + " · " + t.checkPassedCount))
            }
            DemoReportKind.Questions -> {
                for ((index, part) in listOf(t.planWidgets to t.planWidgetsDoc, t.planExport to t.planExportDoc, t.planFamily to t.planFamilyDoc).withIndex()) {
                    body.append("<section><h2>").append(index + 1).append(". ").append(esc(part.first)).append("</h2><p>")
                        .append(esc(part.second)).append("</p></section>")
                }
            }
        }
        body.append("<p class=\"note\">").append(esc(if (kind == DemoReportKind.Questions) t.planDemoNote else t.reportDemoNote)).append("</p>")
        return PAGE.replace("{lang}", t.language).replace("{title}", esc(title)).replace("{body}", body.toString())
    }

    private fun files(out: StringBuilder, t: DemoText, files: List<Pair<String, String>>) {
        out.append("<section><h2>").append(esc(t.reportChanged)).append("</h2><ul class=\"files\">")
        for ((path, note) in files) out.append("<li><code>").append(esc(path)).append("</code><span>").append(esc(note)).append("</span></li>")
        out.append("</ul></section>")
    }

    private fun checks(out: StringBuilder, t: DemoText, items: List<String>) {
        out.append("<section><h2>").append(esc(t.reportChecked)).append("</h2><ul class=\"checks\">")
        for (item in items) out.append("<li><span class=\"pass\" aria-hidden=\"true\">✓</span>").append(esc(item)).append("</li>")
        out.append("</ul></section>")
    }

    private fun beforeAfter(out: StringBuilder, t: DemoText, before: String, after: String) {
        out.append("<section class=\"ba\"><div><p class=\"label\">").append(esc(t.reportBefore)).append("</p>").append(before)
            .append("</div><div><p class=\"label\">").append(esc(t.reportAfter)).append("</p>").append(after).append("</div></section>")
    }

    /** An expense list; before, the last row of the day never arrived. */
    private fun listSvg(missingLast: Boolean): String {
        val rows = StringBuilder()
        for (i in 0 until 4) {
            val y = 58 + i * 40
            val missing = missingLast && i == 3
            if (missing) {
                rows.append("<rect x=\"14\" y=\"$y\" width=\"132\" height=\"30\" rx=\"7\" fill=\"none\" stroke=\"#b8b4aa\" stroke-dasharray=\"4 3\"/>")
            } else {
                val fill = if (!missingLast && i == 3) "#e3f3c9" else "#ffffff"
                rows.append("<rect x=\"14\" y=\"$y\" width=\"132\" height=\"30\" rx=\"7\" fill=\"$fill\" stroke=\"#e6e3dc\"/>")
                rows.append("<rect x=\"24\" y=\"${y + 9}\" width=\"${52 + (i * 13) % 30}\" height=\"5\" rx=\"2.5\" fill=\"#3b3a36\"/>")
                rows.append("<rect x=\"24\" y=\"${y + 18}\" width=\"34\" height=\"4\" rx=\"2\" fill=\"#b8b4aa\"/>")
                rows.append("<rect x=\"114\" y=\"${y + 11}\" width=\"22\" height=\"6\" rx=\"3\" fill=\"#3b3a36\"/>")
            }
        }
        return phone("#f6f5f1", rows.toString())
    }

    /** Bars on a dark background; before, black on almost black. */
    private fun chartSvg(readable: Boolean): String {
        val bar = if (readable) "#c7f183" else "#23242a"
        val grid = if (readable) "#3a3d45" else "#17181c"
        val label = if (readable) "#9b9ba4" else "#1d1e22"
        val shapes = StringBuilder()
        for (i in 0 until 4) shapes.append("<line x1=\"18\" y1=\"${80 + i * 34}\" x2=\"142\" y2=\"${80 + i * 34}\" stroke=\"$grid\"/>")
        val heights = listOf(64, 92, 48, 110, 76)
        for ((i, h) in heights.withIndex()) {
            val x = 24 + i * 24
            shapes.append("<rect x=\"$x\" y=\"${182 - h}\" width=\"14\" height=\"$h\" rx=\"3\" fill=\"$bar\"/>")
            shapes.append("<rect x=\"$x\" y=\"192\" width=\"14\" height=\"4\" rx=\"2\" fill=\"$label\"/>")
        }
        return phone("#0d0e11", shapes.toString())
    }

    /** Onboarding: nothing yet, one screen, or three dots for three steps. */
    private fun onboardingSvg(steps: Int): String {
        val s = StringBuilder()
        if (steps == 0) {
            s.append("<rect x=\"30\" y=\"110\" width=\"100\" height=\"6\" rx=\"3\" fill=\"#b8b4aa\"/>")
        } else {
            s.append("<rect x=\"56\" y=\"70\" width=\"48\" height=\"48\" rx=\"13\" fill=\"#16291c\"/>")
            s.append("<rect x=\"30\" y=\"134\" width=\"100\" height=\"7\" rx=\"3.5\" fill=\"#3b3a36\"/>")
            s.append("<rect x=\"40\" y=\"150\" width=\"80\" height=\"5\" rx=\"2.5\" fill=\"#b8b4aa\"/>")
            if (steps > 1) for (i in 0 until steps) s.append("<circle cx=\"${68 + i * 12}\" cy=\"176\" r=\"3.5\" fill=\"${if (i == 0) "#4a7a17" else "#d6d2c8"}\"/>")
            s.append("<rect x=\"22\" y=\"206\" width=\"116\" height=\"22\" rx=\"7\" fill=\"#4a7a17\"/>")
        }
        return phone("#f6f5f1", s.toString())
    }

    private fun phone(screen: String, content: String) =
        "<svg viewBox=\"0 0 160 250\" role=\"img\" aria-hidden=\"true\"><rect x=\"2\" y=\"2\" width=\"156\" height=\"246\" rx=\"24\" fill=\"$screen\" stroke=\"#c9c5bb\" stroke-width=\"2\"/>" +
            "<rect x=\"58\" y=\"12\" width=\"44\" height=\"10\" rx=\"5\" fill=\"#1c1c1a\"/>$content</svg>"

    private fun esc(s: String) = s.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;").replace("\"", "&quot;")

    private const val PAGE = """<!doctype html><html lang="{lang}"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1"><title>{title}</title>
<style>
:root{color-scheme:light dark;--bg:#fbfaf7;--tx:#1c1c1a;--tx2:#5f5d57;--tx3:#8e8b84;--line:#e6e3dc;--card:#ffffff;--green:#4a7a17;--greenSoft:#e3f3c9}
@media (prefers-color-scheme:dark){:root{--bg:#121311;--tx:#f1f0ec;--tx2:#b3b1aa;--tx3:#85837d;--line:#2b2c29;--card:#1b1c1a;--green:#b4e76d;--greenSoft:rgba(180,231,109,.12)}}
*{box-sizing:border-box}body{margin:0;padding:28px 20px 40px;background:var(--bg);color:var(--tx);font:16px/1.55 -apple-system,BlinkMacSystemFont,"SF Pro Text",Roboto,system-ui,sans-serif;-webkit-font-smoothing:antialiased}
.eyebrow{font-size:12px;letter-spacing:.08em;text-transform:uppercase;color:var(--green);font-weight:600;margin:0 0 10px}
h1{font-size:28px;line-height:1.15;letter-spacing:-.02em;margin:0 0 12px}.lede{color:var(--tx2);margin:0 0 8px}.meta{color:var(--tx3);font-size:13px;margin:0 0 24px}
section{border-top:1px solid var(--line);padding:18px 0 4px}h2{font-size:12px;letter-spacing:.08em;text-transform:uppercase;color:var(--tx3);font-weight:600;margin:0 0 12px}
ul,ol{list-style:none;margin:0;padding:0}.files li,.inside li{display:flex;justify-content:space-between;gap:12px;padding:8px 0;border-bottom:1px solid var(--line);font-size:14px}
.files li:last-child,.inside li:last-child{border-bottom:0}code{font:13px ui-monospace,SFMono-Regular,Menlo,monospace;word-break:break-all}.files span,.inside b{color:var(--tx3);white-space:nowrap;font-weight:500;font-size:13px}
.checks li{display:flex;gap:10px;padding:6px 0;font-size:15px}.pass{color:var(--green);font-weight:700}
.ba{display:grid;grid-template-columns:1fr 1fr;gap:14px}.ba svg{width:100%;height:auto;display:block}.label{font-size:12px;letter-spacing:.06em;text-transform:uppercase;color:var(--tx3);margin:0 0 8px;font-weight:600}
blockquote{margin:0;padding:12px;border-radius:10px;background:var(--card);border:1px solid var(--line);font-size:14px}blockquote.old{color:var(--tx3)}
.note{margin-top:28px;padding:12px 14px;border-radius:10px;background:var(--greenSoft);color:var(--tx2);font-size:13px}
</style></head><body>{body}</body></html>"""
}
