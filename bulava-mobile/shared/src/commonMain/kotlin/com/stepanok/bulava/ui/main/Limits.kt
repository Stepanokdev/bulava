package com.stepanok.bulava.ui.main

import com.stepanok.bulava.ui.system.systemClickable
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.rotate
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import com.stepanok.bulava.link.EngineLimits
import com.stepanok.bulava.link.LimitWindow
import com.stepanok.bulava.link.Limits
import com.stepanok.bulava.resources.Res
import com.stepanok.bulava.resources.limits_fold
import com.stepanok.bulava.resources.limits_show
import com.stepanok.bulava.state.AppController
import com.stepanok.bulava.ui.theme.Bulava
import com.stepanok.bulava.ui.theme.Icons
import org.jetbrains.compose.resources.stringResource

/**
 * The foot of the Mac's sidebar, at the foot of the drawer: how much of Claude's and Codex's
 * session and week is used, and when each comes back. Folded, one line — each engine's tightest
 * window — as the Mac folds it; the fold is this phone's own and is kept.
 */
@Composable
fun LimitsSection(limits: Limits, controller: AppController) {
    val prefs = controller.platform.prefs
    var folded by remember { mutableStateOf(prefs.get(AppController.LIMITS_FOLDED) == "on") }
    fun toggle() {
        folded = !folded
        prefs.put(AppController.LIMITS_FOLDED, if (folded) "on" else "off")
    }
    val c = Bulava.colors
    if (folded) {
        Row(
            Modifier.fillMaxWidth().systemClickable(role = Role.Button, onClickLabel = stringResource(Res.string.limits_show)) { toggle() }
                .padding(horizontal = 16.dp, vertical = 10.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            limits.engines.forEachIndexed { i, engine ->
                if (i > 0) Text("·", style = Bulava.type.meta, color = c.textFaint, modifier = Modifier.padding(horizontal = 8.dp))
                Text(engine.name, style = Bulava.type.meta, color = c.textSecondary)
                Spacer(Modifier.width(4.dp))
                val used = engine.used
                Text(
                    if (used != null) "$used%" else "—",
                    style = if (used != null) Bulava.type.meta.copy(fontWeight = FontWeight.SemiBold) else Bulava.type.meta,
                    color = if (used == null) c.textFaint else pressureText(engine.pressure),
                )
            }
            Spacer(Modifier.weight(1f))
            Icon(Icons.ChevronDown, null, tint = c.textFaint, modifier = Modifier.size(14.dp))
        }
        return
    }
    Column(Modifier.fillMaxWidth().padding(start = 16.dp, end = 16.dp, top = 4.dp, bottom = 10.dp)) {
        Row(
            Modifier.fillMaxWidth().systemClickable(role = Role.Button, onClickLabel = stringResource(Res.string.limits_fold)) { toggle() }
                .padding(vertical = 6.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Text(limits.title, style = Bulava.type.meta, color = c.textFaint, modifier = Modifier.weight(1f))
            Icon(Icons.ChevronDown, null, tint = c.textFaint, modifier = Modifier.size(14.dp).rotate(180f))
        }
        Column(verticalArrangement = Arrangement.spacedBy(14.dp), modifier = Modifier.padding(top = 4.dp)) {
            for (engine in limits.engines) Engine(engine)
        }
    }
}

@Composable
private fun Engine(engine: EngineLimits) {
    val c = Bulava.colors
    Column(verticalArrangement = Arrangement.spacedBy(9.dp)) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Text(engine.name, style = Bulava.type.callout, color = c.text, modifier = Modifier.weight(1f))
            engine.readAgo?.let { Text(it, style = Bulava.type.meta, color = c.textFaint, maxLines = 1) }
        }
        for (window in engine.windows) Meter(window, dimmed = engine.stale)
        engine.note?.let { Text(it, style = Bulava.type.meta, color = c.textFaint) }
    }
}

@Composable
private fun Meter(window: LimitWindow, dimmed: Boolean) {
    val c = Bulava.colors
    val fill = when (window.pressure) {
        "tight" -> c.orange
        "nearlyOut" -> c.red
        else -> c.accent
    }
    Column(verticalArrangement = Arrangement.spacedBy(5.dp)) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Text(window.label, style = Bulava.type.meta, color = c.textSecondary, modifier = Modifier.weight(1f))
            Text(window.usedLabel, style = Bulava.type.meta.copy(fontWeight = FontWeight.SemiBold),
                color = if (window.pressure == "comfortable") c.text else fill, maxLines = 1)
        }
        Row(verticalAlignment = Alignment.CenterVertically) {
            // The Mac's meter: a hairline-weight track, filled to the share used, at least a sliver,
            // with a tick where an even pace would stand by now — the Mac's sidebar draws the same.
            BoxWithConstraints(Modifier.weight(1f).height(10.dp).alpha(if (dimmed) 0.45f else 1f), contentAlignment = Alignment.CenterStart) {
                Box(Modifier.fillMaxWidth().height(4.dp).clip(RoundedCornerShape(2.dp)).background(c.line)) {
                    Box(Modifier.fillMaxWidth((window.used.coerceIn(0, 100) / 100f).coerceAtLeast(0.02f)).height(4.dp)
                        .clip(RoundedCornerShape(2.dp)).background(fill))
                }
                window.elapsed?.let { elapsed ->
                    val x = (maxWidth * (elapsed.coerceIn(0, 100) / 100f) - 1.dp).coerceIn(0.dp, maxWidth - 2.dp)
                    Box(Modifier.offset(x = x).width(2.dp).height(10.dp).clip(RoundedCornerShape(1.dp)).background(c.text))
                }
            }
            // A column of its own width, so the two meters of an engine end at the same place.
            Row(Modifier.width(72.dp), horizontalArrangement = Arrangement.End, verticalAlignment = Alignment.CenterVertically) {
                window.resets?.let { resets ->
                    Icon(Icons.Refresh, null, tint = c.textFaint, modifier = Modifier.size(11.dp))
                    Spacer(Modifier.width(3.dp))
                    Text(resets, style = Bulava.type.meta, color = c.textFaint, maxLines = 1, overflow = TextOverflow.Clip)
                }
            }
        }
        if (!dimmed) window.pace?.let { pace ->
            Text(pace, style = Bulava.type.meta, color = if (window.paceKey == "ahead") c.orange else c.textFaint, maxLines = 1)
        }
    }
}

@Composable
private fun pressureText(pressure: String): Color = when (pressure) {
    "tight" -> Bulava.colors.orange
    "nearlyOut" -> Bulava.colors.red
    else -> Bulava.colors.text
}
