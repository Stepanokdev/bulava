package com.stepanok.bulava.ui.chat

import com.stepanok.bulava.ui.system.systemClickable
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.gestures.detectHorizontalDragGestures
import androidx.compose.foundation.gestures.detectTapGestures
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Rect
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Path
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.graphics.drawscope.rotate
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.progressBarRangeInfo
import androidx.compose.ui.semantics.ProgressBarRangeInfo
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.setProgress
import androidx.compose.ui.semantics.stateDescription
import androidx.compose.ui.text.Placeholder
import androidx.compose.ui.text.PlaceholderVerticalAlign
import androidx.compose.ui.text.SpanStyle
import androidx.compose.ui.text.buildAnnotatedString
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.foundation.text.InlineTextContent
import androidx.compose.foundation.text.appendInlineContent
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.em
import com.stepanok.bulava.link.OptionGroup
import com.stepanok.bulava.link.RunPart
import com.stepanok.bulava.resources.Res
import com.stepanok.bulava.resources.options_depth
import com.stepanok.bulava.state.AppController
import com.stepanok.bulava.ui.components.Eyebrow
import com.stepanok.bulava.ui.components.Hairline
import com.stepanok.bulava.ui.theme.Bulava
import com.stepanok.bulava.ui.theme.Icons
import com.stepanok.bulava.ui.theme.Metrics
import org.jetbrains.compose.resources.stringResource
import kotlin.math.PI
import kotlin.math.cos
import kotlin.math.max
import kotlin.math.min
import kotlin.math.roundToInt
import kotlin.math.sin

/*
 * The Mac composer's run control (`RunControl.swift`), on the phone.
 *
 * The chip under the field says what the Mac's pill says — each engine's mark, its model and its
 * depth, Claude first because it writes and Codex second because it reviews. Behind it, a page per
 * engine: the model as the system's own kind of menu, and depth as a scale with a stop for each
 * level, the way the Mac's panel has it. There is no mode switch, because the Mac has none: Claude
 * alone or Codex alone is not something it offers.
 */

/** What the next message runs on, in the Mac pill's words. */
@Composable
internal fun RunChip(parts: List<RunPart>, modifier: Modifier, onClick: () -> Unit) {
    val c = Bulava.colors
    val text = buildAnnotatedString {
        parts.forEachIndexed { i, part ->
            if (i > 0) {
                // Claude works, Codex reviews — the arrow is the order, not decoration.
                withStyle(c.textFaint) { append("  →  ") }
            }
            appendInlineContent(part.engine, part.name)
            append(" ")
            withStyle(c.textSecondary) { append(part.model) }
            part.depth?.takeIf { it.isNotBlank() }?.let { depth ->
                append(" ")
                withStyle(c.textFaint) { append(depth) }
            }
        }
    }
    val glyphs = parts.map { it.engine }.distinct().associateWith { engine ->
        InlineTextContent(Placeholder(1.05.em, 1.05.em, PlaceholderVerticalAlign.TextCenter)) {
            EngineGlyph(engine, Modifier.size(12.dp), c.textSecondary)
        }
    }
    val spoken = parts.joinToString(", ") { listOfNotNull(it.name, it.model, it.depth).joinToString(" ") }
    Row(
        modifier.padding(horizontal = 4.dp).heightIn(min = 40.dp).clip(RoundedCornerShape(Metrics.radiusChip))
            .systemClickable(role = Role.Button, onClick = onClick).padding(horizontal = 8.dp)
            .semantics { contentDescription = spoken },
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Text(text, style = Bulava.type.meta, color = c.textSecondary, maxLines = 1, overflow = TextOverflow.Ellipsis,
            inlineContent = glyphs)
    }
}

private inline fun androidx.compose.ui.text.AnnotatedString.Builder.withStyle(color: Color, block: () -> Unit) {
    pushStyle(SpanStyle(color = color))
    block()
    pop()
}

/**
 * The panel behind the chip: one page per engine, in the order the groups say they work. Groups
 * without an engine come from a Mac older than this, and are drawn as a plain list elsewhere.
 */
@Composable
internal fun RunPanel(controller: AppController, groups: List<OptionGroup>, chatID: String? = null) {
    val engines = groups.mapNotNull { it.engine }.distinct()
    engines.forEachIndexed { i, engine ->
        if (i > 0) Hairline(Modifier.padding(vertical = 4.dp))
        val model = groups.firstOrNull { it.engine == engine && it.kind == "model" }
        val depth = groups.firstOrNull { it.engine == engine && it.kind == "depth" }
        EnginePage(controller, engine, model, depth, chatID)
    }
}

@Composable
private fun EnginePage(controller: AppController, engine: String, model: OptionGroup?, depth: OptionGroup?, chatID: String?) {
    val c = Bulava.colors
    Column(Modifier.fillMaxWidth().padding(horizontal = Metrics.gutter, vertical = 14.dp)) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            EngineGlyph(engine, Modifier.size(15.dp), c.text)
            Spacer(Modifier.width(8.dp))
            Text(model?.title ?: engine.replaceFirstChar { it.uppercase() }, style = Bulava.type.bodyStrong, color = c.text,
                modifier = Modifier.weight(1f))
            if (model != null) ModelMenu(controller, model, chatID)
        }
        Spacer(Modifier.height(12.dp))
        if (depth != null && depth.options.size > 1) {
            val index = depth.options.indexOfFirst { it.id == depth.selected }.coerceAtLeast(0)
            val label = depth.options.getOrNull(index)?.label.orEmpty()
            Row(verticalAlignment = Alignment.CenterVertically) {
                Icon(Icons.Bolt, null, tint = c.textFaint, modifier = Modifier.size(14.dp))
                Spacer(Modifier.width(10.dp))
                DepthScale(
                    count = depth.options.size, index = index, label = label,
                    name = stringResource(Res.string.options_depth),
                    modifier = Modifier.weight(1f),
                ) { stop -> depth.options.getOrNull(stop)?.let { controller.setOption(depth.id, it.id, chatID) } }
                Spacer(Modifier.width(12.dp))
                // Wide enough for "Automatic · Very high": a label that resizes itself would move the
                // scale under the finger every time the depth changed.
                Text(label, style = Bulava.type.meta, color = c.textSecondary, maxLines = 2,
                    modifier = Modifier.width(128.dp), textAlign = androidx.compose.ui.text.style.TextAlign.End)
            }
        }
    }
}

/** The model, as a menu with nothing in it but the names, under the Mac menu's own headings. */
@Composable
private fun ModelMenu(controller: AppController, group: OptionGroup, chatID: String?) {
    val c = Bulava.colors
    var open by remember { mutableStateOf(false) }
    val chosen = group.options.firstOrNull { it.id == group.selected }
    Box {
        Row(
            Modifier.heightIn(min = 40.dp).clip(RoundedCornerShape(Metrics.radiusChip)).background(c.surfaceMuted)
                .systemClickable(role = Role.Button) { open = true }.padding(start = 12.dp, end = 8.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Text(chosen?.label ?: group.selected.orEmpty(), style = Bulava.type.callout, color = c.text, maxLines = 1,
                overflow = TextOverflow.Ellipsis, modifier = Modifier.widthIn(max = 190.dp))
            Spacer(Modifier.width(4.dp))
            Icon(Icons.ChevronDown, null, tint = c.textFaint, modifier = Modifier.size(16.dp))
        }
        DropdownMenu(open, { open = false }, containerColor = c.surface) {
            var section: String? = null
            for (option in group.options) {
                if (option.section != null && option.section != section) {
                    section = option.section
                    Eyebrow(option.section, Modifier.padding(start = 16.dp, end = 16.dp, top = 10.dp, bottom = 4.dp))
                }
                val selected = option.id == group.selected
                DropdownMenuItem(
                    text = {
                        Text(option.label, style = Bulava.type.callout.copy(fontWeight = if (selected) FontWeight.Medium else FontWeight.Normal),
                            color = if (selected) c.accentEmphasis else c.text)
                    },
                    trailingIcon = if (selected) ({ Icon(Icons.Check, null, tint = c.accent, modifier = Modifier.size(18.dp)) }) else null,
                    onClick = {
                        open = false
                        if (!selected) controller.setOption(group.id, option.id, chatID)
                    },
                )
            }
        }
    }
}

/**
 * A scale with a stop for each depth the engine takes and nothing in between — the Mac's
 * `EffortSlider`. Every stop is drawn, so the shape of the choice is visible before it is touched.
 */
@Composable
internal fun DepthScale(count: Int, index: Int, label: String, name: String, modifier: Modifier, onChange: (Int) -> Unit) {
    val c = Bulava.colors
    val latest by rememberUpdatedState(onChange)
    val current by rememberUpdatedState(index)
    val knobColor = if (c.isDark) Color(0xFFF2F2F3) else Color.White
    BoxWithConstraints(modifier.height(Metrics.touch)) {
        val height = 22.dp
        Canvas(
            Modifier.fillMaxWidth().height(Metrics.touch)
                .pointerInput(count) {
                    fun stopAt(x: Float): Int {
                        val knob = height.toPx() - 6.dp.toPx()
                        val inset = 6.dp.toPx()
                        val usable = max(size.width - knob - inset * 2, 1f)
                        val gap = if (count > 1) usable / (count - 1) else 0f
                        if (gap <= 0f) return 0
                        return ((x - inset - knob / 2) / gap).roundToInt().coerceIn(0, count - 1)
                    }
                    detectTapGestures { offset -> stopAt(offset.x).let { if (it != current) latest(it) } }
                }
                .pointerInput(count) {
                    fun stopAt(x: Float): Int {
                        val knob = height.toPx() - 6.dp.toPx()
                        val inset = 6.dp.toPx()
                        val usable = max(size.width - knob - inset * 2, 1f)
                        val gap = if (count > 1) usable / (count - 1) else 0f
                        if (gap <= 0f) return 0
                        return ((x - inset - knob / 2) / gap).roundToInt().coerceIn(0, count - 1)
                    }
                    detectHorizontalDragGestures { change, _ ->
                        val stop = stopAt(change.position.x)
                        if (stop != current) latest(stop)
                    }
                }
                .semantics {
                    contentDescription = name
                    stateDescription = label
                    progressBarRangeInfo = ProgressBarRangeInfo(index.toFloat(), 0f..(count - 1).coerceAtLeast(1).toFloat(), steps = (count - 2).coerceAtLeast(0))
                    setProgress { target ->
                        val stop = target.roundToInt().coerceIn(0, count - 1)
                        if (stop != current) latest(stop)
                        true
                    }
                },
        ) {
            val h = height.toPx()
            val top = (size.height - h) / 2
            val knob = h - 6.dp.toPx()
            val inset = 6.dp.toPx()
            val usable = max(size.width - knob - inset * 2, 1f)
            val gap = if (count > 1) usable / (count - 1) else 0f
            val centre = inset + knob / 2 + gap * index.coerceIn(0, max(count - 1, 0))
            val radius = androidx.compose.ui.geometry.CornerRadius(h / 2, h / 2)
            drawRoundRect(c.surfaceRaised, topLeft = Offset(0f, top), size = Size(size.width, h), cornerRadius = radius)
            drawRoundRect(c.accent, topLeft = Offset(0f, top), size = Size(min(centre + knob / 2 + 3.dp.toPx(), size.width), h), cornerRadius = radius)
            for (stop in 0 until count) {
                val x = inset + knob / 2 + gap * stop
                drawCircle(
                    if (stop <= index) c.onAccent.copy(alpha = 0.55f) else c.textFaint.copy(alpha = 0.45f),
                    radius = 1.75.dp.toPx(), center = Offset(x, size.height / 2),
                )
            }
            drawCircle(Color.Black.copy(alpha = 0.16f), radius = knob / 2 + 0.5.dp.toPx(), center = Offset(centre, size.height / 2 + 1.dp.toPx()))
            drawCircle(knobColor, radius = knob / 2, center = Offset(centre, size.height / 2))
            drawCircle(c.lineStrong, radius = knob / 2, center = Offset(centre, size.height / 2), style = Stroke(0.5.dp.toPx()))
        }
    }
}

/** Claude's burst and Codex's knot — the Mac's `ClaudeMark` and `CodexMark`, drawn the same way. */
@Composable
internal fun EngineGlyph(engine: String, modifier: Modifier, tint: Color) {
    Canvas(modifier) {
        val side = min(size.width, size.height)
        val cx = size.width / 2
        val cy = size.height / 2
        when (engine) {
            "codex" -> {
                val loop = Rect(cx - side / 2, cy - side * 0.235f, cx + side / 2, cy + side * 0.235f)
                for (turn in 0 until 3) {
                    rotate(60f * turn, Offset(cx, cy)) {
                        drawOval(tint, topLeft = loop.topLeft, size = loop.size,
                            style = Stroke(width = max(1f, side * 0.105f), cap = StrokeCap.Round))
                    }
                }
            }
            else -> {
                val petals = 11
                val outer = side / 2
                val inner = outer * 0.09f
                val waist = outer * 0.40f
                val step = (PI * 2 / petals).toFloat()
                val spread = step * 0.34f
                fun point(angle: Float, r: Float) = Offset(cx + cos(angle) * r, cy + sin(angle) * r)
                val path = Path()
                for (i in 0 until petals) {
                    val angle = step * i - (PI / 2).toFloat()
                    val root = point(angle, inner)
                    val tip = point(angle, outer)
                    val a = point(angle + spread, waist)
                    val b = point(angle - spread, waist)
                    path.moveTo(root.x, root.y)
                    path.quadraticTo(a.x, a.y, tip.x, tip.y)
                    path.quadraticTo(b.x, b.y, root.x, root.y)
                    path.close()
                }
                path.addOval(Rect(cx - inner, cy - inner, cx + inner, cy + inner))
                drawPath(path, tint)
            }
        }
    }
}
