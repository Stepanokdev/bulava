package com.stepanok.bulava.ui.chat

import com.stepanok.bulava.ui.system.systemClickable
import androidx.compose.animation.animateContentSize
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.Immutable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateMapOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.rotate
import androidx.compose.ui.platform.LocalClipboardManager
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.text.AnnotatedString
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextDecoration
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import com.mikepenz.markdown.m3.Markdown
import com.mikepenz.markdown.m3.markdownColor
import com.mikepenz.markdown.m3.markdownTypography
import com.stepanok.bulava.link.Activity
import com.stepanok.bulava.link.Ask
import com.stepanok.bulava.link.Block
import com.stepanok.bulava.link.Card
import com.stepanok.bulava.link.Entry
import com.stepanok.bulava.link.FileRef
import com.stepanok.bulava.link.Question
import com.stepanok.bulava.resources.Res
import com.stepanok.bulava.resources.action_copy
import com.stepanok.bulava.resources.action_edit
import com.stepanok.bulava.resources.action_send_again
import com.stepanok.bulava.resources.decision_label
import com.stepanok.bulava.resources.explanation_stale
import com.stepanok.bulava.resources.explanation_steps
import com.stepanok.bulava.resources.explanation_title
import com.stepanok.bulava.resources.message_not_sent
import com.stepanok.bulava.resources.message_sending
import com.stepanok.bulava.resources.question_answer_hint
import com.stepanok.bulava.resources.question_i_would
import com.stepanok.bulava.resources.question_if_never
import com.stepanok.bulava.resources.question_send
import com.stepanok.bulava.resources.question_several
import com.stepanok.bulava.resources.question_unblocks
import com.stepanok.bulava.state.AppController
import com.stepanok.bulava.state.Outgoing
import com.stepanok.bulava.ui.components.BulavaButton
import com.stepanok.bulava.ui.components.BulavaTextField
import com.stepanok.bulava.ui.components.ButtonKind
import com.stepanok.bulava.ui.components.Eyebrow
import com.stepanok.bulava.ui.components.Hairline
import com.stepanok.bulava.ui.components.MacActions
import com.stepanok.bulava.ui.components.StatusDot
import com.stepanok.bulava.ui.media.RemoteImage
import com.stepanok.bulava.ui.theme.Bulava
import com.stepanok.bulava.ui.theme.Icons
import com.stepanok.bulava.ui.theme.Metrics
import com.stepanok.bulava.ui.theme.toneColor
import com.stepanok.bulava.ui.theme.toneWash
import org.jetbrains.compose.resources.stringResource

/** What every entry in one chat needs to know about where it is drawn. */
@Immutable
class ChatContext(
    val controller: AppController,
    val productID: String,
    val chatID: String,
    val writable: Boolean,
    val onCompose: (String?) -> Unit,
    val onOpenReport: (String, String) -> Unit,
    val onOpenImage: (String, String) -> Unit,
)

@Composable
fun EntryView(entry: Entry, ctx: ChatContext) {
    when (entry.kind) {
        "user" -> UserMessage(entry, ctx)
        "agent", "codex" -> AgentMessage(entry, ctx)
        "event" -> EventLine(entry)
        "decision" -> DecisionNote(entry)
        "question" -> entry.question?.let { QuestionCard(entry, it, ctx) } ?: AgentMessage(entry, ctx)
        "report" -> entry.card?.let { ReportCard(it, ctx) }
        // Something a newer Mac knows how to say: shown as its words, never dropped.
        else -> if (entry.text.isNotBlank() || entry.blocks.isNotEmpty()) AgentMessage(entry, ctx)
    }
}

// MARK: Your messages

@Composable
private fun UserMessage(entry: Entry, ctx: ChatContext) {
    val c = Bulava.colors
    val replaced = entry.delivery?.code == "replaced"
    Column(Modifier.fillMaxWidth().padding(horizontal = Metrics.gutter, vertical = 6.dp), horizontalAlignment = Alignment.End) {
        if (entry.attachments.isNotEmpty()) {
            Attachments(entry.attachments, ctx, alignEnd = true)
            Spacer(Modifier.height(6.dp))
        }
        if (entry.text.isNotBlank()) {
            Box(
                Modifier.widthIn(max = 320.dp).clip(RoundedCornerShape(20.dp)).background(c.surfaceRaised)
                    .padding(horizontal = 14.dp, vertical = 10.dp),
            ) {
                Text(entry.text, style = Bulava.type.body, color = if (replaced) c.textFaint else c.text,
                    textDecoration = if (replaced) TextDecoration.LineThrough else null)
            }
        }
        entry.delivery?.let { d ->
            Spacer(Modifier.height(4.dp))
            Text(d.label, style = Bulava.type.meta, color = if (d.code == "failed") c.red else c.textFaint)
        }
        if (entry.actions.isNotEmpty() && ctx.writable) {
            Spacer(Modifier.height(4.dp))
            MacActions(
                entry.actions,
                onInvoke = { a, input -> ctx.controller.invokeNow(a, input) },
                onTakeBack = { a -> ctx.controller.takeBack(ctx.chatID, a.target ?: entry.id) },
                enabled = ctx.controller.link.isConnected,
            )
        }
        for (ask in entry.asks) {
            Spacer(Modifier.height(8.dp))
            AskCard(ask, ctx)
        }
    }
}

/** A message on its way, or one that did not make it. Only the phone knows about these. */
@Composable
fun OutgoingMessage(item: Outgoing, ctx: ChatContext) {
    val c = Bulava.colors
    Column(Modifier.fillMaxWidth().padding(horizontal = Metrics.gutter, vertical = 6.dp), horizontalAlignment = Alignment.End) {
        if (item.attachments.isNotEmpty()) {
            Attachments(item.attachments, ctx, alignEnd = true)
            Spacer(Modifier.height(6.dp))
        }
        if (item.text.isNotBlank()) {
            Box(
                Modifier.widthIn(max = 320.dp).clip(RoundedCornerShape(20.dp)).background(c.surfaceRaised)
                    .padding(horizontal = 14.dp, vertical = 10.dp),
            ) { Text(item.text, style = Bulava.type.body, color = if (item.failed) c.textSecondary else c.text) }
        }
        Spacer(Modifier.height(4.dp))
        if (item.failed) {
            Text(stringResource(Res.string.message_not_sent), style = Bulava.type.meta, color = c.red)
            Row(horizontalArrangement = Arrangement.spacedBy(4.dp)) {
                BulavaButton(stringResource(Res.string.action_edit), { ctx.controller.discardOutgoing(item.entryID) }, kind = ButtonKind.Quiet)
                BulavaButton(stringResource(Res.string.action_send_again), { ctx.controller.resend(item.entryID) },
                    kind = ButtonKind.Secondary, icon = Icons.Refresh)
            }
        } else {
            Text(stringResource(Res.string.message_sending), style = Bulava.type.meta, color = c.textFaint)
        }
    }
}

// MARK: Bulava's messages

@Composable
private fun AgentMessage(entry: Entry, ctx: ChatContext) {
    val c = Bulava.colors
    // LocalClipboard needs a platform ClipEntry, which common code cannot build yet.
    @Suppress("DEPRECATION")
    val clipboard = LocalClipboardManager.current
    Column(Modifier.fillMaxWidth().padding(horizontal = Metrics.gutter, vertical = 8.dp)) {
        if (entry.kind == "codex") {
            Eyebrow("Codex", color = c.textFaint)
            Spacer(Modifier.height(6.dp))
        }
        val blocks = entry.blocks
        if (blocks.isEmpty()) {
            if (entry.text.isNotBlank()) Prose(entry.text)
        } else {
            BlockStack(blocks, ctx)
        }
        if (entry.attachments.isNotEmpty()) {
            Spacer(Modifier.height(8.dp))
            Attachments(entry.attachments, ctx, alignEnd = false)
        }
        val prose = if (blocks.isEmpty()) entry.text else blocks.filter { it.kind == "markdown" }.joinToString("\n\n") { it.text }
        if (entry.finished != false && prose.isNotBlank()) {
            Row(Modifier.padding(top = 2.dp)) {
                Box(
                    Modifier.size(36.dp).clip(CircleShape)
                        .systemClickable(role = Role.Button) {
                            clipboard.setText(AnnotatedString(prose))
                            ctx.controller.say(AppController.Notice(AppController.Notice.Kind.Copied))
                        },
                    contentAlignment = Alignment.Center,
                ) { Icon(Icons.Copy, stringResource(Res.string.action_copy), tint = c.textFaint, modifier = Modifier.size(16.dp)) }
            }
        }
        if (entry.actions.isNotEmpty() && ctx.writable) {
            MacActions(entry.actions, onInvoke = { a, input -> ctx.controller.invokeNow(a, input) },
                enabled = ctx.controller.link.isConnected)
        }
        entry.explanation?.let { ExplanationBlock(it, ctx) }
    }
}

/** "Explain what happened", as the Mac offers it: the button, then the explanation in a fold. */
@Composable
private fun ExplanationBlock(explanation: com.stepanok.bulava.link.Explanation, ctx: ChatContext) {
    val c = Bulava.colors
    var open by remember { mutableStateOf(false) }
    val text = explanation.brief ?: explanation.stepByStep
    Column(Modifier.padding(top = 6.dp).animateContentSize(), verticalArrangement = Arrangement.spacedBy(8.dp)) {
        if (text != null) {
            Column(
                Modifier.fillMaxWidth().clip(RoundedCornerShape(Metrics.radiusCard)).background(c.accentSoft)
                    .systemClickable(role = Role.Button) { open = !open }.padding(14.dp),
            ) {
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Eyebrow(stringResource(Res.string.explanation_title), color = c.accentEmphasis)
                    Spacer(Modifier.weight(1f))
                    Icon(Icons.ChevronDown, null, tint = c.textFaint, modifier = Modifier.size(14.dp).rotate(if (open) 180f else 0f))
                }
                if (open) {
                    Spacer(Modifier.height(8.dp))
                    Prose(text)
                    if (explanation.brief != null && explanation.stepByStep != null) {
                        Spacer(Modifier.height(12.dp))
                        Eyebrow(stringResource(Res.string.explanation_steps))
                        Spacer(Modifier.height(6.dp))
                        Prose(explanation.stepByStep)
                    }
                    if (explanation.stale) {
                        Spacer(Modifier.height(8.dp))
                        Text(stringResource(Res.string.explanation_stale), style = Bulava.type.meta, color = c.textFaint)
                    }
                }
            }
        }
        explanation.failure?.let { Text(it, style = Bulava.type.meta, color = c.red) }
        if (explanation.actions.isNotEmpty() && ctx.writable) {
            MacActions(explanation.actions, onInvoke = { a, input -> ctx.controller.invokeNow(a, input) },
                enabled = ctx.controller.link.isConnected)
        }
    }
}

@Composable
fun Prose(text: String) {
    val c = Bulava.colors
    val t = Bulava.type
    Markdown(
        content = text,
        colors = markdownColor(text = c.text, codeBackground = c.code, inlineCodeBackground = c.code, dividerColor = c.line),
        typography = markdownTypography(
            h1 = t.title, h2 = t.headline, h3 = t.bodyStrong, h4 = t.bodyStrong, h5 = t.bodyStrong, h6 = t.bodyStrong,
            text = t.body, paragraph = t.body, code = t.mono, inlineCode = t.mono, quote = t.callout.copy(color = c.textSecondary),
            ordered = t.body, bullet = t.body, list = t.body,
        ),
    )
}

/** Blocks in order, with runs of tool steps folded into one line the way Claude's apps do it. */
@Composable
private fun BlockStack(blocks: List<Block>, ctx: ChatContext) {
    val groups = remember(blocks) { group(blocks) }
    Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
        for (g in groups) {
            when {
                g.size > 1 || g.first().kind == "activity" -> Steps(g.mapNotNull { it.activity })
                else -> BlockView(g.first(), ctx)
            }
        }
    }
}

private fun group(blocks: List<Block>): List<List<Block>> {
    val out = mutableListOf<List<Block>>()
    var run = mutableListOf<Block>()
    for (b in blocks) {
        if (b.kind == "activity" && b.activity != null) {
            run.add(b)
        } else {
            if (run.isNotEmpty()) { out.add(run); run = mutableListOf() }
            out.add(listOf(b))
        }
    }
    if (run.isNotEmpty()) out.add(run)
    return out
}

@Composable
private fun BlockView(block: Block, ctx: ChatContext) {
    val c = Bulava.colors
    when (block.kind) {
        "markdown" -> {
            Prose(block.text)
            // Files the answer names, as things to open: the Mac shares each on its own Wi-Fi.
            if (block.links.isNotEmpty() && ctx.controller.can("files.open")) {
                Spacer(Modifier.height(6.dp))
                Attachments(block.links, ctx, alignEnd = false)
            }
        }
        "error" -> Row(
            Modifier.fillMaxWidth().clip(RoundedCornerShape(Metrics.radiusControl)).background(c.redSoft).padding(12.dp),
        ) {
            Icon(Icons.Warning, null, tint = c.red, modifier = Modifier.size(18.dp))
            Spacer(Modifier.width(10.dp))
            Text(block.text, style = Bulava.type.caption, color = c.text)
        }
        "consult" -> Consult(block)
        "file", "gallery" -> {
            if (block.text.isNotBlank()) Text(block.text, style = Bulava.type.caption, color = c.textSecondary)
            Attachments(block.files, ctx, alignEnd = false)
        }
        else -> if (block.text.isNotBlank()) Text(block.text, style = Bulava.type.callout, color = c.textSecondary)
    }
}

@Composable
private fun Steps(steps: List<Activity>) {
    val c = Bulava.colors
    var open by remember { mutableStateOf(false) }
    val running = steps.lastOrNull { it.status == "running" }
    val failed = steps.count { it.status == "failed" }
    Column(Modifier.animateContentSize()) {
        Row(
            Modifier.clip(RoundedCornerShape(8.dp)).systemClickable(role = Role.Button) { open = !open }.padding(vertical = 6.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            if (running != null) {
                CircularProgressIndicator(Modifier.size(12.dp), strokeWidth = 1.5.dp, color = c.accent)
            } else {
                Icon(if (failed > 0) Icons.Warning else Icons.Check, null, tint = if (failed > 0) c.orange else c.textFaint,
                    modifier = Modifier.size(14.dp))
            }
            Spacer(Modifier.width(8.dp))
            Text(
                running?.sentence ?: (steps.lastOrNull()?.sentence ?: ""),
                style = Bulava.type.caption, color = c.textSecondary, maxLines = 1, overflow = TextOverflow.Ellipsis,
                modifier = Modifier.weight(1f, fill = false),
            )
            if (steps.size > 1) {
                Spacer(Modifier.width(6.dp))
                Text("· ${steps.size}", style = Bulava.type.meta, color = c.textFaint)
                Icon(Icons.ChevronDown, null, tint = c.textFaint, modifier = Modifier.size(14.dp).rotate(if (open) 180f else 0f))
            }
        }
        if (open) {
            Column(Modifier.padding(start = 20.dp), verticalArrangement = Arrangement.spacedBy(4.dp)) {
                for (s in steps) {
                    Row(verticalAlignment = Alignment.Top) {
                        StatusDot(if (s.status == "failed") "problem" else if (s.status == "running") "active" else "neutral",
                            Modifier.padding(top = 6.dp), size = 5.dp)
                        Spacer(Modifier.width(8.dp))
                        Column {
                            Text(s.sentence, style = Bulava.type.meta, color = c.textSecondary)
                            if (s.status == "failed" && !s.detail.isNullOrBlank()) {
                                Text(s.detail, style = Bulava.type.meta, color = c.red)
                            }
                        }
                    }
                }
            }
        }
    }
}

@Composable
private fun Consult(block: Block) {
    val c = Bulava.colors
    var open by remember { mutableStateOf(false) }
    val running = block.activity?.status == "running"
    Column(
        Modifier.fillMaxWidth().clip(RoundedCornerShape(Metrics.radiusCard)).border(1.dp, c.line, RoundedCornerShape(Metrics.radiusCard))
            .systemClickable(role = Role.Button) { open = !open }.padding(12.dp).animateContentSize(),
    ) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            if (running) CircularProgressIndicator(Modifier.size(12.dp), strokeWidth = 1.5.dp, color = c.accent)
            else Icon(Icons.Check, null, tint = c.textFaint, modifier = Modifier.size(14.dp))
            Spacer(Modifier.width(8.dp))
            Text(block.activity?.sentence ?: "", style = Bulava.type.caption.copy(fontWeight = FontWeight.Medium),
                color = c.text, modifier = Modifier.weight(1f))
            Icon(Icons.ChevronDown, null, tint = c.textFaint, modifier = Modifier.size(14.dp).rotate(if (open) 180f else 0f))
        }
        if (open) {
            block.activity?.detail?.takeIf { it.isNotBlank() }?.let {
                Spacer(Modifier.height(8.dp))
                Text(it, style = Bulava.type.meta, color = c.textFaint)
            }
            if (block.text.isNotBlank()) {
                Spacer(Modifier.height(8.dp))
                Prose(block.text)
            }
        }
    }
}

// MARK: Files

@Composable
fun Attachments(files: List<FileRef>, ctx: ChatContext, alignEnd: Boolean) {
    val images = files.filter { it.kind == "image" && it.ref != null }
    val others = files - images.toSet()
    Column(horizontalAlignment = if (alignEnd) Alignment.End else Alignment.Start, verticalArrangement = Arrangement.spacedBy(6.dp)) {
        if (images.isNotEmpty()) {
            Row(Modifier.horizontalScroll(rememberScrollState()), horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                for (img in images) {
                    RemoteImage(
                        ctx.controller, img.ref!!, img.name,
                        Modifier.size(if (images.size == 1) 200.dp else 120.dp).clip(RoundedCornerShape(Metrics.radiusCard))
                            .systemClickable(role = Role.Image) { ctx.onOpenImage(img.ref, img.name) },
                    )
                }
            }
        }
        for (f in others) FileChip(f, ctx)
    }
}

@Composable
private fun FileChip(file: FileRef, ctx: ChatContext) {
    val c = Bulava.colors
    Row(
        Modifier.widthIn(max = 300.dp).clip(RoundedCornerShape(Metrics.radiusControl)).border(1.dp, c.line, RoundedCornerShape(Metrics.radiusControl))
            .then(
                when (val tap = FileTap.of(file, ctx.controller.can("files.open"))) {
                    is FileTap.Web -> Modifier.systemClickable(role = Role.Button) { ctx.controller.platform.openUrl(tap.url) }
                    is FileTap.Shared -> Modifier.systemClickable(role = Role.Button) { ctx.controller.openFile(tap.ref) }
                    is FileTap.Picture -> Modifier.systemClickable(role = Role.Image) { ctx.onOpenImage(tap.ref, tap.name) }
                    is FileTap.Report -> Modifier.systemClickable(role = Role.Button) { ctx.onOpenReport(tap.target, tap.name) }
                    FileTap.None -> Modifier
                },
            )
            .padding(horizontal = 12.dp, vertical = 10.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        val opensOutside = file.url != null || FileTap.of(file, ctx.controller.can("files.open")) is FileTap.Shared
        Icon(if (opensOutside) Icons.External else Icons.Document, null, tint = c.textSecondary, modifier = Modifier.size(18.dp))
        Spacer(Modifier.width(10.dp))
        Column {
            Text(file.name, style = Bulava.type.caption, color = c.text, maxLines = 1, overflow = TextOverflow.Ellipsis)
            file.size?.let { Text(sizeLabel(it), style = Bulava.type.meta, color = c.textFaint) }
        }
    }
}

/**
 * What a tap on a file does. A link goes to the browser; a picture to the viewer; anything else the
 * Mac can share is opened by it on its home Wi-Fi and shown in the phone's browser — a site with its
 * styles and scripts, a note as a page. Against a Mac too old to share, a page still opens in the
 * report viewer as before.
 */
sealed interface FileTap {
    data class Web(val url: String) : FileTap
    data class Shared(val ref: String) : FileTap
    data class Picture(val ref: String, val name: String) : FileTap
    data class Report(val target: String, val name: String) : FileTap
    data object None : FileTap

    companion object {
        fun of(file: FileRef, macShares: Boolean): FileTap {
            val ref = file.ref
            return when {
                file.url != null -> Web(file.url)
                ref == null -> None
                file.kind == "image" -> Picture(ref, file.name)
                macShares -> Shared(ref)
                file.name.endsWith(".html") || file.name.endsWith(".htm") -> Report("file:$ref", file.name)
                else -> None
            }
        }
    }
}

fun sizeLabel(bytes: Long): String = when {
    bytes >= 1_048_576 -> "${(bytes / 104_857.6).toInt() / 10.0} MB"
    bytes >= 1024 -> "${bytes / 1024} KB"
    else -> "$bytes B"
}

// MARK: Events, decisions

@Composable
private fun EventLine(entry: Entry) {
    val c = Bulava.colors
    Row(Modifier.fillMaxWidth().padding(horizontal = Metrics.gutter, vertical = 6.dp), verticalAlignment = Alignment.Top) {
        StatusDot(if (entry.tone == "neutral") "neutral" else when (entry.tone) {
            "good" -> "good"; "attention" -> "attention"; "problem" -> "problem"; else -> "neutral"
        }, Modifier.padding(top = 6.dp), size = 6.dp)
        Spacer(Modifier.width(10.dp))
        Text(entry.text, style = Bulava.type.caption, color = c.textSecondary)
    }
}

@Composable
private fun DecisionNote(entry: Entry) {
    val c = Bulava.colors
    Column(
        Modifier.fillMaxWidth().padding(horizontal = Metrics.gutter, vertical = 6.dp)
            .clip(RoundedCornerShape(Metrics.radiusCard)).background(c.accentSoft).padding(14.dp),
    ) {
        Eyebrow(stringResource(Res.string.decision_label), color = c.accentEmphasis)
        Spacer(Modifier.height(4.dp))
        Text(entry.text, style = Bulava.type.callout, color = c.text)
    }
}

// MARK: Asks

/** Something between a message and its answer, with the Mac's own buttons for it. */
@Composable
fun AskCard(ask: Ask, ctx: ChatContext) {
    val c = Bulava.colors
    Column(
        Modifier.fillMaxWidth().clip(RoundedCornerShape(Metrics.radiusCard)).background(toneWash(ask.tone)).padding(14.dp),
    ) {
        Text(ask.title, style = Bulava.type.callout, color = c.text)
        ask.detail?.let {
            Spacer(Modifier.height(6.dp))
            Text(it, style = Bulava.type.caption, color = c.textSecondary)
        }
        ask.code?.let {
            Spacer(Modifier.height(8.dp))
            Text(it, style = Bulava.type.mono.copy(fontSize = Bulava.type.meta.fontSize), color = c.textSecondary, maxLines = 10,
                overflow = TextOverflow.Ellipsis)
        }
        if (ask.actions.isNotEmpty()) {
            Spacer(Modifier.height(12.dp))
            MacActions(ask.actions, onInvoke = { a, input -> ctx.controller.invokeNow(a, input) },
                enabled = ctx.writable && ctx.controller.link.isConnected)
        }
    }
}

// MARK: Questions

@Composable
private fun QuestionCard(entry: Entry, q: Question, ctx: ChatContext) {
    val c = Bulava.colors
    val picked = remember(entry.id) { mutableStateMapOf<Int, List<String>>() }
    var text by remember(entry.id) { mutableStateOf("") }
    val canAnswer = q.answerable && ctx.writable && ctx.controller.link.isConnected
    fun send(selections: List<List<String>>, typed: String) {
        ctx.controller.answer(entry.id, selections, typed)
        text = ""
        picked.clear()
    }
    Column(
        Modifier.fillMaxWidth().padding(horizontal = Metrics.gutter, vertical = 8.dp)
            .clip(RoundedCornerShape(Metrics.radiusCard)).border(1.dp, c.orange.copy(alpha = 0.35f), RoundedCornerShape(Metrics.radiusCard))
            .background(c.surface),
    ) {
        Column(Modifier.padding(16.dp)) {
            Eyebrow(q.eyebrow, color = c.orange)
            Spacer(Modifier.height(6.dp))
            Text(q.headline, style = Bulava.type.bodyStrong, color = c.text)
            q.situation?.let {
                Spacer(Modifier.height(6.dp))
                Text(it, style = Bulava.type.caption, color = c.textSecondary)
            }
            if (q.items.size > 1) {
                for ((i, item) in q.items.withIndex()) {
                    Spacer(Modifier.height(4.dp))
                    Text("${i + 1}. ${item.question}", style = Bulava.type.caption, color = c.textSecondary)
                }
            } else q.items.firstOrNull()?.takeIf { it.question != q.headline }?.let {
                Spacer(Modifier.height(4.dp))
                Text(it.question, style = Bulava.type.caption, color = c.textSecondary)
            }
        }
        for ((index, item) in q.items.withIndex()) {
            if (item.options.isEmpty()) continue
            Hairline()
            if (q.items.size > 1 || item.multiSelect) {
                Text(
                    listOfNotNull(if (q.items.size > 1) "${index + 1}. ${item.header ?: item.question}" else null,
                        if (item.multiSelect) stringResource(Res.string.question_several) else null).joinToString(" · "),
                    style = Bulava.type.meta, color = c.textFaint, modifier = Modifier.padding(start = 16.dp, end = 16.dp, top = 10.dp),
                )
            }
            for (option in item.options) {
                val selected = picked[index]?.contains(option.label) == true
                Row(
                    Modifier.fillMaxWidth().systemClickable(enabled = canAnswer, role = Role.Button) {
                        if (q.items.size <= 1 && !item.multiSelect) {
                            send(listOf(listOf(option.label)), "")
                        } else {
                            val now = picked[index].orEmpty()
                            picked[index] = if (item.multiSelect) {
                                if (option.label in now) now - option.label else now + option.label
                            } else listOf(option.label)
                        }
                    }.padding(horizontal = 16.dp, vertical = 12.dp),
                    verticalAlignment = Alignment.Top,
                ) {
                    Icon(if (selected) Icons.Check else Icons.ChevronRight, null,
                        tint = if (selected) c.accent else c.textFaint, modifier = Modifier.size(16.dp).padding(top = 2.dp))
                    Spacer(Modifier.width(10.dp))
                    Column {
                        Text(option.label, style = Bulava.type.callout, color = c.text)
                        option.detail?.takeIf { it.isNotBlank() }?.let { Text(it, style = Bulava.type.meta, color = c.textFaint) }
                    }
                }
            }
        }
        val context = listOfNotNull(
            q.recommendation?.let { stringResource(Res.string.question_i_would) to it },
            q.ifUnanswered?.let { stringResource(Res.string.question_if_never) to it },
            q.unblocks?.let { stringResource(Res.string.question_unblocks) to it },
        )
        if (context.isNotEmpty()) {
            Hairline()
            Column(Modifier.fillMaxWidth().background(c.surfaceMuted).padding(16.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
                for ((label, value) in context) {
                    Column {
                        Eyebrow(label)
                        Text(value, style = Bulava.type.caption, color = c.textSecondary)
                    }
                }
            }
        }
        if (q.answerable && ctx.writable) {
            Hairline()
            Column(Modifier.padding(12.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
                BulavaTextField(text, { text = it }, stringResource(Res.string.question_answer_hint))
                val selections = q.items.indices.map { picked[it].orEmpty() }
                BulavaButton(
                    stringResource(Res.string.question_send), { send(selections, text.trim()) }, Modifier.fillMaxWidth(),
                    enabled = canAnswer && (text.isNotBlank() || selections.any { it.isNotEmpty() }),
                )
            }
        }
    }
}

// MARK: Reports

@Composable
private fun ReportCard(card: Card, ctx: ChatContext) {
    val c = Bulava.colors
    Column(
        Modifier.fillMaxWidth().padding(horizontal = Metrics.gutter, vertical = 8.dp)
            .clip(RoundedCornerShape(Metrics.radiusCard)).border(1.dp, c.lineStrong, RoundedCornerShape(Metrics.radiusCard))
            .background(c.surface).padding(16.dp),
    ) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Box(Modifier.size(40.dp).clip(RoundedCornerShape(10.dp)).background(toneWash(card.status.tone)), contentAlignment = Alignment.Center) {
                Icon(Icons.Document, null, tint = toneColor(card.status.tone), modifier = Modifier.size(20.dp))
            }
            Spacer(Modifier.width(12.dp))
            Column(Modifier.weight(1f)) {
                Text(card.title, style = Bulava.type.bodyStrong, color = c.text, maxLines = 2, overflow = TextOverflow.Ellipsis)
                Text(card.subtitle ?: card.status.label, style = Bulava.type.meta, color = c.textFaint, maxLines = 2,
                    overflow = TextOverflow.Ellipsis)
            }
        }
        if (card.actions.isNotEmpty()) {
            Spacer(Modifier.height(12.dp))
            MacActions(
                card.actions,
                onInvoke = { a, input -> ctx.controller.invokeNow(a, input) },
                onCompose = { a -> ctx.onCompose(a.input?.placeholder ?: a.label) },
                onReport = { a -> a.target?.let { ctx.onOpenReport(it, card.title) } },
                enabled = ctx.writable && ctx.controller.link.isConnected,
            )
        }
    }
}
