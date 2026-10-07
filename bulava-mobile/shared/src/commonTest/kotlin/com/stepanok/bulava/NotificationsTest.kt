package com.stepanok.bulava

import com.stepanok.bulava.demo.DemoMac
import com.stepanok.bulava.demo.demoText
import com.stepanok.bulava.link.Action
import com.stepanok.bulava.link.ActionInput
import com.stepanok.bulava.link.Credential
import com.stepanok.bulava.link.Attention
import com.stepanok.bulava.link.Finished
import com.stepanok.bulava.link.Home
import com.stepanok.bulava.link.Live
import com.stepanok.bulava.link.LiveLine
import com.stepanok.bulava.link.Product
import com.stepanok.bulava.link.LinkClient
import com.stepanok.bulava.link.LinkJson
import com.stepanok.bulava.link.PairedMac
import com.stepanok.bulava.link.Summary
import com.stepanok.bulava.platform.KeyValueStore
import com.stepanok.bulava.platform.LinkTransport
import com.stepanok.bulava.platform.Notifier
import com.stepanok.bulava.platform.PhoneNotification
import com.stepanok.bulava.platform.PickedFile
import com.stepanok.bulava.platform.PlatformServices
import com.stepanok.bulava.platform.TransportListener
import com.stepanok.bulava.state.AppController
import com.stepanok.bulava.state.Draft
import com.stepanok.bulava.state.NotificationButtons
import com.stepanok.bulava.state.leadingTo
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.test.StandardTestDispatcher
import kotlinx.coroutines.test.TestScope
import kotlinx.coroutines.test.advanceUntilIdle
import kotlinx.coroutines.test.runTest
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNotNull
import kotlin.test.assertTrue

/**
 * What the phone tells the director without being opened: a request with its own buttons, a
 * report that came in said quietly, and the counts for the Live Activity. Driven against the
 * in-phone Mac the demo uses, so the requests and the work are real ones.
 */
class NotificationsTest {

    /** A phone that keeps what it is asked to show, talking to [transport]. */
    private class Phone(private val transport: () -> LinkTransport) : PlatformServices {
        val posted = mutableListOf<PhoneNotification>()
        val cancelled = mutableListOf<String>()
        val summaries = mutableListOf<Summary>()
        val lives = mutableListOf<com.stepanok.bulava.link.Live?>()
        override val platformName = "ios"
        override fun deviceName() = "Test iPhone"
        override fun osVersion() = "iOS 26"
        override fun appVersion() = "1.0"
        override fun transport() = transport.invoke()
        override val secure = Memory().apply {
            put(LinkClient.PAIRED_KEY, LinkJson.encodeToString(PairedMac.serializer(), PairedMac(
                desktopID = "demo", name = "Demo Mac", pin = "demo", hosts = listOf("demo"), port = 1,
                credential = Credential("demo", "demo"),
            )))
        }
        override val prefs = Memory()
        override val notifier = object : Notifier {
            override fun post(note: PhoneNotification) { posted += note }
            override fun cancel(id: String) { cancelled += id }
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
        override fun showSummary(summary: Summary, live: com.stepanok.bulava.link.Live?, macName: String) { summaries += summary; lives += live }

        /** As if this Mac had been heard from before, with nothing announced yet. */
        fun heardBefore() {
            prefs.put("bulava.notified", "[\"earlier\"]")
            prefs.put("bulava.notified.desktop", "demo")
            prefs.put("bulava.notified.done", "[]")
        }
    }

    private class Memory : KeyValueStore {
        private val values = mutableMapOf<String, String>()
        override fun get(key: String) = values[key]
        override fun put(key: String, value: String) { values[key] = value }
        override fun remove(key: String) { values.remove(key) }
    }

    private fun TestScope.macScope() = CoroutineScope(StandardTestDispatcher(testScheduler) + SupervisorJob())
    private fun TestScope.clock(): () -> Long = { 1_790_000_000_000L + testScheduler.currentTime }

    private fun TestScope.phoneWithMac(scope: CoroutineScope): Pair<Phone, AppController> {
        val mac = DemoMac(demoText("en"), scope, clock(), 0)
        val phone = Phone { mac.transport() }.apply { heardBefore() }
        return phone to AppController(phone, scope, clock())
    }

    @Test
    fun onlyButtonsThatActAtOnceGoOnTheNotification() {
        val buttons = NotificationButtons.from(listOf(
            Action("open", "Open the report", kind = "report", target = "r"),
            Action("merge", "Merge", confirm = "Merge into main?"),
            Action("grey", "Retry", disabledReason = "Offline"),
            Action("mac", "Allow it on the Mac", kind = "mac"),
            Action("trust", "Trust and send", style = "primary"),
            Action("why", "Say why", input = ActionInput(placeholder = "What should change")),
            Action("third", "Also this"),
        ))
        assertEquals(listOf("trust", "why"), buttons.map { it.id }, "at most two, and only ones done at once")
        // «Commit as me…» shows the author and every file before it is pressed — not on a lock screen.
        val commit = Action("commit", "Commit as me…", input = com.stepanok.bulava.link.ActionInput(
            placeholder = "Commit message", title = "A commit in your name",
            above = listOf(com.stepanok.bulava.link.InputNote("Author: Ivan")),
        ))
        assertEquals(listOf("leave"), NotificationButtons.from(listOf(Action("leave", "Start, leave my changes"), commit)).map { it.id },
            "a button that opens the Mac's sheet stays in the app")
        assertEquals(null, buttons[0].inputPlaceholder)
        assertEquals("What should change", buttons[1].inputPlaceholder)
        assertEquals("Stop", NotificationButtons.from(listOf(Action("s", "Stop", style = "destructive", input = ActionInput())))
            .single().let { assertTrue(it.destructive); assertEquals("Stop", it.inputPlaceholder, "an empty placeholder falls back to the label"); it.label })
    }

    @Test
    fun aRequestIsAnsweredFromItsNotification() = runTest {
        val scope = macScope()
        val (phone, c) = phoneWithMac(scope)
        advanceUntilIdle()

        val ask = phone.posted.single { it.buttons.isNotEmpty() }
        assertEquals("demo-charts", ask.chatID)
        val trust = ask.buttons.single()
        assertTrue(trust.id.startsWith("demo.trust"))
        assertEquals(setOf("q", "decide"), phone.posted.filter { it.buttons.isEmpty() && !it.finished }.map { it.id.substringBefore(":") }.toSet(),
            "a question, and questions waiting for decisions, are answered in the app, not on the notification")

        val (reply, _) = c.respondFromNotification(ask.id, trust.id, null)
        advanceUntilIdle()
        assertEquals(AppController.Reply.Done, reply)
        assertTrue(ask.id in phone.cancelled, "done on the Mac, so the notification goes")
        assertTrue(assertNotNull(c.home.value).attention.none { it.id == ask.id })

        val (again, _) = c.respondFromNotification(ask.id, trust.id, null)
        assertEquals(AppController.Reply.Stale, again, "pressed a second time, it is already answered")
        scope.cancel()
    }

    @Test
    fun aMacThatCannotBeReachedIsSaidSoAndNothingIsPressed() = runTest {
        val scope = macScope()
        val refused = object : LinkTransport {
            override fun open(url: String, pin: String, listener: TransportListener) = listener.onClosed("refused")
            override fun send(text: String) = false
            override fun close() = Unit
        }
        val phone = Phone { refused }
        val c = AppController(phone, scope, clock())
        val (reply, _) = c.respondFromNotification("ask:1", "trust:1", null)
        assertEquals(AppController.Reply.Unreachable, reply)
        assertTrue(phone.cancelled.isEmpty(), "the request stays where it was")
        scope.cancel()
    }

    @Test
    fun aReportThatCameInIsToldAndTheLockScreenFollowsTheWorkByName() = runTest {
        val scope = macScope()
        val (phone, c) = phoneWithMac(scope)
        advanceUntilIdle()
        // The demo starts with one report already in, told like any other finished work.
        assertEquals(Summary(working = 0, waiting = 3, ready = 1), phone.summaries.last())
        val earlier = phone.posted.single { it.finished }
        assertTrue(earlier.buttons.isEmpty())
        assertTrue(!earlier.quiet, "finished work is what the director waits to hear about")

        val chat = c.newChatID()
        c.setDraft(chat, Draft("Make the sync faster"))
        c.send(DemoMac.LEDGER, chat)
        advanceUntilIdle()
        val yes = assertNotNull(c.chats.value[chat]).entries.last { it.kind == "agent" }.actions.first { it.style == "primary" }
        assertTrue(c.invokeNow(yes))
        advanceUntilIdle()

        assertTrue(phone.summaries.any { it.working == 1 }, "while the work ran, it was counted")
        val running = phone.lives.filterNotNull().first { it.running.isNotEmpty() }
        assertEquals("Make the sync faster", running.running.single().title, "and named, for the Lock Screen")
        assertEquals("Pocket Ledger", running.running.single().product)
        val last = assertNotNull(phone.lives.last())
        assertTrue(last.over, "nothing runs: the stretch is over")
        assertEquals("done", last.ended.first().outcome)
        assertEquals(Summary(working = 0, waiting = 3, ready = 2), phone.summaries.last())
        val done = phone.posted.single { it.finished && it.id != earlier.id && it.id.startsWith("done:") }
        assertTrue(done.buttons.isEmpty())
        val finished = assertNotNull(c.home.value).finished.single { it.id == done.id }
        assertEquals(finished.chatID, done.chatID, "a tap opens the chat the report came in")
        assertEquals("report", finished.report?.kind)
        assertTrue(assertNotNull(c.openReport(assertNotNull(finished.report?.target))).html.isNotBlank())

        // Merged on the Mac: nothing is left to read, and the notification goes.
        val card = assertNotNull(c.chats.value[chat]).entries.last { it.kind == "report" }.card
        assertTrue(c.invokeNow(assertNotNull(card).actions.first { it.id.startsWith("demo.merge") }))
        advanceUntilIdle()
        assertTrue(done.id in phone.cancelled)
        assertEquals(1, phone.summaries.last().ready)
        assertEquals(1, phone.posted.count { it.id == done.id }, "told once")
        scope.cancel()
    }

    @Test
    fun anAnswerThatCameInIsToldOnceWithTheChatsName() = runTest {
        val scope = macScope()
        val (phone, c) = phoneWithMac(scope)
        advanceUntilIdle()
        val chat = c.newChatID()
        c.setDraft(chat, Draft("What is left in the ledger?"))
        c.send(DemoMac.LEDGER, chat)
        advanceUntilIdle()
        val answered = phone.posted.filter { it.id.startsWith("answered:") }
        assertEquals(1, answered.size, "one answer, one notification")
        assertEquals(chat, answered.single().chatID, "a tap opens the chat that answered")
        assertTrue(answered.single().finished)
        assertTrue(answered.single().body.isNotBlank(), "in the Mac's words")

        // The next home says the same, and nothing is told again.
        c.setDraft("other", Draft("x"))
        advanceUntilIdle()
        assertEquals(1, phone.posted.count { it.id.startsWith("answered:") })
        scope.cancel()
    }

    @Test
    fun theDetailsCarryTheChatsReportsAndMakeANewOne() = runTest {
        val scope = macScope()
        val (_, c) = phoneWithMac(scope)
        advanceUntilIdle()
        val chat = c.newChatID()
        c.setDraft(chat, Draft("What is left in the ledger?"))
        c.send(DemoMac.LEDGER, chat)
        advanceUntilIdle()
        val before = assertNotNull(assertNotNull(c.context(DemoMac.LEDGER, chat)).chatReports, "an answered chat has Reports")
        val create = assertNotNull(before.create, "with “Create report”")
        assertTrue(c.invokeNow(create))
        advanceUntilIdle()
        val after = assertNotNull(assertNotNull(c.context(DemoMac.LEDGER, chat)).chatReports)
        assertEquals(before.items.size + 1, after.items.size, "the report that was made is listed")
        assertTrue(!after.generating)
        assertTrue(assertNotNull(c.openReport(assertNotNull(after.items.first().open.target))).html.isNotBlank(), "and opens")
        assertEquals(null, c.context(DemoMac.CAFE, chat)?.chatReports, "another product's details never carry this chat")
        scope.cancel()
    }

    /**
     * A push from the relay says only what happened. Its tap leads to the newest of it — read from
     * what the Mac says once it is heard from again, not from what the phone kept before the push.
     */
    @Test
    fun aPushThatNamesNothingOpensTheNewestOfWhatItIsAbout() = runTest {
        val scope = macScope()
        val mac = DemoMac(demoText("en"), scope, clock(), 0)
        val phone = Phone { mac.transport() }.apply { heardBefore() }
        // What the phone kept from before: a question in a chat that is not the newest any more.
        phone.prefs.put("bulava.home", LinkJson.encodeToString(Home.serializer(), Home(
            products = listOf(Product(id = DemoMac.LEDGER, name = "Pocket Ledger")),
            attention = listOf(Attention("old", DemoMac.LEDGER, "an-old-chat", "question", "Old", "Old", "attention", 1)),
        )))
        val c = AppController(phone, scope, clock())
        val attention = c.destination(AppController.OpenRequest(null, null, "attention"))
        val home = assertNotNull(c.home.value)
        val newest = home.attention.maxBy { it.atMs }
        assertEquals(AppController.Destination.Chat(newest.productID, assertNotNull(newest.chatID)), attention,
            "the newest request in the Mac's list now, not the one kept from before")

        val finished = c.destination(AppController.OpenRequest(null, null, "finished"))
        val report = home.finished.maxBy { it.atMs }
        assertEquals(AppController.Destination.Chat(report.productID, assertNotNull(report.chatID)), finished)

        assertEquals(AppController.Destination.Chat(DemoMac.LEDGER, "c1"),
            c.destination(AppController.OpenRequest(DemoMac.LEDGER, "c1", "attention")), "a chat it names is that chat")
        assertEquals(null, c.destination(AppController.OpenRequest(null, null, null)))
        scope.cancel()
    }

    /**
     * The chats on screen are opened again one by one as the link comes back, each waiting for the
     * Mac — and meanwhile a tapped notification brings another chat on screen. That must not end
     * the app.
     */
    @Test
    fun aChatOpenedWhileTheLinkReopensTheOthersIsFine() = runTest {
        val scope = macScope()
        val mac = DemoMac(demoText("en"), scope, clock(), 0)
        var c: AppController? = null
        var switched = false
        // The moment the phone asks for the first chat again, the chat on screen changes.
        val transport = { val inner = mac.transport(); object : LinkTransport by inner {
            override fun send(text: String): Boolean {
                if (!switched && "chat.open" in text) {
                    switched = true
                    c?.closeChat("demo-charts")
                    c?.openChat("demo-ship")
                }
                return inner.send(text)
            }
        } }
        val phone = Phone(transport).apply { heardBefore() }
        c = AppController(phone, scope, clock())
        c.openChat("demo-charts")
        c.openChat("demo-sync")
        advanceUntilIdle()
        assertTrue(switched, "the chats were asked for again while one was being switched")
        assertTrue(c.link.isConnected, "and the link came up and stayed up")
        scope.cancel()
    }

    /**
     * A tap on the phone's own notification hands back what the notification carries, and leads
     * where the relay's push about the same thing would: a report in a chat opens that chat.
     */
    @Test
    fun aNotificationLeadsWhereItsItemIs() = runTest {
        val scope = macScope()
        val (phone, c) = phoneWithMac(scope)
        advanceUntilIdle()
        val home = assertNotNull(c.home.value)
        suspend fun tap(note: PhoneNotification) = c.destination(AppController.OpenRequest(note.productID, note.chatID, note.about))

        val reports = phone.posted.filter { it.finished && it.id.startsWith("done:") }
        assertTrue(reports.isNotEmpty(), "the reports that came in were told")
        for (note in reports) {
            val item = home.finished.single { it.id == note.id }
            assertEquals(AppController.Destination.Chat(item.productID, assertNotNull(item.chatID)), tap(note),
                "a report that came in a chat opens that chat")
        }
        for (note in phone.posted.filter { !it.finished && home.attention.any { a -> a.id == it.id } }) {
            val item = home.attention.single { it.id == note.id }
            assertEquals(AppController.place(item, home), tap(note))
        }

        // What the demo has none of, formed the same way the phone forms its notifications.
        val product = home.products.first()
        val readiness = Attention("readiness:tmux", "", null, "readiness", "tmux is installed", "", "problem", 1)
        val setup = PhoneNotification("n", "t", "b").leadingTo(AppController.place(readiness, home))
        assertEquals("readiness", setup.about)
        assertEquals(AppController.Destination.Settings, tap(setup), "the Mac's setup is in the settings")
        val alone = Finished("done:alone", product.id, null, "Import", "Report ready", 1)
        assertEquals(AppController.Destination.Details(product.id, product.name),
            tap(PhoneNotification("n", "t", "b").leadingTo(AppController.place(alone, home))),
            "a report with no chat of its own opens its product's details")
        val task = Attention("ask:T", product.id, null, "ask", "", "", "attention", 1)
        assertEquals(null, tap(PhoneNotification("n", "t", "b").leadingTo(AppController.place(task, home))),
            "a task that did not start asks in the dialog that comes up by itself")
        scope.cancel()
    }

    @Test
    fun thePlaceOfAPushDependsOnWhatItIsAbout() {
        val ledger = Product(id = "P", name = "Pocket Ledger")
        fun ask(kind: String, chat: String?, at: Long) = Attention("$kind$at", "P", chat, kind, "", "", "attention", at)
        fun home(vararg attention: Attention, finished: List<Finished> = emptyList(), live: Live? = null) =
            Home(products = listOf(ledger), attention = attention.toList(), finished = finished, live = live)

        assertEquals(AppController.Destination.Settings,
            AppController.newest("attention", home(ask("question", "C", 1), ask("readiness", null, 2))),
            "the Mac's setup is in the settings")
        assertEquals(null, AppController.newest("attention", home(ask("question", "C", 1), ask("ask", null, 2))),
            "a task that did not start asks in its own dialog")
        assertEquals(AppController.Destination.Details("P", "Pocket Ledger"),
            AppController.newest("attention", home(ask("review", null, 2))))
        assertEquals(AppController.Destination.Details("P", "Pocket Ledger"),
            AppController.newest("finished", home(finished = listOf(Finished("f", "P", null, "Import", "Report ready", 5)))),
            "a report with no chat is in its product's details")
        assertEquals(AppController.Destination.Chat("P", "C2"), AppController.newest("done", home(live = Live(
            running = emptyList(),
            ended = listOf(LiveLine("chat:C2", "P", "C2", outcome = "done"), LiveLine("chat:C1", "P", "C1", outcome = "done")),
            over = true))), "the chat whose answer came in last")
        assertEquals(null, AppController.newest("attention", home()))
    }

    @Test
    fun theRunControlIsTheMacsPairWithNoModeSwitch() = runTest {
        val scope = macScope()
        val (_, c) = phoneWithMac(scope)
        advanceUntilIdle()
        val composer = assertNotNull(c.home.value).composer
        assertTrue(composer.groups.none { it.id == "mode" }, "Claude alone or Codex alone is not offered")
        assertEquals(listOf("claude", "codex"), composer.groups.mapNotNull { it.engine }.distinct())
        assertEquals(listOf("claude", "codex"), composer.summary?.map { it.engine })
        c.setOption("claudeModel", "haiku")
        advanceUntilIdle()
        val after = assertNotNull(c.home.value).composer
        assertTrue(after.groups.none { it.id == "claudeEffort" }, "Haiku takes no depth")
        assertEquals(null, after.summary?.first()?.depth)
        scope.cancel()
    }
}
