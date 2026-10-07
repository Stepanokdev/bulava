package com.stepanok.bulava.ui.main

import com.stepanok.bulava.ui.system.systemClickable
import com.stepanok.bulava.ui.system.AlertButton
import com.stepanok.bulava.ui.system.SystemAlert
import com.stepanok.bulava.ui.system.SystemPrompt
import androidx.compose.animation.AnimatedVisibility
import androidx.compose.foundation.background
import com.stepanok.bulava.ui.theme.Metrics
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.draw.clip
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.imePadding
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.layout.width
import androidx.compose.material3.DrawerValue
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.ModalDrawerSheet
import androidx.compose.material3.ModalNavigationDrawer
import androidx.compose.material3.Text
import androidx.compose.material3.rememberDrawerState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.Stable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.backhandler.BackHandler
import androidx.compose.ui.semantics.heading
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import com.stepanok.bulava.link.ChatSummary
import com.stepanok.bulava.link.Home
import com.stepanok.bulava.link.LinkState
import com.stepanok.bulava.link.Product
import com.stepanok.bulava.resources.Res
import com.stepanok.bulava.resources.action_cancel
import com.stepanok.bulava.resources.action_retry_now
import com.stepanok.bulava.resources.action_save
import com.stepanok.bulava.resources.archive_body
import com.stepanok.bulava.resources.archive_title
import com.stepanok.bulava.resources.drawer_new_chat
import com.stepanok.bulava.resources.empty_home_body
import com.stepanok.bulava.resources.empty_home_title
import com.stepanok.bulava.resources.menu_archive
import com.stepanok.bulava.resources.menu_find
import com.stepanok.bulava.resources.menu_context
import com.stepanok.bulava.resources.menu_pin
import com.stepanok.bulava.resources.menu_rename
import com.stepanok.bulava.resources.menu_unarchive
import com.stepanok.bulava.resources.menu_unpin
import com.stepanok.bulava.resources.rename_title
import com.stepanok.bulava.resources.status_connecting
import com.stepanok.bulava.resources.status_offline
import com.stepanok.bulava.resources.status_offline_body
import com.stepanok.bulava.state.AppController
import com.stepanok.bulava.ui.chat.ChatPane
import com.stepanok.bulava.ui.chat.Composer
import com.stepanok.bulava.ui.components.BulavaButton
import com.stepanok.bulava.ui.components.ButtonKind
import com.stepanok.bulava.ui.components.Hairline
import com.stepanok.bulava.ui.components.IconAction
import com.stepanok.bulava.ui.components.dismissKeyboardOnTapOrDrag
import com.stepanok.bulava.ui.theme.Bulava
import com.stepanok.bulava.ui.theme.Icons
import kotlinx.coroutines.launch
import com.stepanok.bulava.resources.cd_menu
import com.stepanok.bulava.resources.cd_more
import org.jetbrains.compose.resources.stringResource

/** Which product and chat are on screen. Remembered between launches. */
@Stable
class Selection(private val controller: AppController) {
    var productID by mutableStateOf(controller.platform.prefs.get(PRODUCT))
        private set
    var chatID by mutableStateOf(controller.platform.prefs.get(CHAT))
        private set

    /** Pulsed to put the cursor in the composer, with an optional hint for what to write. */
    var focusPulse by mutableIntStateOf(0)
        private set
    var hint by mutableStateOf<String?>(null)
        private set

    fun open(productID: String?, chatID: String?) {
        this.productID = productID ?: this.productID
        this.chatID = chatID
        remember()
    }

    /** Nothing on screen — the product it showed is gone. */
    fun clear() {
        productID = null
        chatID = null
        remember()
    }

    fun newChat(productID: String) {
        this.productID = productID
        this.chatID = controller.newChatID()
        hint = null
        remember()
    }

    fun compose(hint: String?) {
        this.hint = hint
        focusPulse++
    }

    private fun remember() {
        productID?.let { controller.platform.prefs.put(PRODUCT, it) } ?: controller.platform.prefs.remove(PRODUCT)
        chatID?.let { controller.platform.prefs.put(CHAT, it) } ?: controller.platform.prefs.remove(CHAT)
    }

    private companion object {
        const val PRODUCT = "bulava.selection.product"
        const val CHAT = "bulava.selection.chat"
    }
}

fun Home.product(id: String?): Product? = products.firstOrNull { it.id == id }
fun Home.chat(id: String?): ChatSummary? =
    products.asSequence().flatMap { it.chats.asSequence() + it.archivedChats.asSequence() }.firstOrNull { it.id == id }

@OptIn(androidx.compose.ui.ExperimentalComposeUiApi::class)
@Composable
fun MainScreen(
    controller: AppController,
    selection: Selection,
    onOpenSettings: () -> Unit,
    onOpenReport: (String, String) -> Unit,
    onOpenImage: (String, String) -> Unit,
    onOpenContext: (productID: String, chatID: String?, title: String) -> Unit,
) {
    val home by controller.home.collectAsState()
    val link by controller.link.state.collectAsState()
    val drawer = rememberDrawerState(if (selection.productID == null) DrawerValue.Open else DrawerValue.Closed)
    // The keyboard belongs to the composer; it does not stay up over the list of chats.
    val focus = androidx.compose.ui.platform.LocalFocusManager.current
    LaunchedEffect(drawer.targetValue) { if (drawer.targetValue == DrawerValue.Open) focus.clearFocus(force = true) }
    val scope = rememberCoroutineScope()

    var finding by remember(selection.chatID) { mutableStateOf(false) }
    var findQuery by remember(selection.chatID) { mutableStateOf("") }
    var findCursor by remember(selection.chatID) { mutableIntStateOf(0) }
    val product = home?.product(selection.productID)
    val chatSummary = home?.chat(selection.chatID)
    val chatID = selection.chatID

    // The chat on screen is the one the Mac keeps this phone posted about.
    DisposableEffect(chatID, chatSummary != null) {
        if (chatID != null && chatSummary != null) controller.openChat(chatID)
        controller.foregroundChatID = chatID
        onDispose { if (chatID != null && chatSummary != null) controller.closeChat(chatID) }
    }
    // A product that vanished on the Mac takes the selection with it, and with nothing on screen
    // the drawer is where to start.
    LaunchedEffect(home?.products?.map { it.id }) {
        val h = home ?: return@LaunchedEffect
        if (selection.productID != null && h.product(selection.productID) == null) selection.clear()
        if (selection.productID == null && h.products.isNotEmpty()) drawer.open()
    }
    // A chat opened from outside the drawer — a tapped notification — is not left behind it.
    LaunchedEffect(chatID) { if (chatID != null && drawer.isOpen) drawer.close() }

    @Suppress("DEPRECATION") // see App.kt
    BackHandler(enabled = drawer.isOpen) { scope.launch { drawer.close() } }

    ModalNavigationDrawer(
        drawerState = drawer,
        drawerContent = {
            ModalDrawerSheet(drawerContainerColor = Bulava.colors.background, drawerContentColor = Bulava.colors.text) {
                Drawer(
                    controller = controller, home = home, link = link,
                    selectedChatID = chatID,
                    onOpenChat = { productID, id -> selection.open(productID, id); scope.launch { drawer.close() } },
                    onNewChat = { productID -> selection.newChat(productID); scope.launch { drawer.close() } },
                    onOpenSettings = { onOpenSettings(); scope.launch { drawer.close() } },
                )
            }
        },
    ) {
        Column(Modifier.fillMaxSize().background(Bulava.colors.background).statusBarsPadding()) {
            TopBar(
                controller = controller,
                title = chatSummary?.title ?: product?.let { stringResource(Res.string.drawer_new_chat) } ?: "",
                subtitle = product?.name,
                chat = chatSummary,
                onMenu = { scope.launch { drawer.open() } },
                onNewChat = product?.let { p -> { selection.newChat(p.id) } },
                onFind = { finding = true },
                onContext = product?.takeIf { controller.can("context") }?.let { p ->
                    { onOpenContext(p.id, chatSummary?.id, chatSummary?.title ?: p.name) }
                },
            )
            if (finding) {
                com.stepanok.bulava.ui.chat.FindBar(
                    query = findQuery, onQuery = { findQuery = it; findCursor = 0 },
                    onStep = { findCursor += it }, onClose = { finding = false; findQuery = "" },
                    controller = controller, chatID = chatID,
                    cursor = findCursor,
                )
            }
            UpdateBanner(controller)
            ConnectionBanner(controller, link)
            // The thread above the composer: a tap on it or a drag of it puts the keyboard away.
            Box(Modifier.weight(1f).fillMaxWidth().dismissKeyboardOnTapOrDrag()) {
                if (product != null && chatID != null) {
                    ChatPane(
                        controller = controller, product = product, chatID = chatID,
                        known = chatSummary != null,
                        find = if (finding) findQuery to findCursor else null,
                        onCompose = { hint -> selection.compose(hint) },
                        onOpenReport = onOpenReport, onOpenImage = onOpenImage,
                    )
                } else {
                    EmptyHome(onMenu = { scope.launch { drawer.open() } })
                }
            }
            if (product != null && chatID != null) {
                Composer(
                    controller = controller, productID = product.id, chatID = chatID,
                    archived = chatSummary?.archived == true, selection = selection,
                    modifier = Modifier.imePadding().navigationBarsPadding(),
                )
            } else {
                Spacer(Modifier.navigationBarsPadding())
            }
        }
    }
}

@Composable
private fun TopBar(
    controller: AppController,
    title: String,
    subtitle: String?,
    chat: ChatSummary?,
    onMenu: () -> Unit,
    onNewChat: (() -> Unit)?,
    onFind: () -> Unit,
    onContext: (() -> Unit)?,
) {
    val c = Bulava.colors
    var menu by remember { mutableStateOf(false) }
    var renaming by remember { mutableStateOf(false) }
    var archiving by remember { mutableStateOf(false) }
    Row(Modifier.fillMaxWidth().height(56.dp).padding(horizontal = 4.dp), verticalAlignment = Alignment.CenterVertically) {
        IconAction(Icons.Menu, stringResource(Res.string.cd_menu), onMenu)
        // The title opens the chat's details too, as Messages and Slack open a conversation's.
        Column(
            Modifier.weight(1f).clip(RoundedCornerShape(Metrics.radiusControl))
                .then(if (onContext != null) Modifier.systemClickable(role = Role.Button, onClick = onContext) else Modifier)
                .padding(horizontal = 4.dp, vertical = 2.dp),
        ) {
            Text(title, style = Bulava.type.headline, color = c.text, maxLines = 1, overflow = TextOverflow.Ellipsis,
                modifier = Modifier.semantics { heading() })
            if (subtitle != null) {
                Text(subtitle, style = Bulava.type.meta, color = c.textFaint, maxLines = 1, overflow = TextOverflow.Ellipsis)
            }
        }
        if (chat != null) {
            Box {
                IconAction(Icons.Dots, stringResource(Res.string.cd_more), { menu = true })
                DropdownMenu(expanded = menu, onDismissRequest = { menu = false }, containerColor = c.surface) {
                    DropdownMenuItem(text = { Text(stringResource(Res.string.menu_find)) },
                        onClick = { menu = false; onFind() })
                    if (controller.can("chat.rename")) DropdownMenuItem(text = { Text(stringResource(Res.string.menu_rename)) },
                        onClick = { menu = false; renaming = true })
                    if (controller.can("chat.pin")) DropdownMenuItem(
                        text = { Text(stringResource(if (chat.pinned) Res.string.menu_unpin else Res.string.menu_pin)) },
                        onClick = { menu = false; controller.setPinned(chat.id, !chat.pinned) })
                    if (controller.can("chat.archive")) DropdownMenuItem(
                        text = { Text(stringResource(if (chat.archived) Res.string.menu_unarchive else Res.string.menu_archive)) },
                        onClick = {
                            menu = false
                            if (chat.archived) controller.setArchived(chat.id, false) else archiving = true
                        })
                }
            }
        }
        // The Mac's right-hand pane — folders, changes, reports — one tap away, for a new chat too.
        if (onContext != null) IconAction(Icons.Panel, stringResource(Res.string.menu_context), onContext)
        if (onNewChat != null) IconAction(Icons.NewChat, stringResource(Res.string.drawer_new_chat), onNewChat)
    }
    Hairline()

    if (renaming && chat != null) {
        SystemPrompt(
            title = stringResource(Res.string.rename_title), value = chat.title, placeholder = chat.title,
            confirm = stringResource(Res.string.action_save), cancel = stringResource(Res.string.action_cancel),
            onConfirm = { title -> renaming = false; controller.rename(chat.id, title) },
            onDismiss = { renaming = false },
        )
    }
    if (archiving && chat != null) {
        SystemAlert(
            title = stringResource(Res.string.archive_title),
            message = stringResource(Res.string.archive_body),
            buttons = listOf(
                AlertButton(stringResource(Res.string.action_cancel), AlertButton.Style.Cancel) { archiving = false },
                AlertButton(stringResource(Res.string.menu_archive)) { archiving = false; controller.setArchived(chat.id, true) },
            ),
            onDismiss = { archiving = false },
        )
    }
}

/**
 * Said in words, and only when the Mac is not here: connected is the normal state and needs no
 * banner. A Mac that is here but too old, or too new, for this app is `UpdateBanner`'s to say.
 */
@Composable
private fun ConnectionBanner(controller: AppController, link: LinkState) {
    val c = Bulava.colors
    val mac = controller.link.paired?.name ?: ""
    val (title, body, retry) = when (link) {
        is LinkState.Offline -> Triple(stringResource(Res.string.status_offline, mac), stringResource(Res.string.status_offline_body), true)
        is LinkState.Connecting -> Triple(stringResource(Res.string.status_connecting, mac), null, false)
        else -> Triple(null, null, false)
    }
    AnimatedVisibility(visible = title != null) {
        Column(Modifier.fillMaxWidth().background(if (link is LinkState.Connecting) c.surfaceMuted else c.orangeSoft)
            .padding(horizontal = 16.dp, vertical = 10.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                androidx.compose.material3.Icon(
                    if (link is LinkState.Connecting) Icons.Wifi else Icons.Unplugged, null,
                    tint = if (link is LinkState.Connecting) c.textSecondary else c.orange, modifier = Modifier.size(18.dp))
                Spacer(Modifier.width(10.dp))
                Text(title ?: "", style = Bulava.type.caption.copy(fontWeight = androidx.compose.ui.text.font.FontWeight.Medium),
                    color = c.text, modifier = Modifier.weight(1f))
                if (retry) {
                    BulavaButton(stringResource(Res.string.action_retry_now), { controller.link.nudge() }, kind = ButtonKind.Quiet)
                }
            }
            if (body != null) {
                Text(body, style = Bulava.type.meta, color = c.textSecondary, modifier = Modifier.padding(start = 28.dp))
            }
        }
    }
}

@Composable
private fun EmptyHome(onMenu: () -> Unit) {
    val c = Bulava.colors
    Column(Modifier.fillMaxSize().padding(32.dp), verticalArrangement = androidx.compose.foundation.layout.Arrangement.Center) {
        Text(stringResource(Res.string.empty_home_title), style = Bulava.type.title, color = c.text)
        Spacer(Modifier.height(8.dp))
        Text(stringResource(Res.string.empty_home_body), style = Bulava.type.callout, color = c.textSecondary)
        Spacer(Modifier.height(20.dp))
        BulavaButton(stringResource(Res.string.empty_home_title), onMenu, kind = ButtonKind.Secondary, icon = Icons.Menu)
    }
}
