package com.stepanok.bulava

import androidx.compose.ui.test.ExperimentalTestApi
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.performClick
import androidx.compose.ui.test.performScrollTo
import androidx.compose.ui.test.runComposeUiTest
import com.stepanok.bulava.demo.DemoSession
import com.stepanok.bulava.platform.KeyValueStore
import com.stepanok.bulava.platform.LinkTransport
import com.stepanok.bulava.platform.Notifier
import com.stepanok.bulava.platform.PhoneNotification
import com.stepanok.bulava.platform.PickedFile
import com.stepanok.bulava.platform.PlatformServices
import com.stepanok.bulava.state.AppController
import com.stepanok.bulava.ui.settings.SettingsScreen
import com.stepanok.bulava.ui.settings.SettingsTags
import com.stepanok.bulava.ui.theme.BulavaTheme
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertTrue

/**
 * The notifications control in Settings, rendered and pressed, on a phone whose notifications are
 * turned off. In the real session it asks the system; in the demo it is not there to press, and
 * nothing the demo does asks the real phone for a permission.
 */
@OptIn(ExperimentalTestApi::class)
class DemoSettingsUiTest {

    private class Denied : PlatformServices {
        val asked = mutableListOf<String>()
        override val platformName = "ios"
        override fun deviceName() = "Test iPhone"
        override fun osVersion() = "iOS 26"
        override fun appVersion() = "1.0"
        override fun transport(): LinkTransport = error("no socket in this test")
        override val secure = memory()
        override val prefs = memory()
        override val notifier = object : Notifier {
            override fun post(note: PhoneNotification) { asked += "notify" }
            override fun cancel(id: String) = Unit
        }
        override fun openUrl(url: String) = Unit
        override fun scanCode(onResult: (String?) -> Unit) = Unit
        override fun pickImage(onResult: (PickedFile?) -> Unit) = Unit
        override fun pickFile(onResult: (PickedFile?) -> Unit) = Unit
        override fun discover(desktopID: String, onFound: (List<String>) -> Unit) = Unit
        override fun keepLinkAlive(active: Boolean, macName: String) { asked += "keepAlive" }
        override fun notificationsAllowed() = false
        override fun requestNotifications() { asked += "requestNotifications" }
        override fun openAppSettings() { asked += "openAppSettings" }

        private fun memory() = object : KeyValueStore {
            val values = mutableMapOf<String, String>()
            override fun get(key: String) = values[key]
            override fun put(key: String, value: String) { values[key] = value }
            override fun remove(key: String) { values.remove(key) }
        }
    }

    private fun scope() = CoroutineScope(Dispatchers.Unconfined + SupervisorJob())

    @Test
    fun inTheRealSessionTheControlAsksTheSystem() = runComposeUiTest {
        val phone = Denied()
        val controller = AppController(phone, scope()) { 0L }
        setContent { BulavaTheme { SettingsScreen(controller, onBack = {}, onOpenSkills = {}) } }

        assertTrue("requestNotifications" !in phone.asked)
        onNodeWithTag(SettingsTags.NOTIFICATIONS_TURN_ON).performScrollTo().assertIsDisplayed().performClick()
        assertEquals(1, phone.asked.count { it == "requestNotifications" }, "pressing the control asks the system once")
    }

    @Test
    fun inTheDemoThereIsNothingToPressAndTheRealPhoneIsNeverAsked() = runComposeUiTest {
        val phone = Denied()
        val demo = DemoSession.instant(phone, "en", { 0L }, scope())
        setContent { BulavaTheme { SettingsScreen(demo.controller, onBack = {}, onOpenSkills = {}, onExitDemo = {}) } }

        onNodeWithTag(SettingsTags.NOTIFICATIONS_TURN_ON).assertDoesNotExist()
        onNodeWithTag(SettingsTags.NOTIFICATIONS_DEMO).performScrollTo().assertIsDisplayed()

        // Even asked directly, the demo's phone keeps the question to itself.
        demo.controller.platform.requestNotifications()
        demo.controller.platform.openAppSettings()
        assertTrue(!demo.controller.platform.notificationsAllowed())
        assertEquals(emptyList(), phone.asked, "the demo asked the real phone for nothing")
        demo.close()
    }
}
