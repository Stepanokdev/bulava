package com.stepanok.bulava.ui.report

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.produceState
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import com.stepanok.bulava.resources.Res
import com.stepanok.bulava.resources.action_cancel
import com.stepanok.bulava.resources.report_tab_document
import com.stepanok.bulava.resources.report_tab_questions
import com.stepanok.bulava.state.asDraft
import com.stepanok.bulava.ui.system.AlertButton
import com.stepanok.bulava.ui.system.SegmentedControl
import com.stepanok.bulava.ui.system.SystemAlert
import androidx.compose.foundation.layout.offset
import androidx.compose.ui.unit.IntOffset
import com.stepanok.bulava.resources.report_failed
import com.stepanok.bulava.resources.report_link_body
import com.stepanok.bulava.resources.report_link_open
import com.stepanok.bulava.resources.report_link_title
import com.stepanok.bulava.resources.report_loading
import com.stepanok.bulava.resources.report_pdf
import com.stepanok.bulava.ui.components.IconAction
import com.stepanok.bulava.ui.theme.Icons
import com.stepanok.bulava.ui.theme.Metrics
import androidx.compose.runtime.rememberCoroutineScope
import kotlinx.coroutines.launch
import com.stepanok.bulava.state.AppController
import com.stepanok.bulava.ui.components.ScreenBar
import com.stepanok.bulava.ui.theme.Bulava
import org.jetbrains.compose.resources.stringResource
import kotlin.io.encoding.Base64
import kotlin.io.encoding.ExperimentalEncodingApi

/**
 * A system web view, drawing HTML the phone already has. It loads nothing from the network and
 * never navigates. A link that was activated is handed to [onLink] — the page cannot leave by
 * itself, and a script clicking a link for the reader gets the same question the reader does.
 */
@Composable
expect fun HtmlView(html: String, modifier: Modifier, onLink: (String) -> Unit, document: ReportDocument? = null)

/** The page a [HtmlView] is showing, for what only the platform can do with it. */
class ReportDocument {
    /** The platform's own view of the page — a `WKWebView`, an Android `WebView` — once it is drawn. */
    internal var view: Any? = null
}

/**
 * The page as a PDF of paper pages, handed to the system's own way of keeping or sending a file:
 * the share sheet on an iPhone, the print dialog's "Save as PDF" on Android. The report's print
 * styles apply, so it comes out on white paper whatever the phone's theme. False when nothing
 * could be made.
 */
expect suspend fun ReportDocument.sharePdf(title: String): Boolean

private sealed interface Page {
    data object Loading : Page
    data object Failed : Page
    data class Ready(
        val html: String,
        val actions: List<com.stepanok.bulava.link.Action>,
        val decisions: com.stepanok.bulava.link.Decisions? = null,
    ) : Page
}

/**
 * A run's report, as the Mac renders it. Its pictures sit beside the page on the Mac, so they are
 * fetched through the link and written into the page before it is shown — the web view never
 * reaches for anything itself.
 */
@Composable
fun ReportScreen(
    controller: AppController,
    target: String,
    title: String,
    onBack: () -> Unit,
    onCompose: (String?) -> Unit,
) {
    val c = Bulava.colors
    // Read again after an answer went, or when the questions changed under it.
    var reads by remember(target) { mutableStateOf(0) }
    // 0 — the page, 1 — its questions: the switch at the bottom.
    var tab by remember(target) { mutableStateOf(0) }
    val page by produceState<Page>(Page.Loading, target, reads) {
        value = load(controller, target) ?: if (value is Page.Ready) value else Page.Failed
    }
    var leaving by remember { mutableStateOf<String?>(null) }
    val document = remember(target) { ReportDocument() }
    var exporting by remember { mutableStateOf(false) }
    val scope = rememberCoroutineScope()
    Column(Modifier.fillMaxSize().background(c.background).statusBarsPadding()) {
        ScreenBar(title, onBack) {
            // The Mac's report window has "Save as PDF"; so has this, once there is a page to save.
            if (page is Page.Ready) {
                if (exporting) {
                    Box(Modifier.size(Metrics.touch), contentAlignment = Alignment.Center) {
                        CircularProgressIndicator(Modifier.size(18.dp), strokeWidth = 2.dp, color = c.textSecondary)
                    }
                } else {
                    IconAction(Icons.Share, stringResource(Res.string.report_pdf), {
                        exporting = true
                        scope.launch {
                            val made = runCatching { document.sharePdf(title) }.getOrDefault(false)
                            exporting = false
                            if (!made) controller.say(AppController.Notice(AppController.Notice.Kind.PdfFailed))
                        }
                    })
                }
            }
        }
        when (val p = page) {
            Page.Loading -> Column(Modifier.fillMaxSize(), verticalArrangement = Arrangement.Center, horizontalAlignment = Alignment.CenterHorizontally) {
                CircularProgressIndicator(Modifier.size(24.dp), strokeWidth = 2.dp, color = c.accent)
                Text(stringResource(Res.string.report_loading), style = Bulava.type.caption, color = c.textSecondary, modifier = Modifier.padding(12.dp))
            }
            Page.Failed -> Box(Modifier.fillMaxSize().padding(32.dp), contentAlignment = Alignment.Center) {
                Text(stringResource(Res.string.report_failed), style = Bulava.type.callout, color = c.textSecondary)
            }
            is Page.Ready -> {
                val decisions = p.decisions
                val asking = decisions != null && tab == 1
                Box(Modifier.weight(1f).fillMaxWidth()) {
                    // While the questions are open the page is moved aside, not dropped: back on it, he
                    // is where he was reading.
                    HtmlView(p.html, Modifier.fillMaxSize().then(if (asking) Modifier.offset { IntOffset(100_000, 0) } else Modifier),
                        onLink = { leaving = it }, document = document)
                    if (decisions != null && asking) {
                        DecisionsPane(controller, decisions, Modifier.fillMaxSize().background(c.background), onReadAgain = { reads++ })
                    }
                }
                if (p.actions.isNotEmpty() && !asking) {
                    com.stepanok.bulava.ui.components.Hairline()
                    com.stepanok.bulava.ui.components.MacActions(
                        p.actions,
                        onInvoke = { a, input -> controller.invokeNow(a, input).also { if (it && a.style == "primary") onBack() } },
                        onCompose = { a -> onCompose(a.input?.placeholder ?: a.label) },
                        enabled = controller.link.isConnected,
                        modifier = Modifier.fillMaxWidth().then(if (decisions == null) Modifier.navigationBarsPadding() else Modifier)
                            .padding(16.dp),
                    )
                }
                if (decisions != null) {
                    // The page and its questions, a tap apart: the platform's own segmented control.
                    val drafts by controller.decisions.collectAsState()
                    val shown = shownAnswer(drafts[decisions.ref], decisions.latest?.asDraft(decisions))
                    com.stepanok.bulava.ui.components.Hairline()
                    Box(
                        Modifier.fillMaxWidth().background(c.surface).navigationBarsPadding()
                            .padding(horizontal = Metrics.gutter, vertical = 10.dp),
                    ) {
                        SegmentedControl(
                            options = listOf(
                                stringResource(Res.string.report_tab_document),
                                stringResource(Res.string.report_tab_questions, decidedCount(decisions, shown), decisions.items.size),
                            ),
                            selected = tab,
                            onSelect = { tab = it },
                            modifier = Modifier.fillMaxWidth(),
                        )
                    }
                } else if (p.actions.isEmpty()) {
                    androidx.compose.foundation.layout.Spacer(Modifier.navigationBarsPadding())
                }
            }
        }
    }
    // Leaving the report is always the reader's decision, made with the address in front of them.
    leaving?.let { url ->
        SystemAlert(
            title = stringResource(Res.string.report_link_title),
            message = stringResource(Res.string.report_link_body, url.take(300)),
            buttons = listOf(
                AlertButton(stringResource(Res.string.action_cancel), AlertButton.Style.Cancel) { leaving = null },
                AlertButton(stringResource(Res.string.report_link_open)) { leaving = null; controller.platform.openUrl(url) },
            ),
            onDismiss = { leaving = null },
        )
    }
}

private suspend fun load(controller: AppController, target: String): Page? {
    if (target.startsWith("file:")) {
        val html = controller.readFile(target.removePrefix("file:"), limit = 20L * 1024 * 1024)?.decodeToString() ?: return null
        return Page.Ready(isolate(html), emptyList())
    }
    val report = controller.openReport(target) ?: return null
    val html = inlineResources(report.html) { path -> controller.readFile("${report.root}/$path", limit = 30L * 1024 * 1024) }
    return Page.Ready(isolate(html), report.actions, report.decisions?.takeIf { it.items.isNotEmpty() })
}

/**
 * The policy every report is shown under: it may draw what it carries inline (pictures and styles
 * inlined as `data:`, its own inline script) and may reach nothing else — no image, script, frame,
 * font, form or fetch from any address. The web views add their own fences on top; this one travels
 * with the page, so it holds in both.
 */
const val REPORT_POLICY =
    "default-src 'none'; img-src data:; media-src data:; font-src data:; style-src 'unsafe-inline' data:; " +
        "script-src 'unsafe-inline'; frame-src 'none'; child-src 'none'; connect-src 'none'; " +
        "form-action 'none'; base-uri 'none'; object-src 'none'"

/**
 * How a report goes onto paper, on top of its own print styles.
 *
 * The text is set in a face whose Cyrillic keeps its own letters: the system font shares one glyph
 * between the Cyrillic "к" and the Latin "ĸ", and a PDF made with it hands "ĸ" to every search and
 * copy — "Директорський" is then not found in a Ukrainian report. And a picture is never taller
 * than a page: a phone screenshot at full width is two pages high, and it was cut in half across
 * them. Only printing is affected, so only print styles change.
 */
const val REPORT_PAPER_STYLE =
    "<style media=\"print\">:root{--font:\"Helvetica Neue\",Helvetica,Arial,sans-serif;--mono:Menlo,monospace}" +
        "body{font-family:\"Helvetica Neue\",Helvetica,Arial,sans-serif}code,pre,kbd,samp{font-family:Menlo,monospace}" +
        "img,svg,video{max-width:100%;max-height:150mm;width:auto;height:auto;object-fit:contain;" +
        "break-inside:avoid;page-break-inside:avoid}</style>"

/** Puts [REPORT_POLICY] first in the page, before anything in it can load, and the paper's own style. */
fun isolate(html: String): String {
    val meta = "<meta http-equiv=\"Content-Security-Policy\" content=\"$REPORT_POLICY\">"
    val paper = Regex("</head>", RegexOption.IGNORE_CASE).find(html)
    val styled = if (paper != null) html.replaceRange(paper.range.first, paper.range.first, REPORT_PAPER_STYLE)
        else html + REPORT_PAPER_STYLE
    return isolateOnly(styled, meta)
}

private fun isolateOnly(html: String, meta: String): String {
    val head = Regex("<head[^>]*>", RegexOption.IGNORE_CASE).find(html)
    return when {
        head != null -> html.replaceRange(head.range.last + 1, head.range.last + 1, meta)
        else -> Regex("<html[^>]*>", RegexOption.IGNORE_CASE).find(html)
            ?.let { html.replaceRange(it.range.last + 1, it.range.last + 1, "<head>$meta</head>") }
            ?: "<head>$meta</head>$html"
    }
}

private val SRC = Regex("""(src|href)=["']([^"'#?]+)["']""")

@OptIn(ExperimentalEncodingApi::class)
suspend fun inlineResources(html: String, fetch: suspend (String) -> ByteArray?): String {
    val paths = SRC.findAll(html).map { it.groupValues[2] }
        .filter { p -> !p.contains("://") && !p.startsWith("data:") && !p.startsWith("/") && !p.startsWith("mailto:") && p.contains('.') }
        .toSet()
    var out = html
    for (path in paths) {
        val bytes = fetch(path) ?: continue
        val uri = "data:${mimeOf(path)};base64,${Base64.encode(bytes)}"
        out = out.replace("\"$path\"", "\"$uri\"").replace("'$path'", "'$uri'")
    }
    return out
}

private fun mimeOf(path: String): String = when (path.substringAfterLast('.').lowercase()) {
    "png" -> "image/png"
    "jpg", "jpeg" -> "image/jpeg"
    "gif" -> "image/gif"
    "webp" -> "image/webp"
    "svg" -> "image/svg+xml"
    "mp4", "m4v" -> "video/mp4"
    "mov" -> "video/quicktime"
    "css" -> "text/css"
    "js" -> "text/javascript"
    else -> "application/octet-stream"
}
