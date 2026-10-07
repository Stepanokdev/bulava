package com.stepanok.bulava.ui.context

import com.stepanok.bulava.ui.system.systemClickable
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import com.stepanok.bulava.link.Card
import com.stepanok.bulava.link.Context
import com.stepanok.bulava.resources.Res
import com.stepanok.bulava.resources.check_fail
import com.stepanok.bulava.resources.check_other
import com.stepanok.bulava.resources.check_pass
import com.stepanok.bulava.resources.context_changes
import com.stepanok.bulava.resources.context_checks
import com.stepanok.bulava.resources.context_failed
import com.stepanok.bulava.resources.context_folders
import com.stepanok.bulava.resources.context_instructions
import com.stepanok.bulava.resources.context_loading
import com.stepanok.bulava.resources.context_missing
import com.stepanok.bulava.resources.context_next
import com.stepanok.bulava.resources.context_primary
import com.stepanok.bulava.resources.context_skills
import com.stepanok.bulava.resources.context_report_preparing
import com.stepanok.bulava.resources.context_reports
import com.stepanok.bulava.resources.context_stale
import com.stepanok.bulava.resources.context_variants
import com.stepanok.bulava.resources.context_work
import com.stepanok.bulava.state.AppController
import com.stepanok.bulava.ui.components.BulavaButton
import com.stepanok.bulava.ui.components.ButtonKind
import com.stepanok.bulava.ui.components.Eyebrow
import com.stepanok.bulava.ui.components.Hairline
import com.stepanok.bulava.ui.components.MacActions
import com.stepanok.bulava.ui.components.SectionHeader
import com.stepanok.bulava.ui.components.StatusDot
import com.stepanok.bulava.ui.components.ScreenBar
import com.stepanok.bulava.ui.theme.Bulava
import com.stepanok.bulava.ui.theme.Icons
import com.stepanok.bulava.ui.theme.Metrics
import com.stepanok.bulava.ui.theme.toneColor
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import org.jetbrains.compose.resources.stringResource

/**
 * The Mac's right-hand pane beside a chat (`ProductInspector`), on its own screen: the project's
 * folders and whether work may change them, what changed in them (tap for the diff), the last
 * checks, this chat's reports with "Create report", and the instructions — in the Mac's order.
 * Below them what the phone adds from the rest of the Mac's window: what is next, the pieces of
 * work, everything done so far.
 *
 * Read again every four seconds while it is open, as the Mac's pane is, so a file changed or a
 * report made meanwhile shows up here. When a read fails, what came before stays and the screen
 * says the Mac is not answering, rather than showing an empty project.
 */
@Composable
fun ContextScreen(
    controller: AppController,
    productID: String,
    chatID: String?,
    title: String,
    onBack: () -> Unit,
    onOpenDiff: (ref: String, title: String) -> Unit,
    onOpenReport: (target: String, title: String) -> Unit,
    onOpenSkills: () -> Unit,
    onCompose: (String?) -> Unit,
) {
    val c = Bulava.colors
    // Keyed by the chat: another chat's details never show what this one's read brought back.
    var context by remember(productID, chatID) { mutableStateOf<Context?>(null) }
    var failed by remember(productID, chatID) { mutableStateOf(false) }
    var stale by remember(productID, chatID) { mutableStateOf(false) }
    var reload by remember { mutableIntStateOf(0) }
    val scope = rememberCoroutineScope()
    LaunchedEffect(productID, chatID, reload) {
        while (true) {
            val next = controller.context(productID, chatID)
            if (next != null) {
                context = next
                failed = false
                stale = false
            } else {
                failed = context == null
                stale = context != null
            }
            delay(REFRESH_MS)
        }
    }
    suspend fun press(action: com.stepanok.bulava.link.Action, input: String?): Boolean =
        controller.invokeNow(action, input).also { if (it) reload++ }

    Column(Modifier.fillMaxSize().background(c.background).statusBarsPadding()) {
        ScreenBar(title, onBack)
        val ctx = context
        when {
            ctx == null && failed -> Box(Modifier.fillMaxSize().padding(32.dp), contentAlignment = Alignment.Center) {
                Text(stringResource(Res.string.context_failed), style = Bulava.type.callout, color = c.textSecondary)
            }
            ctx == null -> Column(Modifier.fillMaxSize(), verticalArrangement = Arrangement.Center, horizontalAlignment = Alignment.CenterHorizontally) {
                CircularProgressIndicator(Modifier.size(24.dp), strokeWidth = 2.dp, color = c.accent)
                Text(stringResource(Res.string.context_loading), style = Bulava.type.caption, color = c.textSecondary,
                    modifier = Modifier.padding(12.dp))
            }
            else -> Column(Modifier.fillMaxSize().verticalScroll(rememberScrollState()).navigationBarsPadding().padding(bottom = 24.dp)) {
                if (stale) {
                    Text(stringResource(Res.string.context_stale), style = Bulava.type.meta, color = c.orange,
                        modifier = Modifier.fillMaxWidth().background(c.orangeSoft).padding(horizontal = Metrics.gutter, vertical = 8.dp))
                }

                SectionHeader(stringResource(Res.string.context_folders))
                for (r in ctx.resources) {
                    Column(Modifier.fillMaxWidth().padding(horizontal = Metrics.gutter, vertical = 8.dp)) {
                        Row(verticalAlignment = Alignment.CenterVertically) {
                            Icon(if (r.kind == "website") Icons.External else Icons.Document, null, tint = c.textSecondary,
                                modifier = Modifier.size(18.dp))
                            Spacer(Modifier.width(10.dp))
                            Text(r.name, style = Bulava.type.bodyStrong, color = if (r.live) c.text else c.textFaint,
                                modifier = Modifier.weight(1f), maxLines = 1, overflow = TextOverflow.Ellipsis)
                            if (r.primary) Eyebrow(stringResource(Res.string.context_primary), color = c.accentEmphasis)
                        }
                        Text(listOfNotNull(r.kindLabel, r.accessLabel, r.branch).joinToString(" · "),
                            style = Bulava.type.meta, color = c.textFaint, modifier = Modifier.padding(start = 28.dp))
                        (r.path ?: r.url)?.let {
                            Text(it, style = Bulava.type.mono.copy(fontSize = Bulava.type.meta.fontSize), color = c.textFaint,
                                maxLines = 1, overflow = TextOverflow.StartEllipsis, modifier = Modifier.padding(start = 28.dp))
                        }
                        if (r.actions.isNotEmpty()) {
                            MacActions(r.actions, onInvoke = { a, input -> press(a, input) },
                                enabled = controller.link.isConnected, modifier = Modifier.padding(start = 28.dp, top = 6.dp))
                        }
                    }
                }

                // As on the Mac: the section is there while something is changed in these folders.
                if (ctx.changes.isNotEmpty()) {
                    SectionHeader(stringResource(Res.string.context_changes))
                    for (change in ctx.changes) {
                        Row(
                            Modifier.fillMaxWidth().systemClickable(pressedFill = Bulava.colors.surfaceMuted, role = Role.Button) { onOpenDiff(change.ref, change.path) }
                                .padding(horizontal = Metrics.gutter, vertical = 10.dp),
                            verticalAlignment = Alignment.CenterVertically,
                        ) {
                            Column(Modifier.weight(1f)) {
                                Text(change.path.substringAfterLast('/'), style = Bulava.type.callout, color = c.text, maxLines = 1)
                                Text(listOf(change.kindLabel, change.project, change.path).filter { it.isNotBlank() }.joinToString(" · "),
                                    style = Bulava.type.meta, color = c.textFaint, maxLines = 1, overflow = TextOverflow.StartEllipsis)
                            }
                            change.added?.let { Text("+$it", style = Bulava.type.meta.copy(fontFamily = FontFamily.Monospace), color = c.green) }
                            change.removed?.let {
                                Spacer(Modifier.width(6.dp))
                                Text("−$it", style = Bulava.type.meta.copy(fontFamily = FontFamily.Monospace), color = c.red)
                            }
                            Icon(Icons.ChevronRight, null, tint = c.textFaint, modifier = Modifier.size(16.dp).padding(start = 4.dp))
                        }
                    }
                }

                ctx.checks?.let { checks ->
                    SectionHeader(stringResource(Res.string.context_checks))
                    for (check in checks.items) {
                        Row(Modifier.fillMaxWidth().padding(horizontal = Metrics.gutter, vertical = 6.dp), verticalAlignment = Alignment.Top) {
                            StatusDot(when (check.status) { "pass" -> "good"; "fail" -> "problem"; else -> "attention" },
                                Modifier.padding(top = 6.dp), size = 7.dp)
                            Spacer(Modifier.width(10.dp))
                            Column {
                                Text(check.criterion, style = Bulava.type.callout, color = c.text)
                                Text(
                                    listOf(
                                        when (check.status) {
                                            "pass" -> stringResource(Res.string.check_pass)
                                            "fail" -> stringResource(Res.string.check_fail)
                                            else -> stringResource(Res.string.check_other)
                                        },
                                        check.note,
                                    ).filter { it.isNotBlank() }.joinToString(" · "),
                                    style = Bulava.type.meta, color = c.textFaint,
                                )
                            }
                        }
                    }
                }

                ctx.chatReports?.let { reports ->
                    SectionHeader(stringResource(Res.string.context_reports))
                    ChatReportsSection(reports, controller.link.isConnected, onCreate = { a -> scope.launch { press(a, null) } },
                        onOpen = { r -> r.open.target?.let { onOpenReport(it, r.detail.ifBlank { r.title }) } })
                }

                ctx.instructions?.let { ins ->
                    SectionHeader(stringResource(Res.string.context_instructions))
                    Column(Modifier.padding(horizontal = Metrics.gutter), verticalArrangement = Arrangement.spacedBy(6.dp)) {
                        if (ins.summary.isNotBlank()) Text(ins.summary, style = Bulava.type.callout, color = c.textSecondary)
                        if (ins.brief.isNotBlank()) Text(ins.brief, style = Bulava.type.caption, color = c.textSecondary)
                    }
                }

                if (ctx.nowAndNext.isNotEmpty()) {
                    SectionHeader(stringResource(Res.string.context_next))
                    for (card in ctx.nowAndNext) CardRow(card, controller, onOpenReport, onCompose, ::press)
                }

                if (ctx.work.isNotEmpty()) {
                    SectionHeader(stringResource(Res.string.context_work))
                    for (work in ctx.work) {
                        Column(
                            Modifier.fillMaxWidth().padding(horizontal = Metrics.gutter, vertical = 6.dp)
                                .clip(RoundedCornerShape(Metrics.radiusCard)).border(1.dp, c.line, RoundedCornerShape(Metrics.radiusCard))
                                .background(c.surface).padding(14.dp),
                            verticalArrangement = Arrangement.spacedBy(8.dp),
                        ) {
                            Row(verticalAlignment = Alignment.CenterVertically) {
                                StatusDot(work.status.tone, size = 7.dp)
                                Spacer(Modifier.width(8.dp))
                                Text(work.title, style = Bulava.type.bodyStrong, color = c.text, modifier = Modifier.weight(1f))
                            }
                            Text(listOfNotNull(
                                if (work.kind == "variants") stringResource(Res.string.context_variants) else null,
                                work.status.label,
                                if (work.missing > 0) stringResource(Res.string.context_missing, work.missing) else null,
                            ).joinToString(" · "), style = Bulava.type.meta, color = c.textFaint)
                            for (part in work.parts) {
                                Hairline()
                                CardRow(part, controller, onOpenReport, onCompose, ::press, inset = false)
                            }
                            work.report?.let { r -> BulavaButton(r.label, { r.target?.let { onOpenReport(it, work.title) } }, kind = ButtonKind.Secondary, icon = Icons.Document) }
                        }
                    }
                }

                Spacer(Modifier.height(16.dp))
                com.stepanok.bulava.ui.components.FlowRowCompat(Modifier.padding(horizontal = Metrics.gutter)) {
                    ctx.report?.let { r -> BulavaButton(r.label, { r.target?.let { onOpenReport(it, title) } }, kind = ButtonKind.Secondary, icon = Icons.Document) }
                    if (controller.can("skills")) BulavaButton(stringResource(Res.string.context_skills), onOpenSkills, kind = ButtonKind.Secondary, icon = Icons.Tune)
                }
            }
        }
    }
}

/** How often the open details are read again — the Mac's pane does it every four seconds. */
private const val REFRESH_MS = 4_000L

/**
 * The Mac panel's Reports: "Create report" first, saying where it is kept, then every report of
 * the chat, newest first, each by when it was made and what it is about.
 */
@Composable
private fun ChatReportsSection(
    reports: com.stepanok.bulava.link.ChatReports,
    connected: Boolean,
    onCreate: (com.stepanok.bulava.link.Action) -> Unit,
    onOpen: (com.stepanok.bulava.link.ChatReport) -> Unit,
) {
    val c = Bulava.colors
    Column(
        Modifier.fillMaxWidth().padding(horizontal = Metrics.gutter).clip(RoundedCornerShape(Metrics.radiusCard))
            .border(1.dp, c.line, RoundedCornerShape(Metrics.radiusCard)).background(c.surface),
    ) {
        reports.create?.let { create ->
            val enabled = connected && !reports.generating
            Row(
                Modifier.fillMaxWidth().systemClickable(enabled = enabled, role = Role.Button) { onCreate(create) }
                    .padding(horizontal = 14.dp, vertical = 12.dp),
                verticalAlignment = Alignment.Top,
            ) {
                Box(Modifier.size(20.dp), contentAlignment = Alignment.Center) {
                    if (reports.generating) CircularProgressIndicator(Modifier.size(16.dp), strokeWidth = 2.dp, color = c.accent)
                    else Icon(Icons.Plus, null, tint = c.accentEmphasis, modifier = Modifier.size(18.dp))
                }
                Spacer(Modifier.width(10.dp))
                Column(Modifier.weight(1f)) {
                    Text(if (reports.generating) stringResource(Res.string.context_report_preparing) else create.label,
                        style = Bulava.type.callout, color = if (enabled) c.text else c.textSecondary)
                    if (reports.note.isNotBlank()) Text(reports.note, style = Bulava.type.meta, color = c.textFaint)
                }
            }
        }
        reports.items.forEachIndexed { index, report ->
            if (index > 0 || reports.create != null) Hairline()
            Row(
                Modifier.fillMaxWidth().systemClickable(pressedFill = Bulava.colors.surfaceMuted, role = Role.Button) { onOpen(report) }.padding(horizontal = 14.dp, vertical = 11.dp),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Icon(Icons.Document, null, tint = c.accentEmphasis, modifier = Modifier.size(18.dp))
                Spacer(Modifier.width(10.dp))
                Column(Modifier.weight(1f)) {
                    Text(report.title, style = Bulava.type.callout, color = c.text)
                    if (report.detail.isNotBlank()) {
                        Text(report.detail, style = Bulava.type.meta, color = c.textFaint, maxLines = 2, overflow = TextOverflow.Ellipsis)
                    }
                }
                Icon(Icons.ChevronRight, null, tint = c.textFaint, modifier = Modifier.size(16.dp))
            }
        }
    }
}

@Composable
private fun CardRow(
    card: Card,
    controller: AppController,
    onOpenReport: (String, String) -> Unit,
    onCompose: (String?) -> Unit,
    press: suspend (com.stepanok.bulava.link.Action, String?) -> Boolean,
    inset: Boolean = true,
) {
    val c = Bulava.colors
    Column(Modifier.fillMaxWidth().padding(horizontal = if (inset) Metrics.gutter else 0.dp, vertical = 8.dp)) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Box(Modifier.size(8.dp).clip(RoundedCornerShape(4.dp)).background(toneColor(card.status.tone)))
            Spacer(Modifier.width(10.dp))
            Text(card.title, style = Bulava.type.callout, color = c.text, modifier = Modifier.weight(1f), maxLines = 2, overflow = TextOverflow.Ellipsis)
        }
        Text(card.subtitle ?: card.status.label, style = Bulava.type.meta, color = c.textFaint, maxLines = 2,
            overflow = TextOverflow.Ellipsis, modifier = Modifier.padding(start = 18.dp))
        if (card.actions.isNotEmpty()) {
            MacActions(
                card.actions, onInvoke = press,
                onCompose = { a -> onCompose(a.input?.placeholder ?: a.label) },
                onReport = { a -> a.target?.let { onOpenReport(it, card.title) } },
                enabled = controller.link.isConnected, modifier = Modifier.padding(start = 18.dp, top = 6.dp),
            )
        }
    }
}
