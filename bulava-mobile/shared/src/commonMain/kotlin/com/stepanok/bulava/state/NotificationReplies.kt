package com.stepanok.bulava.state

import com.stepanok.bulava.platform.PhoneNotification
import com.stepanok.bulava.resources.Res
import com.stepanok.bulava.resources.notify_reply_failed
import com.stepanok.bulava.resources.notify_reply_stale
import com.stepanok.bulava.resources.notify_reply_unreachable
import org.jetbrains.compose.resources.getString

/**
 * A button pressed on a notification, as the phone's system hands it over — perhaps with the app
 * closed. When the Mac did it, the notification is gone and that is all. When it did not, the same
 * notification is replaced by one that says why, and a tap on it still leads to the request.
 */
suspend fun AppController.pressFromNotification(notificationID: String, actionID: String, text: String?): Boolean {
    val (reply, message) = respondFromNotification(notificationID, actionID, text)
    val said = when (reply) {
        AppController.Reply.Done -> return true
        AppController.Reply.Unreachable -> getString(Res.string.notify_reply_unreachable)
        AppController.Reply.Stale -> getString(Res.string.notify_reply_stale)
        AppController.Reply.Failed -> message ?: getString(Res.string.notify_reply_failed)
    }
    val home = home.value
    val item = home?.attention?.firstOrNull { it.id == notificationID }
    val product = home?.products?.firstOrNull { it.id == item?.productID }?.name
    val title = listOfNotNull(product, item?.title?.takeIf { it.isNotBlank() }).distinct().joinToString(" · ")
    if (reply == AppController.Reply.Stale) {
        // Answered already, on the Mac or here: nothing is left to do, so nothing is left to tap.
        platform.notifier.post(PhoneNotification(notificationID, title.ifBlank { home?.desktop?.name ?: "Bulava" }, said, quiet = true))
        return false
    }
    platform.notifier.post(PhoneNotification(notificationID, title.ifBlank { home?.desktop?.name ?: "Bulava" }, said)
        .leadingTo(if (item != null && home != null) AppController.place(item, home) else null))
    return false
}
