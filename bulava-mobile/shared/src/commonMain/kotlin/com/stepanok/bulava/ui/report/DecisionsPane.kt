package com.stepanok.bulava.ui.report

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.defaultMinSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.semantics.selected
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.unit.dp
import com.stepanok.bulava.link.DecisionItem
import com.stepanok.bulava.link.Decisions
import com.stepanok.bulava.resources.Res
import com.stepanok.bulava.resources.action_cancel
import com.stepanok.bulava.resources.decisions_advice
import com.stepanok.bulava.resources.decisions_comment
import com.stepanok.bulava.resources.decisions_confirm_title
import com.stepanok.bulava.resources.decisions_count
import com.stepanok.bulava.resources.decisions_eyebrow
import com.stepanok.bulava.resources.decisions_general
import com.stepanok.bulava.resources.decisions_general_hint
import com.stepanok.bulava.resources.decisions_latest
import com.stepanok.bulava.resources.decisions_open
import com.stepanok.bulava.resources.decisions_send
import com.stepanok.bulava.resources.decisions_send_correction
import com.stepanok.bulava.resources.decisions_undecided
import com.stepanok.bulava.resources.decisions_undecided_note
import com.stepanok.bulava.resources.decisions_waiting
import com.stepanok.bulava.state.AppController
import com.stepanok.bulava.state.DecisionDraft
import com.stepanok.bulava.state.Decided
import com.stepanok.bulava.state.asDraft
import com.stepanok.bulava.link.DecisionSent
import com.stepanok.bulava.resources.decisions_as_sent
import com.stepanok.bulava.ui.system.AlertButton
import com.stepanok.bulava.ui.system.SystemAlert
import com.stepanok.bulava.ui.system.rememberHaptics
import com.stepanok.bulava.ui.system.systemClickable
import com.stepanok.bulava.ui.components.BulavaButton
import com.stepanok.bulava.ui.components.BulavaTextField
import com.stepanok.bulava.ui.components.ButtonKind
import com.stepanok.bulava.ui.components.Card
import com.stepanok.bulava.ui.components.Eyebrow
import com.stepanok.bulava.ui.components.FlowRowCompat
import com.stepanok.bulava.ui.theme.Bulava
import com.stepanok.bulava.ui.theme.Metrics
import kotlinx.coroutines.launch
import org.jetbrains.compose.resources.stringResource

/**
 * A report's questions, drawn by the phone — the page itself has no say in them. What is ticked is
 * kept on the phone as it is ticked (`AppController.decisions`), so a closed app or a lost
 * connection loses nothing. An answer already sent is what the questions open with, until he changes
 * something. "Send" shows what goes first; the Mac then writes it into the report's chat as his message.
 */
@Composable
fun DecisionsPane(
    controller: AppController,
    decisions: Decisions,
    modifier: Modifier = Modifier,
    onReadAgain: () -> Unit,
) {
    val c = Bulava.colors
    val all by controller.decisions.collectAsState()
    // The answer the Mac just took, until the report is read again and says so itself.
    var justSent by remember(decisions.ref) { mutableStateOf<DecisionSent?>(null) }
    val latest = listOfNotNull(justSent, decisions.latest).maxByOrNull { it.sentAt }
    val sent = latest?.asDraft(decisions)
    val draft = shownAnswer(all[decisions.ref], sent)
    val asSent = sent != null && draft.sending == null && draft.answersLike(sent)
    val onItsWay = draft.sending != null
    val haptics = rememberHaptics()
    fun edit(change: (DecisionDraft) -> DecisionDraft) {
        if (onItsWay) return
        val next = change(draft)
        // Back to exactly what was sent: no draft of his own any more, so a newer answer sent from
        // the Mac shows next time. Anything else is his — an emptied answer included.
        if (sent != null && next.answersLike(sent)) controller.setDecisionDraft(decisions.ref, DecisionDraft())
        else controller.setDecisionDraft(decisions.ref, next, keepEmpty = sent != null)
    }
    var openComments by remember(decisions.ref) { mutableStateOf(draft.comments.keys) }
    var confirming by remember { mutableStateOf(false) }
    var problem by remember { mutableStateOf<String?>(null) }
    var busy by remember { mutableStateOf(false) }
    val scope = rememberCoroutineScope()

    fun send() {
        confirming = false
        busy = true
        problem = null
        scope.launch {
            // What is shown is what goes — the answer sent before included, when only part of it changed.
            if (all[decisions.ref] == null && sent != null) controller.setDecisionDraft(decisions.ref, draft)
            val outcome = controller.decide(decisions.ref, decisions.revision, latest?.id)
            busy = false
            when (outcome) {
                is Decided.Sent -> {
                    haptics.success()
                    justSent = outcome.sent
                    controller.say(AppController.Notice(AppController.Notice.Kind.DecisionsSent))
                    onReadAgain()
                }
                Decided.Waiting -> Unit
                is Decided.ReadAgain -> { haptics.failure(); problem = outcome.message; onReadAgain() }
                is Decided.Refused -> { haptics.failure(); problem = outcome.message.ifBlank { null } }
            }
        }
    }

    Column(modifier) {
        Column(
            Modifier.weight(1f).fillMaxWidth().verticalScroll(rememberScrollState())
                .padding(horizontal = Metrics.gutter, vertical = 16.dp),
            verticalArrangement = Arrangement.spacedBy(12.dp),
        ) {
            Eyebrow(stringResource(Res.string.decisions_eyebrow))
            Text(decisions.title, style = Bulava.type.headline, color = c.text)
            if (latest != null) {
                Text(stringResource(if (asSent) Res.string.decisions_as_sent else Res.string.decisions_latest),
                    style = Bulava.type.caption, color = c.textSecondary)
            }
            for ((index, item) in decisions.items.withIndex()) {
                ItemCard(
                    number = index + 1, item = item, chosen = draft.choices[item.id],
                    comment = draft.comments[item.id].orEmpty(),
                    commentOpen = item.comment && (item.id in openComments || draft.comments[item.id]?.isNotBlank() == true),
                    enabled = !onItsWay,
                    onChoose = { option ->
                        haptics.select()
                        edit { d -> d.copy(choices = if (d.choices[item.id] == option) d.choices - item.id else d.choices + (item.id to option)) }
                    },
                    onOpenComment = { openComments = openComments + item.id },
                    onComment = { text ->
                        edit { d -> d.copy(comments = if (text.isEmpty()) d.comments - item.id else d.comments + (item.id to text)) }
                    },
                )
            }
            Text(stringResource(Res.string.decisions_general), style = Bulava.type.bodyStrong, color = c.text,
                modifier = Modifier.padding(top = 4.dp))
            BulavaTextField(draft.general, { text -> edit { it.copy(general = text) } },
                stringResource(Res.string.decisions_general_hint), minLines = 2)
            Text(stringResource(Res.string.decisions_undecided_note), style = Bulava.type.meta, color = c.textFaint)
        }
        Column(
            Modifier.fillMaxWidth().background(c.surface).padding(horizontal = Metrics.gutter, vertical = 12.dp),
            verticalArrangement = Arrangement.spacedBy(8.dp),
        ) {
            if (onItsWay) {
                Text(stringResource(Res.string.decisions_waiting), style = Bulava.type.caption, color = c.orange)
            }
            problem?.let { Text(it, style = Bulava.type.caption, color = c.orange) }
            val chosen = decisions.items.count { draft.choices[it.id] != null }
            Text(stringResource(Res.string.decisions_count, chosen, decisions.items.size),
                style = Bulava.type.meta, color = c.textSecondary)
            BulavaButton(
                stringResource(if (latest == null) Res.string.decisions_send else Res.string.decisions_send_correction),
                // On its way already: the same answer again, under the same id — it lands once.
                { if (onItsWay) send() else confirming = true },
                Modifier.fillMaxWidth(),
                enabled = !draft.isEmpty && !asSent && controller.link.isConnected, busy = busy,
            )
        }
    }

    if (confirming) {
        val undecided = stringResource(Res.string.decisions_undecided)
        val summary = buildString {
            for ((index, item) in decisions.items.withIndex()) {
                if (isNotEmpty()) append("\n")
                append("${index + 1}. ${item.title} — ${draft.choices[item.id] ?: undecided}")
                draft.comments[item.id]?.takeIf { it.isNotBlank() }?.let { append("\n    ").append(it.trim()) }
            }
            if (draft.general.isNotBlank()) append("\n\n").append(draft.general.trim())
        }
        SystemAlert(
            title = stringResource(Res.string.decisions_confirm_title),
            message = summary,
            buttons = listOf(
                AlertButton(stringResource(Res.string.action_cancel), AlertButton.Style.Cancel) { confirming = false },
                AlertButton(stringResource(Res.string.decisions_send)) { send() },
            ),
            onDismiss = { confirming = false },
        )
    }
}

/** What the questions show: his own unsent answer, or else the one already sent, or nothing yet. */
internal fun shownAnswer(local: DecisionDraft?, sent: DecisionDraft?): DecisionDraft = local ?: sent ?: DecisionDraft()

@Composable
private fun ItemCard(
    number: Int,
    item: DecisionItem,
    chosen: String?,
    comment: String,
    commentOpen: Boolean,
    enabled: Boolean,
    onChoose: (String) -> Unit,
    onOpenComment: () -> Unit,
    onComment: (String) -> Unit,
) {
    val c = Bulava.colors
    Card(Modifier.fillMaxWidth(), border = if (chosen != null) c.lineStrong else c.line) {
        Column(Modifier.padding(14.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
            Row(verticalAlignment = Alignment.Top) {
                Text("$number", style = Bulava.type.meta, color = c.textFaint, modifier = Modifier.width(22.dp).padding(top = 2.dp))
                Text(item.title, style = Bulava.type.bodyStrong, color = c.text)
            }
            item.detail?.let { Text(it, style = Bulava.type.caption, color = c.textSecondary) }
            FlowRowCompat(spacing = 8.dp) {
                for (option in item.options) {
                    Option(option, selected = chosen == option, advised = item.recommended == option, enabled = enabled) {
                        onChoose(option)
                    }
                }
            }
            item.recommended?.let {
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Spacer(Modifier.size(6.dp).clip(CircleShape).background(c.accent))
                    Spacer(Modifier.width(6.dp))
                    Text(stringResource(Res.string.decisions_advice, it), style = Bulava.type.meta, color = c.textFaint)
                }
            }
            if (item.comment) {
                if (commentOpen) {
                    BulavaTextField(comment, onComment, stringResource(Res.string.decisions_comment))
                } else if (enabled) {
                    Text(stringResource(Res.string.decisions_open), style = Bulava.type.caption, color = c.accentEmphasis,
                        modifier = Modifier.systemClickable(onClick = onOpenComment).padding(vertical = 6.dp))
                }
            }
        }
    }
}

@Composable
private fun Option(label: String, selected: Boolean, advised: Boolean, enabled: Boolean, onClick: () -> Unit) {
    val c = Bulava.colors
    val shape = RoundedCornerShape(Metrics.radiusControl)
    Row(
        Modifier.defaultMinSize(minHeight = Metrics.touch).clip(shape)
            .background(if (selected) c.accent else c.surface, shape)
            .border(1.dp, if (selected) Color.Transparent else c.lineStrong, shape)
            .systemClickable(enabled = enabled, onClick = onClick)
            .semantics { this.selected = selected }
            .padding(horizontal = 14.dp, vertical = 10.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Text(label, style = Bulava.type.callout, color = if (selected) c.onAccent else c.text)
        if (advised) {
            Spacer(Modifier.width(6.dp))
            Spacer(Modifier.size(6.dp).clip(CircleShape).background(if (selected) c.onAccent else c.accent))
        }
    }
}

/** How much of a report's questions is answered — for the switch under the report. */
fun decidedCount(decisions: Decisions, draft: DecisionDraft): Int = decisions.items.count { draft.choices[it.id] != null }
