package com.stepanok.bulava

import android.Manifest
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.activity.result.PickVisualMediaRequest
import androidx.activity.result.contract.ActivityResultContracts
import androidx.core.content.ContextCompat
import com.stepanok.bulava.platform.AndroidLauncher
import com.stepanok.bulava.platform.AndroidPlatform

class MainActivity : ComponentActivity(), AndroidLauncher {
    private val app get() = application as BulavaApplication

    private var scanResult: ((String?) -> Unit)? = null
    private var pickResult: ((Uri?) -> Unit)? = null

    private val scanner = registerForActivityResult(ActivityResultContracts.StartActivityForResult()) { result ->
        val code = result.data?.getStringExtra(ScanActivity.EXTRA_CODE)
        val waiting = scanResult
        scanResult = null
        // The screen that asked for the scan can be gone by the time the answer comes: turning the
        // phone, low memory, a theme change all make this activity again, and the new one knows
        // nothing of the old one's callback. The code is not lost for that — it goes to the same
        // place a pairing link does.
        if (waiting != null) waiting(code) else if (code != null) app.controller.handleLink(code)
    }
    private val photos = registerForActivityResult(ActivityResultContracts.PickVisualMedia()) { uri ->
        pickResult?.invoke(uri)
        pickResult = null
    }
    private val documents = registerForActivityResult(ActivityResultContracts.OpenDocument()) { uri ->
        pickResult?.invoke(uri)
        pickResult = null
    }
    private val permissions = registerForActivityResult(ActivityResultContracts.RequestMultiplePermissions()) { }
    private var micResult: ((Boolean) -> Unit)? = null
    private val microphone = registerForActivityResult(ActivityResultContracts.RequestPermission()) { allowed ->
        micResult?.invoke(allowed)
        micResult = null
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        enableEdgeToEdge()
        super.onCreate(savedInstanceState)
        app.platform.launcher = this
        askForWhatTheLinkNeeds()
        handle(intent)
        setContent { BulavaApp(app.controller) }
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        handle(intent)
    }

    override fun onDestroy() {
        if (app.platform.launcher === this) app.platform.launcher = null
        super.onDestroy()
    }

    /** A notification tap opens what it is about; a pairing link from the site pairs. */
    private fun handle(intent: Intent?) {
        intent ?: return
        intent.data?.let { uri -> if (uri.scheme == "bulava") app.controller.handleLink(uri.toString()) }
        val product = intent.getStringExtra(AndroidPlatform.EXTRA_PRODUCT)
        val chat = intent.getStringExtra(AndroidPlatform.EXTRA_CHAT)
        val about = intent.getStringExtra(AndroidPlatform.EXTRA_ABOUT)
        if (product != null || chat != null || about != null) {
            app.controller.openFromNotification(product, chat, about)
            intent.removeExtra(AndroidPlatform.EXTRA_PRODUCT)
            intent.removeExtra(AndroidPlatform.EXTRA_CHAT)
            intent.removeExtra(AndroidPlatform.EXTRA_ABOUT)
        }
    }

    /**
     * Local network access (Android 17) is what the link runs on; notifications are how a request
     * reaches a phone in a pocket. Asked once, together, at the start — each can be changed later
     * in the system settings, and the app says so where it matters.
     */
    private fun askForWhatTheLinkNeeds() {
        val wanted = buildList {
            if (Build.VERSION.SDK_INT >= 33) add(Manifest.permission.POST_NOTIFICATIONS)
            if (Build.VERSION.SDK_INT >= 37) add("android.permission.ACCESS_LOCAL_NETWORK")
        }.filter { ContextCompat.checkSelfPermission(this, it) != PackageManager.PERMISSION_GRANTED }
        if (wanted.isNotEmpty()) permissions.launch(wanted.toTypedArray())
    }

    override fun scan(onResult: (String?) -> Unit) {
        scanResult = onResult
        scanner.launch(Intent(this, ScanActivity::class.java))
    }

    override fun pick(image: Boolean, onResult: (Uri?) -> Unit) {
        pickResult = onResult
        if (image) photos.launch(PickVisualMediaRequest(ActivityResultContracts.PickVisualMedia.ImageAndVideo))
        else documents.launch(arrayOf("*/*"))
    }

    override fun requestNotifications() {
        if (Build.VERSION.SDK_INT >= 33) permissions.launch(arrayOf(Manifest.permission.POST_NOTIFICATIONS))
    }

    /**
     * Asked when the mic in the composer is first pressed, not at launch with the others: it is
     * for dictation, which he may never use, and a question asked at the moment it matters is the
     * one people understand.
     */
    override fun requestMicrophone(onResult: (Boolean) -> Unit) {
        micResult = onResult
        microphone.launch(Manifest.permission.RECORD_AUDIO)
    }
}
