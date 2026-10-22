package com.stepanok.bulava

import androidx.compose.foundation.layout.width
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateListOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.semantics.SemanticsProperties
import androidx.compose.ui.test.ExperimentalTestApi
import androidx.compose.ui.test.SemanticsNodeInteraction
import androidx.compose.ui.test.click
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.performTouchInput
import androidx.compose.ui.test.runComposeUiTest
import androidx.compose.ui.test.swipe
import androidx.compose.ui.unit.dp
import com.stepanok.bulava.ui.chat.DEPTH_SCALE_TAG
import com.stepanok.bulava.ui.chat.DepthScale
import com.stepanok.bulava.ui.theme.BulavaTheme
import kotlinx.coroutines.delay
import kotlin.test.Test
import kotlin.test.assertEquals

/**
 * The effort scale against a Mac that confirms each choice a moment later: every change goes out
 * once, and going back to the depth the sheet opened with is a change too (review, 22.10 — a
 * captured index made A → B → A send nothing for the second step and the knob slid back to B).
 */
@OptIn(ExperimentalTestApi::class)
class DepthScaleUiTest {

    private val count = 7

    /** Where stop `i` sits across the scale's width, as `DepthScale` lays its stops out. */
    private fun SemanticsNodeInteraction.stopX(i: Int, width: Float): Float {
        val density = fetchSemanticsNode().layoutInfo.density.density
        val knob = 16f * density // 22dp track minus 6dp
        val inset = 6f * density
        val gap = (width - knob - inset * 2) / (count - 1)
        return inset + knob / 2 + gap * i
    }

    private fun SemanticsNodeInteraction.shown(): Int =
        fetchSemanticsNode().config[SemanticsProperties.ProgressBarRangeInfo].current.toInt()

    @Test
    fun goingBackToTheFirstDepthIsSentByTapAndByDrag() = runComposeUiTest {
        val sent = mutableStateListOf<Int>()
        setContent {
            BulavaTheme(dark = true) {
                // The Mac's copy of the setting: it takes a choice, then echoes it back.
                var onMac by remember { mutableIntStateOf(4) }
                var asked by remember { mutableStateOf<Int?>(null) }
                LaunchedEffect(asked) {
                    val value = asked ?: return@LaunchedEffect
                    delay(150)
                    onMac = value
                }
                DepthScale(count = count, index = onMac, label = "L$onMac", name = "Depth",
                    modifier = Modifier.width(300.dp)) { stop -> sent += stop; asked = stop }
            }
        }
        val scale = onNodeWithTag(DEPTH_SCALE_TAG)
        val width = scale.fetchSemanticsNode().size.width.toFloat()
        val y = scale.fetchSemanticsNode().size.height / 2f

        // A → B by a tap.
        scale.performTouchInput { click(Offset(scale.stopX(1, width), y)) }
        mainClock.advanceTimeBy(400)
        waitForIdle()
        assertEquals(listOf(1), sent.toList())
        assertEquals(1, scale.shown())

        // B → A by a drag, without closing anything in between.
        scale.performTouchInput { swipe(Offset(scale.stopX(1, width), y), Offset(scale.stopX(4, width), y), 300) }
        mainClock.advanceTimeBy(400)
        waitForIdle()
        assertEquals(listOf(1, 4), sent.toList(), "going back to where it started is sent too")
        assertEquals(4, scale.shown())

        // A → B by a tap once more, and back by a tap: each one goes out, once.
        scale.performTouchInput { click(Offset(scale.stopX(1, width), y)) }
        mainClock.advanceTimeBy(400)
        waitForIdle()
        scale.performTouchInput { click(Offset(scale.stopX(4, width), y)) }
        mainClock.advanceTimeBy(400)
        waitForIdle()
        assertEquals(listOf(1, 4, 1, 4), sent.toList())
        assertEquals(4, scale.shown())

        // A tap on the depth already chosen sends nothing.
        scale.performTouchInput { click(Offset(scale.stopX(4, width), y)) }
        mainClock.advanceTimeBy(400)
        waitForIdle()
        assertEquals(listOf(1, 4, 1, 4), sent.toList())
    }
}
