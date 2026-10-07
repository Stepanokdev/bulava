package com.stepanok.bulava.link

import com.stepanok.bulava.platform.LinkTransport
import com.stepanok.bulava.platform.PlatformServices
import com.stepanok.bulava.platform.TransportListener
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.SharedFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.launch
import kotlinx.coroutines.suspendCancellableCoroutine
import kotlinx.coroutines.withTimeoutOrNull
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.decodeFromJsonElement
import kotlin.concurrent.Volatile
import kotlin.coroutines.resume
import kotlin.io.encoding.Base64
import kotlin.io.encoding.ExperimentalEncodingApi
import kotlin.random.Random

/** The Mac this phone is paired with, as remembered between launches. */
@Serializable
data class PairedMac(
    val desktopID: String,
    val name: String,
    val pin: String,
    val hosts: List<String>,
    val port: Int,
    val credential: Credential,
    val lastHost: String? = null,
)

sealed interface LinkState {
    /** Nothing paired. [notice] says why, when the pairing was taken away. */
    data class Unpaired(val notice: String? = null) : LinkState
    data class Pairing(val macName: String) : LinkState
    data class PairingFailed(val macName: String, val code: String, val message: String) : LinkState
    data class Connecting(val macName: String) : LinkState
    data class Connected(val desktop: Desktop, val capabilities: Set<String>) : LinkState
    /** Paired, and the Mac cannot be reached right now. Retried by itself. */
    data class Offline(val macName: String, val lastSeenMs: Long?, val retrying: Boolean) : LinkState
    /**
     * Paired, and one side is too old for the other. Retrying will not help; an update will.
     * [code] says which side: `protocol_too_old` — this phone, `protocol_too_new` — the Mac.
     * [desktopVersion] is the Mac's Bulava, [phoneApps] the newest phone app, when the Mac said.
     */
    data class Incompatible(
        val macName: String,
        val code: String,
        val message: String,
        val desktopVersion: String? = null,
        val phoneApps: PhoneApps? = null,
    ) : LinkState
}

sealed interface CallResult {
    data class Ok(val result: JsonElement?) : CallResult
    data class Failed(val error: LinkError) : CallResult
}

/**
 * The phone's end of the link: finds the Mac, proves who it is, keeps the connection up and turns
 * requests into answers.
 *
 * All state lives on the scope's thread (the main thread in the app); transport callbacks arrive
 * on whatever thread the platform uses and are handed over through a channel.
 */
class LinkClient(
    private val platform: PlatformServices,
    private val scope: CoroutineScope,
    private val now: () -> Long,
) {
    private val _state = MutableStateFlow<LinkState>(LinkState.Unpaired())
    val state: StateFlow<LinkState> = _state

    private val _events = MutableSharedFlow<Incoming>(extraBufferCapacity = 256)
    val events: SharedFlow<Incoming> = _events

    var paired: PairedMac? = loadPaired()
        private set

    private var live: Connection? = null
    private var loop: Job? = null
    private val pending = mutableMapOf<String, CompletableDeferred<Incoming>>()
    private var lastSeenMs: Long? = null
    private var wake = Channel<Unit>(Channel.CONFLATED)

    val isConnected: Boolean get() = _state.value is LinkState.Connected

    init {
        paired?.let { _state.value = LinkState.Connecting(it.name) }
    }

    // MARK: Pairing

    /**
     * Reads what the QR code (or a pasted pairing link) carries. Accepts the whole link or just the
     * part after `#`.
     */
    fun parse(text: String): PairingCode? = parsePairing(text)

    fun pair(code: PairingCode) {
        stop()
        _state.value = LinkState.Pairing(code.n)
        loop = scope.launch {
            val hello = hello(pairing = Hello.Pairing(code.t))
            when (val outcome = attempt(code.h, code.p, code.k, hello)) {
                is Attempt.Reply -> {
                    val reply = outcome.reply
                    val credential = reply.credential
                    if (reply.type == "welcome" && credential != null) {
                        val mac = PairedMac(
                            desktopID = reply.desktop?.id ?: code.id.ifEmpty { code.k.take(22) }, name = reply.desktop?.name ?: code.n,
                            pin = code.k, hosts = code.h, port = code.p, credential = credential,
                            lastHost = outcome.host,
                        )
                        savePaired(mac)
                        adopt(outcome.connection, reply, mac)
                        runLoop()
                    } else {
                        outcome.connection.close()
                        _state.value = LinkState.PairingFailed(code.n, reply.code ?: "refused", reply.message ?: "")
                    }
                }
                Attempt.Unreachable -> _state.value = LinkState.PairingFailed(code.n, ErrorCodes.OFFLINE, "")
            }
        }
    }

    /** Back to the scanner after a failed pairing. */
    fun cancelPairing() {
        stop()
        _state.value = paired?.let { LinkState.Offline(it.name, lastSeenMs, retrying = false) } ?: LinkState.Unpaired()
    }

    // MARK: Staying connected

    /** Starts (or restarts) the loop that keeps a paired phone connected. */
    fun connect() {
        val mac = paired ?: return
        if (loop?.isActive == true) {
            nudge()
            return
        }
        _state.value = LinkState.Connecting(mac.name)
        loop = scope.launch { runLoop() }
    }

    /** Try now instead of waiting out the pause — the app came to the front, the network changed. */
    fun nudge() {
        wake.trySend(Unit)
    }

    fun stop() {
        loop?.cancel()
        loop = null
        live?.close()
        live = null
        failPending(LinkError(ErrorCodes.OFFLINE, ""))
    }

    /** Forget the Mac on this phone. Tells the Mac too, when it can hear. */
    suspend fun forget() {
        if (isConnected) call("device.forget", JsonObject(emptyMap()), 3_000)
        stop()
        platform.secure.remove(KEY)
        paired = null
        _state.value = LinkState.Unpaired()
    }

    private suspend fun runLoop() {
        var failures = 0
        while (true) {
            val connection = live
            if (connection != null) {
                val reason = connection.closed.await()
                live = null
                failPending(LinkError(ErrorCodes.OFFLINE, ""))
                if (reason == Connection.REVOKED) return
                failures = 0
            }
            val mac = paired ?: return
            _state.value = if (lastSeenMs == null) LinkState.Connecting(mac.name)
            else LinkState.Offline(mac.name, lastSeenMs, retrying = true)

            val hello = hello(credential = mac.credential)
            val hosts = listOfNotNull(mac.lastHost) + mac.hosts.filter { it != mac.lastHost }
            var outcome = attempt(hosts, mac.port, mac.pin, hello)
            if (outcome == Attempt.Unreachable) {
                val found = discover(mac.desktopID)
                if (found.isNotEmpty()) {
                    val hostsFound = found.map { it.substringBeforeLast(':') }
                    val port = found.first().substringAfterLast(':').toIntOrNull() ?: mac.port
                    outcome = attempt(hostsFound, port, mac.pin, hello)
                    if (outcome is Attempt.Reply) {
                        savePaired(mac.copy(hosts = (hostsFound + mac.hosts).distinct().take(6), port = port))
                    }
                }
            }
            when (outcome) {
                is Attempt.Reply -> {
                    val reply = outcome.reply
                    if (reply.type == "welcome") {
                        paired?.let { if (it.lastHost != outcome.host) savePaired(it.copy(lastHost = outcome.host)) }
                        adopt(outcome.connection, reply, paired ?: mac)
                        continue
                    }
                    outcome.connection.close()
                    when (reply.code) {
                        ErrorCodes.REVOKED, ErrorCodes.UNAUTHORIZED -> {
                            platform.secure.remove(KEY)
                            paired = null
                            _state.value = LinkState.Unpaired(reply.message)
                            return
                        }
                        ErrorCodes.PROTOCOL_TOO_OLD, ErrorCodes.PROTOCOL_TOO_NEW -> {
                            _state.value = LinkState.Incompatible(
                                mac.name, reply.code, reply.message ?: "", reply.desktopVersion, reply.phoneApps,
                            )
                            waitForNudge(60_000)
                            continue
                        }
                        else -> failures++
                    }
                }
                Attempt.Unreachable -> failures++
            }
            _state.value = LinkState.Offline(mac.name, lastSeenMs, retrying = true)
            waitForNudge(BACKOFF[minOf(failures, BACKOFF.size) - 1])
        }
    }

    private suspend fun waitForNudge(ms: Long) {
        // Drain an old nudge first: it was about the attempt that just happened.
        wake.tryReceive()
        withTimeoutOrNull(ms) { wake.receive() }
    }

    private fun adopt(connection: Connection, reply: HandshakeReply, mac: PairedMac) {
        live = connection
        lastSeenMs = now()
        val desktop = reply.desktop ?: Desktop(id = mac.desktopID, name = mac.name)
        _state.value = LinkState.Connected(desktop, reply.capabilities.toSet())
        connection.onText = { text -> handle(text) }
        scope.launch { connection.pump() }
    }

    private fun handle(text: String) {
        val frame = runCatching { LinkJson.decodeFromString(Incoming.serializer(), text) }.getOrNull() ?: return
        lastSeenMs = now()
        when (frame.type) {
            "response" -> frame.id?.let { pending.remove(it)?.complete(frame) }
            "event" -> {
                if (frame.event == "revoked") {
                    val message = frame.data?.let { runCatching { LinkJson.decodeFromJsonElement<LinkError>(it) }.getOrNull() }
                    platform.secure.remove(KEY)
                    paired = null
                    live?.close(Connection.REVOKED)
                    _state.value = LinkState.Unpaired(message?.message)
                } else {
                    _events.tryEmit(frame)
                }
            }
        }
    }

    // MARK: Requests

    suspend fun call(op: String, args: JsonObject = JsonObject(emptyMap()), timeoutMs: Long = 20_000): CallResult {
        val connection = live ?: return CallResult.Failed(LinkError(ErrorCodes.OFFLINE, ""))
        val id = randomID()
        val waiter = CompletableDeferred<Incoming>()
        pending[id] = waiter
        val frame = LinkJson.encodeToString(Request.serializer(), Request(id = id, op = op, args = args))
        if (!connection.send(frame)) {
            pending.remove(id)
            return CallResult.Failed(LinkError(ErrorCodes.OFFLINE, ""))
        }
        val reply = withTimeoutOrNull(timeoutMs) { waiter.await() }
        pending.remove(id)
        return when {
            reply == null -> CallResult.Failed(LinkError(ErrorCodes.TIMEOUT, ""))
            reply.type == "failed" -> CallResult.Failed(reply.error ?: LinkError(ErrorCodes.OFFLINE, ""))
            reply.ok == true -> CallResult.Ok(reply.result)
            else -> CallResult.Failed(reply.error ?: LinkError())
        }
    }

    private fun failPending(error: LinkError) {
        val waiting = pending.values.toList()
        pending.clear()
        waiting.forEach { it.complete(Incoming(type = "failed", error = error)) }
    }

    // MARK: Attempts

    private sealed interface Attempt {
        data class Reply(val reply: HandshakeReply, val connection: Connection, val host: String) : Attempt
        data object Unreachable : Attempt
    }

    private suspend fun attempt(hosts: List<String>, port: Int, pin: String, hello: Hello): Attempt {
        for (host in hosts.distinct()) {
            val connection = Connection(platform.transport())
            val url = "wss://${if (host.contains(':')) "[$host]" else host}:$port/link"
            connection.open(url, pin)
            val opened = withTimeoutOrNull(OPEN_TIMEOUT) { connection.opened.await() } ?: false
            if (!opened) {
                connection.close()
                continue
            }
            connection.send(LinkJson.encodeToString(Hello.serializer(), hello))
            val first = withTimeoutOrNull(HELLO_TIMEOUT) { connection.firstText.await() }
            val reply = first?.let { runCatching { LinkJson.decodeFromString(HandshakeReply.serializer(), it) }.getOrNull() }
            if (reply == null || (reply.type != "welcome" && reply.type != "refused")) {
                connection.close()
                continue
            }
            return Attempt.Reply(reply, connection, host)
        }
        return Attempt.Unreachable
    }

    private suspend fun discover(desktopID: String): List<String> =
        withTimeoutOrNull(4_000) {
            suspendCancellableCoroutine { continuation ->
                platform.discover(desktopID) { found -> if (continuation.isActive) continuation.resume(found) }
            }
        } ?: emptyList()

    private fun hello(pairing: Hello.Pairing? = null, credential: Credential? = null) = Hello(
        app = ClientApp(
            platform = platform.platformName, version = platform.appVersion(),
            deviceName = platform.deviceName(), osVersion = platform.osVersion(),
        ),
        pairing = pairing,
        credential = credential,
    )

    // MARK: Storage

    private fun loadPaired(): PairedMac? =
        platform.secure.get(KEY)?.let { runCatching { LinkJson.decodeFromString(PairedMac.serializer(), it) }.getOrNull() }

    private fun savePaired(mac: PairedMac) {
        paired = mac
        platform.secure.put(KEY, LinkJson.encodeToString(PairedMac.serializer(), mac))
    }

    companion object {
        /** Where the pairing is kept in [PlatformServices.secure]. */
        const val PAIRED_KEY = "bulava.link.paired"
        private const val KEY = PAIRED_KEY
        private const val OPEN_TIMEOUT = 5_000L
        private const val HELLO_TIMEOUT = 8_000L
        private val BACKOFF = listOf(1_000L, 2_000L, 4_000L, 8_000L, 15_000L, 30_000L)

        @OptIn(ExperimentalEncodingApi::class)
        fun parsePairing(text: String): PairingCode? {
            val fragment = text.trim().substringAfter('#', text.trim())
            return runCatching {
                val bytes = Base64.UrlSafe.withPadding(Base64.PaddingOption.ABSENT_OPTIONAL).decode(fragment)
                LinkJson.decodeFromString(PairingCode.serializer(), bytes.decodeToString())
            }.getOrNull()?.takeIf { it.k.isNotEmpty() && it.t.isNotEmpty() && it.p > 0 && it.h.isNotEmpty() }
        }

        fun randomID(): String {
            val bytes = Random.nextBytes(16)
            return bytes.joinToString("") { (it.toInt() and 0xFF).toString(16).padStart(2, '0') }
        }
    }
}

/** One socket, from opening to closing, with its callbacks turned into things to await. */
private class Connection(private val transport: LinkTransport) {
    val opened = CompletableDeferred<Boolean>()
    val firstText = CompletableDeferred<String>()
    val closed = CompletableDeferred<String?>()

    @Volatile
    var onText: ((String) -> Unit)? = null

    private val inbox = Channel<String>(Channel.UNLIMITED)

    fun open(url: String, pin: String) {
        transport.open(url, pin, object : TransportListener {
            override fun onOpen() { opened.complete(true) }
            override fun onText(text: String) {
                if (!firstText.isCompleted) firstText.complete(text) else inbox.trySend(text)
            }
            override fun onClosed(failure: String?) {
                opened.complete(false)
                inbox.close()
                closed.complete(failure)
            }
        })
    }

    fun send(text: String): Boolean = !closed.isCompleted && transport.send(text)

    fun close(reason: String? = null) {
        closed.complete(reason)
        transport.close()
    }

    /** Hands frames after the handshake to [onText], on the collector's thread. */
    suspend fun pump() {
        for (text in inbox) onText?.invoke(text)
    }

    companion object {
        const val REVOKED = "revoked"
    }
}
