package com.stepanok.bulava

import com.stepanok.bulava.state.Decided
import com.stepanok.bulava.state.DecisionDraft
import com.stepanok.bulava.demo.DemoMac
import com.stepanok.bulava.demo.DemoSession
import com.stepanok.bulava.link.CallResult
import com.stepanok.bulava.link.LinkState
import com.stepanok.bulava.platform.KeyValueStore
import com.stepanok.bulava.platform.LinkTransport
import com.stepanok.bulava.platform.Notifier
import com.stepanok.bulava.platform.PhoneNotification
import com.stepanok.bulava.platform.PickedFile
import com.stepanok.bulava.platform.PlatformServices
import com.stepanok.bulava.state.Draft
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.isActive
import kotlinx.coroutines.test.StandardTestDispatcher
import kotlinx.coroutines.test.TestScope
import kotlinx.coroutines.test.advanceUntilIdle
import kotlinx.coroutines.test.runTest
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertIs
import kotlin.test.assertNotNull
import kotlin.test.assertTrue

/** The demo: the real screens' controller, a Mac inside the phone, and nothing of the real session touched. */
class DemoTest {

    /** The phone the demo runs on. Anything the demo does to it is written down. */
    private class Watched : PlatformServices {
        val touched = mutableListOf<String>()
        override val platformName = "ios"
        override fun deviceName() = "Test iPhone"
        override fun osVersion() = "iOS 26"
        override fun appVersion() = "1.0"
        override fun transport(): LinkTransport { touched += "transport"; error("the demo opened a real socket") }
        override val secure = store("secure")
        override val prefs = store("prefs")
        override val notifier = object : Notifier {
            override fun post(note: PhoneNotification) { touched += "notify" }
            override fun cancel(id: String) { touched += "cancel" }
        }
        override fun openUrl(url: String) { touched += "open $url" }
        override fun scanCode(onResult: (String?) -> Unit) { touched += "scan" }
        override fun pickImage(onResult: (PickedFile?) -> Unit) { touched += "pickImage" }
        override fun pickFile(onResult: (PickedFile?) -> Unit) { touched += "pickFile" }
        override fun discover(desktopID: String, onFound: (List<String>) -> Unit) { touched += "discover" }
        override fun keepLinkAlive(active: Boolean, macName: String) { touched += "keepAlive" }
        override fun notificationsAllowed() = true
        override fun requestNotifications() { touched += "requestNotifications" }
        override fun openAppSettings() { touched += "settings" }

        private fun store(name: String) = object : KeyValueStore {
            override fun get(key: String): String? = null
            override fun put(key: String, value: String) { touched += "$name.put $key" }
            override fun remove(key: String) { touched += "$name.remove $key" }
        }
    }

    /** On the test's clock, as foreground work — `backgroundScope` is not run by `advanceUntilIdle`. */
    private fun TestScope.demoScope() = CoroutineScope(StandardTestDispatcher(testScheduler) + SupervisorJob())

    private fun TestScope.demo(real: PlatformServices, language: String = "en", scope: CoroutineScope = demoScope()) =
        DemoSession.instant(real, language, { 1_790_000_000_000L + testScheduler.currentTime }, scope)

    @Test
    fun aNewMessageIsAnsweredTurnedIntoWorkAndReportedWithoutAMac() = runTest {
        val real = Watched()
        val c = demo(real).controller
        advanceUntilIdle()
        assertIs<LinkState.Connected>(c.link.state.value)
        val home = assertNotNull(c.home.value)
        assertEquals(listOf(DemoMac.LEDGER, DemoMac.CAFE), home.products.map { it.id })
        assertEquals(listOf("ask", "decide", "question"), home.attention.map { it.kind }.sorted(),
            "a question, a folder waiting for trust, and questions waiting for decisions")

        val chat = c.newChatID()
        c.setDraft(chat, Draft("How is the budget screen built?"))
        c.send(DemoMac.LEDGER, chat)
        advanceUntilIdle()
        assertTrue(c.outbox.value.isEmpty(), "the message arrived, so nothing is left to send")
        assertTrue(assertNotNull(c.home.value).products.first().chats.any { it.id == chat }, "the first message made the chat")
        val answer = assertNotNull(c.chats.value[chat]).entries.last { it.kind == "agent" }
        assertEquals(true, answer.finished)
        assertTrue(answer.text.contains("How is the budget screen built?"))

        val yes = answer.actions.first { it.style == "primary" }
        assertTrue(c.invokeNow(yes))
        advanceUntilIdle()
        assertFalse(c.invokeNow(yes), "pressed twice, the work starts once")
        val cards = assertNotNull(c.chats.value[chat]).entries.filter { it.kind == "report" }
        assertEquals(1, cards.size)
        val card = assertNotNull(cards.single().card)
        assertEquals("reportReady", card.status.code)
        assertFalse(assertNotNull(c.chats.value[chat]).state.busy)

        val report = assertNotNull(c.openReport(assertNotNull(card.actions.first { it.kind == "report" }.target)))
        assertTrue(report.html.contains(card.title))
        val merge = card.actions.first { it.id.startsWith("demo.merge") }
        assertTrue(c.invokeNow(merge))
        advanceUntilIdle()
        assertEquals("merged", assertNotNull(c.chats.value[chat]).entries.last { it.kind == "report" }.card?.status?.code)
        assertFalse(c.invokeNow(merge), "merged once")

        // Permissions belong to the real session: the demo shows notifications as off and asks for nothing.
        assertFalse(c.platform.notificationsAllowed())
        c.platform.requestNotifications()
        c.platform.openAppSettings()
        c.platform.keepLinkAlive(true, "Demo Mac")
        assertEquals(emptyList(), real.touched, "the demo reached nothing of the real phone")
    }

    @Test
    fun theQuestionAndTheFolderAreAnsweredFromThePhone() = runTest {
        val c = demo(Watched()).controller
        advanceUntilIdle()
        c.openChat("demo-ship")
        c.openChat("demo-charts")
        advanceUntilIdle()

        val question = assertNotNull(c.chats.value["demo-ship"]).entries.first { it.kind == "question" }
        c.answer(question.id, listOf(listOf("42")), "")
        advanceUntilIdle()
        val ship = assertNotNull(c.chats.value["demo-ship"])
        assertEquals(false, ship.entries.first { it.id == question.id }.question?.answerable)
        assertEquals("42", ship.entries.last { it.kind == "user" }.text)
        assertEquals("event", ship.entries.last().kind)

        val trust = assertNotNull(c.chats.value["demo-charts"]).entries.first { it.asks.isNotEmpty() }.asks.single().actions.single()
        assertTrue(c.invokeNow(trust))
        advanceUntilIdle()
        assertEquals(listOf("decide"), assertNotNull(c.home.value).attention.map { it.kind },
            "both requests are answered; the questions wait for an answer of their own")
        // Answered from the phone, as on a real Mac: the questions stop waiting, and opened again
        // they show what was sent.
        c.setDecisionDraft(DemoMac.PLAN_REF, DecisionDraft(choices = mapOf("widgets" to "Take it")))
        val sent = assertIs<Decided.Sent>(c.decide(DemoMac.PLAN_REF, "demo-1", null)).sent
        advanceUntilIdle()
        assertTrue(assertNotNull(c.home.value).attention.isEmpty(), "nothing waits any more")
        val questions = assertNotNull(c.openReport("demo.report:${DemoMac.PLAN_REPORT}")?.decisions)
        assertEquals(sent?.id, questions.latest?.id)
        assertEquals(mapOf("widgets" to "Take it"), questions.latest?.choices)
        assertTrue(assertNotNull(c.chats.value["demo-charts"]).entries.any { it.kind == "agent" && it.finished == true })
    }

    @Test
    fun whatTheDemoDoesNotSimulateIsSaidAtOnceNotTimedOut() = runTest {
        val c = demo(Watched()).controller
        advanceUntilIdle()
        val before = testScheduler.currentTime
        val r = c.link.call("folder.connect")
        assertIs<CallResult.Failed>(r)
        assertEquals("not_in_demo", r.error.code)
        assertTrue(r.error.message.isNotBlank())
        assertEquals(before, testScheduler.currentTime, "answered without waiting")
    }

    @Test
    fun leavingTheDemoStopsItsWorkMidSentence() = runTest {
        val scope = demoScope()
        val session = demo(Watched(), scope = scope)
        val c = session.controller
        advanceUntilIdle()
        val chat = c.newChatID()
        c.setDraft(chat, Draft("Anything"))
        c.send(DemoMac.CAFE, chat)
        session.close()
        advanceUntilIdle()
        assertFalse(scope.isActive, "its answers and work stop with it")
        assertIs<CallResult.Failed>(c.link.call("home.subscribe"), "and nothing is answered any more")
    }

    @Test
    fun theDemoSpeaksThePhonesLanguage() = runTest {
        val c = demo(Watched(), language = "uk").controller
        advanceUntilIdle()
        val home = assertNotNull(c.home.value)
        assertEquals("Демо-Mac", home.desktop.name)
        assertEquals("Облік витрат для iPhone", home.products.first().brief)
    }
}
