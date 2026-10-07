package com.stepanok.bulava

import androidx.compose.ui.uikit.OnFocusBehavior
import androidx.compose.ui.window.ComposeUIViewController
import com.stepanok.bulava.link.LinkState
import com.stepanok.bulava.platform.IosHost
import com.stepanok.bulava.platform.IosPlatform
import com.stepanok.bulava.state.AppController
import com.stepanok.bulava.state.pressFromNotification
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.launch
import kotlinx.coroutines.withTimeoutOrNull
import platform.Foundation.NSDate
import platform.Foundation.timeIntervalSince1970
import platform.UIKit.UIViewController

private var shared: AppController? = null
private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main)

/** A push token iOS handed over before the controller existed; it can arrive that early. */
private var pendingPushToken: Pair<String, String>? = null

/** Live Activity tokens that arrived before the controller did: kind to (token, environment). */
private val pendingActivityTokens = mutableMapOf<String, Pair<String, String>>()

/** A notification tap that launched the app, before the controller existed: product, chat, about. */
private var pendingOpen: Triple<String?, String?, String?>? = null

private fun controller(host: IosHost): AppController {
    com.stepanok.bulava.platform.currentHost = host
    return shared ?: AppController(IosPlatform(host), scope) { (NSDate().timeIntervalSince1970 * 1000).toLong() }
        .also { created ->
            shared = created
            pendingPushToken?.let { (token, environment) -> created.setPushToken(token, environment) }
            pendingPushToken = null
            for ((kind, value) in pendingActivityTokens) created.setActivityToken(kind, value.first, value.second)
            pendingActivityTokens.clear()
            pendingOpen?.let { (product, chat, about) -> created.openFromNotification(product, chat, about) }
            pendingOpen = null
        }
}

/**
 * The app's one screen, for the Swift side to put in its window.
 *
 * The screens keep themselves clear of the keyboard: the composer and the pairing form sit on
 * `imePadding`, and a field inside a list is scrolled to by the list. Compose's own habit of
 * panning the whole screen up to the focused field is therefore off — the two together moved the
 * screen twice, and after a return from another app the composer was left floating under the
 * status bar with the top bar pushed out of sight and a gap above the keyboard.
 */
fun MainViewController(host: IosHost): UIViewController {
    val c = controller(host)
    return ComposeUIViewController(configure = { onFocusBehavior = OnFocusBehavior.DoNothing }) { BulavaApp(c) }
}

/** A `bulava://pair#…` link from the pairing page. */
fun handleURL(url: String): Boolean = shared?.handleLink(url) ?: false

/**
 * A notification was tapped: its chat or product, or — a push from the relay — only [about], what
 * kind of thing it says happened. A tap that launched the app arrives before the app's screen has
 * made the controller; it is kept until then.
 */
fun handleNotification(productID: String?, chatID: String?, about: String?) {
    val c = shared
    if (c != null) c.openFromNotification(productID, chatID, about) else pendingOpen = Triple(productID, chatID, about)
}

/** Apple handed this iPhone a push token; [environment] is "development" or "production". */
fun setPushToken(token: String, environment: String) {
    val c = shared
    if (c != null) c.setPushToken(token, environment) else pendingPushToken = token to environment
}

/**
 * A Live Activity token from iOS: [kind] "start" (for starting one by push) or "update" (the one
 * running now). An empty [token] means that activity is over.
 */
fun setActivityToken(kind: String, token: String, environment: String) {
    val c = shared
    if (c != null) c.setActivityToken(kind, token, environment) else pendingActivityTokens[kind] = token to environment
}

/**
 * A button pressed on a notification, perhaps with the app closed: pressed on the Mac over the
 * link. [done] is told whether the Mac did it; either way the notification says what happened.
 */
fun respondToNotification(host: IosHost, notificationID: String, actionID: String, text: String?, done: (Boolean) -> Unit) {
    val c = controller(host)
    scope.launch { done(c.pressFromNotification(notificationID, actionID, text)) }
}

fun setForeground(foreground: Boolean) {
    shared?.inForeground = foreground
    if (foreground) shared?.link?.nudge()
}

/**
 * A background wake from iOS: connect, wait for the Mac's current list of requests — announcing
 * whatever is new as it arrives — and report back. iOS allows about thirty seconds for this.
 */
fun backgroundCheck(host: IosHost, done: (Boolean) -> Unit) {
    val c = controller(host)
    scope.launch {
        val before = c.homeCount.value
        c.link.connect()
        val connected = withTimeoutOrNull(12_000) { c.link.state.first { it is LinkState.Connected } } != null
        val heard = connected && withTimeoutOrNull(8_000) { c.homeCount.first { it > before } } != null
        done(heard)
    }
}
