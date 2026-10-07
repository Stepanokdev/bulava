package com.stepanok.bulava

import androidx.compose.ui.test.ExperimentalTestApi
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.performClick
import androidx.compose.ui.test.runComposeUiTest
import com.stepanok.bulava.link.Credential
import com.stepanok.bulava.link.Desktop
import com.stepanok.bulava.link.HandshakeReply
import com.stepanok.bulava.link.Home
import com.stepanok.bulava.link.LinkClient
import com.stepanok.bulava.link.LinkJson
import com.stepanok.bulava.link.LinkProtocol
import com.stepanok.bulava.link.PairedMac
import com.stepanok.bulava.link.PhoneApp
import com.stepanok.bulava.link.PhoneApps
import com.stepanok.bulava.platform.KeyValueStore
import com.stepanok.bulava.platform.LinkTransport
import com.stepanok.bulava.platform.Notifier
import com.stepanok.bulava.platform.PhoneNotification
import com.stepanok.bulava.platform.PickedFile
import com.stepanok.bulava.platform.PlatformServices
import com.stepanok.bulava.platform.TransportListener
import com.stepanok.bulava.state.AppController
import com.stepanok.bulava.state.Updates
import com.stepanok.bulava.ui.main.UpdateBanner
import com.stepanok.bulava.ui.main.UpdateTags
import com.stepanok.bulava.ui.theme.BulavaTheme
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.put
import kotlin.test.Test
import kotlin.test.assertEquals

/**
 * The "a newer app is out" banner, rendered and pressed: it offers the build the Mac read from
 * bulava.app, opens where the update is, and once put off stays away for that build.
 */
@OptIn(ExperimentalTestApi::class)
class UpdateBannerUiTest {

    /** A Mac that welcomes the phone and sends a `home` naming a newer iPhone build. */
    private class Phone : PlatformServices {
        val opened = mutableListOf<String>()
        override val platformName = "ios"
        override fun deviceName() = "Test iPhone"
        override fun osVersion() = "iOS 26"
        override fun appVersion() = "1.0"
        override fun appBuild() = 7
        override fun transport(): LinkTransport = object : LinkTransport {
            private var listener: TransportListener? = null
            override fun open(url: String, pin: String, listener: TransportListener) {
                this.listener = listener
                listener.onOpen()
            }
            override fun send(text: String): Boolean {
                val l = listener ?: return false
                val frame = LinkJson.parseToJsonElement(text).jsonObject
                when (frame["type"]?.jsonPrimitive?.contentOrNull) {
                    "hello" -> l.onText(LinkJson.encodeToString(HandshakeReply.serializer(), HandshakeReply(
                        type = "welcome", protocolVersion = 1, desktop = Desktop("mac", "Studio", "1.9"),
                        capabilities = LinkProtocol.USED_CAPABILITIES.toList(),
                    )))
                    "request" -> {
                        l.onText(LinkJson.encodeToString(JsonObject.serializer(), buildJsonObject {
                            put("type", "response"); put("id", frame["id"]!!.jsonPrimitive.content); put("ok", true)
                        }))
                        if (frame["op"]?.jsonPrimitive?.contentOrNull == "home.subscribe") {
                            l.onText(LinkJson.encodeToString(JsonObject.serializer(), buildJsonObject {
                                put("type", "event"); put("event", "home")
                                put("data", LinkJson.encodeToJsonElement(Home.serializer(), Home(
                                    desktop = Desktop("mac", "Studio", "1.9"),
                                    phoneApps = PhoneApps(ios = PhoneApp("1.1", 9, "https://testflight.apple.com/join/test")),
                                )))
                            }))
                        }
                    }
                }
                return true
            }
            override fun close() { listener?.let { listener = null; it.onClosed(null) } }
        }
        override val secure = memory().apply {
            put(LinkClient.PAIRED_KEY, LinkJson.encodeToString(PairedMac.serializer(), PairedMac(
                desktopID = "mac", name = "Studio", pin = "pin", hosts = listOf("mac"), port = 1, credential = Credential("d", "s"),
            )))
        }
        override val prefs = memory()
        override val notifier = object : Notifier {
            override fun post(note: PhoneNotification) = Unit
            override fun cancel(id: String) = Unit
        }
        override fun openUrl(url: String) { opened += url }
        override fun scanCode(onResult: (String?) -> Unit) = Unit
        override fun pickImage(onResult: (PickedFile?) -> Unit) = Unit
        override fun pickFile(onResult: (PickedFile?) -> Unit) = Unit
        override fun discover(desktopID: String, onFound: (List<String>) -> Unit) = onFound(emptyList())
        override fun keepLinkAlive(active: Boolean, macName: String) = Unit
        override fun notificationsAllowed() = true
        override fun requestNotifications() = Unit
        override fun openAppSettings() = Unit

        private fun memory() = object : KeyValueStore {
            val values = mutableMapOf<String, String>()
            override fun get(key: String) = values[key]
            override fun put(key: String, value: String) { values[key] = value }
            override fun remove(key: String) { values.remove(key) }
        }
    }

    @Test
    fun aNewerBuildIsOfferedOpenedAndPutOffForThatBuild() = runComposeUiTest {
        val phone = Phone()
        val controller = AppController(phone, CoroutineScope(Dispatchers.Unconfined + SupervisorJob())) { 0L }
        setContent { BulavaTheme { UpdateBanner(controller) } }
        waitUntil(timeoutMillis = 5_000) { controller.home.value?.phoneApps != null }

        onNodeWithTag(UpdateTags.UPDATE).assertIsDisplayed().performClick()
        assertEquals(listOf("https://testflight.apple.com/join/test"), phone.opened, "the update opens where the Mac said it is")

        onNodeWithTag(UpdateTags.NOT_NOW).performClick()
        waitForIdle()
        onNodeWithTag(UpdateTags.BANNER).assertDoesNotExist()
        assertEquals("9", phone.prefs.get(Updates.DISMISSED), "put off for build 9, and only for it")
    }
}
