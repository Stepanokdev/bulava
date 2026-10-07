package com.stepanok.bulava

import com.stepanok.bulava.link.Block
import com.stepanok.bulava.link.FileRef
import com.stepanok.bulava.link.LinkJson
import com.stepanok.bulava.ui.chat.FileTap
import kotlin.test.Test
import kotlin.test.assertEquals

/**
 * What a tap on a file does. A site, a note or a PDF a Mac can share opens in the phone's browser
 * through it — no longer a bare page in the report viewer, nor nothing at all. A picture keeps its
 * viewer, a web link its browser, and an older Mac keeps what it had.
 */
class FileTapTest {
    private fun file(name: String, kind: String = "document", ref: String? = "lnk:C1:00ff", url: String? = null) =
        FileRef(ref = ref, name = name, kind = kind, url = url)

    @Test
    fun aMacThatSharesOpensEveryFileThroughIt() {
        assertEquals(FileTap.Shared("lnk:C1:00ff"), FileTap.of(file("index.html"), macShares = true))
        assertEquals(FileTap.Shared("lnk:C1:00ff"), FileTap.of(file("plan.md"), macShares = true))
        assertEquals(FileTap.Shared("lnk:C1:00ff"), FileTap.of(file("report.pdf"), macShares = true))
        assertEquals(FileTap.Shared("art:run/site/"), FileTap.of(file("site/", ref = "art:run/site/"), macShares = true))
    }

    @Test
    fun picturesAndLinksKeepTheirOwnWay() {
        assertEquals(FileTap.Picture("lnk:C1:00ff", "shot.png"), FileTap.of(file("shot.png", kind = "image"), macShares = true))
        assertEquals(FileTap.Web("https://bulava.app"), FileTap.of(file("bulava.app", url = "https://bulava.app"), macShares = true))
        assertEquals(FileTap.None, FileTap.of(file("x.md", ref = null), macShares = true), "nothing to ask for")
    }

    @Test
    fun anOlderMacKeepsWhatItHad() {
        assertEquals(FileTap.Report("file:lnk:C1:00ff", "index.html"), FileTap.of(file("index.html"), macShares = false))
        assertEquals(FileTap.None, FileTap.of(file("plan.md"), macShares = false))
    }

    @Test
    fun aBlockFromAnOlderMacHasNoLinks() {
        val block = LinkJson.decodeFromString(Block.serializer(), """{"id":"m1","kind":"markdown","text":"done","files":[]}""")
        assertEquals(emptyList(), block.links)
        val newer = LinkJson.decodeFromString(Block.serializer(),
            """{"id":"m1","kind":"markdown","text":"done","files":[],"links":[{"ref":"lnk:C1:aa","name":"index.html","kind":"document"}]}""")
        assertEquals("index.html", newer.links.single().name)
    }
}
