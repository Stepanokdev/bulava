package com.stepanok.bulava

import com.stepanok.bulava.link.ChatDelta
import com.stepanok.bulava.link.ChatHeader
import com.stepanok.bulava.link.ChatState
import com.stepanok.bulava.link.Entry
import com.stepanok.bulava.link.LinkClient
import com.stepanok.bulava.state.ChatMerge
import com.stepanok.bulava.ui.chat.findMatches
import com.stepanok.bulava.ui.report.REPORT_POLICY
import com.stepanok.bulava.ui.report.inlineResources
import com.stepanok.bulava.ui.report.isolate
import kotlinx.coroutines.test.runTest
import kotlin.test.assertTrue
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNotNull
import kotlin.test.assertNull

class PhoneLogicTest {

    private fun entry(id: String, at: Long, text: String = id) = Entry(id = id, kind = "agent", atMs = at, text = text)

    @Test
    fun aPairingLinkIsReadWholeOrAsItsFragment() {
        // {"v":1,"id":"D","n":"Mac","k":"PIN","p":47291,"h":["10.0.1.4"],"t":"TOKEN","e":1}
        val fragment = "eyJ2IjoxLCJpZCI6IkQiLCJuIjoiTWFjIiwiayI6IlBJTiIsInAiOjQ3MjkxLCJoIjpbIjEwLjAuMS40Il0sInQiOiJUT0tFTiIsImUiOjF9"
        val whole = assertNotNull(LinkClient.parsePairing("https://bulava.app/pair#$fragment"))
        assertEquals("Mac", whole.n)
        assertEquals(47291, whole.p)
        assertEquals(listOf("10.0.1.4"), whole.h)
        assertEquals(whole, LinkClient.parsePairing("bulava://pair#$fragment"))
        assertEquals(whole, LinkClient.parsePairing("  $fragment \n"))
        assertNull(LinkClient.parsePairing("https://bulava.app/pair#nonsense"))
        assertNull(LinkClient.parsePairing("hello"))
    }

    @Test
    fun olderMessagesTheChatScrolledBackToSurviveANewWindow() {
        val loaded = ChatMerge.snapshot(null, ChatState(id = "C", entries = listOf(entry("a", 1), entry("b", 2), entry("c", 3))))
        val window = ChatMerge.snapshot(loaded, ChatState(id = "C", entries = listOf(entry("b", 2), entry("c", 3, "c2"), entry("d", 4))))
        assertEquals(listOf("a", "b", "c", "d"), window.entries.map { it.id })
        assertEquals("c2", window.entries[2].text)
    }

    @Test
    fun aDeltaReplacesRemovesAndKeepsTheMacsOrder() {
        val view = ChatMerge.snapshot(null, ChatState(id = "C", entries = listOf(entry("a", 1), entry("b", 2), entry("c", 2))))
        val next = ChatMerge.delta(view, ChatDelta(
            id = "C", header = ChatHeader(title = "Renamed", busy = true),
            upserts = listOf(entry("b", 2, "b grown"), entry("d", 5)), removed = listOf("a"), order = listOf("c", "b", "d"),
        ))
        assertEquals(listOf("c", "b", "d"), next.entries.map { it.id }, "ties in time follow the Mac's order")
        assertEquals("b grown", next.entries[1].text)
        assertEquals("Renamed", next.state.title)
        assertEquals(true, next.state.busy)
    }

    @Test
    fun findLooksThroughWordsAndBlocksNewestFirst() {
        val entries = listOf(
            Entry(id = "1", atMs = 1, text = "export is grey"),
            Entry(id = "2", atMs = 2, blocks = listOf(com.stepanok.bulava.link.Block(id = "b", kind = "markdown", text = "The EXPORT flag"))),
            Entry(id = "3", atMs = 3, text = "unrelated"),
        )
        assertEquals(listOf(1, 0), findMatches(entries, "export"))
        assertEquals(emptyList(), findMatches(entries, "e"), "one letter is not a search")
    }

    @Test
    fun aReportIsShownUnderAPolicyThatReachesNothing() {
        val withHead = isolate("<html><head><title>R</title></head><body><img src=\"https://x.test/a.png\"></body></html>")
        assertTrue(withHead.indexOf("Content-Security-Policy") < withHead.indexOf("<title>"), "the policy comes before anything can load")
        assertTrue(withHead.contains(REPORT_POLICY))
        val bare = isolate("<p>no head at all</p>")
        assertTrue(bare.startsWith("<head><meta http-equiv=\"Content-Security-Policy\""))
        listOf("default-src 'none'", "connect-src 'none'", "frame-src 'none'", "img-src data:").forEach {
            assertTrue(REPORT_POLICY.contains(it), it)
        }
    }

    @Test
    fun onlyTheReportsOwnFilesAreInlinedAndAbsoluteAddressesAreLeftForThePolicyToRefuse() = runTest {
        val asked = mutableListOf<String>()
        val html = inlineResources("<img src=\"shots/a.png\"><img src=\"https://x.test/b.png\"><script src=\"//x.test/c.js\"></script>") { path ->
            asked += path; byteArrayOf(1, 2, 3)
        }
        assertEquals(listOf("shots/a.png"), asked, "nothing but a relative path is fetched from the Mac")
        assertTrue(html.contains("data:image/png;base64,AQID"))
        assertTrue(html.contains("https://x.test/b.png"))
    }
}
