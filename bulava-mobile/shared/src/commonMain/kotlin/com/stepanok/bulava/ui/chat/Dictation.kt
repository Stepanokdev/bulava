package com.stepanok.bulava.ui.chat

import com.stepanok.bulava.ui.system.systemClickable
import com.stepanok.bulava.ui.system.AlertButton
import com.stepanok.bulava.ui.system.SystemAlert
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableFloatStateOf
import androidx.compose.runtime.mutableLongStateOf
import androidx.compose.runtime.mutableStateListOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.liveRegion
import androidx.compose.ui.semantics.LiveRegionMode
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import com.stepanok.bulava.link.ErrorCodes
import com.stepanok.bulava.resources.Res
import com.stepanok.bulava.resources.action_cancel
import com.stepanok.bulava.resources.action_dictate
import com.stepanok.bulava.resources.action_ok
import com.stepanok.bulava.resources.action_open_settings
import com.stepanok.bulava.resources.dictation_cancel
import com.stepanok.bulava.resources.dictation_denied_body
import com.stepanok.bulava.resources.dictation_denied_title
import com.stepanok.bulava.resources.dictation_discard
import com.stepanok.bulava.resources.dictation_done
import com.stepanok.bulava.resources.dictation_failed_gone
import com.stepanok.bulava.resources.dictation_failed_mac_old
import com.stepanok.bulava.resources.dictation_failed_model
import com.stepanok.bulava.resources.dictation_failed_nothing
import com.stepanok.bulava.resources.dictation_failed_offline
import com.stepanok.bulava.resources.dictation_failed_other
import com.stepanok.bulava.resources.dictation_failed_plain
import com.stepanok.bulava.resources.dictation_failed_timeout
import com.stepanok.bulava.resources.dictation_failed_too_large
import com.stepanok.bulava.resources.dictation_mac_old_body
import com.stepanok.bulava.resources.dictation_mac_old_title
import com.stepanok.bulava.resources.dictation_note
import com.stepanok.bulava.resources.dictation_recording
import com.stepanok.bulava.resources.dictation_retry
import com.stepanok.bulava.resources.dictation_sending
import com.stepanok.bulava.resources.dictation_start_failed
import com.stepanok.bulava.resources.dictation_transcribing
import com.stepanok.bulava.state.AppController
import com.stepanok.bulava.state.Dictation
import com.stepanok.bulava.state.VoiceNote
import com.stepanok.bulava.ui.components.BulavaButton
import com.stepanok.bulava.ui.components.ButtonKind
import com.stepanok.bulava.ui.theme.Bulava
import com.stepanok.bulava.ui.theme.Icons
import com.stepanok.bulava.ui.theme.Metrics
import kotlinx.coroutines.delay
import org.jetbrains.compose.resources.stringResource

/** "0:42", "12:05" — how long a recording has run. */
internal fun clock(ms: Long): String {
    val seconds = (ms / 1000).coerceAtLeast(0)
    return "${seconds / 60}:${(seconds % 60).toString().padStart(2, '0')}"
}

/**
 * The mic beside the send button. A tap starts a voice note for this chat; the Mac's Whisper
 * writes it down and the words come back into this field — never sent by themselves.
 *
 * A Mac too old to transcribe is said so on the tap, with the keyboard's own microphone as what to
 * use meanwhile. The permission is asked at the first tap, and a refusal leads to the settings.
 */
@Composable
internal fun MicButton(controller: AppController, productID: String, chatID: String, enabled: Boolean) {
    val c = Bulava.colors
    var dialog by remember { mutableStateOf<String?>(null) }
    val dictation = controller.dictation
    val description = stringResource(Res.string.action_dictate)

    fun outcome(start: Dictation.Start) {
        dialog = when (start) {
            Dictation.Start.Denied -> DENIED
            Dictation.Start.Failed -> FAILED
            else -> null
        }
    }

    Box(Modifier.size(48.dp), contentAlignment = Alignment.Center) {
        Box(
            Modifier.size(36.dp).clip(CircleShape)
                .systemClickable(enabled = enabled, role = Role.Button) {
                    if (!dictation.macCanTranscribe) { dialog = MAC_OLD; return@systemClickable }
                    outcome(dictation.start(productID, chatID) { asked -> outcome(asked) })
                }
                .semantics { contentDescription = description },
            contentAlignment = Alignment.Center,
        ) {
            Icon(Icons.Mic, null, tint = if (enabled) c.textSecondary else c.textFaint, modifier = Modifier.size(20.dp))
        }
    }

    when (dialog) {
        MAC_OLD -> Explain(
            stringResource(Res.string.dictation_mac_old_title), stringResource(Res.string.dictation_mac_old_body),
            onDismiss = { dialog = null },
        )
        DENIED -> Explain(
            stringResource(Res.string.dictation_denied_title), stringResource(Res.string.dictation_denied_body),
            action = stringResource(Res.string.action_open_settings) to { dictation.recorder?.openSettings() },
            onDismiss = { dialog = null },
        )
        FAILED -> Explain(null, stringResource(Res.string.dictation_start_failed), onDismiss = { dialog = null })
    }
}

private const val MAC_OLD = "macOld"
private const val DENIED = "denied"
private const val FAILED = "failed"

@Composable
private fun Explain(title: String?, body: String, action: Pair<String, () -> Unit>? = null, onDismiss: () -> Unit) {
    val buttons = if (action != null) {
        listOf(
            AlertButton(stringResource(Res.string.action_cancel), AlertButton.Style.Cancel, onClick = onDismiss),
            AlertButton(action.first) { onDismiss(); action.second() },
        )
    } else {
        listOf(AlertButton(stringResource(Res.string.action_ok), onClick = onDismiss))
    }
    // Without a title of its own, the alert's one sentence is its title, as the iPhone sets them.
    SystemAlert(title = title ?: body, message = if (title == null) null else body, buttons = buttons, onDismiss = onDismiss)
}

/**
 * The composer while the microphone is on: how long, how loud, and the two ways out — throw it
 * away, or done, which sends it to the Mac.
 */
@Composable
internal fun RecordingBar(controller: AppController) {
    val c = Bulava.colors
    val recording by controller.dictation.recording.collectAsState()
    val r = recording ?: return
    var elapsed by remember(r) { mutableLongStateOf(0L) }
    var level by remember(r) { mutableFloatStateOf(0f) }
    val history = remember(r) { mutableStateListOf<Float>() }
    LaunchedEffect(r) {
        while (true) {
            elapsed = controller.nowMs() - r.startedAtMs
            level = controller.dictation.level()
            history.add(level)
            if (history.size > BARS) history.removeAt(0)
            delay(80)
        }
    }
    val shown by animateFloatAsState(level)
    val label = stringResource(Res.string.dictation_recording)
    Row(
        Modifier.fillMaxWidth().heightIn(min = 56.dp).padding(horizontal = 6.dp, vertical = 4.dp)
            .semantics { contentDescription = label },
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Box(
            Modifier.size(48.dp).clip(CircleShape).systemClickable(role = Role.Button) { controller.dictation.cancelRecording() },
            contentAlignment = Alignment.Center,
        ) {
            val cancel = stringResource(Res.string.dictation_cancel)
            Icon(Icons.Close, cancel, tint = c.textSecondary, modifier = Modifier.size(18.dp))
        }
        Box(Modifier.size(10.dp).clip(CircleShape).background(c.red.copy(alpha = 0.55f + 0.45f * shown)))
        Spacer(Modifier.width(8.dp))
        Text(clock(elapsed), style = Bulava.type.callout.copy(fontWeight = FontWeight.Medium), color = c.text,
            modifier = Modifier.semantics { liveRegion = LiveRegionMode.Polite })
        Spacer(Modifier.width(12.dp))
        Row(Modifier.weight(1f).height(28.dp), horizontalArrangement = Arrangement.spacedBy(2.dp), verticalAlignment = Alignment.CenterVertically) {
            for (i in 0 until BARS) {
                val v = history.getOrNull(i - (BARS - history.size)) ?: 0f
                Box(Modifier.width(3.dp).height((4 + 24 * v).dp).clip(RoundedCornerShape(2.dp)).background(if (v > 0f) c.textSecondary else c.line))
            }
        }
        Spacer(Modifier.width(8.dp))
        Box(Modifier.size(48.dp), contentAlignment = Alignment.Center) {
            val done = stringResource(Res.string.dictation_done)
            Box(
                Modifier.size(36.dp).clip(CircleShape).background(c.accent)
                    .systemClickable(role = Role.Button) { controller.dictation.finish() }
                    .semantics { contentDescription = done },
                contentAlignment = Alignment.Center,
            ) { Icon(Icons.Check, null, tint = c.onAccent, modifier = Modifier.size(18.dp)) }
        }
    }
}

private const val BARS = 28

/**
 * The voice notes of this chat that are not words yet: on their way to the Mac, being transcribed
 * there, or stopped — with why, and "try again" where trying again can help.
 */
@Composable
internal fun VoiceNotes(controller: AppController, chatID: String) {
    val notes by controller.dictation.notes.collectAsState()
    val mine = notes.filter { it.chatID == chatID }
    if (mine.isEmpty()) return
    Column(Modifier.fillMaxWidth().padding(start = 12.dp, end = 12.dp, top = 10.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
        for (note in mine) VoiceNoteRow(controller, note)
    }
}

@Composable
private fun VoiceNoteRow(controller: AppController, note: VoiceNote) {
    val c = Bulava.colors
    val failed = note.stage == VoiceNote.Stage.Failed
    Column(
        Modifier.fillMaxWidth().clip(RoundedCornerShape(Metrics.radiusCard))
            .background(if (failed) c.orangeSoft else c.surfaceMuted)
            .padding(start = 12.dp, end = 4.dp, top = 8.dp, bottom = if (failed) 4.dp else 8.dp),
    ) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            if (failed) Icon(Icons.Warning, null, tint = c.orange, modifier = Modifier.size(16.dp))
            else CircularProgressIndicator(Modifier.size(14.dp), strokeWidth = 1.5.dp, color = c.textFaint)
            Spacer(Modifier.width(8.dp))
            Column(Modifier.weight(1f).semantics { liveRegion = LiveRegionMode.Polite }) {
                Text(stringResource(Res.string.dictation_note, clock(note.durationMs)), style = Bulava.type.meta, color = c.textFaint)
                Text(
                    when (note.stage) {
                        VoiceNote.Stage.Sending -> stringResource(Res.string.dictation_sending)
                        VoiceNote.Stage.Transcribing -> stringResource(Res.string.dictation_transcribing)
                        VoiceNote.Stage.Failed -> reason(note)
                    },
                    style = Bulava.type.caption, color = c.text,
                )
            }
        }
        if (failed) {
            Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.End) {
                BulavaButton(stringResource(Res.string.dictation_discard), { controller.dictation.discard(note.requestID) }, kind = ButtonKind.Quiet)
                if (note.retryable) {
                    BulavaButton(stringResource(Res.string.dictation_retry), { controller.dictation.retry(note.requestID) }, kind = ButtonKind.Quiet, icon = Icons.Refresh)
                }
            }
        }
    }
}

/** Why a note stopped, in this phone's language; the Mac's own words only for what the phone has none for. */
@Composable
private fun reason(note: VoiceNote): String = when (note.failure) {
    ErrorCodes.OFFLINE -> stringResource(Res.string.dictation_failed_offline)
    ErrorCodes.TIMEOUT -> stringResource(Res.string.dictation_failed_timeout)
    ErrorCodes.DICTATION_UNAVAILABLE -> note.message ?: stringResource(Res.string.dictation_failed_model)
    ErrorCodes.NOT_TRANSCRIBED -> stringResource(Res.string.dictation_failed_nothing)
    ErrorCodes.TOO_LARGE -> stringResource(Res.string.dictation_failed_too_large)
    Dictation.GONE -> stringResource(Res.string.dictation_failed_gone)
    Dictation.MAC_TOO_OLD, ErrorCodes.UNKNOWN_OPERATION -> stringResource(Res.string.dictation_failed_mac_old)
    else -> note.message?.let { stringResource(Res.string.dictation_failed_other, it) } ?: stringResource(Res.string.dictation_failed_plain)
}
