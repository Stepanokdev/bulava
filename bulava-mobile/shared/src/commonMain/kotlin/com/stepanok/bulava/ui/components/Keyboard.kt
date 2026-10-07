package com.stepanok.bulava.ui.components

import androidx.compose.foundation.gestures.awaitEachGesture
import androidx.compose.foundation.gestures.awaitFirstDown
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.input.pointer.PointerEventPass
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.platform.LocalFocusManager
import kotlin.math.abs

/**
 * Puts the keyboard away the way any iPhone app does: a finger dragging this content up or down,
 * or a tap on it that nothing under the finger took — not a button, not a field. A Compose screen
 * on iOS gets neither by itself, and a keyboard that came up stayed until the screen changed.
 *
 * It only watches. Every touch still reaches what is under it, and the app scrolling by itself —
 * following a new message, jumping to a match — is no touch at all, so it leaves the keyboard be.
 * A drag counts whether or not the content could scroll: a short chat is dragged the same way.
 */
@Composable
fun Modifier.dismissKeyboardOnTapOrDrag(): Modifier {
    val focus = LocalFocusManager.current
    return pointerInput(focus) {
        awaitEachGesture {
            // After the content has had its turn, so what a button, a field or a list did with the
            // touch is already decided.
            val down = awaitFirstDown(requireUnconsumed = false, pass = PointerEventPass.Final)
            var dragged = false
            while (true) {
                val change = awaitPointerEvent(PointerEventPass.Final).changes.firstOrNull { it.id == down.id } ?: break
                val moved = change.position - down.position
                if (!dragged && abs(moved.y) > viewConfiguration.touchSlop && abs(moved.y) > abs(moved.x)) {
                    dragged = true
                    focus.clearFocus()
                }
                if (!change.pressed) {
                    if (!dragged && !change.isConsumed && moved.getDistance() <= viewConfiguration.touchSlop) focus.clearFocus()
                    break
                }
            }
        }
    }
}
