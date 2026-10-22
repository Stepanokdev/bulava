package com.stepanok.bulava

import androidx.compose.ui.test.ExperimentalTestApi
import androidx.compose.ui.test.hasText
import androidx.compose.ui.test.performClick
import androidx.compose.ui.test.runComposeUiTest
import androidx.compose.ui.test.waitUntilDoesNotExist
import androidx.compose.ui.test.waitUntilExactlyOneExists
import com.stepanok.bulava.link.LinkState
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
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertIs

/**
 * The demo's code, `bulava://demo`, on the whole app as the phone starts it: it opens the demo
 * from the first screen — also when it arrived before that screen did, as a code read by the
 * Camera arrives on a cold start — and once the demo is left, it is not opened again by itself.
 */
@OptIn(ExperimentalTestApi::class)
class DemoLinkUiTest {

    /** A phone with no Mac; its camera "reads" [scanned] when the scanner is opened. */
    private class Unpaired(val scanned: String? = null) : PlatformServices {
        var scans = 0
        override val platformName = "ios"
        override fun deviceName() = "Test iPhone"
        override fun osVersion() = "iOS 26"
        override fun appVersion() = "1.0"
        override fun transport(): LinkTransport = error("no socket in this test")
        override val secure = memory()
        override val prefs = memory()
        override val notifier = object : Notifier {
            override fun post(note: PhoneNotification) = Unit
            override fun cancel(id: String) = Unit
        }
        override fun openUrl(url: String) = Unit
        override fun scanCode(onResult: (String?) -> Unit) { scans++; onResult(scanned) }
        override fun pickImage(onResult: (PickedFile?) -> Unit) = Unit
        override fun pickFile(onResult: (PickedFile?) -> Unit) = Unit
        override fun discover(desktopID: String, onFound: (List<String>) -> Unit) = Unit
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

    private fun controller(phone: Unpaired = Unpaired()) =
        AppController(phone, CoroutineScope(Dispatchers.Unconfined + SupervisorJob())) { 0L }

    private val demoBar = hasText("Sample projects on this phone", substring = true)
    private val firstScreen = hasText("Try it without a Mac")

    @Test
    fun theCodeOpensTheDemoFromTheFirstScreen() = runComposeUiTest {
        val c = controller()
        setContent { BulavaApp(c) }
        waitUntilExactlyOneExists(firstScreen)
        c.handleLink(AppController.DEMO_LINK)
        waitUntilExactlyOneExists(demoBar, timeoutMillis = 5_000)
    }

    @Test
    fun aCodeThatCameBeforeTheScreenStillOpensTheDemoAndOnlyOnce() = runComposeUiTest {
        val c = controller()
        c.handleLink(AppController.DEMO_LINK)
        setContent { BulavaApp(c) }
        waitUntilExactlyOneExists(demoBar, timeoutMillis = 5_000)
        onNode(hasText("Exit")).performClick()
        waitUntilExactlyOneExists(firstScreen, timeoutMillis = 5_000)
        waitForIdle()
        waitUntilDoesNotExist(demoBar, timeoutMillis = 1_000)
    }

    @Test
    fun scanTheCodeOnTheDemosCodeOpensTheDemo() = runComposeUiTest {
        val phone = Unpaired(scanned = AppController.DEMO_LINK)
        val c = controller(phone)
        setContent { BulavaApp(c) }
        waitUntilExactlyOneExists(firstScreen)
        onNode(hasText("Scan the code")).performClick()
        waitUntilExactlyOneExists(demoBar, timeoutMillis = 5_000)
        assertEquals(1, phone.scans, "the scanner was opened once")
        assertIs<LinkState.Unpaired>(c.link.state.value, "and nothing was paired")
    }

    @Test
    fun scanTheCodeOnAnyOtherCodeDoesNotOpenTheDemo() = runComposeUiTest {
        val c = controller(Unpaired(scanned = "bulava://demo/other"))
        setContent { BulavaApp(c) }
        waitUntilExactlyOneExists(firstScreen)
        onNode(hasText("Scan the code")).performClick()
        waitForIdle()
        waitUntilDoesNotExist(demoBar, timeoutMillis = 1_000)
    }
}
