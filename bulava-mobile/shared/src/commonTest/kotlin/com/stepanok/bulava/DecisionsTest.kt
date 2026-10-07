package com.stepanok.bulava

import com.stepanok.bulava.link.Credential
import com.stepanok.bulava.link.Desktop
import com.stepanok.bulava.link.ErrorCodes
import com.stepanok.bulava.link.HandshakeReply
import com.stepanok.bulava.link.LinkClient
import com.stepanok.bulava.link.LinkJson
import com.stepanok.bulava.link.LinkProtocol
import com.stepanok.bulava.link.PairedMac
import com.stepanok.bulava.platform.KeyValueStore
import com.stepanok.bulava.platform.LinkTransport
import com.stepanok.bulava.platform.Notifier
import com.stepanok.bulava.platform.PhoneNotification
import com.stepanok.bulava.platform.PickedFile
import com.stepanok.bulava.platform.PlatformServices
import com.stepanok.bulava.platform.TransportListener
import com.stepanok.bulava.state.AppController
import com.stepanok.bulava.state.DecisionDraft
import com.stepanok.bulava.state.Decided
import com.stepanok.bulava.state.asDraft
import com.stepanok.bulava.ui.report.shownAnswer
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.async
import kotlinx.coroutines.cancel
import kotlinx.coroutines.test.StandardTestDispatcher
import kotlinx.coroutines.test.TestScope
import kotlinx.coroutines.test.advanceTimeBy
import kotlinx.coroutines.test.advanceUntilIdle
import kotlinx.coroutines.test.runTest
import kotlinx.serialization.builtins.MapSerializer
import kotlinx.serialization.builtins.serializer
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.put
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertIs
import kotlin.test.assertNotNull
import kotlin.test.assertNull
import kotlin.test.assertTrue

/**
 * His answer to a report's questions, from the phone: kept as it is ticked, sent under an id of
 * its own, and sent again under the same id when the Mac never said it arrived — after a dropped
 * connection, or after the app was closed with it on its way — so the Mac writes it once.
 */
class DecisionsTest {

    /** A Mac that answers `report.decide` the way the test says, and records what it was asked. */
    private class Mac {
        /** A result, an error code, or null — no answer at all. */
        var answer: (JsonObject) -> Pair<JsonElement?, String?>? = { args ->
            buildJsonObject { put("id", args["submissionID"]!!.jsonPrimitive.content); put("sentAt", 1); put("device", "phone") } to null
        }
        val decideCalls = mutableListOf<JsonObject>()
        private var listener: TransportListener? = null

        fun transport(): LinkTransport = object : LinkTransport {
            override fun open(url: String, pin: String, listener: TransportListener) {
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

        private fun receive(l: TransportListener, text: String) {
            val frame = LinkJson.parseToJsonElement(text).jsonObject
            when (frame["type"]?.jsonPrimitive?.contentOrNull) {
                "hello" -> l.onText(LinkJson.encodeToString(HandshakeReply.serializer(), HandshakeReply(
                    type = "welcome", protocolVersion = 1, desktop = Desktop("mac", "Studio", "1.12"),
                    capabilities = LinkProtocol.USED_CAPABILITIES.toList(),
                )))
                "request" -> {
                    val id = frame["id"]!!.jsonPrimitive.content
                    val op = frame["op"]!!.jsonPrimitive.content
                    val args = frame["args"] as? JsonObject ?: JsonObject(emptyMap())
                    val reply: Pair<JsonElement?, String?> = if (op == "report.decide") {
                        decideCalls += args
                        answer(args) ?: return
                    } else null to null
                    l.onText(LinkJson.encodeToString(JsonObject.serializer(), buildJsonObject {
                        put("type", "response")
                        put("id", id)
                        val (result, error) = reply
                        if (error == null) { put("ok", true); result?.let { put("result", it) } }
                        else { put("ok", false); put("error", buildJsonObject { put("code", error); put("message", "changed meanwhile") }) }
                    }))
                }
            }
        }
    }

    private class Phone(private val mac: Mac, override val prefs: Memory = Memory()) : PlatformServices {
        override val platformName = "ios"
        override fun deviceName() = "iPhone"
        override fun osVersion() = "iOS 26"
        override fun appVersion() = "1.0"
        override fun appBuild() = 7
        override fun transport() = mac.transport()
        override val secure = Memory().apply {
            put(LinkClient.PAIRED_KEY, LinkJson.encodeToString(PairedMac.serializer(), PairedMac(
                desktopID = "mac", name = "Studio", pin = "pin", hosts = listOf("mac"), port = 1, credential = Credential("d", "s"),
            )))
        }
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
    }

    private class Memory : KeyValueStore {
        val values = mutableMapOf<String, String>()
        override fun get(key: String) = values[key]
        override fun put(key: String, value: String) { values[key] = value }
        override fun remove(key: String) { values.remove(key) }
    }

    private val ref = "dec:0123456789abcdef01234567"
    private fun TestScope.setup(mac: Mac, prefs: Memory = Memory()): Pair<AppController, CoroutineScope> {
        val scope = CoroutineScope(StandardTestDispatcher(testScheduler) + SupervisorJob())
        return AppController(Phone(mac, prefs), scope) { 1_790_000_000_000L + testScheduler.currentTime } to scope
    }

    @Test
    fun whatIsTickedIsKeptAndWhatIsSentIsExactlyThat() = runTest {
        val mac = Mac()
        val prefs = Memory()
        val (c, scope) = setup(mac, prefs)
        advanceUntilIdle()
        c.setDecisionDraft(ref, DecisionDraft(choices = mapOf("leak" to "Take it"), comments = mapOf("leak" to "today", "x" to " "),
            general = "Start with the leak."))
        val (reopened, second) = setup(Mac(), prefs)
        advanceUntilIdle()
        assertEquals(mapOf("leak" to "Take it"), reopened.decisionDraft(ref).choices, "a closed app loses nothing ticked")

        val outcome = c.decide(ref, revision = "r1", basedOn = "PREV")
        assertIs<Decided.Sent>(outcome)
        val asked = mac.decideCalls.single()
        assertEquals(ref, asked["ref"]!!.jsonPrimitive.content)
        assertEquals("r1", asked["revision"]!!.jsonPrimitive.content)
        assertEquals("PREV", asked["basedOn"]!!.jsonPrimitive.content)
        assertEquals("Take it", asked["choices"]!!.jsonObject["leak"]!!.jsonPrimitive.content)
        assertEquals(setOf("leak"), asked["comments"]!!.jsonObject.keys, "a blank comment is no comment")
        assertEquals("Start with the leak.", asked["general"]!!.jsonPrimitive.content)
        assertTrue(c.decisionDraft(ref).isEmpty, "what the Mac has is no longer kept here")
        assertNull(c.decisions.value[ref])
        scope.cancel(); second.cancel()
    }

    @Test
    fun anAnswerTheMacNeverAcknowledgedGoesAgainUnderTheSameId() = runTest {
        val mac = Mac()
        val (c, scope) = setup(mac)
        advanceUntilIdle()
        c.setDecisionDraft(ref, DecisionDraft(choices = mapOf("leak" to "No")))
        val heard = mac.answer
        mac.answer = { null }                     // the reply is lost on the way back
        val first = async { c.decide(ref, "r1", null) }
        advanceTimeBy(31_000)
        assertIs<Decided.Waiting>(first.await())
        val kept = c.decisionDraft(ref)
        assertNotNull(kept.sending, "it is on its way, not dropped")
        assertEquals(mapOf("leak" to "No"), kept.choices)

        mac.answer = heard
        assertIs<Decided.Sent>(c.decide(ref, "r1", null))
        val ids = mac.decideCalls.map { it["submissionID"]!!.jsonPrimitive.content }
        assertEquals(2, ids.size)
        assertEquals(ids[0], ids[1], "the same answer, so the Mac writes it once")
        scope.cancel()
    }

    @Test
    fun anAnswerOnItsWayWhenTheAppClosedGoesByItselfOnceConnected() = runTest {
        val mac = Mac()
        val prefs = Memory()
        prefs.put("bulava.decisions", LinkJson.encodeToString(MapSerializer(String.serializer(), DecisionDraft.serializer()),
            mapOf(ref to DecisionDraft(choices = mapOf("leak" to "Later"), revision = "r1", sending = "SUB-1"))))
        val (c, scope) = setup(mac, prefs)
        advanceUntilIdle()
        val asked = mac.decideCalls.single()
        assertEquals("SUB-1", asked["submissionID"]!!.jsonPrimitive.content)
        assertEquals("Later", asked["choices"]!!.jsonObject["leak"]!!.jsonPrimitive.content)
        assertTrue(c.decisionDraft(ref).isEmpty)
        scope.cancel()
    }

    @Test
    fun questionsThatChangedAreReadAgainAndWhatWasTickedStays() = runTest {
        val mac = Mac()
        val (c, scope) = setup(mac)
        advanceUntilIdle()
        c.setDecisionDraft(ref, DecisionDraft(choices = mapOf("leak" to "Take it")))
        for (code in listOf(ErrorCodes.DECISIONS_CHANGED, ErrorCodes.DECISIONS_CONFLICT)) {
            mac.answer = { null to code }
            assertIs<Decided.ReadAgain>(c.decide(ref, "r1", null))
            val kept = c.decisionDraft(ref)
            assertNull(kept.sending, "refused, not on its way: the next send is a new answer")
            assertEquals(mapOf("leak" to "Take it"), kept.choices)
        }
        scope.cancel()
    }

    private val questions = com.stepanok.bulava.link.Decisions(
        ref = ref, title = "What next", revision = "r2",
        items = listOf(
            com.stepanok.bulava.link.DecisionItem(id = "leak", title = "Close the leak", options = listOf("Take it", "Later", "No")),
            com.stepanok.bulava.link.DecisionItem(id = "docs", title = "Rewrite the docs", options = listOf("Yes", "No")),
        ),
    )

    @Test
    fun anAnsweredReportOpensWithTheAnswerThatWasSent() {
        val sent = com.stepanok.bulava.link.DecisionSent(
            id = "S1", choices = mapOf("leak" to "Later", "gone" to "Yes", "docs" to "Maybe"),
            comments = mapOf("leak" to "after the release", "gone" to "x"), general = "Small steps.",
        ).asDraft(questions)
        assertEquals(mapOf("leak" to "Later"), sent.choices,
            "what still fits the questions is shown; an item that is gone, or an option it no longer offers, is not")
        assertEquals(mapOf("leak" to "after the release"), sent.comments)
        assertEquals("Small steps.", sent.general)

        assertEquals(sent, shownAnswer(null, sent), "nothing of his own yet: the sent answer is what he sees")
        val edited = sent.copy(choices = mapOf("leak" to "Take it"))
        assertEquals(edited, shownAnswer(edited, sent), "a change of his own is shown over it")
        assertTrue(sent.answersLike(sent.copy(comments = sent.comments + ("docs" to "  "), general = " Small steps. ")),
            "blank comments and spaces around the text are not a change")
        assertTrue(!edited.answersLike(sent))
        assertEquals(DecisionDraft(), shownAnswer(null, null))
    }

    @Test
    fun clearingAnAnswerThatWasSentIsKeptAsAChange() = runTest {
        val prefs = Memory()
        val (c, scope) = setup(Mac(), prefs)
        advanceUntilIdle()
        val sent = com.stepanok.bulava.link.DecisionSent(id = "S1", choices = mapOf("leak" to "Later")).asDraft(questions)
        c.setDecisionDraft(ref, DecisionDraft(), keepEmpty = true)
        assertNotNull(c.decisions.value[ref], "nothing ticked over a sent answer stays nothing, not the sent answer again")
        assertEquals(DecisionDraft(), shownAnswer(c.decisions.value[ref], sent))

        val (reopened, second) = setup(Mac(), prefs)
        advanceUntilIdle()
        assertEquals(DecisionDraft(), shownAnswer(reopened.decisions.value[ref], sent), "and so after the app was closed")

        c.setDecisionDraft(ref, DecisionDraft())
        assertNull(c.decisions.value[ref], "with nothing sent, an empty draft is no draft")
        assertEquals(sent, shownAnswer(c.decisions.value[ref], sent), "without one of his own, the sent answer shows")
        scope.cancel(); second.cancel()
    }
}
