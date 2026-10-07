@file:OptIn(kotlinx.cinterop.ExperimentalForeignApi::class)

package com.stepanok.bulava.ui.system

import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.size
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.uikit.LocalUIViewController
import androidx.compose.ui.unit.dp
import androidx.compose.ui.viewinterop.UIKitInteropInteractionMode
import androidx.compose.ui.viewinterop.UIKitInteropProperties
import androidx.compose.ui.viewinterop.UIKitView
import com.stepanok.bulava.ui.theme.Bulava
import kotlinx.cinterop.ExperimentalForeignApi
import kotlinx.cinterop.ObjCAction
import platform.Foundation.NSSelectorFromString
import platform.UIKit.UIAlertAction
import platform.UIKit.UIAlertActionStyleCancel
import platform.UIKit.UIAlertActionStyleDefault
import platform.UIKit.UIAlertActionStyleDestructive
import platform.UIKit.UIAlertController
import platform.UIKit.UIAlertControllerStyleAlert
import platform.UIKit.UIColor
import platform.UIKit.UIControl
import platform.UIKit.UIControlEventValueChanged
import platform.UIKit.UIImpactFeedbackGenerator
import platform.UIKit.UIImpactFeedbackStyle
import platform.UIKit.UINotificationFeedbackGenerator
import platform.UIKit.UINotificationFeedbackType
import platform.UIKit.UISegmentedControl
import platform.UIKit.UISelectionFeedbackGenerator
import platform.UIKit.UISwitch
import platform.UIKit.UITextField
import platform.UIKit.UITextFieldViewMode
import platform.UIKit.UIViewController
import platform.darwin.NSObject

private object UIKitHaptics : Haptics {
    override fun tap() {
        UIImpactFeedbackGenerator(style = UIImpactFeedbackStyle.UIImpactFeedbackStyleLight).impactOccurred()
    }

    override fun select() {
        UISelectionFeedbackGenerator().selectionChanged()
    }

    override fun success() {
        UINotificationFeedbackGenerator().notificationOccurred(UINotificationFeedbackType.UINotificationFeedbackTypeSuccess)
    }

    override fun failure() {
        UINotificationFeedbackGenerator().notificationOccurred(UINotificationFeedbackType.UINotificationFeedbackTypeError)
    }
}

@Composable
actual fun rememberHaptics(): Haptics = UIKitHaptics

actual val dimsWhenPressed: Boolean = true

/**
 * UIKit's target–action for a control drawn inside Compose. UIKit does not keep its targets, so the
 * composable holds this one for as long as the control lives and detaches it when the control goes.
 */
private class ControlTarget(private val changed: (UIControl) -> Unit) : NSObject() {
    @ObjCAction
    fun valueChanged(sender: UIControl) {
        changed(sender)
    }
}

private val valueChanged = NSSelectorFromString("valueChanged:")

private fun Color.toUIColor(): UIColor =
    UIColor.colorWithRed(red.toDouble(), green.toDouble(), blue.toDouble(), alpha.toDouble())

@OptIn(ExperimentalForeignApi::class)
@Composable
actual fun SegmentedControl(options: List<String>, selected: Int, onSelect: (Int) -> Unit, modifier: Modifier) {
    val latest = rememberUpdatedState(onSelect)
    val target = remember {
        ControlTarget { control ->
            UIKitHaptics.select()
            latest.value((control as UISegmentedControl).selectedSegmentIndex.toInt())
        }
    }
    UIKitView(
        factory = {
            UISegmentedControl(items = options).apply {
                selectedSegmentIndex = selected.toLong()
                addTarget(target, valueChanged, UIControlEventValueChanged)
            }
        },
        update = { control ->
            // Labels follow the counts in them; setting them never fires the control's action.
            if (control.numberOfSegments.toInt() == options.size) {
                options.forEachIndexed { index, title ->
                    if (control.titleForSegmentAtIndex(index.toULong()) != title) control.setTitle(title, forSegmentAtIndex = index.toULong())
                }
            } else {
                control.removeAllSegments()
                options.forEachIndexed { index, title -> control.insertSegmentWithTitle(title, atIndex = index.toULong(), animated = false) }
            }
            if (control.selectedSegmentIndex != selected.toLong()) control.selectedSegmentIndex = selected.toLong()
        },
        onRelease = { control -> control.removeTarget(target, valueChanged, UIControlEventValueChanged) },
        // A fixed bar, not inside anything that scrolls: the touch is the control's at once.
        modifier = modifier.height(32.dp),
        properties = UIKitInteropProperties(
            interactionMode = UIKitInteropInteractionMode.NonCooperative,
            isNativeAccessibilityEnabled = true,
        ),
    )
}

@OptIn(ExperimentalForeignApi::class)
@Composable
actual fun SystemSwitch(checked: Boolean, onCheckedChange: (Boolean) -> Unit, modifier: Modifier, enabled: Boolean) {
    val latest = rememberUpdatedState(onCheckedChange)
    // UISwitch gives its own haptic as it flips.
    val target = remember { ControlTarget { control -> latest.value((control as UISwitch).on) } }
    val tint = Bulava.colors.accent
    UIKitView(
        factory = {
            UISwitch().apply {
                on = checked
                addTarget(target, valueChanged, UIControlEventValueChanged)
            }
        },
        update = { control ->
            if (control.on != checked) control.setOn(checked, animated = true)
            control.enabled = enabled
            control.onTintColor = tint.toUIColor()
        },
        onRelease = { control -> control.removeTarget(target, valueChanged, UIControlEventValueChanged) },
        // UISwitch's own size; its artwork is never stretched.
        modifier = modifier.size(51.dp, 31.dp),
        properties = UIKitInteropProperties(isNativeAccessibilityEnabled = true),
    )
}

/** Where an alert goes: on top of whatever this screen already shows, never under it. */
private fun topOf(root: UIViewController): UIViewController {
    var top = root
    while (true) {
        val next = top.presentedViewController ?: break
        if (next.isBeingDismissed()) break
        top = next
    }
    return top
}

@Composable
actual fun SystemAlert(title: String?, message: String?, buttons: List<AlertButton>, onDismiss: () -> Unit) {
    val root = LocalUIViewController.current
    val latest = rememberUpdatedState(buttons)
    val shape = buttons.map { Triple(it.label, it.style, it.enabled) }
    DisposableEffect(title, message, shape) {
        val alert = UIAlertController.alertControllerWithTitle(title, message, UIAlertControllerStyleAlert)
        var answered = false
        buttons.forEachIndexed { index, button ->
            val style = when (button.style) {
                AlertButton.Style.Cancel -> UIAlertActionStyleCancel
                AlertButton.Style.Destructive -> UIAlertActionStyleDestructive
                AlertButton.Style.Default -> UIAlertActionStyleDefault
            }
            val action = UIAlertAction.actionWithTitle(button.label, style) { _ ->
                if (!answered) {
                    answered = true
                    latest.value.getOrNull(index)?.onClick?.invoke()
                }
            }
            action.enabled = button.enabled
            alert.addAction(action)
            if (button.style == AlertButton.Style.Default) alert.preferredAction = action
        }
        topOf(root).presentViewController(alert, animated = true, completion = null)
        // Gone from the screen without an answer — the state that asked for it changed: this alert
        // goes too, and only this one.
        onDispose {
            if (!answered) {
                answered = true
                alert.dismissViewControllerAnimated(true, completion = null)
            }
        }
    }
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
    val root = LocalUIViewController.current
    val confirmNow = rememberUpdatedState(onConfirm)
    val dismissNow = rememberUpdatedState(onDismiss)
    DisposableEffect(title) {
        val alert = UIAlertController.alertControllerWithTitle(title, null, UIAlertControllerStyleAlert)
        var answered = false
        alert.addTextFieldWithConfigurationHandler { field ->
            field?.text = value
            field?.placeholder = placeholder
            field?.clearButtonMode = UITextFieldViewMode.UITextFieldViewModeWhileEditing
        }
        alert.addAction(UIAlertAction.actionWithTitle(cancel, UIAlertActionStyleCancel) { _ ->
            if (!answered) { answered = true; dismissNow.value() }
        })
        val ok = UIAlertAction.actionWithTitle(confirm, UIAlertActionStyleDefault) { _ ->
            if (!answered) {
                answered = true
                val text = (alert.textFields?.firstOrNull() as? UITextField)?.text.orEmpty().trim()
                if (text.isEmpty()) dismissNow.value() else confirmNow.value(text)
            }
        }
        alert.addAction(ok)
        alert.preferredAction = ok
        topOf(root).presentViewController(alert, animated = true, completion = null)
        onDispose {
            if (!answered) {
                answered = true
                alert.dismissViewControllerAnimated(true, completion = null)
            }
        }
    }
}
