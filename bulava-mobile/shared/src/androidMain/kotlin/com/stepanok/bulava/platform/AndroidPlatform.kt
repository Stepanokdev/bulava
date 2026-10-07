package com.stepanok.bulava.platform

import android.Manifest
import android.annotation.SuppressLint
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.net.nsd.NsdManager
import android.net.nsd.NsdServiceInfo
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.provider.OpenableColumns
import android.provider.Settings
import androidx.core.app.NotificationCompat
import androidx.core.app.NotificationManagerCompat
import androidx.core.app.RemoteInput
import com.stepanok.bulava.link.Summary
import androidx.core.content.ContextCompat

/** What only an Activity can do — open the camera, show a picker, ask for a permission. */
interface AndroidLauncher {
    fun scan(onResult: (String?) -> Unit)
    fun pick(image: Boolean, onResult: (Uri?) -> Unit)
    fun requestNotifications()
    /** Asks for the microphone; [onResult] is told whether it was allowed. */
    fun requestMicrophone(onResult: (Boolean) -> Unit)
}

/**
 * How the app's own components are reached from here: the service, the screen a tap opens, and
 * the one a button pressed on a notification goes to, which has the phone unlocked first.
 */
class AndroidComponents(
    val mainActivity: Class<*>,
    val linkService: Class<*>,
    val answerActivity: Class<*>,
    val notificationIcon: Int,
    val requestsChannelName: String,
    val finishedChannelName: String,
    val linkChannelName: String,
    /** Told when the week the Home Screen widgets draw has changed, so they redraw. */
    val weekChanged: ((Context) -> Unit)? = null,
)

class AndroidPlatform(
    private val context: Context,
    private val components: AndroidComponents,
) : PlatformServices {
    /** Set by the activity while it is alive. */
    @Volatile var launcher: AndroidLauncher? = null

    override val platformName = "android"

    override fun deviceName(): String =
        Settings.Global.getString(context.contentResolver, Settings.Global.DEVICE_NAME)?.takeIf { it.isNotBlank() }
            ?: "${Build.MANUFACTURER.replaceFirstChar { it.uppercase() }} ${Build.MODEL}"

    override fun osVersion(): String = "Android ${Build.VERSION.RELEASE}"

    override fun appVersion(): String = runCatching {
        context.packageManager.getPackageInfo(context.packageName, 0).versionName ?: ""
    }.getOrDefault("")

    override fun appBuild(): Int = runCatching {
        val info = context.packageManager.getPackageInfo(context.packageName, 0)
        @Suppress("DEPRECATION")
        if (Build.VERSION.SDK_INT >= 28) info.longVersionCode.toInt() else info.versionCode
    }.getOrDefault(0)

    override val voice: VoiceRecorder = AndroidVoice(context) { launcher }

    override fun transport(): LinkTransport = AndroidTransport()

    override val secure: KeyValueStore = KeystoreStore(context)
    override val prefs: KeyValueStore = PrefsStore(context, "bulava.prefs")
    override val notifier: Notifier = AndroidNotifier(context, components)

    private val main = Handler(Looper.getMainLooper())

    override fun openUrl(url: String) {
        context.startActivity(Intent(Intent.ACTION_VIEW, Uri.parse(url)).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
    }

    override fun scanCode(onResult: (String?) -> Unit) {
        launcher?.scan(onResult) ?: onResult(null)
    }

    override fun pickImage(onResult: (PickedFile?) -> Unit) = pick(true, onResult)
    override fun pickFile(onResult: (PickedFile?) -> Unit) = pick(false, onResult)

    private fun pick(image: Boolean, onResult: (PickedFile?) -> Unit) {
        val l = launcher ?: return onResult(null)
        l.pick(image) { uri ->
            if (uri == null) return@pick onResult(null)
            Thread {
                val file = read(uri, image)
                main.post { onResult(file) }
            }.start()
        }
    }

    private fun read(uri: Uri, image: Boolean): PickedFile? = runCatching {
        val resolver = context.contentResolver
        var name = "attachment"
        var size = -1L
        resolver.query(uri, arrayOf(OpenableColumns.DISPLAY_NAME, OpenableColumns.SIZE), null, null, null)?.use { c ->
            if (c.moveToFirst()) {
                c.getString(0)?.let { name = it }
                if (!c.isNull(1)) size = c.getLong(1)
            }
        }
        if (size > MAX_BYTES) return@runCatching null
        val bytes = resolver.openInputStream(uri)?.use { it.readBytes() } ?: return@runCatching null
        if (bytes.size > MAX_BYTES) return@runCatching null
        val mime = resolver.getType(uri).orEmpty()
        val kind = when {
            image || mime.startsWith("image/") -> "image"
            mime.startsWith("audio/") -> "audio"
            else -> "file"
        }
        if (!name.contains('.')) {
            val ext = android.webkit.MimeTypeMap.getSingleton().getExtensionFromMimeType(mime)
            if (ext != null) name = "$name.$ext"
        }
        PickedFile(name, kind, bytes)
    }.getOrNull()

    override fun discover(desktopID: String, onFound: (List<String>) -> Unit) {
        val nsd = context.getSystemService(Context.NSD_SERVICE) as? NsdManager ?: return onFound(emptyList())
        val found = mutableListOf<String>()
        var done = false
        val listener = object : NsdManager.DiscoveryListener {
            override fun onDiscoveryStarted(serviceType: String) = Unit
            override fun onDiscoveryStopped(serviceType: String) = Unit
            override fun onStartDiscoveryFailed(serviceType: String, errorCode: Int) = finish()
            override fun onStopDiscoveryFailed(serviceType: String, errorCode: Int) = Unit
            override fun onServiceLost(serviceInfo: NsdServiceInfo) = Unit
            override fun onServiceFound(serviceInfo: NsdServiceInfo) = resolve(nsd, serviceInfo, desktopID) { hostPort ->
                main.post { if (!done && hostPort != null) found += hostPort }
            }
            fun finish() {
                main.post {
                    if (done) return@post
                    done = true
                    onFound(found.distinct())
                }
            }
        }
        runCatching { nsd.discoverServices("_bulava-link._tcp.", NsdManager.PROTOCOL_DNS_SD, listener) }
            .onFailure { return onFound(emptyList()) }
        main.postDelayed({
            runCatching { nsd.stopServiceDiscovery(listener) }
            if (!done) { done = true; onFound(found.distinct()) }
        }, 3_000)
    }

    @Suppress("DEPRECATION")
    private fun resolve(nsd: NsdManager, info: NsdServiceInfo, desktopID: String, result: (String?) -> Unit) {
        nsd.resolveService(info, object : NsdManager.ResolveListener {
            override fun onResolveFailed(serviceInfo: NsdServiceInfo, errorCode: Int) = result(null)
            override fun onServiceResolved(serviceInfo: NsdServiceInfo) {
                val id = serviceInfo.attributes["id"]?.toString(Charsets.UTF_8)
                val host = serviceInfo.host?.hostAddress
                result(if (id == desktopID && host != null) "$host:${serviceInfo.port}" else null)
            }
        })
    }

    /** Whether the connection service is running, and what its notification should count. */
    @Volatile private var linkAlive = false
    @Volatile private var macName = ""
    @Volatile var lastSummary: Summary = Summary()
        private set
    @Volatile var lastLive: com.stepanok.bulava.link.Live? = null
        private set

    override fun keepLinkAlive(active: Boolean, macName: String) {
        val intent = Intent(context, components.linkService).putExtra("mac", macName)
        linkAlive = active
        if (macName.isNotBlank()) this.macName = macName
        if (active) {
            runCatching { ContextCompat.startForegroundService(context, intent) }
        } else {
            context.stopService(intent)
        }
    }

    /** The connection's own notification says what is going on; it is redrawn when that changes. */
    override fun showSummary(summary: Summary, live: com.stepanok.bulava.link.Live?, macName: String) {
        if (summary == lastSummary && live == lastLive) return
        lastSummary = summary
        lastLive = live
        if (!linkAlive) return
        // A running foreground service lets its app start it again from the background.
        runCatching { context.startService(Intent(context, components.linkService).putExtra("mac", macName.ifBlank { this.macName })) }
    }

    /** The Home Screen widgets' week: kept where they read it, and they are told to redraw. */
    override fun showWeek(week: com.stepanok.bulava.link.Week?) {
        if (WeekPrefs.write(context, week)) components.weekChanged?.invoke(context)
    }

    override fun notificationsAllowed(): Boolean = NotificationManagerCompat.from(context).areNotificationsEnabled()

    override fun requestNotifications() {
        if (Build.VERSION.SDK_INT >= 33 &&
            ContextCompat.checkSelfPermission(context, Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED) {
            launcher?.requestNotifications()
        } else {
            openAppSettings()
        }
    }

    override fun openAppSettings() {
        val intent = if (Build.VERSION.SDK_INT >= 26) {
            Intent(Settings.ACTION_APP_NOTIFICATION_SETTINGS).putExtra(Settings.EXTRA_APP_PACKAGE, context.packageName)
        } else {
            Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS, Uri.parse("package:${context.packageName}"))
        }
        context.startActivity(intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
    }

    companion object {
        const val MAX_BYTES = 50L * 1024 * 1024
        const val CHANNEL_REQUESTS = "requests"
        const val CHANNEL_FINISHED = "finished.heard"
        const val CHANNEL_FINISHED_QUIET = "finished"
        const val CHANNEL_LINK = "link"
        const val EXTRA_PRODUCT = "bulava.product"
        const val EXTRA_CHAT = "bulava.chat"
        /** `PhoneNotification.about`: where a tap leads when it is not a chat or a product. */
        const val EXTRA_ABOUT = "bulava.about"
        const val EXTRA_NOTIFICATION = "bulava.notification"
        const val EXTRA_ACTION = "bulava.action"
        const val REPLY_TEXT = "bulava.reply"
    }
}

class AndroidNotifier(private val context: Context, private val components: AndroidComponents) : Notifier {
    init {
        if (Build.VERSION.SDK_INT >= 26) {
            val manager = context.getSystemService(NotificationManager::class.java)
            manager.createNotificationChannel(
                NotificationChannel(AndroidPlatform.CHANNEL_REQUESTS, components.requestsChannelName, NotificationManager.IMPORTANCE_HIGH),
            )
            // Work that finished — a report in, a chat's answer — is what the director waits to
            // hear about: a sound and a heads-up. It used to be a silent channel, and a channel's
            // importance cannot be raised once made, so the old one goes and this one replaces it.
            manager.deleteNotificationChannel(AndroidPlatform.CHANNEL_FINISHED_QUIET)
            manager.createNotificationChannel(
                NotificationChannel(AndroidPlatform.CHANNEL_FINISHED, components.finishedChannelName, NotificationManager.IMPORTANCE_HIGH),
            )
            manager.createNotificationChannel(
                NotificationChannel(AndroidPlatform.CHANNEL_LINK, components.linkChannelName, NotificationManager.IMPORTANCE_MIN)
                    .apply { setShowBadge(false) },
            )
        }
    }

    @SuppressLint("MissingPermission")
    override fun post(note: PhoneNotification) {
        if (!NotificationManagerCompat.from(context).areNotificationsEnabled()) return
        val open = Intent(context, components.mainActivity)
            .addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_CLEAR_TOP)
            .putExtra(AndroidPlatform.EXTRA_PRODUCT, note.productID)
            .putExtra(AndroidPlatform.EXTRA_CHAT, note.chatID)
            .putExtra(AndroidPlatform.EXTRA_ABOUT, note.about)
        val pending = PendingIntent.getActivity(context, note.id.hashCode(), open,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
        val builder = NotificationCompat.Builder(context, if (note.finished) AndroidPlatform.CHANNEL_FINISHED else AndroidPlatform.CHANNEL_REQUESTS)
            .setSmallIcon(components.notificationIcon)
            .setContentTitle(note.title)
            .setContentText(note.body)
            .setStyle(NotificationCompat.BigTextStyle().bigText(note.body))
            .setContentIntent(pending)
            .setAutoCancel(true)
            .setOnlyAlertOnce(true)
            .setCategory(if (note.quiet) NotificationCompat.CATEGORY_STATUS else NotificationCompat.CATEGORY_MESSAGE)
            .setPriority(if (note.quiet) NotificationCompat.PRIORITY_LOW else NotificationCompat.PRIORITY_HIGH)
            .setSilent(note.quiet)
        for (button in note.buttons) builder.addAction(action(note.id, button))
        NotificationManagerCompat.from(context).notify(note.id.hashCode(), builder.build())
    }

    /**
     * A request's button on its notification. It opens the app's answer screen, which on a locked
     * phone asks for it to be unlocked before anything is pressed — on every version; Android 12
     * and later also ask on their own first. One that needs words takes them in the notification.
     */
    private fun action(noteID: String, button: NotificationButton): NotificationCompat.Action {
        val intent = Intent(context, components.answerActivity)
            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_NO_ANIMATION)
            .putExtra(AndroidPlatform.EXTRA_NOTIFICATION, noteID)
            .putExtra(AndroidPlatform.EXTRA_ACTION, button.id)
        // Text typed into the notification is added to the intent, which it must therefore allow.
        val mutability = if (button.inputPlaceholder != null && Build.VERSION.SDK_INT >= 31) PendingIntent.FLAG_MUTABLE
            else PendingIntent.FLAG_IMMUTABLE
        val pending = PendingIntent.getActivity(context, (noteID + button.id).hashCode(), intent,
            PendingIntent.FLAG_UPDATE_CURRENT or mutability)
        val action = NotificationCompat.Action.Builder(0, button.label, pending)
            .setAuthenticationRequired(true)
        if (button.inputPlaceholder != null) {
            action.addRemoteInput(RemoteInput.Builder(AndroidPlatform.REPLY_TEXT).setLabel(button.inputPlaceholder).build())
                .setAllowGeneratedReplies(false)
        }
        if (button.destructive) action.setSemanticAction(NotificationCompat.Action.SEMANTIC_ACTION_DELETE)
        return action.build()
    }

    override fun cancel(id: String) {
        NotificationManagerCompat.from(context).cancel(id.hashCode())
    }
}
