package com.stepanok.bulava.state

import com.stepanok.bulava.link.Action
import com.stepanok.bulava.link.Attention
import com.stepanok.bulava.link.CallResult
import com.stepanok.bulava.link.ChatDelta
import com.stepanok.bulava.link.ChatGone
import com.stepanok.bulava.link.FileOpen
import com.stepanok.bulava.link.ChatState
import com.stepanok.bulava.link.Entry
import com.stepanok.bulava.link.ErrorCodes
import com.stepanok.bulava.link.FileChunk
import com.stepanok.bulava.link.FileRef
import com.stepanok.bulava.link.Finished
import com.stepanok.bulava.link.HistoryPage
import com.stepanok.bulava.link.Home
import com.stepanok.bulava.link.LinkClient
import com.stepanok.bulava.link.LinkError
import com.stepanok.bulava.link.LinkJson
import com.stepanok.bulava.link.LinkState
import com.stepanok.bulava.link.DecisionSent
import com.stepanok.bulava.link.Report
import com.stepanok.bulava.link.TakenBack
import com.stepanok.bulava.link.UploadStarted
import com.stepanok.bulava.platform.NotificationButton
import com.stepanok.bulava.platform.PhoneNotification
import com.stepanok.bulava.platform.PickedFile
import com.stepanok.bulava.platform.PlatformServices
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.SharedFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch
import kotlinx.coroutines.withTimeoutOrNull
import kotlinx.coroutines.yield
import kotlinx.serialization.KSerializer
import kotlinx.serialization.Serializable
import kotlinx.serialization.builtins.ListSerializer
import kotlinx.serialization.builtins.MapSerializer
import kotlinx.serialization.builtins.serializer
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put
import kotlin.io.encoding.Base64
import kotlin.io.encoding.ExperimentalEncodingApi
import kotlin.uuid.ExperimentalUuidApi
import kotlin.uuid.Uuid

/** What the composer holds for one chat. Survives the app being closed. */
@Serializable
data class Draft(val text: String = "", val attachments: List<FileRef> = emptyList()) {
    val isEmpty: Boolean get() = text.isBlank() && attachments.isEmpty()
}

/** A message the phone is sending, or failed to send. Shown in the thread until the Mac has it. */
@Serializable
data class Outgoing(
    val entryID: String,
    val productID: String,
    val chatID: String,
    val text: String,
    val attachments: List<FileRef>,
    val atMs: Long,
    val failed: Boolean = false,
    val reason: String? = null,
)

/**
 * What is ticked on a report's questions, kept on the phone — across a closed app too — until the
 * Mac has it. [sending] is set from the first press of "Send" until the Mac answers: a retry after
 * a lost connection carries the same id, so the answer lands once.
 */
@Serializable
data class DecisionDraft(
    val choices: Map<String, String> = emptyMap(),
    val comments: Map<String, String> = emptyMap(),
    val general: String = "",
    /** The questions it answers, as read, and the answer it corrects. */
    val revision: String = "",
    val basedOn: String? = null,
    val sending: String? = null,
) {
    val isEmpty: Boolean get() = choices.isEmpty() && comments.values.all { it.isBlank() } && general.isBlank()

    /** The same answer, whatever else differs: what is ticked and what is written. */
    fun answersLike(other: DecisionDraft): Boolean =
        choices == other.choices && comments.filterValues { it.isNotBlank() } == other.comments.filterValues { it.isNotBlank() } &&
            general.trim() == other.general.trim()
}

/** An answer already sent, as a draft of these questions: what no longer fits them is left out. */
fun com.stepanok.bulava.link.DecisionSent.asDraft(decisions: com.stepanok.bulava.link.Decisions): DecisionDraft {
    val items = decisions.items.associateBy { it.id }
    return DecisionDraft(
        choices = choices.filter { (id, choice) -> items[id]?.options?.contains(choice) == true },
        comments = comments.filter { (id, text) -> id in items && text.isNotBlank() },
        general = general,
    )
}

/** What became of an answer to a report's questions. */
sealed interface Decided {
    data class Sent(val sent: DecisionSent?) : Decided
    /** No connection: it is kept, marked as on its way, and goes by itself once there is one. */
    data object Waiting : Decided
    /** The questions changed, or another device answered meanwhile: read the report again. */
    data class ReadAgain(val message: String) : Decided
    data class Refused(val message: String) : Decided
}

/** An open chat as the phone holds it: the Mac's state plus older messages it scrolled back to. */
data class ChatView(
    val state: ChatState,
    val entries: List<Entry>,
    val loadingEarlier: Boolean = false,
)

/**
 * The phone's model of the app. Holds only what the Mac sent and what the person typed; it
 * decides nothing about the work itself.
 */
@OptIn(ExperimentalUuidApi::class, ExperimentalEncodingApi::class)
class AppController(
    val platform: PlatformServices,
    private val scope: CoroutineScope,
    private val now: () -> Long,
) {
    val link = LinkClient(platform, scope, now)

    private val _home = MutableStateFlow(loadCachedHome())
    /** The last thing the Mac said about products and chats. Kept while offline, and labelled so. */
    val home: StateFlow<Home?> = _home

    private val _homeCount = MutableStateFlow(0)
    /** How many times the Mac has sent the home list — for waiting on the next one. */
    val homeCount: StateFlow<Int> = _homeCount

    private val _chats = MutableStateFlow<Map<String, ChatView>>(emptyMap())
    val chats: StateFlow<Map<String, ChatView>> = _chats

    private val _drafts = MutableStateFlow(load(DRAFTS, MapSerializer(String.serializer(), Draft.serializer())) ?: emptyMap())
    val drafts: StateFlow<Map<String, Draft>> = _drafts

    private val _outbox = MutableStateFlow(load(OUTBOX, ListSerializer(Outgoing.serializer())) ?: emptyList())
    val outbox: StateFlow<List<Outgoing>> = _outbox

    private val _decisions = MutableStateFlow(load(DECISIONS, MapSerializer(String.serializer(), DecisionDraft.serializer())) ?: emptyMap())
    /** Answers to reports' questions not yet with the Mac, by the report's `ref`. */
    val decisions: StateFlow<Map<String, DecisionDraft>> = _decisions

    private val _notices = MutableSharedFlow<Notice>(extraBufferCapacity = 16)
    /** One-line things to say at the bottom of the screen. */
    val notices: SharedFlow<Notice> = _notices

    data class Notice(val kind: Kind, val code: String? = null, val message: String? = null) {
        enum class Kind { Stale, Failed, Offline, NotOnPhone, TooLarge, Copied, PdfFailed, DecisionsSent }
    }

    /**
     * A notification was tapped. It names its chat or product, or — a push from the relay, which
     * carries nothing of the work — only [about]: "attention", "finished" or "done".
     */
    data class OpenRequest(val productID: String?, val chatID: String?, val about: String? = null)

    /** Where a tapped notification leads. */
    sealed interface Destination {
        data class Chat(val productID: String?, val chatID: String) : Destination
        /** A product's details: where a report that came in with no chat of its own is. */
        data class Details(val productID: String, val name: String) : Destination
        /** The Mac's setup, which the settings here show. */
        data object Settings : Destination
    }

    private val _openRequests = MutableSharedFlow<OpenRequest>(replay = 1, extraBufferCapacity = 4)
    val openRequests: SharedFlow<OpenRequest> = _openRequests

    fun openFromNotification(productID: String?, chatID: String?, about: String? = null) {
        _openRequests.tryEmit(OpenRequest(productID, chatID, about))
    }

    /**
     * Where [request] leads. A chat it names is opened as it is. A push that says only what
     * happened leads to the newest thing of that kind the Mac lists — read after the Mac has said
     * what it lists now, because what this phone kept from before the push need not have it yet.
     * Null is nothing to open: a task that stopped before it started asks in a dialog that comes up
     * by itself, and a Mac that cannot be reached has nothing to say where.
     */
    suspend fun destination(request: OpenRequest): Destination? {
        request.chatID?.let { return Destination.Chat(request.productID, it) }
        if (request.about == READINESS) return Destination.Settings
        request.productID?.let { id ->
            val home = _home.value?.takeIf { h -> h.products.any { it.id == id } } ?: freshHome()
            return home?.products?.firstOrNull { it.id == id }?.let { Destination.Details(it.id, it.name) }
        }
        val about = request.about ?: return null
        return freshHome()?.let { newest(about, it) }
    }

    /**
     * The Mac's list as it is now. On a live link a round trip is enough — the lists it sent before
     * answering have been read by then; otherwise the one sent once the link is back.
     */
    private suspend fun freshHome(waitMs: Long = 20_000): Home? {
        val before = _homeCount.value
        if (link.state.value is LinkState.Connected && homeSinceConnect &&
            link.call("home.subscribe", timeoutMs = 5_000) is CallResult.Ok) {
            yield() // the events before the answer are handled on the same thread, ahead of this
            return _home.value
        }
        return withTimeoutOrNull(waitMs) { _homeCount.first { it > before }; _home.value }
    }

    /**
     * A link from outside the app: the site's "open in Bulava" button with a pairing code, or a tap
     * on the Lock Screen's activity — `bulava://open?product=…&chat=…` — which opens that chat.
     */
    fun handleLink(url: String): Boolean {
        if (url.startsWith("bulava://open")) {
            val query = url.substringAfter('?', "").split('&').mapNotNull { part ->
                part.split('=', limit = 2).takeIf { it.size == 2 }?.let { it[0] to it[1] }
            }.toMap()
            openFromNotification(query["product"]?.takeIf { it.isNotBlank() }, query["chat"]?.takeIf { it.isNotBlank() })
            return true
        }
        val code = link.parse(url) ?: return false
        link.pair(code)
        return true
    }

    private val _uploading = MutableStateFlow<Set<String>>(emptySet())
    val uploading: StateFlow<Set<String>> = _uploading

    private val openChats = mutableSetOf<String>()
    private var notified: Set<String> = load(NOTIFIED, ListSerializer(String.serializer()))?.toSet() ?: emptySet()
    private var baselined = notified.isNotEmpty()
    /** Finished work already told about; null until the first list from this Mac sets the line. */
    private var notifiedDone: Set<String>? = load(NOTIFIED_DONE, ListSerializer(String.serializer()))?.toSet()
    /** Chats whose answer came in and was already told about, the same way. */
    private var notifiedAnswered: Set<String>? = load(NOTIFIED_ANSWERED, ListSerializer(String.serializer()))?.toSet()
    /** Whether the Mac has sent the home list since this connection opened. */
    private var homeSinceConnect = false

    /** The chat on screen, so a request about it is not also announced as a notification. */
    var foregroundChatID: String? = null

    /**
     * Whether the app is on screen. The Mac is told, so it wakes an iPhone through the push relay
     * only when the app is not already listening.
     */
    var inForeground: Boolean = true
        set(value) {
            val changed = field != value
            field = value
            if (changed) tellPresence()
        }

    private fun tellPresence() {
        if (!link.isConnected || !can("push")) return
        val foreground = inForeground
        scope.launch { link.call("presence.set", args("foreground" to foreground)) }
    }

    /**
     * The token Apple gave this iPhone for waking it. Kept, and handed to the Mac on every
     * connection, so a Mac that forgot it (or a new pairing) learns it again. Nothing else is
     * done with it on the phone.
     */
    fun setPushToken(token: String, environment: String) {
        val known = platform.prefs.get(PUSH_TOKEN) == token && platform.prefs.get(PUSH_ENV) == environment
        platform.prefs.put(PUSH_TOKEN, token)
        platform.prefs.put(PUSH_ENV, environment)
        if (!known && link.isConnected) scope.launch { registerPush() }
    }

    /**
     * With the token go the key this phone's Lock Screen reads the names of the work with, and the
     * pushes it has words for — so a Mac sends "the answer is in" only to a phone that can say it.
     */
    private suspend fun registerPush() {
        val token = platform.prefs.get(PUSH_TOKEN) ?: return
        if (!can("push")) return
        link.call("push.register", args(
            "token" to token, "environment" to (platform.prefs.get(PUSH_ENV) ?: "production"),
            "seal" to platform.liveKey(),
            "kinds" to JsonArray(PUSH_KINDS.map { JsonPrimitive(it) }),
        ))
    }

    /**
     * An iPhone's Live Activity tokens, from iOS: [kind] "start" lets the Mac begin an activity
     * with a push while the app is closed, "update" belongs to the activity running now. An empty
     * [token] means that activity ended. Kept, and handed to the Mac on every connection.
     */
    fun setActivityToken(kind: String, token: String, environment: String) {
        val key = if (kind == "start") ACTIVITY_START else ACTIVITY_UPDATE
        val known = platform.prefs.get(key).orEmpty() == token
        if (token.isEmpty()) platform.prefs.remove(key) else platform.prefs.put(key, token)
        platform.prefs.put(PUSH_ENV_ACTIVITY, environment)
        if (!known && link.isConnected) scope.launch { registerActivity(kind) }
    }

    private suspend fun registerActivity(kind: String) {
        if (!can("liveActivity")) return
        val key = if (kind == "start") ACTIVITY_START else ACTIVITY_UPDATE
        link.call("activity.register", args(
            "kind" to kind, "token" to platform.prefs.get(key).orEmpty(),
            "environment" to (platform.prefs.get(PUSH_ENV_ACTIVITY) ?: "production"),
        ))
    }

    /** Voice notes the Mac transcribes into this phone's composers. */
    val dictation = Dictation(this, scope, now)

    init {
        scope.launch { link.events.collect { handleEvent(it.event, it.data) } }
        scope.launch {
            link.state.collect { state ->
                when (state) {
                    is LinkState.Connected -> onConnected()
                    is LinkState.Unpaired -> {
                        _home.value = null
                        _chats.value = emptyMap()
                        platform.prefs.remove(HOME)
                        platform.keepLinkAlive(false, "")
                    }
                    else -> Unit
                }
            }
        }
        link.connect()
    }

    private suspend fun onConnected() {
        homeSinceConnect = false
        platform.keepLinkAlive(platform.prefs.get(KEEP_ALIVE) != "off", link.paired?.name ?: "")
        link.call("home.subscribe")
        // Over a copy: each call waits for the Mac, and meanwhile the chat on screen can change — a
        // tapped notification brings its chat up just as the link comes back. One opened meanwhile
        // asks for itself (`openChat`); one closed meanwhile is not asked for.
        for (id in openChats.toList()) if (id in openChats) link.call("chat.open", args("chatID" to id))
        registerPush()
        if (platform.prefs.get(ACTIVITY_START) != null) registerActivity("start")
        if (platform.prefs.get(ACTIVITY_UPDATE) != null) registerActivity("update")
        tellPresence()
        retryOutbox()
        retryDecisions()
    }

    // MARK: Events from the Mac

    private fun handleEvent(event: String?, data: JsonElement?) {
        data ?: return
        when (event) {
            "home" -> decode<Home>(data)?.let { adoptHome(it) }
            "chat" -> decode<ChatState>(data)?.let { adoptChat(it) }
            "chat.delta" -> decode<ChatDelta>(data)?.let { applyDelta(it) }
            "chat.gone" -> decode<ChatGone>(data)?.let { gone ->
                openChats.remove(gone.id)
                _chats.update { it - gone.id }
            }
        }
    }

    private fun adoptHome(home: Home) {
        _home.value = home
        _homeCount.value += 1
        homeSinceConnect = true
        platform.prefs.put(HOME, LinkJson.encodeToString(Home.serializer(), home))
        // A different Mac — a new pairing — starts from its own line, not from the last Mac's.
        if (platform.prefs.get(NOTIFIED_FOR) != home.desktop.id) {
            platform.prefs.put(NOTIFIED_FOR, home.desktop.id)
            baselined = false
            notifiedDone = null
            notifiedAnswered = null
        }
        announce(home)
        announceFinished(home)
        announceAnswered(home)
        platform.notifier.clearWakeUps()
        if (can("liveActivity")) platform.showSummary(home.summary, home.live, home.desktop.name)
        // The widgets keep the newest week they were given; a Mac that sends none leaves it alone.
        home.week?.let { week ->
            if (week != weekShown) {
                weekShown = week
                platform.showWeek(week)
            }
        }
    }

    /** The week last handed to the widgets, so an unchanged home does not rewrite it. */
    private var weekShown: com.stepanok.bulava.link.Week? = null

    /**
     * Whether this phone should say it itself: not about the chat on screen, and not from the
     * background of an iPhone, where the Mac's push through the relay already says it — twice
     * would be two banners for one piece of work.
     */
    private fun tellsItself(chatID: String?): Boolean {
        if (inForeground) return chatID == null || chatID != foregroundChatID
        return !platform.relayWakes
    }

    /**
     * Posts a notification for every request that is new since the last home, and takes back the
     * ones that were answered — on the Mac or here. The very first home after pairing is taken as
     * the starting line rather than announced all at once.
     *
     * A request's own buttons come with it, as long as they do something at once: "Trust and
     * send" can be pressed on the notification, once the phone is unlocked.
     */
    private fun announce(home: Home) {
        val current = home.attention.associateBy { it.id }
        if (!baselined) {
            baselined = true
            notified = current.keys
            save(NOTIFIED, ListSerializer(String.serializer()), notified.toList())
            return
        }
        for ((id, item) in current) {
            if (id in notified) continue
            val onScreen = inForeground && item.chatID != null && item.chatID == foregroundChatID
            if (!onScreen) {
                val product = home.products.firstOrNull { it.id == item.productID }?.name
                val title = listOfNotNull(product, item.title.takeIf { it.isNotBlank() }).distinct().joinToString(" · ")
                val buttons = if (can("actions")) NotificationButtons.from(item.actions) else emptyList()
                // A tap leads where a tap on the relay's push about it would (`place`).
                platform.notifier.post(PhoneNotification(
                    id, title.ifBlank { home.desktop.name }, item.body, buttons = buttons,
                ).leadingTo(place(item, home)))
            }
        }
        for (id in notified - current.keys) platform.notifier.cancel(id)
        notified = current.keys
        save(NOTIFIED, ListSerializer(String.serializer()), notified.toList())
    }

    /**
     * A report that came in is told — it is what the director was waiting for — and taken back
     * once it has been read on the Mac. Tapping it opens its chat, where the report is, or — one
     * with no chat of its own — its product's details. What was already finished when the phone
     * first heard from this Mac is the starting line.
     */
    private fun announceFinished(home: Home) {
        if (!can("finished")) return
        val current = home.finished.associateBy { it.id }
        val seen = notifiedDone
        if (seen != null) {
            for ((id, item) in current) {
                if (id in seen || !tellsItself(item.chatID)) continue
                val product = home.products.firstOrNull { it.id == item.productID }?.name
                val title = listOfNotNull(product, item.title.takeIf { it.isNotBlank() }).distinct().joinToString(" · ")
                platform.notifier.post(PhoneNotification(
                    id, title.ifBlank { home.desktop.name }, item.body, finished = true,
                ).leadingTo(place(item, home)))
            }
            for (id in seen - current.keys) platform.notifier.cancel(id)
        }
        notifiedDone = current.keys
        save(NOTIFIED_DONE, ListSerializer(String.serializer()), current.keys.toList())
    }

    /**
     * A chat whose answer is in — the Mac says so once the answer has stayed in, so the moment
     * between Claude and Codex's review is not taken for the end. Told with the chat's name and
     * the Mac's words for it; a tap opens the chat. The first list from this Mac is the line.
     */
    private fun announceAnswered(home: Home) {
        val live = home.live ?: return
        val answered = live.ended.filter { it.outcome == "done" && it.chatID != null }
        // One answer is one piece of work: the same chat answering again later is news again.
        val keys = answered.associate { "answered:${it.chatID}:${it.sinceMs ?: 0}" to it }
        val seen = notifiedAnswered
        if (seen != null) {
            for ((id, line) in keys) {
                if (id in seen || !tellsItself(line.chatID)) continue
                val title = listOf(line.product, line.title).filter { it.isNotBlank() }.distinct().joinToString(" · ")
                platform.notifier.post(PhoneNotification(
                    id, title.ifBlank { home.desktop.name }, line.label ?: "", line.productID, line.chatID, finished = true,
                ))
            }
        }
        // Remembered past the stretch that ended them: a list that moved on is not a reason to tell again.
        val kept = ((seen ?: emptySet()) + keys.keys).toList().takeLast(64)
        notifiedAnswered = kept.toSet()
        save(NOTIFIED_ANSWERED, ListSerializer(String.serializer()), kept)
    }

    /** What pressing a button on a notification came to. */
    enum class Reply { Done, Unreachable, Stale, Failed }

    /**
     * A button pressed on a notification, perhaps with the app closed: reach the Mac, wait for the
     * list it hands this connection (it knows a button only by that list), and press it. The
     * notification goes once the Mac has done it; otherwise the answer says why, and the request
     * stays where it was.
     */
    suspend fun respondFromNotification(notificationID: String, actionID: String, text: String?): Pair<Reply, String?> {
        val before = homeCount.value
        link.connect()
        val connected = withTimeoutOrNull(12_000) { link.state.first { it is LinkState.Connected } } != null
        if (!connected) return Reply.Unreachable to null
        if (!homeSinceConnect) withTimeoutOrNull(8_000) { homeCount.first { it > before } }
        val r = link.call("action.invoke", buildJsonObject {
            put("id", actionID)
            if (text != null) put("input", buildJsonObject { put("text", text) })
        }, 60_000)
        return when (r) {
            is CallResult.Ok -> {
                platform.notifier.cancel(notificationID)
                Reply.Done to null
            }
            is CallResult.Failed -> when (r.error.code) {
                ErrorCodes.STALE, ErrorCodes.NOT_FOUND -> Reply.Stale to null
                ErrorCodes.OFFLINE, ErrorCodes.TIMEOUT -> Reply.Unreachable to null
                else -> Reply.Failed to r.error.message.ifBlank { null }
            }
        }
    }

    private fun adoptChat(state: ChatState) {
        _chats.update { all -> all + (state.id to ChatMerge.snapshot(all[state.id], state)) }
        settleOutbox(state.id, state.entries)
    }

    private fun applyDelta(delta: ChatDelta) {
        _chats.update { all ->
            val view = all[delta.id] ?: return@update all
            all + (delta.id to ChatMerge.delta(view, delta))
        }
        settleOutbox(delta.id, delta.upserts)
    }

    /**
     * Whether the Mac this phone is talking to offers [capability]. An older Mac lacks some; what
     * it lacks is hidden rather than offered and refused. While offline the last answer holds.
     */
    fun can(capability: String): Boolean {
        (link.state.value as? LinkState.Connected)?.let { lastCapabilities = it.capabilities }
        return lastCapabilities?.contains(capability) ?: true
    }

    private var lastCapabilities: Set<String>? = null

    // MARK: Chats

    fun openChat(chatID: String) {
        openChats += chatID
        if (link.isConnected) scope.launch { link.call("chat.open", args("chatID" to chatID)) }
    }

    fun closeChat(chatID: String) {
        openChats -= chatID
        if (link.isConnected) scope.launch { link.call("chat.close", args("chatID" to chatID)) }
    }

    fun loadEarlier(chatID: String) {
        val view = _chats.value[chatID] ?: return
        if (view.loadingEarlier || !view.state.hasEarlier) return
        _chats.update { it + (chatID to view.copy(loadingEarlier = true)) }
        scope.launch {
            val before = view.entries.firstOrNull()?.id
            val page = result<HistoryPage>(link.call("chat.history", args("chatID" to chatID, "before" to before, "limit" to 40)))
            _chats.update { all ->
                val current = all[chatID] ?: return@update all
                if (page == null) return@update all + (chatID to current.copy(loadingEarlier = false))
                val known = current.entries.map { it.id }.toSet()
                val older = page.entries.filter { it.id !in known }
                all + (chatID to current.copy(
                    entries = older + current.entries, loadingEarlier = false,
                    state = current.state.copy(hasEarlier = page.hasEarlier),
                ))
            }
        }
    }

    /** The phone's clock, as this controller reads it — for a timer on screen. */
    fun nowMs(): Long = now()

    /** A chat id for a conversation that does not exist yet. It comes into being with its first message. */
    fun newChatID(): String = Uuid.random().toString().uppercase()

    fun rename(chatID: String, title: String) = fire("chat.rename", args("chatID" to chatID, "title" to title))
    fun setArchived(chatID: String, archived: Boolean) = fire("chat.archive", args("chatID" to chatID, "archived" to archived))
    fun setPinned(chatID: String, pinned: Boolean) = fire("chat.pin", args("chatID" to chatID, "pinned" to pinned))
    fun stop(chatID: String) = fire("chat.stop", args("chatID" to chatID))
    fun retry(entryID: String) = fire("entry.retry", args("entryID" to entryID))
    /**
     * A choice in the run control. With [chatID] — from a Mac that keeps model and depth per chat,
     * which says so by sending the chat its own `composer` — it is that chat's; without, the Mac's
     * default, as an older Mac takes every choice.
     */
    fun setOption(group: String, value: String, chatID: String? = null) =
        fire("settings.set", args("group" to group, "value" to value, "chat" to chatID))
    fun renameProduct(productID: String, name: String) = fire("product.rename", args("productID" to productID, "name" to name))
    fun setProductPinned(productID: String, pinned: Boolean) = fire("product.pin", args("productID" to productID, "pinned" to pinned))
    fun removeProduct(productID: String) = fire("product.remove", args("productID" to productID))

    private fun fire(op: String, args: JsonObject) {
        scope.launch { report(link.call(op, args)) }
    }

    // MARK: Drafts

    fun draft(key: String): Draft = _drafts.value[key] ?: Draft()

    fun setDraft(key: String, draft: Draft) {
        _drafts.update { if (draft.isEmpty) it - key else it + (key to draft) }
        save(DRAFTS, MapSerializer(String.serializer(), Draft.serializer()), _drafts.value)
    }

    // MARK: Sending

    /**
     * Sends the draft of [chatID]. The composer empties at once and the message shows in the
     * thread as "sending"; if the Mac never confirms, it stays there marked "not sent" with the
     * words intact. A retry carries the same entry id, so a reply lost on the way back cannot make
     * the message arrive twice.
     */
    fun send(productID: String, chatID: String) {
        val draft = draft(chatID)
        if (draft.isEmpty) return
        val outgoing = Outgoing(
            entryID = Uuid.random().toString().uppercase(), productID = productID, chatID = chatID,
            text = draft.text.trim(), attachments = draft.attachments, atMs = now(),
        )
        setDraft(chatID, Draft())
        _outbox.update { it + outgoing }
        persistOutbox()
        scope.launch { deliver(outgoing) }
    }

    fun resend(entryID: String) {
        val item = _outbox.value.firstOrNull { it.entryID == entryID } ?: return
        replaceOutgoing(item.copy(failed = false, reason = null))
        scope.launch { deliver(item) }
    }

    /** Takes a message that never reached the Mac back into the composer. */
    fun discardOutgoing(entryID: String) {
        val item = _outbox.value.firstOrNull { it.entryID == entryID } ?: return
        _outbox.update { list -> list.filter { it.entryID != entryID } }
        persistOutbox()
        val current = draft(item.chatID)
        setDraft(item.chatID, Draft(
            text = listOf(item.text, current.text).filter { it.isNotBlank() }.joinToString("\n"),
            attachments = item.attachments + current.attachments,
        ))
    }

    private suspend fun deliver(item: Outgoing) {
        val result = link.call("chat.send", buildJsonObject {
            put("productID", item.productID)
            put("chatID", item.chatID)
            put("entryID", item.entryID)
            put("text", item.text)
            put("attachments", JsonArray(item.attachments.mapNotNull { it.ref }.map { JsonPrimitive(it) }))
        })
        when (result) {
            is CallResult.Ok -> {
                if (item.chatID !in openChats) openChat(item.chatID)
            }
            is CallResult.Failed -> {
                replaceOutgoing(item.copy(failed = true, reason = result.error.code))
                report(result)
            }
        }
    }

    private suspend fun retryOutbox() {
        for (item in _outbox.value) {
            // Only the ones that were in flight when the link dropped. A message marked "not sent"
            // waits for the person to press "send again" — it might no longer be what they want.
            if (!item.failed) deliver(item)
        }
    }

    /** The Mac has the message: the local copy goes, and the real one takes its place. */
    private fun settleOutbox(chatID: String, entries: List<Entry>) {
        val arrived = entries.map { it.id }.toSet()
        if (_outbox.value.none { it.chatID == chatID && it.entryID in arrived }) return
        _outbox.update { list -> list.filterNot { it.chatID == chatID && it.entryID in arrived } }
        persistOutbox()
    }

    private fun replaceOutgoing(item: Outgoing) {
        _outbox.update { list -> list.map { if (it.entryID == item.entryID) item else it } }
        persistOutbox()
    }

    private fun persistOutbox() = save(OUTBOX, ListSerializer(Outgoing.serializer()), _outbox.value)

    // MARK: Attachments

    /** Uploads a picked file to the Mac and adds it to the draft of [chatID]. */
    fun attach(chatID: String, file: PickedFile) {
        val token = Uuid.random().toString()
        _uploading.update { it + token }
        scope.launch {
            val ref = upload(file)
            _uploading.update { it - token }
            if (ref != null) {
                val d = draft(chatID)
                setDraft(chatID, d.copy(attachments = d.attachments + ref))
            }
        }
    }

    fun removeAttachment(chatID: String, ref: FileRef) {
        val d = draft(chatID)
        setDraft(chatID, d.copy(attachments = d.attachments.filterNot { it == ref }))
    }

    private suspend fun upload(file: PickedFile): FileRef? {
        val (ref, error) = uploadBytes(file.name, file.kind, file.bytes)
        if (error != null) _notices.emit(noticeFor(error))
        return ref
    }

    /**
     * Sends [bytes] to the Mac in chunks: the file's ref, or why it did not get there. Said nowhere —
     * a photo's failure is a line at the bottom of the screen, a voice note's is on the note.
     */
    internal suspend fun uploadBytes(name: String, kind: String, bytes: ByteArray): Pair<FileRef?, LinkError?> {
        val begun = link.call("upload.begin", args("name" to name, "kind" to kind, "size" to bytes.size))
        val started = result<UploadStarted>(begun) ?: return null to failure(begun)
        var offset = 0
        val step = started.chunkSize.coerceIn(16 * 1024, 512 * 1024)
        while (offset < bytes.size) {
            val end = minOf(bytes.size, offset + step)
            val chunk = Base64.encode(bytes, offset, end)
            val r = link.call("upload.chunk", args("uploadID" to started.uploadID, "offset" to offset, "data" to chunk))
            if (r is CallResult.Failed) {
                link.call("upload.cancel", args("uploadID" to started.uploadID))
                return null to r.error
            }
            offset = end
        }
        val done = link.call("upload.finish", args("uploadID" to started.uploadID))
        return result<FileRef>(done)?.let { it to null } ?: (null to failure(done))
    }

    private fun failure(r: CallResult): LinkError = (r as? CallResult.Failed)?.error ?: LinkError(ErrorCodes.OFFLINE, "")

    /** Reads a file the Mac mentioned, all of it, chunk by chunk. */
    suspend fun readFile(ref: String, limit: Long = 40L * 1024 * 1024): ByteArray? {
        var offset = 0L
        var out = ByteArray(0)
        while (true) {
            val chunk = result<FileChunk>(link.call("file.read", args("ref" to ref, "offset" to offset, "length" to 512 * 1024)))
                ?: return null
            if (chunk.total > limit) return null
            val bytes = Base64.decode(chunk.data)
            out += bytes
            offset += bytes.size
            if (bytes.isEmpty() || offset >= chunk.total) return out
        }
    }

    // MARK: Buttons from the Mac

    /** Presses a button the Mac sent. [input] is what the person typed, when it asked for text. */
    fun invoke(action: Action, input: String? = null) {
        if (action.kind != "invoke") return
        scope.launch {
            val a = buildJsonObject {
                put("id", action.id)
                if (input != null) put("input", buildJsonObject { put("text", input) })
            }
            report(link.call("action.invoke", a))
        }
    }

    /** Presses a button and waits for the Mac's answer, for screens that reload after it. */
    suspend fun invokeNow(action: Action, input: String? = null): Boolean {
        if (action.kind != "invoke") return false
        val a = buildJsonObject {
            put("id", action.id)
            if (input != null) put("input", buildJsonObject { put("text", input) })
        }
        val r = link.call("action.invoke", a, 120_000)
        report(r)
        return r is CallResult.Ok
    }

    fun takeBack(chatID: String, entryID: String) {
        scope.launch {
            val back = result<TakenBack>(link.call("entry.takeBack", args("entryID" to entryID), 30_000)) ?: return@launch
            val current = draft(chatID)
            setDraft(chatID, Draft(
                text = listOf(back.text, current.text).filter { it.isNotBlank() }.joinToString("\n"),
                attachments = back.attachments + current.attachments,
            ))
        }
    }

    fun answer(entryID: String, selections: List<List<String>>, text: String) {
        scope.launch {
            val a = buildJsonObject {
                put("entryID", entryID)
                put("selections", JsonArray(selections.map { s -> JsonArray(s.map { JsonPrimitive(it) }) }))
                put("text", text)
            }
            report(link.call("question.answer", a))
        }
    }

    private val commandCache = mutableMapOf<String, Pair<Long, List<com.stepanok.bulava.link.Option>>>()

    /** The slash commands this product's folders offer, as the Mac's composer lists them. */
    suspend fun commands(productID: String): List<com.stepanok.bulava.link.Option> {
        commandCache[productID]?.let { (at, list) -> if (now() - at < 60_000) return list }
        val list = result<List<com.stepanok.bulava.link.Option>>(link.call("commands.list", args("productID" to productID)))
            ?: return commandCache[productID]?.second.orEmpty()
        commandCache[productID] = now() to list
        return list
    }

    suspend fun context(productID: String, chatID: String?): com.stepanok.bulava.link.Context? =
        result(link.call("context.get", args("productID" to productID, "chatID" to chatID), 60_000))

    suspend fun diff(ref: String): String? =
        result<com.stepanok.bulava.link.Diff>(link.call("context.diff", args("ref" to ref), 30_000))?.text

    suspend fun skills(productID: String?, full: Boolean): com.stepanok.bulava.link.Skills? =
        result(link.call("skills.get", args("productID" to productID, "full" to full), if (full) 300_000 else 120_000))

    suspend fun openReport(target: String): Report? = result(link.call("report.open", args("target" to target), 30_000))

    /**
     * A file the Mac was asked to open for this phone: it shares it on its home Wi-Fi and says where,
     * and the phone's browser shows it — a site with its own files beside it, a note as a page. Why
     * it could not (a Mac switched off sharing, a file gone) comes back as a notice in its words.
     */
    fun openFile(ref: String) {
        scope.launch {
            val answer = link.call("file.open", args("ref" to ref), 30_000)
            val opened = result<FileOpen>(answer)
            if (opened != null && opened.url.isNotBlank()) platform.openUrl(opened.url) else report(answer)
        }
    }

    // MARK: Decisions

    fun decisionDraft(ref: String): DecisionDraft = _decisions.value[ref] ?: DecisionDraft()

    /**
     * Keeps [draft] for [ref]. An empty one is forgotten — unless [keepEmpty]: over an answer already
     * sent, nothing ticked is a change of its own, not a return to what was sent.
     */
    fun setDecisionDraft(ref: String, draft: DecisionDraft, keepEmpty: Boolean = false) {
        _decisions.update { if (draft.isEmpty && draft.sending == null && !keepEmpty) it - ref else it + (ref to draft) }
        save(DECISIONS, MapSerializer(String.serializer(), DecisionDraft.serializer()), _decisions.value)
    }

    /**
     * Sends what is ticked on [ref] as his answer to the questions of [revision], correcting
     * [basedOn] — the answer the report showed as the last one sent. The Mac writes it into the
     * report's chat as his message, as if pressed beside the report there.
     */
    suspend fun decide(ref: String, revision: String, basedOn: String?): Decided {
        val draft = decisionDraft(ref)
        if (draft.isEmpty) return Decided.Refused("")
        val sending = draft.copy(revision = revision, basedOn = basedOn,
            sending = draft.sending ?: Uuid.random().toString().uppercase())
        setDecisionDraft(ref, sending)
        return deliverDecision(ref, sending)
    }

    private suspend fun deliverDecision(ref: String, draft: DecisionDraft): Decided {
        val id = draft.sending ?: return Decided.Refused("")
        val answer = link.call("report.decide", buildJsonObject {
            put("ref", ref)
            put("revision", draft.revision)
            draft.basedOn?.let { put("basedOn", it) }
            put("submissionID", id)
            put("choices", JsonObject(draft.choices.mapValues { JsonPrimitive(it.value) }))
            put("comments", JsonObject(draft.comments.filterValues { it.isNotBlank() }.mapValues { JsonPrimitive(it.value) }))
            put("general", draft.general)
        }, 30_000)
        return when (answer) {
            is CallResult.Ok -> {
                setDecisionDraft(ref, DecisionDraft())
                Decided.Sent(answer.result?.let { decode<DecisionSent>(it) })
            }
            is CallResult.Failed -> when (answer.error.code) {
                // Not refused — not heard. It stays on its way, under the same id.
                ErrorCodes.OFFLINE, ErrorCodes.TIMEOUT -> Decided.Waiting
                ErrorCodes.DECISIONS_CHANGED, ErrorCodes.DECISIONS_CONFLICT -> {
                    setDecisionDraft(ref, draft.copy(sending = null))
                    Decided.ReadAgain(answer.error.message)
                }
                else -> {
                    setDecisionDraft(ref, draft.copy(sending = null))
                    Decided.Refused(answer.error.message)
                }
            }
        }
    }

    /** Answers that were on their way when the link dropped go again, under their own ids. */
    private suspend fun retryDecisions() {
        for ((ref, draft) in _decisions.value) {
            if (draft.sending == null) continue
            when (val outcome = deliverDecision(ref, draft)) {
                is Decided.Sent -> _notices.emit(Notice(Notice.Kind.DecisionsSent))
                is Decided.ReadAgain -> _notices.emit(Notice(Notice.Kind.Failed, message = outcome.message))
                is Decided.Refused -> _notices.emit(Notice(Notice.Kind.Failed, message = outcome.message))
                Decided.Waiting -> Unit
            }
        }
    }

    // MARK: Pairing

    fun forget() {
        scope.launch {
            link.forget()
            dictation.clear()
            _drafts.value = emptyMap()
            _outbox.value = emptyList()
            _decisions.value = emptyMap()
            for (key in listOf(DRAFTS, OUTBOX, NOTIFIED, NOTIFIED_FOR, NOTIFIED_DONE, HOME, DECISIONS)) platform.prefs.remove(key)
            notified = emptySet()
            notifiedDone = null
            baselined = false
            // A forgotten Mac's week does not stay on the Home Screen.
            weekShown = null
            platform.showWeek(null)
        }
    }

    // MARK: Helpers

    private suspend fun report(result: CallResult) {
        val error = (result as? CallResult.Failed)?.error ?: return
        _notices.emit(noticeFor(error))
    }

    private fun noticeFor(error: LinkError): Notice = when (error.code) {
        ErrorCodes.STALE -> Notice(Notice.Kind.Stale, error.code, error.message)
        ErrorCodes.OFFLINE, ErrorCodes.TIMEOUT -> Notice(Notice.Kind.Offline, error.code, error.message)
        ErrorCodes.NOT_ON_PHONE -> Notice(Notice.Kind.NotOnPhone, error.code, error.message)
        ErrorCodes.TOO_LARGE -> Notice(Notice.Kind.TooLarge, error.code, error.message)
        else -> Notice(Notice.Kind.Failed, error.code, error.message)
    }

    fun say(notice: Notice) { _notices.tryEmit(notice) }

    private inline fun <reified T> decode(data: JsonElement): T? =
        runCatching { LinkJson.decodeFromJsonElement(kotlinx.serialization.serializer<T>(), data) }.getOrNull()

    private inline fun <reified T> result(r: CallResult): T? =
        (r as? CallResult.Ok)?.result?.let { decode<T>(it) }

    private fun <T> load(key: String, serializer: KSerializer<T>): T? =
        platform.prefs.get(key)?.let { runCatching { LinkJson.decodeFromString(serializer, it) }.getOrNull() }

    private fun <T> save(key: String, serializer: KSerializer<T>, value: T) {
        platform.prefs.put(key, LinkJson.encodeToString(serializer, value))
    }

    private fun loadCachedHome(): Home? = load(HOME, Home.serializer())

    companion object {
        /**
         * The newest thing a push of kind [about] is about: a question or request in its chat, the
         * Mac's setup in the settings, a report in its chat or its product's details, a chat whose
         * answer came in. A request of a task that did not start has no place: its dialog comes up.
         */
        fun newest(about: String, home: Home): Destination? = when (about) {
            "attention" -> home.attention.maxByOrNull { it.atMs }?.let { place(it, home) }
            "finished" -> home.finished.maxByOrNull { it.atMs }?.let { place(it, home) }
            "done" -> home.live?.ended?.firstOrNull { it.outcome == "done" && it.chatID != null }
                ?.let { Destination.Chat(it.productID, it.chatID!!) }
            else -> null
        }

        /**
         * Where a request leads — for a notification about it, the phone's own or the relay's: its
         * chat; the settings for the Mac's setup; nothing for a task that did not start, whose
         * dialog comes up by itself; its product's details for anything else with no chat.
         */
        fun place(item: Attention, home: Home): Destination? = when {
            item.chatID != null -> Destination.Chat(item.productID, item.chatID)
            item.kind == READINESS -> Destination.Settings
            item.kind == "ask" -> null
            else -> details(item.productID, home)
        }

        /** Where a report that came in leads: its chat, or its product's details. */
        fun place(item: Finished, home: Home): Destination? =
            item.chatID?.let { Destination.Chat(item.productID, it) } ?: details(item.productID, home)

        private fun details(productID: String, home: Home) =
            home.products.firstOrNull { it.id == productID }?.let { Destination.Details(it.id, it.name) }

        /** The kind of a request about the Mac's setup, and the `about` of a notification about it. */
        const val READINESS = "readiness"

        private const val DRAFTS = "bulava.drafts"
        private const val OUTBOX = "bulava.outbox"
        private const val DECISIONS = "bulava.decisions"
        private const val NOTIFIED = "bulava.notified"
        private const val NOTIFIED_FOR = "bulava.notified.desktop"
        private const val HOME = "bulava.home"
        private const val PUSH_TOKEN = "bulava.push.token"
        private const val PUSH_ENV = "bulava.push.environment"
        private const val NOTIFIED_DONE = "bulava.notified.done"
        private const val NOTIFIED_ANSWERED = "bulava.notified.answered"
        /** The pushes this phone has words for — `push.register` tells the Mac. */
        val PUSH_KINDS = listOf("attention", "finished", "done")
        private const val ACTIVITY_START = "bulava.activity.start"
        private const val ACTIVITY_UPDATE = "bulava.activity.update"
        private const val PUSH_ENV_ACTIVITY = "bulava.activity.environment"
        /** "off" when the person turned off staying connected in the background. */
        const val KEEP_ALIVE = "bulava.background"
        /** "on" while the limits at the foot of the drawer are folded to one line. */
        const val LIMITS_FOLDED = "bulava.limits.folded"

        fun args(vararg pairs: Pair<String, Any?>): JsonObject = buildJsonObject {
            for ((k, v) in pairs) when (v) {
                null -> Unit
                is String -> put(k, v)
                is Int -> put(k, v)
                is Long -> put(k, v)
                is Boolean -> put(k, v)
                is JsonElement -> put(k, v)
                else -> put(k, v.toString())
            }
        }
    }
}

/** Which of a request's buttons can be pressed on its notification. Pure, so it can be tested. */
object NotificationButtons {
    /**
     * The ones that do something on the Mac at once. A button that first asks "are you sure?", one
     * the Mac greyed out, one that opens something or can only be done at the Mac is left for the
     * app, where it can be shown properly. At most two: a notification is not a form.
     */
    fun from(actions: List<Action>): List<NotificationButton> =
        // A button that opens one of the Mac's sheets — «Commit as me…», with the author and every
        // file it takes — is not a line of text on a lock screen: it stays in the app.
        actions.filter {
            it.kind == "invoke" && it.confirm == null && it.disabledReason == null && it.label.isNotBlank() &&
                it.input?.isSheet != true
        }
            .take(2)
            .map { a ->
                NotificationButton(
                    id = a.id, label = a.label, destructive = a.style == "destructive",
                    inputPlaceholder = a.input?.let { i -> i.placeholder.ifBlank { a.label } },
                )
            }
}

/** How what the Mac sends is folded into what the phone already holds. Pure, so it can be tested. */
object ChatMerge {
    /**
     * A whole chat window. Messages the phone loaded from further back stay, as long as they are
     * older than the window and not in it.
     */
    fun snapshot(previous: ChatView?, state: ChatState): ChatView {
        val older = previous?.entries.orEmpty()
        val firstAt = state.entries.firstOrNull()?.atMs ?: Long.MAX_VALUE
        val keep = older.filter { old -> old.atMs < firstAt && state.entries.none { it.id == old.id } }
        return ChatView(state, keep + state.entries)
    }

    /** What changed: gone entries leave, changed and new ones take their place, in the Mac's order. */
    fun delta(view: ChatView, delta: ChatDelta): ChatView {
        val byID = view.entries.associateBy { it.id }.toMutableMap()
        delta.removed.forEach { byID.remove(it) }
        delta.upserts.forEach { byID[it.id] = it }
        val order = (delta.order ?: emptyList()).withIndex().associate { it.value to it.index }
        val merged = byID.values.sortedWith(compareBy<Entry> { it.atMs }.thenBy { order[it.id] ?: -1 })
        val h = delta.header
        val state = view.state.copy(
            title = h.title, archived = h.archived, status = h.status, activity = h.activity,
            degradation = h.degradation, queueCount = h.queueCount, busy = h.busy,
            hasEarlier = h.hasEarlier, actions = h.actions, composer = h.composer,
        )
        return view.copy(state = state, entries = merged)
    }
}

/**
 * This notification, with what a tap on it hands back: the chat, the product for its details, or
 * `about` for the settings — `AppController.destination` reads the same fields.
 */
internal fun PhoneNotification.leadingTo(to: AppController.Destination?): PhoneNotification = when (to) {
    is AppController.Destination.Chat -> copy(productID = to.productID, chatID = to.chatID, about = null)
    is AppController.Destination.Details -> copy(productID = to.productID, chatID = null, about = null)
    AppController.Destination.Settings -> copy(productID = null, chatID = null, about = AppController.READINESS)
    null -> copy(productID = null, chatID = null, about = null)
}
