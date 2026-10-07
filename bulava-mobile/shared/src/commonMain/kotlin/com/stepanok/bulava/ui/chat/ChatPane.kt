package com.stepanok.bulava.ui.chat

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.derivedStateOf
import androidx.compose.runtime.getValue
import androidx.compose.runtime.remember
import androidx.compose.runtime.snapshotFlow
import androidx.compose.ui.draw.rotate
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.semantics.LiveRegionMode
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.liveRegion
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import com.stepanok.bulava.link.ChatState
import com.stepanok.bulava.link.Product
import com.stepanok.bulava.resources.Res
import com.stepanok.bulava.resources.action_close
import com.stepanok.bulava.resources.empty_chat_body
import com.stepanok.bulava.resources.find_count
import com.stepanok.bulava.resources.find_hint
import com.stepanok.bulava.resources.find_next
import com.stepanok.bulava.resources.find_none
import com.stepanok.bulava.resources.find_previous
import com.stepanok.bulava.resources.empty_chat_title
import com.stepanok.bulava.resources.queued_count
import com.stepanok.bulava.resources.show_earlier
import com.stepanok.bulava.state.AppController
import com.stepanok.bulava.ui.components.BulavaButton
import com.stepanok.bulava.ui.components.ButtonKind
import com.stepanok.bulava.ui.components.MacActions
import com.stepanok.bulava.ui.theme.Bulava
import com.stepanok.bulava.ui.theme.Icons
import com.stepanok.bulava.ui.theme.Metrics
import com.stepanok.bulava.ui.theme.toneColor
import kotlinx.coroutines.flow.distinctUntilChanged
import kotlinx.coroutines.flow.filter
import org.jetbrains.compose.resources.stringResource

/**
 * One conversation. Drawn bottom-up, so the newest line sits above the composer and the thread
 * follows a streaming answer by itself — and does not move under someone who scrolled back to read.
 */
@Composable
fun ChatPane(
    controller: AppController,
    product: Product,
    chatID: String,
    /** Whether the Mac already has this chat. A new one exists only here until its first message. */
    known: Boolean,
    /** What to find in this chat and which match is current, while the find bar is open. */
    find: Pair<String, Int>?,
    onCompose: (String?) -> Unit,
    onOpenReport: (String, String) -> Unit,
    onOpenImage: (String, String) -> Unit,
) {
    val chats by controller.chats.collectAsState()
    val outbox by controller.outbox.collectAsState()
    val link by controller.link.state.collectAsState()
    val view = chats[chatID]
    val mine = outbox.filter { it.chatID == chatID }
    val entries = view?.entries.orEmpty()
    val ctx = remember(chatID, product.id, view?.state?.archived, link) {
        ChatContext(controller, product.id, chatID, writable = view?.state?.archived != true,
            onCompose = onCompose, onOpenReport = onOpenReport, onOpenImage = onOpenImage)
    }
    val list = rememberLazyListState()

    // Scrolling to the top of what is loaded asks the Mac for the stretch before it.
    val nearTop by remember { derivedStateOf { list.layoutInfo.visibleItemsInfo.lastOrNull()?.index?.let { it >= list.layoutInfo.totalItemsCount - 2 } == true } }
    LaunchedEffect(chatID) {
        snapshotFlow { nearTop }.distinctUntilChanged().filter { it }.collect { controller.loadEarlier(chatID) }
    }

    // Find: newest match first, as the thread reads bottom-up.
    val matches = remember(entries, find?.first) { findMatches(entries, find?.first.orEmpty()) }
    LaunchedEffect(find, matches.size) {
        val f = find ?: return@LaunchedEffect
        if (matches.isEmpty()) return@LaunchedEffect
        val entryIndex = matches[((f.second % matches.size) + matches.size) % matches.size]
        val lazyIndex = (if (view?.state != null) 1 else 0) + mine.size + (entries.size - 1 - entryIndex)
        list.animateScrollToItem(lazyIndex)
    }

    if (entries.isEmpty() && mine.isEmpty()) {
        EmptyChat(product.name, loading = known && view == null)
        return
    }

    LazyColumn(
        state = list, reverseLayout = true, modifier = Modifier.fillMaxSize(),
        contentPadding = PaddingValues(top = 12.dp, bottom = 8.dp),
    ) {
        view?.state?.let { state ->
            item(key = "status") { StatusRow(state, ctx) }
        }
        items(mine.reversed(), key = { "out-" + it.entryID }) { OutgoingMessage(it, ctx) }
        items(entries.asReversed(), key = { it.id }) { EntryView(it, ctx) }
        if (view?.state?.hasEarlier == true) {
            item(key = "earlier") {
                Box(Modifier.fillMaxWidth().padding(12.dp), contentAlignment = Alignment.Center) {
                    if (view.loadingEarlier) {
                        CircularProgressIndicator(Modifier.size(20.dp), strokeWidth = 2.dp, color = Bulava.colors.textFaint)
                    } else {
                        BulavaButton(stringResource(Res.string.show_earlier), { controller.loadEarlier(chatID) }, kind = ButtonKind.Quiet)
                    }
                }
            }
        }
    }
}

/** What the run is doing right now, under the last message — the same line the Mac shows. */
@Composable
private fun StatusRow(state: ChatState, ctx: ChatContext) {
    val c = Bulava.colors
    val status = state.status
    val extra = state.actions.filter { it.id.startsWith("stop:").not() }
    // Nothing worth a line: an idle chat, or one that has not started. Its buttons still show.
    val silent = status.code == "new" || (!status.active && status.tone == "neutral" && state.queueCount == 0)
    if (silent && (extra.isEmpty() || !ctx.writable)) return
    Column(
        Modifier.fillMaxWidth().padding(horizontal = Metrics.gutter, vertical = 8.dp)
            .semantics { liveRegion = LiveRegionMode.Polite },
    ) {
        if (!silent) Row(
            Modifier.clip(RoundedCornerShape(Metrics.radiusControl))
                .background(if (status.active) c.surface else androidx.compose.ui.graphics.Color.Transparent)
                .padding(horizontal = if (status.active) 12.dp else 0.dp, vertical = 8.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            if (status.active) {
                CircularProgressIndicator(Modifier.size(14.dp), strokeWidth = 1.8.dp, color = c.accent)
            } else {
                Box(Modifier.size(8.dp).clip(RoundedCornerShape(4.dp)).background(toneColor(status.tone)))
            }
            Spacer(Modifier.width(10.dp))
            Column(Modifier.weight(1f, fill = false)) {
                Text(status.label, style = Bulava.type.caption.copy(fontWeight = FontWeight.Medium),
                    color = when (status.tone) { "problem" -> c.red; "attention" -> c.orange; else -> c.textSecondary })
                state.activity?.let { Text(it, style = Bulava.type.meta, color = c.textFaint, maxLines = 2) }
                state.degradation?.let { Text(it, style = Bulava.type.meta, color = c.textFaint, maxLines = 3) }
            }
            if (state.queueCount > 0) {
                Spacer(Modifier.width(10.dp))
                Icon(Icons.Refresh, null, tint = c.textFaint, modifier = Modifier.size(14.dp))
                Spacer(Modifier.width(4.dp))
                Text(stringResource(Res.string.queued_count, state.queueCount), style = Bulava.type.meta, color = c.textFaint)
            }
        }
        if (extra.isNotEmpty() && ctx.writable) {
            if (!silent) Spacer(Modifier.height(6.dp))
            MacActions(
                extra, onInvoke = { a, input -> ctx.controller.invokeNow(a, input) },
                onReport = { a -> a.target?.let { ctx.onOpenReport(it, state.title) } },
                enabled = ctx.controller.link.isConnected,
            )
        }
    }
}

@Composable
private fun EmptyChat(productName: String, loading: Boolean) {
    val c = Bulava.colors
    Column(
        Modifier.fillMaxSize().padding(horizontal = 28.dp),
        verticalArrangement = Arrangement.Center,
    ) {
        if (loading) {
            CircularProgressIndicator(Modifier.size(20.dp), strokeWidth = 2.dp, color = c.textFaint)
        } else {
            Text(stringResource(Res.string.empty_chat_title, productName), style = Bulava.type.display, color = c.text)
            Spacer(Modifier.height(12.dp))
            Text(stringResource(Res.string.empty_chat_body), style = Bulava.type.callout, color = c.textSecondary)
        }
    }
}

/** Indices of the entries that say [query], newest first. */
fun findMatches(entries: List<com.stepanok.bulava.link.Entry>, query: String): List<Int> {
    val q = query.trim()
    if (q.length < 2) return emptyList()
    return entries.indices.reversed().filter { i ->
        val e = entries[i]
        e.text.contains(q, ignoreCase = true) ||
            e.blocks.any { it.text.contains(q, ignoreCase = true) } ||
            e.question?.headline?.contains(q, ignoreCase = true) == true
    }
}

@Composable
fun FindBar(
    query: String,
    onQuery: (String) -> Unit,
    onStep: (Int) -> Unit,
    onClose: () -> Unit,
    controller: AppController,
    chatID: String?,
    cursor: Int,
) {
    val c = Bulava.colors
    val chats by controller.chats.collectAsState()
    val entries = chatID?.let { chats[it]?.entries }.orEmpty()
    val count = remember(entries, query) { findMatches(entries, query).size }
    val focus = remember { androidx.compose.ui.focus.FocusRequester() }
    val label = stringResource(Res.string.find_hint)
    LaunchedEffect(Unit) { runCatching { focus.requestFocus() } }
    Row(
        Modifier.fillMaxWidth().background(c.surface).padding(start = 16.dp, end = 4.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Icon(Icons.Search, null, tint = c.textFaint, modifier = Modifier.size(18.dp))
        Spacer(Modifier.width(8.dp))
        Box(Modifier.weight(1f).padding(vertical = 14.dp)) {
            if (query.isEmpty()) Text(stringResource(Res.string.find_hint), style = Bulava.type.callout, color = c.textFaint)
            androidx.compose.foundation.text.BasicTextField(
                query, onQuery, singleLine = true, textStyle = Bulava.type.callout.copy(color = c.text),
                cursorBrush = androidx.compose.ui.graphics.SolidColor(c.accent),
                modifier = Modifier.fillMaxWidth().focusRequester(focus)
                    .semantics { contentDescription = label },
            )
        }
        if (query.trim().length >= 2) {
            Text(
                if (count == 0) stringResource(Res.string.find_none)
                else stringResource(Res.string.find_count, ((cursor % count) + count) % count + 1, count),
                style = Bulava.type.meta, color = c.textFaint,
            )
        }
        // Up is older: the thread is read bottom-up, so the first match is the newest.
        com.stepanok.bulava.ui.components.IconAction(Icons.ChevronDown, stringResource(Res.string.find_previous),
            { onStep(1) }, enabled = count > 1, size = 18.dp, modifier = Modifier.rotate(180f))
        com.stepanok.bulava.ui.components.IconAction(Icons.ChevronDown, stringResource(Res.string.find_next),
            { onStep(-1) }, enabled = count > 1, size = 18.dp)
        com.stepanok.bulava.ui.components.IconAction(Icons.Close, stringResource(Res.string.action_close), onClose, tint = c.textSecondary, size = 18.dp)
    }
    com.stepanok.bulava.ui.components.Hairline()
}

