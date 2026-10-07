package com.stepanok.bulava.ui.components

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.interaction.collectIsPressedAsState
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.defaultMinSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Icon
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.OutlinedTextFieldDefaults
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.scale
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import com.stepanok.bulava.link.Action
import com.stepanok.bulava.link.ActionInput
import com.stepanok.bulava.link.InputNote
import com.stepanok.bulava.resources.Res
import com.stepanok.bulava.resources.action_cancel
import com.stepanok.bulava.resources.confirm
import com.stepanok.bulava.ui.theme.Brand
import com.stepanok.bulava.ui.theme.Bulava
import com.stepanok.bulava.ui.theme.Icons
import com.stepanok.bulava.ui.theme.Metrics
import com.stepanok.bulava.ui.theme.toneColor
import com.stepanok.bulava.ui.system.AlertButton
import com.stepanok.bulava.ui.system.SystemAlert
import com.stepanok.bulava.ui.system.dimsWhenPressed
import com.stepanok.bulava.ui.system.rememberHaptics
import com.stepanok.bulava.ui.system.systemClickable
import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.layout.RowScope
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.FilledTonalButton
import androidx.compose.material3.LocalContentColor
import androidx.compose.material3.OutlinedButton
import androidx.compose.runtime.rememberCoroutineScope
import kotlinx.coroutines.launch
import org.jetbrains.compose.resources.stringResource

// MARK: Buttons

enum class ButtonKind { Primary, Secondary, Quiet, Destructive }

/**
 * A button drawn the way its platform draws one: Material's filled, outlined, text and tonal buttons
 * with their ripple on Android; on the iPhone UIKit's filled, gray, plain and destructive styles, which
 * dim under the finger. A press is felt as well as seen; while [busy] it shows its progress and takes
 * no second press.
 */
@Composable
fun BulavaButton(
    text: String,
    onClick: () -> Unit,
    modifier: Modifier = Modifier,
    kind: ButtonKind = ButtonKind.Primary,
    icon: ImageVector? = null,
    enabled: Boolean = true,
    busy: Boolean = false,
) {
    val haptics = rememberHaptics()
    val press = {
        if (!busy) {
            haptics.tap()
            onClick()
        }
    }
    if (dimsWhenPressed) {
        UIKitStyleButton(text, press, modifier, kind, icon, enabled, busy)
    } else {
        MaterialStyleButton(text, press, modifier, kind, icon, enabled, busy)
    }
}

@Composable
private fun ButtonLabel(text: String, icon: ImageVector?, busy: Boolean, color: Color) {
    if (busy) {
        CircularProgressIndicator(modifier = Modifier.size(16.dp), strokeWidth = 2.dp, color = color)
        Spacer(Modifier.width(10.dp))
    } else if (icon != null) {
        Icon(icon, contentDescription = null, tint = color, modifier = Modifier.size(18.dp))
        Spacer(Modifier.width(8.dp))
    }
    Text(text, style = Bulava.type.bodyStrong.copy(fontSize = Bulava.type.callout.fontSize),
        color = color, maxLines = 2, overflow = TextOverflow.Ellipsis)
}

@Composable
private fun MaterialStyleButton(
    text: String, onClick: () -> Unit, modifier: Modifier, kind: ButtonKind, icon: ImageVector?,
    enabled: Boolean, busy: Boolean,
) {
    val c = Bulava.colors
    val shape = RoundedCornerShape(Metrics.radiusControl)
    val padding = PaddingValues(horizontal = 18.dp, vertical = 12.dp)
    val sized = modifier.defaultMinSize(minHeight = Metrics.touch)
    val label: @Composable RowScope.() -> Unit = { ButtonLabel(text, icon, busy, LocalContentColor.current) }
    when (kind) {
        ButtonKind.Primary -> Button(onClick, sized, enabled, shape,
            ButtonDefaults.buttonColors(containerColor = c.accent, contentColor = c.onAccent,
                disabledContainerColor = c.surfaceMuted, disabledContentColor = c.textFaint),
            contentPadding = padding, content = label)
        ButtonKind.Secondary -> OutlinedButton(onClick, sized, enabled, shape,
            ButtonDefaults.outlinedButtonColors(contentColor = c.text, disabledContentColor = c.textFaint),
            border = BorderStroke(1.dp, if (enabled) c.lineStrong else c.line), contentPadding = padding, content = label)
        ButtonKind.Quiet -> TextButton(onClick, sized, enabled, shape,
            ButtonDefaults.textButtonColors(contentColor = c.textSecondary, disabledContentColor = c.textFaint),
            contentPadding = padding, content = label)
        ButtonKind.Destructive -> FilledTonalButton(onClick, sized, enabled, shape,
            ButtonDefaults.filledTonalButtonColors(containerColor = c.redSoft, contentColor = c.red,
                disabledContainerColor = c.surfaceMuted, disabledContentColor = c.textFaint),
            contentPadding = padding, content = label)
    }
}

@Composable
private fun UIKitStyleButton(
    text: String, onClick: () -> Unit, modifier: Modifier, kind: ButtonKind, icon: ImageVector?,
    enabled: Boolean, busy: Boolean,
) {
    val c = Bulava.colors
    // UIButton.Configuration's filled, gray, plain and destructive: no outlines, the label in the tint.
    val (fill, content) = when (kind) {
        ButtonKind.Primary -> c.accent to c.onAccent
        ButtonKind.Secondary -> c.surfaceMuted to c.accentEmphasis
        ButtonKind.Quiet -> Color.Transparent to c.accentEmphasis
        ButtonKind.Destructive -> c.redSoft to c.red
    }
    val shape = RoundedCornerShape(Metrics.radiusControl)
    Row(
        modifier = modifier
            .defaultMinSize(minHeight = Metrics.touch)
            .clip(shape)
            .background(if (enabled || kind == ButtonKind.Quiet) fill else c.surfaceMuted, shape)
            .systemClickable(enabled = enabled && !busy, onClick = onClick)
            .padding(horizontal = 18.dp, vertical = 12.dp),
        horizontalArrangement = Arrangement.Center,
        verticalAlignment = Alignment.CenterVertically,
    ) {
        ButtonLabel(text, icon, busy, if (enabled) content else c.textFaint)
    }
}

@Composable
fun IconAction(
    icon: ImageVector,
    description: String,
    onClick: () -> Unit,
    modifier: Modifier = Modifier,
    tint: Color = Bulava.colors.text,
    enabled: Boolean = true,
    size: Dp = 22.dp,
) {
    Box(
        modifier = modifier
            .size(Metrics.touch)
            .clip(CircleShape)
            .systemClickable(enabled = enabled, onClick = onClick)
            .semantics { contentDescription = description },
        contentAlignment = Alignment.Center,
    ) {
        Icon(icon, contentDescription = null, tint = if (enabled) tint else Bulava.colors.textFaint,
            modifier = Modifier.size(size))
    }
}

// MARK: Small pieces

@Composable
fun Hairline(modifier: Modifier = Modifier, color: Color = Bulava.colors.line) {
    Box(modifier.fillMaxWidth().height(Metrics.hairline).background(color))
}

@Composable
fun StatusDot(tone: String, modifier: Modifier = Modifier, size: Dp = 8.dp) {
    Box(modifier.size(size).clip(CircleShape).background(toneColor(tone)))
}

@Composable
fun Eyebrow(text: String, modifier: Modifier = Modifier, color: Color = Bulava.colors.textFaint) {
    Text(text.uppercase(), style = Bulava.type.eyebrow, color = color, modifier = modifier)
}

/** The Bulava mark on its deep-green tile, as on the app icon. */
@Composable
fun BrandTile(size: Dp = 40.dp) {
    Box(
        Modifier.size(size).clip(RoundedCornerShape(size * 0.3f)).background(Brand.field),
        contentAlignment = Alignment.Center,
    ) {
        Icon(Icons.Mark, contentDescription = null, tint = Brand.lime, modifier = Modifier.height(size * 0.6f))
    }
}

@Composable
fun Monogram(initials: String, modifier: Modifier = Modifier, size: Dp = 28.dp) {
    Box(
        modifier.size(size).clip(RoundedCornerShape(8.dp)).background(Bulava.colors.surfaceRaised),
        contentAlignment = Alignment.Center,
    ) {
        Text(initials.take(2), style = Bulava.type.meta.copy(fontWeight = FontWeight.SemiBold),
            color = Bulava.colors.textSecondary)
    }
}

@Composable
fun Card(modifier: Modifier = Modifier, border: Color = Bulava.colors.line, fill: Color = Bulava.colors.surface,
         content: @Composable () -> Unit) {
    val shape = RoundedCornerShape(Metrics.radiusCard)
    Box(modifier.clip(shape).background(fill, shape).border(1.dp, border, shape)) { content() }
}

@Composable
fun BulavaTextField(
    value: String,
    onValueChange: (String) -> Unit,
    placeholder: String,
    modifier: Modifier = Modifier,
    singleLine: Boolean = false,
    minLines: Int = 1,
) {
    val c = Bulava.colors
    OutlinedTextField(
        value = value, onValueChange = onValueChange, modifier = modifier.fillMaxWidth(),
        placeholder = { Text(placeholder, color = c.textFaint, style = Bulava.type.callout) },
        textStyle = Bulava.type.callout.copy(color = c.text), singleLine = singleLine, minLines = minLines,
        shape = RoundedCornerShape(Metrics.radiusControl),
        colors = OutlinedTextFieldDefaults.colors(
            focusedBorderColor = c.accent, unfocusedBorderColor = c.lineStrong,
            focusedContainerColor = c.field, unfocusedContainerColor = c.field, cursorColor = c.accent,
        ),
    )
}

// MARK: Buttons the Mac sent

/**
 * A row of the Mac's buttons. What each does is decided by its `kind`: pressed here and done on the
 * Mac; something to write first; a report to open; or — for "mac" — a sentence, not a button,
 * because the thing it names can only be done at the Mac.
 */
@Composable
fun MacActions(
    actions: List<Action>,
    onInvoke: suspend (Action, String?) -> Boolean,
    onCompose: (Action) -> Unit = {},
    onReport: (Action) -> Unit = {},
    onTakeBack: (Action) -> Unit = {},
    enabled: Boolean = true,
    modifier: Modifier = Modifier,
) {
    var asking by remember { mutableStateOf<Action?>(null) }
    var confirming by remember { mutableStateOf<Action?>(null) }
    // The button pressed and not answered yet: it spins, and nothing in the row takes a second press
    // until the Mac has said how it went.
    var pressing by remember { mutableStateOf<String?>(null) }
    val haptics = rememberHaptics()
    val scope = rememberCoroutineScope()
    fun run(action: Action, input: String?) {
        if (pressing != null) return
        pressing = action.id
        scope.launch {
            try {
                if (onInvoke(action, input)) haptics.success() else haptics.failure()
            } finally {
                pressing = null
            }
        }
    }
    FlowRowCompat(modifier = modifier, spacing = 8.dp) {
        for (action in actions) {
            // A kind this build does not know how to perform is shown as what it is — words — not
            // as a button that would do nothing.
            if (action.kind !in KNOWN_KINDS) {
                OnMacNote(action.label)
                continue
            }
            if (action.kind == "mac") {
                OnMacNote(action.label)
                continue
            }
            val kind = when (action.style) {
                "primary" -> ButtonKind.Primary
                "destructive" -> ButtonKind.Destructive
                else -> ButtonKind.Secondary
            }
            BulavaButton(
                text = action.label, kind = kind,
                enabled = enabled && action.disabledReason == null && (pressing == null || pressing == action.id),
                busy = pressing == action.id,
                onClick = {
                    when {
                        action.kind == "compose" -> onCompose(action)
                        action.kind == "report" -> onReport(action)
                        action.kind == "takeBack" -> onTakeBack(action)
                        action.input != null -> asking = action
                        action.confirm != null -> confirming = action
                        else -> run(action, null)
                    }
                },
            )
        }
    }
    asking?.let { action ->
        InputDialog(action, onDismiss = { asking = null }) { text -> asking = null; run(action, text) }
    }
    confirming?.let { action ->
        SystemAlert(
            title = action.label, message = action.confirm,
            buttons = listOf(
                AlertButton(stringResource(Res.string.action_cancel), AlertButton.Style.Cancel) { confirming = null },
                AlertButton(stringResource(Res.string.confirm),
                    if (action.style == "destructive") AlertButton.Style.Destructive else AlertButton.Style.Default) {
                    confirming = null
                    run(action, null)
                },
            ),
            onDismiss = { confirming = null },
        )
    }
}

private val KNOWN_KINDS = setOf("invoke", "compose", "report", "takeBack", "mac")

@Composable
fun OnMacNote(text: String) {
    Row(
        Modifier.defaultMinSize(minHeight = 40.dp).clip(RoundedCornerShape(Metrics.radiusControl))
            .background(Bulava.colors.surfaceMuted).padding(horizontal = 12.dp, vertical = 9.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Icon(Icons.Laptop, contentDescription = null, tint = Bulava.colors.textSecondary, modifier = Modifier.size(17.dp))
        Spacer(Modifier.width(8.dp))
        Text(text, style = Bulava.type.caption, color = Bulava.colors.textSecondary)
    }
}

@Composable
private fun InputDialog(action: Action, onDismiss: () -> Unit, onDone: (String) -> Unit) {
    val input = action.input
    if (input != null && input.isSheet) {
        InputSheet(action, input, onDismiss, onDone)
        return
    }
    var text by remember { mutableStateOf(action.input?.value ?: "") }
    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text(action.label, style = Bulava.type.headline) },
        text = { BulavaTextField(text, { text = it }, action.input?.placeholder ?: "", minLines = 2) },
        confirmButton = {
            TextButton(enabled = text.isNotBlank() || action.input?.required == false, onClick = { onDone(text.trim()) }) {
                Text(stringResource(Res.string.confirm), color = Bulava.colors.accent)
            }
        },
        dismissButton = { TextButton(onClick = onDismiss) { Text(stringResource(Res.string.action_cancel), color = Bulava.colors.textSecondary) } },
        containerColor = Bulava.colors.surface,
    )
}

/**
 * One of the Mac's own sheets, drawn on the phone with what it shows there: «Commit as me…» names
 * the author before anything is pressed, says which branch, lists every file the commit takes, and
 * keeps its button off when git does not know who is committing.
 */
@Composable
private fun InputSheet(action: Action, input: ActionInput, onDismiss: () -> Unit, onDone: (String) -> Unit) {
    val c = Bulava.colors
    var text by remember(action.id) { mutableStateOf(input.value ?: "") }
    val canSubmit = input.blocked == null && (text.isNotBlank() || !input.required)
    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text(input.title ?: action.label, style = Bulava.type.headline) },
        text = {
            Column(Modifier.verticalScroll(rememberScrollState()), verticalArrangement = Arrangement.spacedBy(10.dp)) {
                for (note in input.above.orEmpty()) SheetNote(note)
                input.blocked?.let { SheetNote(InputNote(it, tone = "problem")) }
                BulavaTextField(text, { text = it }, input.placeholder, minLines = 2)
                for (note in input.below.orEmpty()) SheetNote(note)
            }
        },
        confirmButton = {
            TextButton(enabled = canSubmit, onClick = { onDone(text.trim()) }) {
                Text(input.submit ?: stringResource(Res.string.confirm), color = if (canSubmit) c.accent else c.textFaint)
            }
        },
        dismissButton = { TextButton(onClick = onDismiss) { Text(stringResource(Res.string.action_cancel), color = c.textSecondary) } },
        containerColor = c.surface,
    )
}

@Composable
private fun SheetNote(note: InputNote) {
    val c = Bulava.colors
    val color = when (note.tone) {
        "faint" -> c.textFaint
        "attention" -> c.orange
        "problem" -> c.red
        else -> c.textSecondary
    }
    if (note.mono == true) {
        Box(
            Modifier.fillMaxWidth().heightIn(max = 180.dp).clip(RoundedCornerShape(Metrics.radiusControl))
                .background(c.surfaceMuted).verticalScroll(rememberScrollState()).padding(horizontal = 10.dp, vertical = 8.dp),
        ) {
            Text(note.text, style = Bulava.type.mono.copy(fontSize = Bulava.type.meta.fontSize), color = c.textSecondary)
        }
    } else {
        Text(note.text, style = if (note.tone == "faint") Bulava.type.meta else Bulava.type.caption, color = color)
    }
}

/** A wrapping row for buttons. */
@OptIn(androidx.compose.foundation.layout.ExperimentalLayoutApi::class)
@Composable
fun FlowRowCompat(modifier: Modifier = Modifier, spacing: Dp = 8.dp, content: @Composable () -> Unit) {
    androidx.compose.foundation.layout.FlowRow(
        modifier = modifier,
        horizontalArrangement = Arrangement.spacedBy(spacing),
        verticalArrangement = Arrangement.spacedBy(spacing),
    ) { content() }
}

@Composable
fun SectionHeader(text: String, modifier: Modifier = Modifier) {
    Eyebrow(text, modifier.padding(PaddingValues(start = Metrics.gutter, end = Metrics.gutter, top = 20.dp, bottom = 8.dp)))
}

@Composable
fun ListRow(
    title: String,
    modifier: Modifier = Modifier,
    subtitle: String? = null,
    leading: (@Composable () -> Unit)? = null,
    trailing: (@Composable () -> Unit)? = null,
    selected: Boolean = false,
    onClick: (() -> Unit)? = null,
) {
    val c = Bulava.colors
    Row(
        modifier = modifier
            .fillMaxWidth()
            .defaultMinSize(minHeight = Metrics.touch)
            .clip(RoundedCornerShape(Metrics.radiusControl))
            .background(if (selected) c.accentSoft else Color.Transparent)
            .then(if (onClick != null) Modifier.systemClickable(pressedFill = c.surfaceMuted, onClick = onClick) else Modifier)
            .padding(horizontal = 12.dp, vertical = 10.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        if (leading != null) {
            leading()
            Spacer(Modifier.width(12.dp))
        }
        Column(Modifier.weight(1f)) {
            Text(title, style = Bulava.type.callout, color = if (selected) c.accentEmphasis else c.text,
                maxLines = 1, overflow = TextOverflow.Ellipsis)
            if (subtitle != null) {
                Text(subtitle, style = Bulava.type.meta, color = c.textFaint, maxLines = 2, overflow = TextOverflow.Ellipsis)
            }
        }
        if (trailing != null) {
            Spacer(Modifier.width(8.dp))
            trailing()
        }
    }
}
