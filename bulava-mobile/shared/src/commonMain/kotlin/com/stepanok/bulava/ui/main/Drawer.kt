package com.stepanok.bulava.ui.main

import com.stepanok.bulava.ui.system.systemClickable
import com.stepanok.bulava.ui.system.AlertButton
import com.stepanok.bulava.ui.system.SystemAlert
import com.stepanok.bulava.ui.system.SystemPrompt
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateMapOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.rotate
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import com.stepanok.bulava.link.ChatSummary
import com.stepanok.bulava.link.Home
import com.stepanok.bulava.link.LinkState
import com.stepanok.bulava.link.Product
import com.stepanok.bulava.resources.Res
import com.stepanok.bulava.resources.action_cancel
import com.stepanok.bulava.resources.action_save
import com.stepanok.bulava.resources.app_name
import com.stepanok.bulava.resources.menu_pin
import com.stepanok.bulava.resources.menu_rename
import com.stepanok.bulava.resources.menu_unpin
import com.stepanok.bulava.resources.product_menu
import com.stepanok.bulava.resources.remove_product
import com.stepanok.bulava.resources.remove_product_body
import com.stepanok.bulava.resources.remove_product_title
import com.stepanok.bulava.resources.rename_product_title
import com.stepanok.bulava.resources.drawer_archived
import com.stepanok.bulava.resources.drawer_new_chat
import com.stepanok.bulava.resources.drawer_no_chats
import com.stepanok.bulava.resources.drawer_no_products
import com.stepanok.bulava.resources.drawer_no_results
import com.stepanok.bulava.resources.drawer_search
import com.stepanok.bulava.resources.drawer_settings
import com.stepanok.bulava.resources.status_connected
import com.stepanok.bulava.resources.status_connecting
import com.stepanok.bulava.resources.status_incompatible
import com.stepanok.bulava.resources.status_offline
import com.stepanok.bulava.state.AppController
import com.stepanok.bulava.ui.components.BrandTile
import com.stepanok.bulava.ui.components.Hairline
import com.stepanok.bulava.ui.components.IconAction
import com.stepanok.bulava.ui.components.ListRow
import com.stepanok.bulava.ui.components.Monogram
import com.stepanok.bulava.ui.components.StatusDot
import com.stepanok.bulava.ui.components.dismissKeyboardOnTapOrDrag
import com.stepanok.bulava.ui.theme.Bulava
import com.stepanok.bulava.ui.theme.Icons
import com.stepanok.bulava.ui.theme.Metrics
import com.stepanok.bulava.resources.cd_clear
import org.jetbrains.compose.resources.stringResource

@Composable
fun Drawer(
    controller: AppController,
    home: Home?,
    link: LinkState,
    selectedChatID: String?,
    onOpenChat: (productID: String, chatID: String) -> Unit,
    onNewChat: (productID: String) -> Unit,
    onOpenSettings: () -> Unit,
) {
    val c = Bulava.colors
    var query by remember { mutableStateOf("") }
    val collapsed = remember { mutableStateMapOf<String, Boolean>() }
    val archivesOpen = remember { mutableStateMapOf<String, Boolean>() }
    val products = home?.products.orEmpty().sortedWith(compareByDescending<Product> { it.pinned }.thenByDescending { it.lastWorkedAtMs ?: 0L })
    val attention = home?.attention.orEmpty()
    val waiting = attention.mapNotNull { it.chatID }.toSet()

    Column(Modifier.fillMaxHeight().statusBarsPadding().navigationBarsPadding()) {
        // Who this phone is connected to, in words.
        Row(Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 14.dp), verticalAlignment = Alignment.CenterVertically) {
            BrandTile(32.dp)
            Spacer(Modifier.width(12.dp))
            Column(Modifier.weight(1f)) {
                Text(stringResource(Res.string.app_name), style = Bulava.type.bodyStrong, color = c.text)
                val mac = controller.link.paired?.name ?: ""
                val (tone, line) = when (link) {
                    is LinkState.Connected -> "good" to stringResource(Res.string.status_connected, link.desktop.name)
                    is LinkState.Connecting -> "neutral" to stringResource(Res.string.status_connecting, mac)
                    is LinkState.Incompatible -> "problem" to stringResource(Res.string.status_incompatible)
                    else -> "attention" to stringResource(Res.string.status_offline, mac)
                }
                Row(verticalAlignment = Alignment.CenterVertically) {
                    StatusDot(tone, size = 6.dp)
                    Spacer(Modifier.width(6.dp))
                    Text(line, style = Bulava.type.meta, color = c.textSecondary, maxLines = 1, overflow = TextOverflow.Ellipsis)
                }
            }
        }

        SearchField(query) { query = it }

        // Searching, then scrolling through what was found, or tapping beside it, puts the keyboard away.
        LazyColumn(Modifier.weight(1f).dismissKeyboardOnTapOrDrag(), contentPadding = PaddingValues(horizontal = 8.dp, vertical = 4.dp)) {
            if (products.isEmpty()) {
                item {
                    Text(stringResource(Res.string.drawer_no_products), style = Bulava.type.caption, color = c.textFaint,
                        modifier = Modifier.padding(16.dp))
                }
            }
            val q = query.trim()
            if (q.isNotEmpty()) {
                val hits = products.flatMap { p -> (p.chats + p.archivedChats).filter { it.title.contains(q, ignoreCase = true) }.map { p to it } }
                if (hits.isEmpty()) {
                    item { Text(stringResource(Res.string.drawer_no_results), style = Bulava.type.caption, color = c.textFaint, modifier = Modifier.padding(16.dp)) }
                }
                items(hits, key = { "hit-" + it.second.id }) { (p, chat) ->
                    ListRow(chat.title, subtitle = p.name, selected = chat.id == selectedChatID,
                        trailing = liveMark(chat.status.active, chat.status.tone, chat.id in waiting),
                        onClick = { onOpenChat(p.id, chat.id) })
                }
            } else {
                for (product in products) {
                    val open = collapsed[product.id] != true
                    item(key = "p-" + product.id) {
                        ProductHeader(product, open, controller, onToggle = { collapsed[product.id] = open }, onNewChat = { onNewChat(product.id) })
                    }
                    if (open) {
                        if (product.chats.isEmpty()) {
                            item(key = "empty-" + product.id) {
                                Text(stringResource(Res.string.drawer_no_chats), style = Bulava.type.meta, color = c.textFaint,
                                    modifier = Modifier.padding(start = 52.dp, top = 4.dp, bottom = 8.dp))
                            }
                        }
                        items(product.chats, key = { "c-" + it.id }) { chat ->
                            ChatRow(chat, selected = chat.id == selectedChatID, waiting = chat.id in waiting) { onOpenChat(product.id, chat.id) }
                        }
                        if (product.archivedChats.isNotEmpty()) {
                            val showArchive = archivesOpen[product.id] == true
                            item(key = "a-" + product.id) {
                                Row(
                                    Modifier.fillMaxWidth().padding(start = 40.dp).height(40.dp).clip(RoundedCornerShape(8.dp))
                                        .systemClickable(pressedFill = Bulava.colors.surfaceMuted, role = Role.Button) { archivesOpen[product.id] = !showArchive }.padding(horizontal = 12.dp),
                                    verticalAlignment = Alignment.CenterVertically,
                                ) {
                                    Icon(Icons.Archive, null, tint = c.textFaint, modifier = Modifier.size(16.dp))
                                    Spacer(Modifier.width(8.dp))
                                    Text("${stringResource(Res.string.drawer_archived)} · ${product.archivedChats.size}", style = Bulava.type.meta, color = c.textFaint)
                                }
                            }
                            if (showArchive) {
                                items(product.archivedChats, key = { "ac-" + it.id }) { chat ->
                                    ChatRow(chat, selected = chat.id == selectedChatID, muted = true) { onOpenChat(product.id, chat.id) }
                                }
                            }
                        }
                    }
                }
            }
        }
        Hairline()
        // As at the foot of the Mac's sidebar, above the way to the settings.
        home?.limits?.takeIf { it.engines.isNotEmpty() }?.let { LimitsSection(it, controller) }
        ListRow(
            stringResource(Res.string.drawer_settings), modifier = Modifier.padding(8.dp),
            leading = { Icon(Icons.Settings, null, tint = c.textSecondary, modifier = Modifier.size(20.dp)) },
            onClick = onOpenSettings,
        )
    }
}

@Composable
private fun ProductHeader(product: Product, open: Boolean, controller: AppController, onToggle: () -> Unit, onNewChat: () -> Unit) {
    val c = Bulava.colors
    var menu by remember { mutableStateOf(false) }
    var renaming by remember { mutableStateOf(false) }
    var removing by remember { mutableStateOf(false) }
    Row(Modifier.fillMaxWidth().padding(top = 14.dp), verticalAlignment = Alignment.CenterVertically) {
        Row(
            Modifier.weight(1f).height(Metrics.touch).clip(RoundedCornerShape(Metrics.radiusControl))
                .systemClickable(role = Role.Button, onClick = onToggle).padding(horizontal = 8.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Monogram(product.initials)
            Spacer(Modifier.width(12.dp))
            Text(product.name, style = Bulava.type.bodyStrong.copy(fontWeight = FontWeight.SemiBold), color = c.text,
                maxLines = 1, overflow = TextOverflow.Ellipsis, modifier = Modifier.weight(1f, fill = false))
            product.status?.let { status ->
                // Working, waiting or failed; a product whose work is done carries no mark, as on the Mac.
                if (status.active || status.tone == "attention" || status.tone == "problem") {
                    Spacer(Modifier.width(8.dp))
                    StatusDot(status.tone, size = 7.dp)
                }
            }
            Spacer(Modifier.width(4.dp))
            Icon(Icons.ChevronDown, null, tint = c.textFaint, modifier = Modifier.size(16.dp).rotate(if (open) 0f else -90f))
        }
        if (controller.can("products.manage")) {
            Box {
                IconAction(Icons.Dots, stringResource(Res.string.product_menu), { menu = true }, tint = c.textFaint, size = 18.dp)
                DropdownMenu(menu, { menu = false }, containerColor = c.surface) {
                    DropdownMenuItem(text = { Text(stringResource(Res.string.menu_rename)) }, onClick = { menu = false; renaming = true })
                    DropdownMenuItem(
                        text = { Text(stringResource(if (product.pinned) Res.string.menu_unpin else Res.string.menu_pin)) },
                        onClick = { menu = false; controller.setProductPinned(product.id, !product.pinned) })
                    DropdownMenuItem(text = { Text(stringResource(Res.string.remove_product), color = c.red) },
                        onClick = { menu = false; removing = true })
                }
            }
        }
        IconAction(Icons.Plus, stringResource(Res.string.drawer_new_chat), onNewChat, tint = c.textSecondary, size = 20.dp)
    }

    if (renaming) {
        SystemPrompt(
            title = stringResource(Res.string.rename_product_title), value = product.name, placeholder = product.name,
            confirm = stringResource(Res.string.action_save), cancel = stringResource(Res.string.action_cancel),
            onConfirm = { name -> renaming = false; controller.renameProduct(product.id, name) },
            onDismiss = { renaming = false },
        )
    }
    if (removing) {
        SystemAlert(
            title = stringResource(Res.string.remove_product_title, product.name),
            message = stringResource(Res.string.remove_product_body),
            buttons = listOf(
                AlertButton(stringResource(Res.string.action_cancel), AlertButton.Style.Cancel) { removing = false },
                AlertButton(stringResource(Res.string.remove_product), AlertButton.Style.Destructive) {
                    removing = false; controller.removeProduct(product.id)
                },
            ),
            onDismiss = { removing = false },
        )
    }
}

@Composable
private fun ChatRow(chat: ChatSummary, selected: Boolean, muted: Boolean = false, waiting: Boolean = false, onClick: () -> Unit) {
    val c = Bulava.colors
    Row(
        Modifier.fillMaxWidth().padding(start = 40.dp).height(44.dp).clip(RoundedCornerShape(Metrics.radiusControl))
            .background(if (selected) c.accentSoft else androidx.compose.ui.graphics.Color.Transparent)
            .systemClickable(pressedFill = Bulava.colors.surfaceMuted, role = Role.Button, onClick = onClick).padding(horizontal = 12.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        if (chat.pinned) {
            Icon(Icons.Pin, null, tint = c.textFaint, modifier = Modifier.size(14.dp))
            Spacer(Modifier.width(6.dp))
        }
        Text(chat.title, style = Bulava.type.callout, color = when {
            selected -> c.accentEmphasis
            muted -> c.textFaint
            else -> c.textSecondary
        }, maxLines = 1, overflow = TextOverflow.Ellipsis, modifier = Modifier.weight(1f))
        liveMark(chat.status.active, chat.status.tone, waiting)?.let {
            Spacer(Modifier.width(8.dp))
            it()
        }
    }
}

/**
 * A chat's mark in a list: working, waiting for the director, or failed — each goes by itself when
 * the state changes. An answer that came in is not marked: it stays answered, and a mark for it
 * would sit on every chat that ever finished, as the Mac's sidebar no longer does either.
 */
private fun liveMark(active: Boolean, tone: String, waiting: Boolean): (@Composable () -> Unit)? {
    if (!active && !waiting && tone != "attention" && tone != "problem") return null
    return { StatusDot(if (waiting && !active) "attention" else tone, size = 7.dp) }
}

/**
 * A search that takes the keyboard only when asked. A live field here was focused the moment the
 * drawer opened, and the keyboard came up over the chat list every time.
 */
@Composable
private fun SearchField(query: String, onChange: (String) -> Unit) {
    val c = Bulava.colors
    var searching by remember { mutableStateOf(query.isNotEmpty()) }
    val focus = remember { FocusRequester() }
    val label = stringResource(Res.string.drawer_search)
    Row(
        Modifier.padding(horizontal = 16.dp, vertical = 4.dp).fillMaxWidth().height(Metrics.touch)
            .clip(RoundedCornerShape(Metrics.radiusControl)).background(c.surfaceMuted)
            .systemClickable(enabled = !searching, role = Role.Button) { searching = true }
            .padding(horizontal = 12.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Icon(Icons.Search, null, tint = c.textFaint, modifier = Modifier.size(18.dp))
        Spacer(Modifier.width(8.dp))
        Box(Modifier.weight(1f)) {
            if (query.isEmpty()) Text(stringResource(Res.string.drawer_search), style = Bulava.type.callout, color = c.textFaint)
            if (searching) {
                BasicTextField(query, onChange, singleLine = true, textStyle = Bulava.type.callout.copy(color = c.text),
                    cursorBrush = SolidColor(c.accent),
                    modifier = Modifier.fillMaxWidth().focusRequester(focus)
                        .semantics { contentDescription = label })
                LaunchedEffect(Unit) { runCatching { focus.requestFocus() } }
            }
        }
        if (searching) {
            IconAction(Icons.Close, stringResource(Res.string.cd_clear), { onChange(""); searching = false },
                tint = c.textFaint, size = 16.dp)
        }
    }
}
