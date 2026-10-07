package com.stepanok.bulava.ui.system

import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.tween
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.interaction.collectIsPressedAsState
import androidx.compose.material3.ripple
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.remember
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.semantics.Role

/*
 * What the phone's own platform draws and does, where a look of Bulava's own would only imitate it:
 * on the iPhone UIKit's segmented control, switch and alerts, its haptics, and a pressed control that
 * dims; on Android Material's controls and dialogs, the view's haptics, and the ripple.
 */

/** The platform's haptics, for what the person did and for how it ended. */
interface Haptics {
    /** A button pressed — the press itself, before anything is known about its result. */
    fun tap()

    /** A choice changed: an option, a segment, a switch. */
    fun select()

    /** What was asked for is done: the Mac took the answer, the button's work finished. */
    fun success()

    /** It did not go: refused, failed, or no connection. */
    fun failure()
}

@Composable
expect fun rememberHaptics(): Haptics

/** True on the iPhone, where a pressed control dims; Android draws a ripple instead. */
expect val dimsWhenPressed: Boolean

/**
 * A row of mutually exclusive segments: `UISegmentedControl` on the iPhone, Material's segmented
 * buttons on Android. [onSelect] is called only when the person picks another one.
 */
@Composable
expect fun SegmentedControl(options: List<String>, selected: Int, onSelect: (Int) -> Unit, modifier: Modifier = Modifier)

/** `UISwitch` on the iPhone, Material's switch on Android. */
@Composable
expect fun SystemSwitch(checked: Boolean, onCheckedChange: (Boolean) -> Unit, modifier: Modifier = Modifier, enabled: Boolean = true)

/** One button of a [SystemAlert]. Each runs at most once: the alert is gone after it. */
class AlertButton(
    val label: String,
    val style: Style = Style.Default,
    val enabled: Boolean = true,
    val onClick: () -> Unit,
) {
    enum class Style { Default, Cancel, Destructive }
}

/**
 * The platform's alert, shown while it is in composition: `UIAlertController` on the iPhone (a long
 * [message] scrolls inside it), Material's dialog on Android. [onDismiss] is for leaving it without a
 * button — Android's back gesture or a tap outside; the iPhone's alert has no such way out.
 */
@Composable
expect fun SystemAlert(title: String?, message: String?, buttons: List<AlertButton>, onDismiss: () -> Unit)

/** The platform's alert with one line to type in: a rename. */
@Composable
expect fun SystemPrompt(
    title: String,
    value: String,
    placeholder: String,
    confirm: String,
    cancel: String,
    onConfirm: (String) -> Unit,
    onDismiss: () -> Unit,
)

/**
 * A click with the platform's pressed state: on the iPhone the control dims at once and comes back
 * as the finger lifts — or, for a row ([pressedFill]), the row is highlighted, as a table cell is;
 * on Android, the ripple.
 */
@Composable
fun Modifier.systemClickable(
    enabled: Boolean = true,
    role: Role = Role.Button,
    pressedFill: Color? = null,
    onClickLabel: String? = null,
    onClick: () -> Unit,
): Modifier {
    val interaction = remember { MutableInteractionSource() }
    if (!dimsWhenPressed) {
        return clickable(interactionSource = interaction, indication = ripple(), enabled = enabled,
            onClickLabel = onClickLabel, role = role, onClick = onClick)
    }
    val pressed by interaction.collectIsPressedAsState()
    val down = pressed && enabled
    val alpha by animateFloatAsState(if (down && pressedFill == null) 0.45f else 1f, tween(if (down) 0 else 220))
    val shown = if (pressedFill != null) background(if (down) pressedFill else Color.Transparent) else alpha(alpha)
    return shown.clickable(interactionSource = interaction, indication = null, enabled = enabled,
        onClickLabel = onClickLabel, role = role, onClick = onClick)
}
