package com.stepanok.bulava

import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.material3.Button
import androidx.compose.material3.Text
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.test.ExperimentalTestApi
import androidx.compose.ui.test.hasSetTextAction
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performClick
import androidx.compose.ui.test.performTouchInput
import androidx.compose.ui.test.runComposeUiTest
import androidx.compose.ui.test.swipeDown
import androidx.compose.ui.test.swipeUp
import androidx.compose.ui.unit.dp
import com.stepanok.bulava.demo.DemoMac
import com.stepanok.bulava.demo.DemoSession
import com.stepanok.bulava.platform.KeyValueStore
import com.stepanok.bulava.platform.LinkTransport
import com.stepanok.bulava.platform.Notifier
import com.stepanok.bulava.platform.PhoneNotification
import com.stepanok.bulava.platform.PickedFile
import com.stepanok.bulava.platform.PlatformServices
import com.stepanok.bulava.ui.components.dismissKeyboardOnTapOrDrag
import com.stepanok.bulava.ui.main.MainScreen
import com.stepanok.bulava.ui.main.Selection
import com.stepanok.bulava.ui.theme.BulavaTheme
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.launch
import kotlin.test.Test
import kotlin.test.assertEquals

/**
 * The keyboard on an iPhone goes away on a tap beside the field or when the person drags the
 * content — and only then: a button still works with the keyboard up, and the app scrolling by
 * itself leaves it where it is. Rendered and touched on iOS.
 */
@OptIn(ExperimentalTestApi::class)
class KeyboardDismissUiTest {

    @Test
    fun aTapBesideTheFieldOrADragPutsTheKeyboardAwayAndNothingElseDoes() = runComposeUiTest {
        var pressed = 0
        var scrollBySelf: (() -> Unit)? = null
        setContent {
            BulavaTheme {
                val list = rememberLazyListState()
                val scope = rememberCoroutineScope()
                scrollBySelf = { scope.launch { list.scrollToItem(30) } }
                var text by remember { mutableStateOf("") }
                Column(Modifier.fillMaxSize()) {
                    LazyColumn(Modifier.weight(1f).fillMaxWidth().dismissKeyboardOnTapOrDrag().testTag("thread"), state = list) {
                        item { Button({ pressed++ }, Modifier.testTag("button")) { Text("Yes, do it") } }
                        items(60) { i -> Text("Line $i", Modifier.fillMaxWidth().height(40.dp).testTag("line$i")) }
                    }
                    Box(Modifier.fillMaxWidth().height(60.dp)) {
                        BasicTextField(text, { text = it }, Modifier.fillMaxWidth().testTag("field"))
                    }
                }
            }
        }
        val field = onNodeWithTag("field")

        pause(); field.performClick(); field.expectFocused(true, "step 1")
        onNodeWithTag("line3").performClick()
        field.expectFocused(false, "step 2")

        pause(); field.performClick(); field.expectFocused(true, "step 3")
        onNodeWithTag("thread").performTouchInput { swipeUp() }
        waitForIdle()
        field.expectFocused(false, "step 4")

        pause(); field.performClick(); field.expectFocused(true, "step 5")
        runOnIdle { scrollBySelf!!() }
        waitForIdle()
        field.expectFocused(true, "step 6")

        onNodeWithTag("thread").performTouchInput { swipeDown() }
        waitForIdle()
        pause(); field.performClick(); field.expectFocused(true, "step 7")
        onNodeWithTag("button").performClick()
        assertEquals(1, pressed, "the button still works with the keyboard up")
        field.expectFocused(true, "step 8")
    }

    @Test
    fun aFieldInsideTheAreaStillTakesTheKeyboardWhenTapped() = runComposeUiTest {
        setContent {
            BulavaTheme {
                var text by remember { mutableStateOf("") }
                // The pairing screen and a question's own answer field sit inside the area.
                Column(Modifier.fillMaxSize().dismissKeyboardOnTapOrDrag()) {
                    Text("Paste the pairing link", Modifier.fillMaxWidth().height(60.dp).testTag("title"))
                    BasicTextField(text, { text = it }, Modifier.fillMaxWidth().height(80.dp).testTag("inner"))
                }
            }
        }
        val inner = onNodeWithTag("inner")
        pause(); inner.performClick()
        waitForIdle()
        inner.expectFocused(true, "a tap on the field itself")
        pause(); onNodeWithTag("title").performClick()
        inner.expectFocused(false, "a tap on the words above it")
        pause(); inner.performClick()
        waitForIdle()
        inner.expectFocused(true, "and on the field again")
    }

    private class Phone : PlatformServices {
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
        override fun scanCode(onResult: (String?) -> Unit) = Unit
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

    @Test
    fun inTheRealChatScreenATapOnTheThreadPutsTheComposersKeyboardAway() = runComposeUiTest {
        val demo = DemoSession.instant(Phone(), "en", { 0L }, CoroutineScope(Dispatchers.Unconfined + SupervisorJob()))
        val selection = Selection(demo.controller)
        selection.open(DemoMac.LEDGER, "demo-ship")
        setContent {
            BulavaTheme {
                MainScreen(demo.controller, selection, onOpenSettings = {},
                    onOpenReport = { _, _ -> }, onOpenImage = { _, _ -> }, onOpenContext = { _, _, _ -> })
            }
        }
        waitUntil(timeoutMillis = 5_000) { onAllNodesWithTextSafe("Everything is ready to upload. One thing needs you first.") }
        val composer = onNode(hasSetTextAction() and androidx.compose.ui.test.hasContentDescription("Message Bulava", substring = true, ignoreCase = true))

        pause(); composer.performClick(); composer.expectFocused(true, "step 9")
        onNodeWithText("Everything is ready to upload. One thing needs you first.").performClick()
        composer.expectFocused(false, "step 10")

        pause(); composer.performClick(); composer.expectFocused(true, "step 11")
        onNodeWithText("Everything is ready to upload. One thing needs you first.").performTouchInput { swipeDown() }
        waitForIdle()
        composer.expectFocused(false, "step 12")
        demo.close()
    }

    /** A person's pause between two taps: quicker than this, two taps on a field are a double tap. */
    private fun androidx.compose.ui.test.ComposeUiTest.pause() = mainClock.advanceTimeBy(700)

    private fun androidx.compose.ui.test.SemanticsNodeInteraction.expectFocused(want: Boolean, step: String) {
        val focused = fetchSemanticsNode().config.getOrElseNullable(androidx.compose.ui.semantics.SemanticsProperties.Focused) { null }
        assertEquals(want, focused, "$step: the field should ${if (want) "have" else "not have"} the keyboard")
    }

    private fun androidx.compose.ui.test.ComposeUiTest.onAllNodesWithTextSafe(text: String): Boolean =
        onAllNodes(androidx.compose.ui.test.hasText(text)).fetchSemanticsNodes().isNotEmpty()
}
