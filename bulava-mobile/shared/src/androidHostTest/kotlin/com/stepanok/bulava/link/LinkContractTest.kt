package com.stepanok.bulava.link

import kotlinx.serialization.KSerializer
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.int
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import java.io.File
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertTrue
import kotlin.test.fail

/**
 * The phone's half of the wire contract: the same files the Mac's `LinkContractTests` writes are
 * read here. If the Mac starts sending something the phone does not model, this fails — on the
 * phone's side, before either ships. See `link-protocol/README.md`.
 */
class LinkContractTest {
    private val root = generateSequence(File(System.getProperty("user.dir") ?: ".").absoluteFile) { it.parentFile }
        .map { File(it, "link-protocol") }
        .first { it.isDirectory }

    private fun read(path: String): JsonElement = LinkJson.parseToJsonElement(File(root, path).readText())

    /**
     * The iPhone's widgets read the week back in Swift, from what this phone re-encodes — not from
     * the Mac's own bytes. Swift's decoder needs every key it models, so every key the Mac sent has
     * to come back out of the round trip, at every depth.
     */
    @Test
    fun theWeekSurvivesTheRoundTripToTheWidgetsKeyForKey() {
        val original = read("fixtures/v1/home.json").jsonObject["data"]!!.jsonObject["week"]!!
        val week = LinkJson.decodeFromJsonElement(Week.serializer(), original)
        val again = LinkJson.parseToJsonElement(LinkJson.encodeToString(Week.serializer(), week))
        fun keys(e: JsonElement, at: String = ""): Set<String> = when (e) {
            is JsonObject -> e.flatMap { (k, v) -> keys(v, "$at.$k") + "$at.$k" }.toSet()
            is JsonArray -> e.flatMapIndexed { i, v -> keys(v, "$at[$i]") }.toSet()
            else -> emptySet()
        }
        val lost = keys(original) - keys(again)
        assertTrue(lost.isEmpty(), "the widgets would not find these after the phone re-encodes the week: $lost")
        // Numbers compare by value: Swift writes 275 where Kotlin writes 275.0, and both decode alike.
        fun same(a: JsonElement, b: JsonElement): Boolean = when {
            a is JsonObject && b is JsonObject -> a.keys == b.keys && a.keys.all { same(a[it]!!, b[it]!!) }
            a is JsonArray && b is JsonArray -> a.size == b.size && a.indices.all { same(a[it], b[it]) }
            a is kotlinx.serialization.json.JsonPrimitive && b is kotlinx.serialization.json.JsonPrimitive ->
                a.content == b.content || (a.content.toDoubleOrNull() != null && a.content.toDoubleOrNull() == b.content.toDoubleOrNull())
            else -> a == b
        }
        assertTrue(same(original, again), "the week the widgets read must say exactly what the Mac sent")
    }

    @Test
    fun theVersionAndCapabilitiesAreTheOnesInTheContract() {
        val contract = read("contract.json").jsonObject
        assertEquals(LinkProtocol.VERSION, contract["protocolVersion"]!!.jsonPrimitive.int)
        assertEquals(LinkProtocol.MINIMUM_VERSION, contract["minimumVersion"]!!.jsonPrimitive.int)
        val offered = contract["capabilities"]!!.jsonArray.map { it.jsonPrimitive.content }.toSet()
        val missing = LinkProtocol.USED_CAPABILITIES - offered
        assertTrue(missing.isEmpty(), "the phone relies on capabilities no Mac offers: $missing")
    }

    /** Which Kotlin type reads each fixture, and where in the file its payload sits. */
    private val readers: Map<String, Pair<KSerializer<*>, (JsonElement) -> JsonElement>> = mapOf(
        "hello-pairing" to (Hello.serializer() to { it }),
        "hello-credential" to (Hello.serializer() to { it }),
        "welcome" to (HandshakeReply.serializer() to { it }),
        "refused" to (HandshakeReply.serializer() to { it }),
        "home" to (Home.serializer() to { it.jsonObject["data"]!! }),
        "chat" to (ChatState.serializer() to { it.jsonObject["data"]!! }),
        "chat-delta" to (ChatDelta.serializer() to { it.jsonObject["data"]!! }),
        "response-sent" to (Sent.serializer() to { it.jsonObject["result"]!! }),
        "response-stale" to (LinkError.serializer() to { it.jsonObject["error"]!! }),
        "response-file" to (FileChunk.serializer() to { it.jsonObject["result"]!! }),
        "response-report" to (Report.serializer() to { it.jsonObject["result"]!! }),
        "response-commands" to (kotlinx.serialization.builtins.ListSerializer(Option.serializer()) to { it.jsonObject["result"]!! }),
        "response-context" to (Context.serializer() to { it.jsonObject["result"]!! }),
        "response-diff" to (Diff.serializer() to { it.jsonObject["result"]!! }),
        "response-skills" to (Skills.serializer() to { it.jsonObject["result"]!! }),
        "response-transcript" to (Transcript.serializer() to { it.jsonObject["result"]!! }),
        "response-open" to (FileOpen.serializer() to { it.jsonObject["result"]!! }),
        "response-report-decisions" to (Report.serializer() to { it.jsonObject["result"]!! }),
        "response-decisions-conflict" to (LinkError.serializer() to { it.jsonObject["error"]!! }),
    )

    @Test
    fun everyFileTheMacWritesIsReadAndNothingInItIsIgnored() {
        val files = File(root, "fixtures/v1").listFiles { f -> f.extension == "json" }.orEmpty()
        assertTrue(files.isNotEmpty(), "no fixtures — run the Mac's LinkContractTests with BULAVA_UPDATE_FIXTURES=1")
        for (file in files) {
            val name = file.nameWithoutExtension
            val (serializer, payload) = readers[name]
                ?: fail("$name.json has no reader on the phone. A new message type needs a Kotlin model and an entry here.")
            val whole = LinkJson.parseToJsonElement(file.readText())
            // The envelope itself must decode too.
            if (whole.jsonObject["type"]?.jsonPrimitive?.content in setOf("event", "response")) {
                LinkJson.decodeFromJsonElement(Incoming.serializer(), whole)
            }
            val sent = payload(whole)
            @Suppress("UNCHECKED_CAST")
            val typed = serializer as KSerializer<Any?>
            val decoded = LinkJson.decodeFromJsonElement(typed, sent)
            val known = paths(LinkJson.encodeToJsonElement(typed, decoded))
            val unknown = paths(sent) - known
            assertTrue(unknown.isEmpty(), "$name.json: the Mac sends fields the phone does not read: $unknown")
        }
    }

    @Test
    fun aNewerMacWithNewFieldsAndNewValuesStillReads() {
        val home = LinkJson.decodeFromJsonElement(Home.serializer(), read("fixtures/future/home-from-a-newer-mac.json").jsonObject["data"]!!)
        assertEquals("hibernating", home.products.single().chats.single().status.code, "an unknown status code is kept, not dropped")
        assertEquals("biometric", home.attention.single().actions.single().kind, "an unknown button kind arrives as itself")
        val chat = LinkJson.decodeFromJsonElement(ChatState.serializer(), read("fixtures/future/chat-from-a-newer-mac.json").jsonObject["data"]!!)
        assertEquals(listOf("hologram", "agent"), chat.entries.map { it.kind })
        assertEquals("diagram", chat.entries[1].blocks.single().kind)
    }

    private fun paths(element: JsonElement, prefix: String = ""): Set<String> = when (element) {
        is JsonObject -> element.flatMap { (key, value) -> setOf("$prefix.$key") + paths(value, "$prefix.$key") }.toSet()
        is JsonArray -> element.flatMap { paths(it, "$prefix[]") }.toSet()
        else -> emptySet()
    }
}
