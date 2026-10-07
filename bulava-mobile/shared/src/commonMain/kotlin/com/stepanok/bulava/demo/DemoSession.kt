package com.stepanok.bulava.demo

import com.stepanok.bulava.link.Credential
import com.stepanok.bulava.link.LinkClient
import com.stepanok.bulava.link.LinkJson
import com.stepanok.bulava.link.PairedMac
import com.stepanok.bulava.platform.KeyValueStore
import com.stepanok.bulava.platform.LinkTransport
import com.stepanok.bulava.platform.Notifier
import com.stepanok.bulava.platform.PhoneNotification
import com.stepanok.bulava.platform.PickedFile
import com.stepanok.bulava.platform.PlatformServices
import com.stepanok.bulava.state.AppController
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel

/**
 * Trying Bulava without a Mac: a controller of its own, talking to a [DemoMac] inside the phone.
 *
 * Nothing of the real session is touched. The demo has its own stores, which live in memory and
 * vanish with it — the real pairing, drafts and unsent messages stay exactly as they were — and it
 * posts no notifications, keeps no service running and looks for no Mac on the network.
 */
class DemoSession private constructor(
    real: PlatformServices, language: String, now: () -> Long, pace: Long,
    private val scope: CoroutineScope,
) {
    private val text = demoText(language)
    private val mac = DemoMac(text, scope, now, pace)
    private val platform = DemoPlatform(real, mac, text.macName)
    val controller = AppController(platform, scope, now)

    /** Ends the demo: its work stops mid-sentence and everything it held is dropped. */
    fun close() {
        controller.link.stop()
        scope.cancel()
    }

    companion object {
        fun start(real: PlatformServices, language: String, now: () -> Long): DemoSession =
            DemoSession(real, language, now, pace = 1, CoroutineScope(SupervisorJob() + Dispatchers.Main))

        /** For tests: the same demo on the test's own scope, with no pauses. */
        internal fun instant(real: PlatformServices, language: String, now: () -> Long, scope: CoroutineScope): DemoSession =
            DemoSession(real, language, now, pace = 0, scope)
    }
}

/** The phone as the demo sees it: the real device for what is harmless, and nothing that reaches out. */
private class DemoPlatform(private val real: PlatformServices, private val mac: DemoMac, macName: String) : PlatformServices {
    override val platformName = real.platformName
    override fun deviceName() = real.deviceName()
    override fun osVersion() = real.osVersion()
    override fun appVersion() = real.appVersion()

    override fun transport(): LinkTransport = mac.transport()

    override val secure: KeyValueStore = MemoryStore().apply {
        // The demo Mac is "paired" only inside the demo; the real pairing is in the real store.
        put(LinkClient.PAIRED_KEY, LinkJson.encodeToString(PairedMac.serializer(), PairedMac(
            desktopID = "demo", name = macName, pin = "demo", hosts = listOf("demo"), port = 1,
            credential = Credential("demo", "demo"),
        )))
    }
    override val prefs: KeyValueStore = MemoryStore()

    override val notifier: Notifier = object : Notifier {
        override fun post(note: PhoneNotification) = Unit
        override fun cancel(id: String) = Unit
    }

    override fun openUrl(url: String) = real.openUrl(url)
    override fun scanCode(onResult: (String?) -> Unit) = onResult(null)
    override fun pickImage(onResult: (PickedFile?) -> Unit) = real.pickImage(onResult)
    override fun pickFile(onResult: (PickedFile?) -> Unit) = real.pickFile(onResult)
    override fun discover(desktopID: String, onFound: (List<String>) -> Unit) = onFound(emptyList())
    override fun keepLinkAlive(active: Boolean, macName: String) = Unit
    // Permissions belong to the real session. The demo neither shows nor asks for them: a
    // prompt the demo raised would be answered for the real app.
    override fun notificationsAllowed() = false
    override fun requestNotifications() = Unit
    override fun openAppSettings() = Unit
}

private class MemoryStore : KeyValueStore {
    private val values = mutableMapOf<String, String>()
    override fun get(key: String) = values[key]
    override fun put(key: String, value: String) { values[key] = value }
    override fun remove(key: String) { values.remove(key) }
}
