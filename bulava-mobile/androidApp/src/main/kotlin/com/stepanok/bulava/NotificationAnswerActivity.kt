package com.stepanok.bulava

import android.app.Activity
import android.app.KeyguardManager
import android.os.Bundle
import androidx.core.app.RemoteInput
import com.stepanok.bulava.platform.AndroidPlatform
import com.stepanok.bulava.platform.UnlockGate
import com.stepanok.bulava.state.pressFromNotification
import kotlinx.coroutines.launch

/**
 * A button pressed on a request's notification — "Trust and send", "Yes, do it". It has no screen
 * of its own: it shows over the lock screen only long enough to ask for the phone to be unlocked,
 * when it is locked, and presses the button on the Mac over the local link once it is. Asked and
 * not unlocked, nothing is pressed and the request stays where it was.
 */
class NotificationAnswerActivity : Activity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        setShowWhenLocked(true)
        val noteID = intent.getStringExtra(AndroidPlatform.EXTRA_NOTIFICATION)
        val actionID = intent.getStringExtra(AndroidPlatform.EXTRA_ACTION)
        if (noteID == null || actionID == null || savedInstanceState != null) {
            finish()
            return
        }
        val text = RemoteInput.getResultsFromIntent(intent)?.getCharSequence(AndroidPlatform.REPLY_TEXT)?.toString()
        val keyguard = getSystemService(KeyguardManager::class.java)
        val app = application as BulavaApplication
        UnlockGate(
            locked = { keyguard.isDeviceLocked },
            askToUnlock = { answer ->
                keyguard.requestDismissKeyguard(this, object : KeyguardManager.KeyguardDismissCallback() {
                    override fun onDismissSucceeded() = answer(true)
                    override fun onDismissCancelled() = answer(false)
                    override fun onDismissError() = answer(false)
                })
            },
        ).pass(
            press = {
                // The application's scope outlives this screen; the connection service keeps it running.
                app.scope.launch { app.controller.pressFromNotification(noteID, actionID, text) }
                finish()
            },
            refused = { finish() },
        )
    }
}
