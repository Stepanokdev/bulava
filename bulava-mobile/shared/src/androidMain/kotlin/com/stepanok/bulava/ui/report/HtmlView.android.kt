package com.stepanok.bulava.ui.report

import android.app.Activity
import android.content.Context
import android.content.ContextWrapper
import android.print.PrintAttributes
import android.print.PrintManager
import kotlinx.coroutines.delay
import kotlinx.coroutines.suspendCancellableCoroutine
import kotlinx.coroutines.withTimeoutOrNull
import kotlin.coroutines.resume
import android.webkit.WebResourceRequest
import android.webkit.WebResourceResponse
import android.webkit.WebView
import android.webkit.WebViewClient
import androidx.compose.runtime.Composable
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.ui.Modifier
import androidx.compose.ui.viewinterop.AndroidView

@Composable
actual fun HtmlView(html: String, modifier: Modifier, onLink: (String) -> Unit, document: ReportDocument?) {
    val latest = rememberUpdatedState(onLink)
    AndroidView(
        modifier = modifier,
        factory = { context ->
            WebView(context).also { document?.view = it }.apply {
                // The page is complete before it gets here; nothing in it may reach the network.
                settings.blockNetworkLoads = true
                settings.javaScriptEnabled = true
                settings.allowFileAccess = false
                settings.allowContentAccess = false
                webViewClient = object : WebViewClient() {
                    // Nothing but what the page carries inline: any other request gets an empty answer.
                    override fun shouldInterceptRequest(view: WebView, request: WebResourceRequest): WebResourceResponse? {
                        val scheme = request.url.scheme
                        return if (scheme == "data" || scheme == "about") null
                        else WebResourceResponse("text/plain", "utf-8", 403, "Blocked", emptyMap(), "".byteInputStream())
                    }
                    // The page never navigates by itself. A link the reader tapped is offered to them —
                    // "open this in the browser?" — and only their answer leaves the report.
                    override fun shouldOverrideUrlLoading(view: WebView, request: WebResourceRequest): Boolean {
                        val url = request.url
                        if (request.hasGesture() && (url.scheme == "https" || url.scheme == "http")) {
                            latest.value(url.toString())
                        }
                        return true
                    }
                }
            }
        },
        update = { it.loadDataWithBaseURL(null, html, "text/html", "utf-8", null) },
    )
}

/**
 * The system's print dialog for the page, where "Save as PDF" is one of the printers. The WebView
 * lays it out on A4 with the report's print styles.
 */
actual suspend fun ReportDocument.sharePdf(title: String): Boolean {
    val web = view as? WebView ?: return false
    val activity = generateSequence(web.context) { (it as? ContextWrapper)?.baseContext }.firstOrNull { it is Activity } ?: return false
    val printer = activity.getSystemService(Context.PRINT_SERVICE) as? PrintManager ?: return false
    // The report's pictures load lazily, and a picture never scrolled to would be an empty frame on
    // paper. They are all inline, so this is only decoding — done now, for the paper.
    web.evaluateJavascript("Array.from(document.images).forEach(function (p) { p.loading = 'eager'; });", null)
    withTimeoutOrNull(5_000) {
        while (!picturesReady(web)) delay(150)
    }
    val name = title.replace("/", "-").trim().ifEmpty { "Report" }.take(80)
    printer.print(name, web.createPrintDocumentAdapter(name),
        PrintAttributes.Builder().setMediaSize(PrintAttributes.MediaSize.ISO_A4).build())
    return true
}

private suspend fun picturesReady(web: WebView): Boolean = suspendCancellableCoroutine { done ->
    web.evaluateJavascript("Array.from(document.images).every(function (p) { return p.complete; })") { answer ->
        if (done.isActive) done.resume(answer == "true")
    }
}
