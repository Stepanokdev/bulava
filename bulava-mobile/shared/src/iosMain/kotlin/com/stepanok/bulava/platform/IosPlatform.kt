package com.stepanok.bulava.platform

import kotlinx.cinterop.ExperimentalForeignApi
import kotlinx.cinterop.addressOf
import kotlinx.cinterop.usePinned
import platform.Foundation.NSApplicationSupportDirectory
import platform.Foundation.NSBundle
import platform.Foundation.NSData
import platform.Foundation.NSFileManager
import platform.Foundation.NSSearchPathForDirectoriesInDomains
import platform.Foundation.NSUUID
import platform.Foundation.NSUserDefaults
import platform.Foundation.NSUserDomainMask
import platform.Foundation.dataWithContentsOfFile
import platform.posix.memcpy

/**
 * What the iOS app provides from Swift. The things iOS only offers well to Swift — a pinned TLS
 * socket, the Keychain, the camera, the pickers, Bonjour, notifications — live there, behind this.
 */
interface IosHost {
    fun deviceName(): String
    fun osVersion(): String
    fun appVersion(): String
    fun openSocket(url: String, pin: String, listener: TransportListener): IosSocket
    fun keychainGet(key: String): String?
    fun keychainPut(key: String, value: String)
    fun keychainRemove(key: String)
    fun notify(note: PhoneNotification)
    fun clearWakeUps()
    fun cancelNotification(id: String)
    fun notificationsAllowed(): Boolean
    fun requestNotifications()
    fun openURL(url: String)
    fun openSettings()
    fun scanCode(onResult: (String?) -> Unit)
    /** Calls back with a path to a copy of the picked file, and its name. */
    fun pickImage(onResult: (String?, String?) -> Unit)
    fun pickFile(onResult: (String?, String?) -> Unit)
    fun browse(desktopID: String, onFound: (List<String>) -> Unit)
    /** Asks iOS to wake the app now and then to check for requests. */
    fun scheduleRefresh(active: Boolean)

    /**
     * The Live Activity: started, updated or ended to match. [live] is the Mac's `live` as JSON —
     * the work by name — or null from a Mac that sends only the counts.
     */
    fun showSummary(working: Int, waiting: Int, ready: Int, live: String?, macName: String)

    /** The key the Lock Screen reads the names of the work with, made once and kept in the Keychain. */
    fun liveKey(): String?

    /**
     * The week for the widgets, as JSON in the Mac's `WeekSnapshot` shape, or null to remove it.
     * Kept in the Keychain group the widgets share; they redraw from it.
     */
    fun showWeek(json: String?)

    /**
     * The report in [view] as a PDF of A4 pages — its print styles, so white paper whatever the
     * theme — offered with the system's share sheet. [done] is told whether one was made.
     */
    fun shareReportPdf(view: platform.UIKit.UIView, title: String, done: (Boolean) -> Unit)

    /**
     * A web view for a report that cannot reach the network: every load but `data:` and
     * `about:` is blocked, and the page cannot navigate. An activated http(s) link is handed to
     * [onLink], which asks the reader before anything opens.
     */
    fun reportView(html: String, onLink: (String) -> Unit): platform.UIKit.UIView

    /** The microphone for dictation: 0 allowed, 1 refused, 2 not asked yet. */
    fun micPermission(): Int
    fun requestMicrophone(onResult: (Boolean) -> Unit)

    /** Records AAC (an M4A) into [path] until stopped. False when the microphone could not be had. */
    fun startRecording(path: String): Boolean

    /** How loud it is right now, 0…1. */
    fun recordingLevel(): Float

    /** Stops and keeps the file. False when nothing was recorded. */
    fun stopRecording(): Boolean

    /** Stops and deletes the file. */
    fun cancelRecording()
}

/** The host the app was started with, for the few composables that need Swift directly. */
var currentHost: IosHost? = null

/**
 * The microphone on an iPhone: `AVAudioRecorder` in Swift, files here. The recordings live in
 * Application Support — not the caches, which iOS empties when it likes: a note is kept until its
 * words are in the composer, however long the Mac takes to come back.
 */
@OptIn(ExperimentalForeignApi::class)
private class IosVoice(private val host: IosHost) : VoiceRecorder {
    private val folder: String by lazy {
        val base = NSSearchPathForDirectoriesInDomains(NSApplicationSupportDirectory, NSUserDomainMask, true)
            .firstOrNull() as? String ?: platform.Foundation.NSTemporaryDirectory()
        val dir = "$base/voice"
        NSFileManager.defaultManager.createDirectoryAtPath(dir, withIntermediateDirectories = true, attributes = null, error = null)
        dir
    }

    override fun permission(): MicPermission = when (host.micPermission()) {
        0 -> MicPermission.Granted
        1 -> MicPermission.Denied
        else -> MicPermission.NotAsked
    }

    override fun requestPermission(onResult: (Boolean) -> Unit) = host.requestMicrophone(onResult)
    override fun openSettings() = host.openSettings()
    override fun newRecordingPath(): String = "$folder/${NSUUID().UUIDString}.m4a"
    override fun start(path: String): Boolean = host.startRecording(path)
    override fun level(): Float = host.recordingLevel()
    override fun stop(): Boolean = host.stopRecording()
    override fun cancel() = host.cancelRecording()

    override fun read(path: String): ByteArray? {
        val data = NSData.dataWithContentsOfFile(path) ?: return null
        val size = data.length.toInt()
        if (size <= 0) return ByteArray(0)
        val bytes = ByteArray(size)
        bytes.usePinned { memcpy(it.addressOf(0), data.bytes, data.length) }
        return bytes
    }

    override fun delete(path: String) {
        // Only what this class made: a note's path comes back from storage, and storage can be edited.
        if (path.substringBeforeLast('/') == folder) NSFileManager.defaultManager.removeItemAtPath(path, null)
    }

    override fun exists(path: String): Boolean = NSFileManager.defaultManager.fileExistsAtPath(path)
}

interface IosSocket {
    fun send(text: String): Boolean
    fun close()
}

class IosPlatform(private val host: IosHost) : PlatformServices {
    override val platformName = "ios"
    override fun deviceName() = host.deviceName()
    override fun osVersion() = host.osVersion()
    override fun appVersion() = host.appVersion()

    override fun appBuild(): Int =
        (NSBundle.mainBundle.objectForInfoDictionaryKey("CFBundleVersion") as? String)?.toIntOrNull() ?: 0

    override val voice: VoiceRecorder = IosVoice(host)

    override fun transport(): LinkTransport = object : LinkTransport {
        private var socket: IosSocket? = null
        override fun open(url: String, pin: String, listener: TransportListener) {
            socket = host.openSocket(url, pin, listener)
        }
        override fun send(text: String): Boolean = socket?.send(text) ?: false
        override fun close() { socket?.close() }
    }

    override val secure: KeyValueStore = object : KeyValueStore {
        override fun get(key: String) = host.keychainGet(key)
        override fun put(key: String, value: String) = host.keychainPut(key, value)
        override fun remove(key: String) = host.keychainRemove(key)
    }

    override val prefs: KeyValueStore = object : KeyValueStore {
        private val defaults = NSUserDefaults.standardUserDefaults
        override fun get(key: String) = defaults.stringForKey(key)
        override fun put(key: String, value: String) = defaults.setObject(value, key)
        override fun remove(key: String) = defaults.removeObjectForKey(key)
    }

    override val notifier: Notifier = object : Notifier {
        override fun post(note: PhoneNotification) = host.notify(note)
        override fun clearWakeUps() = host.clearWakeUps()
        override fun cancel(id: String) = host.cancelNotification(id)
    }

    override fun openUrl(url: String) = host.openURL(url)
    override fun scanCode(onResult: (String?) -> Unit) = host.scanCode(onResult)
    override fun pickImage(onResult: (PickedFile?) -> Unit) = host.pickImage { path, name -> onResult(read(path, name, "image")) }
    override fun pickFile(onResult: (PickedFile?) -> Unit) = host.pickFile { path, name -> onResult(read(path, name, null)) }
    override fun discover(desktopID: String, onFound: (List<String>) -> Unit) = host.browse(desktopID, onFound)
    override fun keepLinkAlive(active: Boolean, macName: String) = host.scheduleRefresh(active)
    override fun notificationsAllowed() = host.notificationsAllowed()
    override fun requestNotifications() = host.requestNotifications()
    override fun openAppSettings() = host.openSettings()
    override fun showSummary(summary: com.stepanok.bulava.link.Summary, live: com.stepanok.bulava.link.Live?, macName: String) =
        host.showSummary(summary.working, summary.waiting, summary.ready,
            live?.let { com.stepanok.bulava.link.LinkJson.encodeToString(com.stepanok.bulava.link.Live.serializer(), it) }, macName)

    override fun liveKey(): String? = host.liveKey()

    override fun showWeek(week: com.stepanok.bulava.link.Week?) =
        host.showWeek(week?.let { com.stepanok.bulava.link.LinkJson.encodeToString(com.stepanok.bulava.link.Week.serializer(), it) })

    override val relayWakes: Boolean get() = true

    @OptIn(ExperimentalForeignApi::class)
    private fun read(path: String?, name: String?, kind: String?): PickedFile? {
        path ?: return null
        val data = NSData.dataWithContentsOfFile(path) ?: return null
        NSFileManager.defaultManager.removeItemAtPath(path, null)
        val size = data.length.toInt()
        if (size <= 0 || size > 50 * 1024 * 1024) return null
        val bytes = ByteArray(size)
        bytes.usePinned { memcpy(it.addressOf(0), data.bytes, data.length) }
        val fileName = name ?: path.substringAfterLast('/')
        val ext = fileName.substringAfterLast('.', "").lowercase()
        val resolved = kind ?: when (ext) {
            "png", "jpg", "jpeg", "heic", "gif", "webp" -> "image"
            "m4a", "mp3", "wav", "aac" -> "audio"
            else -> "file"
        }
        return PickedFile(fileName, resolved, bytes)
    }
}
