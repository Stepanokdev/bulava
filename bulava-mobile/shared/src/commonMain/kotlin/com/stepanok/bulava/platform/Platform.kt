package com.stepanok.bulava.platform

/**
 * Everything the shared code needs from the phone it runs on. One implementation per platform:
 * Android in `androidMain`, iOS in `iosMain` (backed by Swift in the iosApp target).
 */
interface PlatformServices {
    /** "android" or "ios" — what the Mac shows next to the phone's name. */
    val platformName: String
    fun deviceName(): String
    fun osVersion(): String
    fun appVersion(): String

    /**
     * The build number — Android's versionCode, the iPhone's CFBundleVersion — which only ever
     * rises. Whether a newer app is out is decided by it; 0 where it cannot be read.
     */
    fun appBuild(): Int = 0

    /** A pinned-TLS WebSocket. Nothing else in the app opens a network connection. */
    fun transport(): LinkTransport

    /** For the credential the Mac handed over: Keychain on iOS, Keystore-wrapped on Android. */
    val secure: KeyValueStore

    /** Ordinary preferences: drafts, which requests were already announced. */
    val prefs: KeyValueStore

    val notifier: Notifier

    fun openUrl(url: String)

    /** Opens the camera to read a pairing code. Null when the person backed out. */
    fun scanCode(onResult: (String?) -> Unit)

    fun pickImage(onResult: (PickedFile?) -> Unit)
    fun pickFile(onResult: (PickedFile?) -> Unit)

    /** Finds a Mac on this network by its Bonjour name when its address changed. host:port pairs. */
    fun discover(desktopID: String, onFound: (List<String>) -> Unit)

    /**
     * Whether the link should keep running while the app is in the background. Android keeps it in
     * a foreground service so requests still reach the phone; iOS cannot hold a socket open, and
     * checks in when the system lets it.
     */
    fun keepLinkAlive(active: Boolean, macName: String)

    /** Whether the system may show notifications at all, and a way to ask. */
    fun notificationsAllowed(): Boolean
    fun requestNotifications()

    /** Where the system settings for this app are, for a permission that was refused. */
    fun openAppSettings()

    /**
     * How much is going on at the Mac, where the phone shows that at a glance: a Live Activity on
     * an iPhone, the connection notification on Android. [live] names the work, from a Mac that
     * sends it.
     */
    fun showSummary(summary: com.stepanok.bulava.link.Summary, live: com.stepanok.bulava.link.Live?, macName: String) = Unit

    /**
     * The week for the phone's widgets, as the Mac sent it — or null to take it away (the Mac was
     * forgotten). Kept where the widgets can read it while the app is not running.
     */
    fun showWeek(week: com.stepanok.bulava.link.Week?) = Unit

    /**
     * The key this phone's Lock Screen reads the names of the work with, base64 — made once and
     * kept where the Lock Screen can reach it. The Mac seals what goes through the push relay with
     * it. Null where there is no such thing (Android, which keeps its own connection).
     */
    fun liveKey(): String? = null

    /**
     * Whether the Mac's pushes reach this phone while the app is not on screen — an iPhone's do,
     * through the relay. Then a finished piece of work is told by that push alone, and the app
     * does not say it a second time from the background.
     */
    val relayWakes: Boolean get() = false

    /**
     * The microphone, for dictation the Mac transcribes. Null where there is none to offer — the
     * demo, a test — and then the composer has no mic button: the keyboard's own dictation is
     * still there.
     */
    val voice: VoiceRecorder? get() = null
}

/**
 * Records one voice note at a time into a file of its own, for the Mac's Whisper to hear.
 *
 * AAC in an M4A file on both platforms: small (about half a megabyte a minute), and what Whisper on
 * the Mac reads without conversion. The file stays on the phone until its words are in the
 * composer or he throws it away — the shared code says when, with [delete].
 */
interface VoiceRecorder {
    /** Whether the app may use the microphone now, was refused, or has not asked yet. */
    fun permission(): MicPermission

    /** Asks for the microphone, once; [onResult] is told whether it was allowed. */
    fun requestPermission(onResult: (Boolean) -> Unit)

    /** A path for a new recording, in the app's own storage. Nothing is created yet. */
    fun newRecordingPath(): String

    /** Starts recording into [path]. False when the microphone could not be had. */
    fun start(path: String): Boolean

    /** How loud it is right now, 0…1, for the meter. */
    fun level(): Float

    /** Stops and keeps the file. False when nothing usable was written. */
    fun stop(): Boolean

    /** Stops and throws the file away. */
    fun cancel()

    /** The system settings where the microphone is allowed for this app, after a refusal. */
    fun openSettings()

    /** The recording's bytes, for the upload; null when the file is gone. */
    fun read(path: String): ByteArray?

    fun delete(path: String)

    /** Whether the file is still on the phone. */
    fun exists(path: String): Boolean
}

enum class MicPermission { Granted, Denied, NotAsked }

interface KeyValueStore {
    fun get(key: String): String?
    fun put(key: String, value: String)
    fun remove(key: String)
}

interface Notifier {
    /** A system notification that opens its chat (or the inbox) when tapped. */
    fun post(note: PhoneNotification)
    fun cancel(id: String)

    /**
     * Takes back the relay's wake-ups — "Bulava needs you", "a task is done" — once the Mac has
     * been heard from directly: what they stood for is now told in full, one notification per
     * request, or is on screen. Only an iPhone has any.
     */
    fun clearWakeUps() = Unit
}

/** One system notification: what it says, where a tap leads, and how loudly it says it. */
data class PhoneNotification(
    val id: String,
    val title: String,
    val body: String,
    val productID: String? = null,
    val chatID: String? = null,
    /**
     * Where a tap leads when it is not a chat or a product: "readiness" — the Mac's setup, in the
     * settings. Handed back on the tap, as `AppController.OpenRequest.about`.
     */
    val about: String? = null,
    /** No sound, no lit screen: it waits in the list for whenever. */
    val quiet: Boolean = false,
    /** Work that finished — a report in, a chat's answer. Heard, and grouped on its own. */
    val finished: Boolean = false,
    /**
     * Buttons that answer from the notification itself, the same ones the request has on the Mac.
     * The phone must be unlocked — Face ID, a fingerprint or the code — before one is pressed.
     */
    val buttons: List<NotificationButton> = emptyList(),
)

data class NotificationButton(
    /** The Mac's action id: what `action.invoke` is sent. */
    val id: String,
    val label: String,
    val destructive: Boolean = false,
    /** Set when the button asks for a line of text first: the field's placeholder. */
    val inputPlaceholder: String? = null,
)

class PickedFile(
    val name: String,
    /** image | audio | file */
    val kind: String,
    val bytes: ByteArray,
)

interface LinkTransport {
    fun open(url: String, pin: String, listener: TransportListener)
    fun send(text: String): Boolean
    fun close()
}

interface TransportListener {
    fun onOpen()
    fun onText(text: String)
    /** [failure] is null for an orderly close. */
    fun onClosed(failure: String?)
}
