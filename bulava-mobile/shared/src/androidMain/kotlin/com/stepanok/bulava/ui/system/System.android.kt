package com.stepanok.bulava.ui.system

import android.os.Build
import android.view.HapticFeedbackConstants
import android.view.View
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.SegmentedButton
import androidx.compose.material3.SegmentedButtonDefaults
import androidx.compose.material3.SingleChoiceSegmentedButtonRow
import androidx.compose.material3.Switch
import androidx.compose.material3.SwitchDefaults
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalView
import androidx.compose.ui.text.style.TextOverflow
import com.stepanok.bulava.ui.theme.Bulava

private class ViewHaptics(private val view: View) : Haptics {
    // performHapticFeedback honours the person's own haptics setting.
    override fun tap() {
        view.performHapticFeedback(HapticFeedbackConstants.VIRTUAL_KEY)
    }

    override fun select() {
        view.performHapticFeedback(
            if (Build.VERSION.SDK_INT >= 34) HapticFeedbackConstants.SEGMENT_TICK else HapticFeedbackConstants.CLOCK_TICK,
        )
    }

    override fun success() {
        view.performHapticFeedback(
            if (Build.VERSION.SDK_INT >= 30) HapticFeedbackConstants.CONFIRM else HapticFeedbackConstants.CONTEXT_CLICK,
        )
    }

    override fun failure() {
        view.performHapticFeedback(
            if (Build.VERSION.SDK_INT >= 30) HapticFeedbackConstants.REJECT else HapticFeedbackConstants.LONG_PRESS,
        )
    }
}

@Composable
actual fun rememberHaptics(): Haptics {
    val view = LocalView.current
    return remember(view) { ViewHaptics(view) }
}

actual val dimsWhenPressed: Boolean = false

@Composable
actual fun SegmentedControl(options: List<String>, selected: Int, onSelect: (Int) -> Unit, modifier: Modifier) {
    val c = Bulava.colors
    val haptics = rememberHaptics()
    SingleChoiceSegmentedButtonRow(modifier) {
        options.forEachIndexed { index, label ->
            SegmentedButton(
                selected = index == selected,
                onClick = {
                    if (index != selected) {
                        haptics.select()
                        onSelect(index)
                    }
                },
                shape = SegmentedButtonDefaults.itemShape(index, options.size),
                colors = SegmentedButtonDefaults.colors(
                    activeContainerColor = c.accentSoft, activeContentColor = c.accentEmphasis,
                    activeBorderColor = c.lineStrong, inactiveContainerColor = c.surface,
                    inactiveContentColor = c.textSecondary, inactiveBorderColor = c.lineStrong,
                ),
            ) {
                Text(label, maxLines = 1, overflow = TextOverflow.Ellipsis)
            }
        }
    }
}

@Composable
actual fun SystemSwitch(checked: Boolean, onCheckedChange: (Boolean) -> Unit, modifier: Modifier, enabled: Boolean) {
    val c = Bulava.colors
    val haptics = rememberHaptics()
    Switch(
        checked = checked,
        onCheckedChange = { haptics.select(); onCheckedChange(it) },
        modifier = modifier,
        enabled = enabled,
        colors = SwitchDefaults.colors(
            checkedThumbColor = c.onAccent, checkedTrackColor = c.accent,
            uncheckedThumbColor = c.textSecondary, uncheckedTrackColor = c.surfaceMuted, uncheckedBorderColor = c.lineStrong,
        ),
    )
}

@Composable
actual fun SystemAlert(title: String?, message: String?, buttons: List<AlertButton>, onDismiss: () -> Unit) {
    val c = Bulava.colors
    val cancel = buttons.firstOrNull { it.style == AlertButton.Style.Cancel }
    val confirm = buttons.lastOrNull { it.style != AlertButton.Style.Cancel }
    AlertDialog(
        onDismissRequest = onDismiss,
        title = title?.let { { Text(it, style = Bulava.type.headline) } },
        text = message?.let {
            {
                Box(Modifier.verticalScroll(rememberScrollState())) {
                    Text(it, style = Bulava.type.callout, color = c.textSecondary)
                }
            }
        },
        confirmButton = {
            confirm?.let { b ->
                TextButton(enabled = b.enabled, onClick = b.onClick) {
                    Text(b.label, color = if (!b.enabled) c.textFaint else if (b.style == AlertButton.Style.Destructive) c.red else c.accent)
                }
            }
        },
        dismissButton = cancel?.let { b ->
            { TextButton(onClick = b.onClick) { Text(b.label, color = c.textSecondary) } }
        },
        containerColor = c.surface,
    )
}

@Composable
actual fun SystemPrompt(
    title: String,
    value: String,
    placeholder: String,
    confirm: String,
    cancel: String,
    onConfirm: (String) -> Unit,
    onDismiss: () -> Unit,
) {
    val c = Bulava.colors
    var text by remember { mutableStateOf(value) }
    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text(title, style = Bulava.type.headline) },
        text = {
            OutlinedTextField(
                value = text, onValueChange = { text = it }, singleLine = true,
                placeholder = { Text(placeholder, color = c.textFaint) },
            )
        },
        confirmButton = {
            TextButton(enabled = text.isNotBlank(), onClick = { onConfirm(text.trim()) }) {
                Text(confirm, color = if (text.isNotBlank()) c.accent else c.textFaint)
            }
        },
        dismissButton = { TextButton(onClick = onDismiss) { Text(cancel, color = c.textSecondary) } },
        containerColor = c.surface,
    )
}
