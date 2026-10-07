package com.stepanok.bulava

import com.stepanok.bulava.link.Credential
import com.stepanok.bulava.link.Desktop
import com.stepanok.bulava.link.ErrorCodes
import com.stepanok.bulava.link.HandshakeReply
import com.stepanok.bulava.link.Home
import com.stepanok.bulava.link.LinkClient
import com.stepanok.bulava.link.LinkJson
import com.stepanok.bulava.link.LinkProtocol
import com.stepanok.bulava.link.LinkState
import com.stepanok.bulava.link.PairedMac
import com.stepanok.bulava.link.PhoneApp
import com.stepanok.bulava.link.PhoneApps
import com.stepanok.bulava.platform.KeyValueStore
import com.stepanok.bulava.platform.LinkTransport
import com.stepanok.bulava.platform.MicPermission
import com.stepanok.bulava.platform.Notifier
import com.stepanok.bulava.platform.PhoneNotification
import com.stepanok.bulava.platform.PickedFile
import com.stepanok.bulava.platform.PlatformServices
import com.stepanok.bulava.platform.TransportListener
import com.stepanok.bulava.platform.VoiceRecorder
import com.stepanok.bulava.state.AppController
import com.stepanok.bulava.state.Dictation
import com.stepanok.bulava.state.Draft
import com.stepanok.bulava.state.UpdateNotice
import com.stepanok.bulava.state.Updates
import com.stepanok.bulava.state.VoiceNote
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.test.StandardTestDispatcher
import kotlinx.coroutines.test.TestScope
import kotlinx.coroutines.test.advanceTimeBy
import kotlinx.coroutines.test.advanceUntilIdle
import kotlinx.coroutines.test.runTest
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.put
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertIs
import kotlin.test.assertNotNull
import kotlin.test.assertNull
import kotlin.test.assertTrue

/**
 * Dictation the Mac transcribes, against a Mac that answers `audio.transcribe` the way this test
 * says: the words land in the composer of the chat the note was recorded in, once, never sent;
 * whatever goes wrong leaves the recording on the phone with a reason and, where it can help,
 * "try again" — which asks under the same request id, so a Mac that already heard it answers from
 * memory instead of putting the words in twice.
 */
class DictationTest {

    /** A Mac with the link's upload and transcription, and nothing else. */
    private class Mac(var capabilities: List<String> = LinkProtocol.USED_CAPABILITIES.toList()) {
        /** What `audio.transcribe` answers: a result, an error code, or null — no answer at all. */
        var answer: (JsonObject) -> Pair<String?, String?>? = { "words" to null }
        val transcribeCalls = mutableListOf<JsonObject>()
        val uploads = mutableListOf<String>()
        var reachable = true
        private val received = mutableMapOf<String, Int>()
        private var listener: TransportListener? = null

        fun transport(): LinkTransport = object : LinkTransport {
            override fun open(url: String, pin: String, listener: TransportListener) {
                if (!reachable) return listener.onClosed("refused")
                this@Mac.listener = listener
                listener.onOpen()
            }
            override fun send(text: String): Boolean {
                val l = this@Mac.listener ?: return false
                receive(l, text)
                return true
            }
            override fun close() {
                val l = this@Mac.listener ?: return
                this@Mac.listener = null
                l.onClosed(null)
            }
        }

        fun drop() { listener?.let { listener = null; it.onClosed("gone") } }

        private fun receive(l: TransportListener, text: String) {
            val frame = LinkJson.parseToJsonElement(text).jsonObject
            when (frame["type"]?.jsonPrimitive?.contentOrNull) {
                "hello" -> l.onText(LinkJson.encodeToString(HandshakeReply.serializer(), HandshakeReply(
                    type = "welcome", protocolVersion = 1, desktop = Desktop("mac", "Studio", "1.9"), capabilities = capabilities,
                )))
                "request" -> {
                    val id = frame["id"]!!.jsonPrimitive.content
                    val op = frame["op"]!!.jsonPrimitive.content
                    val args = frame["args"] as? JsonObject ?: JsonObject(emptyMap())
                    val reply: Pair<JsonElement?, String?>? = when (op) {
                        "upload.begin" -> {
                            val upload = "U${uploads.size + 1}"
                            uploads += upload
                            buildJsonObject { put("uploadID", upload); put("chunkSize", 16 * 1024) } to null
                        }
                        "upload.chunk" -> {
                            val upload = args["uploadID"]!!.jsonPrimitive.content
                            received[upload] = (received[upload] ?: 0) + 1
                            buildJsonObject { put("received", 1) } to null
                        }
                        "upload.finish" -> buildJsonObject {
                            put("ref", "att:" + args["uploadID"]!!.jsonPrimitive.content); put("name", "d.m4a"); put("kind", "audio")
                        } to null
                        "audio.transcribe" -> {
                            transcribeCalls += args
                            answer(args)?.let { (text, error) ->
                                if (error != null) null to error
                                else buildJsonObject {
                                    put("requestID", args["requestID"]!!.jsonPrimitive.content)
                                    args["chatID"]?.jsonPrimitive?.contentOrNull?.let { put("chatID", it) }
                                    put("text", text ?: "")
                                } to null
                            }
                        }
                        else -> null to null
                    }
                    if (reply == null) return // never answered
                    l.onText(LinkJson.encodeToString(JsonObject.serializer(), buildJsonObject {
                        put("type", "response")
                        put("id", id)
                        val (result, error) = reply
                        if (error == null) { put("ok", true); result?.let { put("result", it) } }
                        else { put("ok", false); put("error", buildJsonObject { put("code", error); put("message", "") }) }
                    }))
                }
            }
        }
    }

    /** A microphone that writes a file of bytes and keeps track of what was deleted. */
    private class Mic : VoiceRecorder {
        var permission = MicPermission.Granted
        var asked = 0
        val files = mutableMapOf<String, ByteArray>()
        var size = 3_000
        private var current: String? = null
        private var n = 0
        override fun permission() = permission
        override fun requestPermission(onResult: (Boolean) -> Unit) { asked++; permission = MicPermission.Granted; onResult(true) }
        override fun openSettings() = Unit
        override fun newRecordingPath() = "/voice/${++n}.m4a"
        override fun start(path: String): Boolean { current = path; return true }
        override fun level() = 0.5f
        override fun stop(): Boolean { current?.let { files[it] = ByteArray(size) { i -> i.toByte() } }; current = null; return true }
        override fun cancel() { current = null }
        override fun read(path: String) = files[path]
        override fun delete(path: String) { files.remove(path) }
        override fun exists(path: String) = path in files
    }

    private class Phone(private val mac: Mac, val mic: Mic?) : PlatformServices {
        override val platformName = "android"
        override fun deviceName() = "Pixel"
        override fun osVersion() = "Android 17"
        override fun appVersion() = "1.0"
        override fun appBuild() = 7
        override fun transport() = mac.transport()
        override val secure = Memory().apply {
            put(LinkClient.PAIRED_KEY, LinkJson.encodeToString(PairedMac.serializer(), PairedMac(
                desktopID = "mac", name = "Studio", pin = "pin", hosts = listOf("mac"), port = 1, credential = Credential("d", "s"),
            )))
        }
        override val prefs = Memory()
        override val notifier = object : Notifier {
            override fun post(note: PhoneNotification) = Unit
            override fun cancel(id: String) = Unit
        }
        override fun openUrl(url: String) = Unit
        override fun scanCode(onResult: (String?) -> Unit) = Unit
        override fun pickImage(onResult: (PickedFile?) -> Unit) = Unit
        override fun pickFile(onResult: (PickedFile?) -> Unit) = Unit
        override fun discover(desktopID: String, onFound: (List<String>) -> Unit) = onFound(emptyList())
        override fun keepLinkAlive(active: Boolean, macName: String) = Unit
        override fun notificationsAllowed() = true
        override fun requestNotifications() = Unit
        override fun openAppSettings() = Unit
        override val voice: VoiceRecorder? get() = mic
    }

    private class Memory : KeyValueStore {
        private val values = mutableMapOf<String, String>()
        override fun get(key: String) = values[key]
        override fun put(key: String, value: String) { values[key] = value }
        override fun remove(key: String) { values.remove(key) }
    }

    private var time = 1_790_000_000_000L
    private fun TestScope.scope() = CoroutineScope(StandardTestDispatcher(testScheduler) + SupervisorJob())
    private fun TestScope.setup(mac: Mac = Mac(), mic: Mic? = Mic()): Triple<Phone, AppController, CoroutineScope> {
        val scope = scope()
        val phone = Phone(mac, mic)
        val c = AppController(phone, scope) { time + testScheduler.currentTime }
        return Triple(phone, c, scope)
    }

    /** Records [seconds] of speech into [chatID] and lets the note go to the Mac. */
    private fun TestScope.dictate(c: AppController, chatID: String = "C1", seconds: Long = 4) {
        assertEquals(Dictation.Start.Started, c.dictation.start("P1", chatID))
        time += seconds * 1000
        c.dictation.finish()
        advanceUntilIdle()
    }

    @Test
    fun theWordsLandInTheChatTheyWereSpokenInOnceAndNothingIsSent() = runTest {
        val mac = Mac()
        val (phone, c, scope) = setup(mac)
        advanceUntilIdle()
        c.setDraft("C1", Draft("Before that,"))
        mac.answer = { "make the export grey" to null }
        dictate(c, "C1")

        assertEquals("Before that,\nmake the export grey", c.draft("C1").text, "after what was written, on a line of its own")
        assertTrue(c.dictation.notes.value.isEmpty())
        assertTrue(phone.mic!!.files.isEmpty(), "the recording goes once its words are in")
        assertTrue(c.outbox.value.isEmpty(), "dictation never sends a message")
        val asked = mac.transcribeCalls.single()
        assertEquals("C1", asked["chatID"]?.jsonPrimitive?.content)
        assertTrue(asked["ref"]?.jsonPrimitive?.content.orEmpty().startsWith("att:"))
        scope.cancel()
    }

    @Test
    fun aMacWithoutItsModelKeepsTheRecordingAndTryingAgainHearsItOnce() = runTest {
        val mac = Mac()
        val (phone, c, scope) = setup(mac)
        advanceUntilIdle()
        mac.answer = { null to ErrorCodes.DICTATION_UNAVAILABLE }
        dictate(c)

        val note = c.dictation.notes.value.single()
        assertEquals(VoiceNote.Stage.Failed, note.stage)
        assertEquals(ErrorCodes.DICTATION_UNAVAILABLE, note.failure)
        assertTrue(note.retryable)
        assertNull(note.ref, "the Mac deletes what it heard; trying again sends the recording again")
        assertTrue(note.path in phone.mic!!.files, "the recording stays on the phone")

        mac.answer = { "now it works" to null }
        c.dictation.retry(note.requestID)
        advanceUntilIdle()
        assertEquals("now it works", c.draft("C1").text)
        assertEquals(listOf(note.requestID, note.requestID), mac.transcribeCalls.map { it["requestID"]!!.jsonPrimitive.content },
            "the same request, both times")
        assertEquals(2, mac.uploads.size)
        scope.cancel()
    }

    @Test
    fun aMacThatTakesTooLongIsAskedAgainUnderTheSameRequestAndTheWordsGoInOnce() = runTest {
        val mac = Mac()
        val (_, c, scope) = setup(mac)
        advanceUntilIdle()
        mac.answer = { null } // still loading its model: no answer in time
        assertEquals(Dictation.Start.Started, c.dictation.start("P1", "C1"))
        time += 3_000
        c.dictation.finish()
        advanceTimeBy(Dictation.TRANSCRIBE_TIMEOUT + 1_000)

        val note = c.dictation.notes.value.single()
        assertEquals(ErrorCodes.TIMEOUT, note.failure)
        assertNotNull(note.ref, "nothing says the Mac is done with it: the same file is named again")

        // The Mac finished meanwhile and remembers the words under this request.
        mac.answer = { "said once" to null }
        c.dictation.retry(note.requestID)
        advanceUntilIdle()
        c.dictation.retry(note.requestID) // a second press after the words are in does nothing
        advanceUntilIdle()
        assertEquals("said once", c.draft("C1").text)
        assertEquals(1, mac.uploads.size, "the recording went up once")
        assertEquals(2, mac.transcribeCalls.size)
        scope.cancel()
    }

    @Test
    fun aMacThatForgotTheUploadIsSentTheRecordingAgainOnce() = runTest {
        val mac = Mac()
        val (_, c, scope) = setup(mac)
        advanceUntilIdle()
        mac.answer = { null }
        dictate(c)
        advanceTimeBy(Dictation.TRANSCRIBE_TIMEOUT + 1_000)
        val note = c.dictation.notes.value.single()

        // Restarted: neither the file nor the request is known any more.
        mac.answer = { args -> if (args["ref"]?.jsonPrimitive?.content == note.ref) null to ErrorCodes.NOT_FOUND else "again" to null }
        c.dictation.retry(note.requestID)
        advanceUntilIdle()
        assertEquals("again", c.draft("C1").text)
        assertEquals(2, mac.uploads.size)
        scope.cancel()
    }

    @Test
    fun aMacOutOfReachOrTooOldLeavesTheNoteWithItsReason() = runTest {
        val mac = Mac(capabilities = LinkProtocol.USED_CAPABILITIES.toList() - Dictation.CAPABILITY)
        val (phone, c, scope) = setup(mac)
        advanceUntilIdle()
        assertFalse(c.dictation.macCanTranscribe)
        dictate(c)
        assertEquals(Dictation.MAC_TOO_OLD, c.dictation.notes.value.single().failure)

        mac.capabilities = LinkProtocol.USED_CAPABILITIES.toList()
        mac.reachable = false
        mac.drop()
        advanceTimeBy(1_000)
        val stopped = c.dictation.notes.value.single()
        c.dictation.retry(stopped.requestID)
        advanceTimeBy(1_000)
        assertEquals(ErrorCodes.OFFLINE, c.dictation.notes.value.single().failure)
        assertTrue(stopped.path in phone.mic!!.files)

        c.dictation.discard(stopped.requestID)
        assertTrue(c.dictation.notes.value.isEmpty())
        assertTrue(phone.mic.files.isEmpty(), "thrown away, file and all")
        assertEquals("", c.draft("C1").text)
        scope.cancel()
    }

    @Test
    fun aRecordingTooBigOrGoneCanOnlyBeThrownAwayAndATapIsNotARecording() = runTest {
        val mic = Mic()
        val (_, c, scope) = setup(mic = mic)
        advanceUntilIdle()
        mic.size = (Dictation.MAX_BYTES + 1).toInt()
        dictate(c)
        val big = c.dictation.notes.value.single()
        assertEquals(ErrorCodes.TOO_LARGE, big.failure)
        assertFalse(big.retryable)
        c.dictation.discard(big.requestID)

        mic.size = 3_000
        assertEquals(Dictation.Start.Started, c.dictation.start("P1", "C1"))
        time += 100
        c.dictation.finish()
        advanceUntilIdle()
        assertTrue(c.dictation.notes.value.isEmpty(), "a tap that let go at once sends nothing")
        assertTrue(mic.files.isEmpty())
        scope.cancel()
    }

    @Test
    fun theMicrophoneIsAskedForAtTheFirstTapAndARefusalIsSaid() = runTest {
        val mic = Mic().apply { permission = MicPermission.NotAsked }
        val (_, c, scope) = setup(mic = mic)
        advanceUntilIdle()
        var asked: Dictation.Start? = null
        assertEquals(Dictation.Start.NeedsPermission, c.dictation.start("P1", "C1") { asked = it })
        assertEquals(Dictation.Start.Started, asked)
        assertEquals(1, mic.asked)
        c.dictation.cancelRecording()
        mic.permission = MicPermission.Denied
        assertEquals(Dictation.Start.Denied, c.dictation.start("P1", "C1"))
        scope.cancel()
    }

    @Test
    fun aPhoneWithNoMicrophoneOffersNone() = runTest {
        val (_, c, scope) = setup(mic = null)
        assertEquals(Dictation.Start.Unavailable, c.dictation.start("P1", "C1"))
        scope.cancel()
    }

    // MARK: Versions

    private val newer = PhoneApps(
        android = PhoneApp("1.1", 9, "https://bulava.app/Bulava-android.apk"),
        ios = PhoneApp("1.1", 9, "https://testflight.apple.com/join/x"),
    )

    @Test
    fun theBannerNamesTheDeviceToUpdate() {
        val connected = LinkState.Connected(Desktop(name = "Studio"), emptySet())
        val tooOld = Updates.decide(
            LinkState.Incompatible("Studio", ErrorCodes.PROTOCOL_TOO_OLD, "", "2.0", newer), null, "ios", "1.0", 7, null,
        )
        assertIs<UpdateNotice.PhoneTooOld>(tooOld)
        assertEquals("1.1", tooOld.newest)
        assertEquals("https://testflight.apple.com/join/x", tooOld.url, "the phone's own platform")
        val fromAnOlderMac = Updates.decide(LinkState.Incompatible("Studio", ErrorCodes.PROTOCOL_TOO_OLD, ""), null, "android", "1.0", 7, null)
        assertIs<UpdateNotice.PhoneTooOld>(fromAnOlderMac)
        assertNull(fromAnOlderMac.newest)
        assertEquals(LinkProtocol.DOWNLOAD_PAGE, fromAnOlderMac.url)

        val macTooOld = Updates.decide(LinkState.Incompatible("Studio", ErrorCodes.PROTOCOL_TOO_NEW, "", "1.8"), Home(phoneApps = newer), "android", "1.0", 7, null)
        assertEquals(UpdateNotice.MacTooOld("Studio", "1.8", "1.0"), macTooOld, "the Mac's turn comes first; no offer of a phone update over it")

        assertNull(Updates.decide(connected, Home(), "android", "1.0", 7, null), "an older Mac says nothing about phone versions")
        assertNull(Updates.decide(LinkState.Offline("Studio", null, true), null, "android", "1.0", 7, null))
    }

    @Test
    fun aNewerAppIsOfferedUntilItIsPutOffAndTheNextOneAsksAgain() {
        val connected = LinkState.Connected(Desktop(name = "Studio"), emptySet())
        val home = Home(phoneApps = newer)
        val offer = Updates.decide(connected, home, "android", "1.0", 7, null)
        assertIs<UpdateNotice.Available>(offer)
        assertEquals(9, offer.newest.build)
        assertNull(Updates.decide(connected, home, "android", "1.1", 9, null), "the build that is out is the one installed")
        assertNull(Updates.decide(connected, home, "android", "1.0", 7, 9), "put off for this build")
        assertIs<UpdateNotice.Available>(Updates.decide(connected, home, "android", "1.0", 7, 8), "a later build asks again")
        assertNull(Updates.decide(connected, home, "android", "1.0", 0, null), "an unknown build is never told to update to itself")
        assertNull(Updates.decide(connected, Home(phoneApps = PhoneApps(android = PhoneApp("1.1", 9, "http://plain"))), "android", "1.0", 7, null),
            "only an https address is opened")
        assertNull(Updates.decide(connected, Home(phoneApps = PhoneApps(ios = newer.ios)), "android", "1.0", 7, null), "another platform's release")
    }
}
