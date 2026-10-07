package com.stepanok.bulava.ui.report

import androidx.compose.runtime.Composable
import androidx.compose.runtime.key
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.ui.Modifier
import androidx.compose.ui.viewinterop.UIKitView
import com.stepanok.bulava.platform.currentHost
import kotlinx.cinterop.ExperimentalForeignApi
import kotlinx.coroutines.suspendCancellableCoroutine
import platform.UIKit.UIView
import kotlin.coroutines.resume

/** The locked-down web view comes from Swift (`BulavaHost.reportView`); see there for the fences. */
@OptIn(ExperimentalForeignApi::class)
@Composable
actual fun HtmlView(html: String, modifier: Modifier, onLink: (String) -> Unit, document: ReportDocument?) {
    val host = currentHost ?: return
    val latest = rememberUpdatedState(onLink)
    key(html) {
        UIKitView<UIView>(
            factory = { host.reportView(html) { latest.value(it) }.also { document?.view = it } },
            modifier = modifier,
        )
    }
}

/** Swift paginates the page with its print styles and offers the file (`BulavaHost.shareReportPdf`). */
actual suspend fun ReportDocument.sharePdf(title: String): Boolean {
    val host = currentHost ?: return false
    val page = view as? UIView ?: return false
    return suspendCancellableCoroutine { done -> host.shareReportPdf(page, title) { made -> if (done.isActive) done.resume(made) } }
}
