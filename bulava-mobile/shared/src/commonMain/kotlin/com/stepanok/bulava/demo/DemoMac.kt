package com.stepanok.bulava.demo

import com.stepanok.bulava.link.Action
import com.stepanok.bulava.link.ActionInput
import com.stepanok.bulava.link.Activity
import com.stepanok.bulava.link.Ask
import com.stepanok.bulava.link.Attention
import com.stepanok.bulava.link.Block
import com.stepanok.bulava.link.Card
import com.stepanok.bulava.link.Change
import com.stepanok.bulava.link.ChatGone
import com.stepanok.bulava.link.ChatState
import com.stepanok.bulava.link.ChatSummary
import com.stepanok.bulava.link.Check
import com.stepanok.bulava.link.Checks
import com.stepanok.bulava.link.ComposerOptions
import com.stepanok.bulava.link.Context
import com.stepanok.bulava.link.Delivery
import com.stepanok.bulava.link.Desktop
import com.stepanok.bulava.link.Diff
import com.stepanok.bulava.link.Entry
import com.stepanok.bulava.link.ErrorCodes
import com.stepanok.bulava.link.FileChunk
import com.stepanok.bulava.link.FileRef
import com.stepanok.bulava.link.Finished
import com.stepanok.bulava.link.HandshakeReply
import com.stepanok.bulava.link.HistoryPage
import com.stepanok.bulava.link.Home
import com.stepanok.bulava.link.Instructions
import com.stepanok.bulava.link.LinkError
import com.stepanok.bulava.link.LinkJson
import com.stepanok.bulava.link.LinkProtocol
import com.stepanok.bulava.link.Option
import com.stepanok.bulava.link.OptionGroup
import com.stepanok.bulava.link.EngineLimits
import com.stepanok.bulava.link.LimitWindow
import com.stepanok.bulava.link.Limits
import com.stepanok.bulava.link.Live
import com.stepanok.bulava.link.ChatReport
import com.stepanok.bulava.link.ChatReports
import com.stepanok.bulava.link.DecisionItem
import com.stepanok.bulava.link.DecisionSent
import com.stepanok.bulava.link.Decisions
import com.stepanok.bulava.link.LiveLine
import com.stepanok.bulava.link.RunPart
import com.stepanok.bulava.link.Product
import com.stepanok.bulava.link.Question
import com.stepanok.bulava.link.QuestionItem
import com.stepanok.bulava.link.Readiness
import com.stepanok.bulava.link.Report
import com.stepanok.bulava.link.Resource
import com.stepanok.bulava.link.Sent
import com.stepanok.bulava.link.Server
import com.stepanok.bulava.link.Skill
import com.stepanok.bulava.link.Skills
import com.stepanok.bulava.link.Status
import com.stepanok.bulava.link.Summary
import com.stepanok.bulava.link.TakenBack
import com.stepanok.bulava.link.UploadStarted
import com.stepanok.bulava.link.Work
import com.stepanok.bulava.platform.LinkTransport
import com.stepanok.bulava.platform.TransportListener
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.serialization.KSerializer
import kotlinx.serialization.builtins.ListSerializer
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.booleanOrNull
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.intOrNull
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.longOrNull
import kotlinx.serialization.json.put
import kotlin.io.encoding.Base64
import kotlin.io.encoding.ExperimentalEncodingApi

/**
 * A Mac that lives inside the phone, for trying Bulava without one.
 *
 * It speaks the same Bulava Link protocol as Bulava on a Mac — the phone's link, controller and
 * screens are the real ones and do not know the difference — but nothing leaves the phone: every
 * answer is prepared here, from [DemoText], and every button does what it says to this invented
 * state. Whatever it does not simulate is answered at once with [DemoText.notInDemo], never left
 * to time out.
 */
@OptIn(ExperimentalEncodingApi::class)
internal class DemoMac(
    private val t: DemoText,
    private val scope: CoroutineScope,
    private val now: () -> Long,
    /** How long the pauses are; tests make them zero. */
    private val pace: Long = 1,
) {
    private var sink: ((String) -> Unit)? = null
    private val open = mutableSetOf<String>()
    private val products = mutableListOf<DProduct>()
    private val chats = mutableListOf<DChat>()
    private val jobs = mutableMapOf<String, Job>()
    private val uploads = mutableMapOf<String, Pair<FileRef, ByteArray>>()
    private val files = mutableMapOf<String, Pair<FileRef, ByteArray>>()
    private val reports = mutableMapOf<String, DReport>()
    private val merged = mutableSetOf<String>()
    private val access = mutableMapOf(RES_FOLDER to "workspace", RES_SITE to "source")
    private val selected = mutableMapOf("claudeModel" to "opus", "claudeEffort" to "auto", "codexModel" to "", "codexEffort" to "auto")
    /** What stopped since the stretch of work began, newest first — the Mac's `LiveTracker`, without its settle. */
    private val ended = mutableListOf<LiveLine>()
    /** Reports made with "Create report", per chat, and the chats one is being made for. */
    private val chatReports = mutableMapOf<String, MutableList<String>>()
    private val makingReport = mutableSetOf<String>()
    private var seq = 0

    init { seed() }

    /** One socket's worth of the demo: what `LinkClient` opens for every connection attempt. */
    fun transport(): LinkTransport = object : LinkTransport {
        private var listener: TransportListener? = null
        override fun open(url: String, pin: String, listener: TransportListener) {
            this.listener = listener
            sink = { text -> this.listener?.onText(text) }
            listener.onOpen()
        }
        override fun send(text: String): Boolean {
            if (listener == null) return false
            receive(text)
            return true
        }
        override fun close() {
            val l = listener ?: return
            listener = null
            sink = null
            open.clear()
            l.onClosed(null)
        }
    }

    // MARK: Frames

    private fun receive(text: String) {
        val frame = runCatching { LinkJson.parseToJsonElement(text).jsonObject }.getOrNull() ?: return
        when (frame["type"]?.jsonPrimitive?.contentOrNull) {
            "hello" -> reply(LinkJson.encodeToString(HandshakeReply.serializer(), HandshakeReply(
                type = "welcome", protocolVersion = LinkProtocol.VERSION, desktop = desktop(),
                capabilities = LinkProtocol.USED_CAPABILITIES.toList(),
            )))
            "request" -> {
                val id = frame["id"]?.jsonPrimitive?.contentOrNull ?: return
                val op = frame["op"]?.jsonPrimitive?.contentOrNull ?: ""
                val args = frame["args"] as? JsonObject ?: JsonObject(emptyMap())
                val outcome = runCatching { handle(op, args) }.getOrElse { Outcome.Err(LinkError("failed", t.notInDemo)) }
                reply(LinkJson.encodeToString(JsonObject.serializer(), buildJsonObject {
                    put("type", "response")
                    put("id", id)
                    when (outcome) {
                        is Outcome.Ok -> { put("ok", true); outcome.result?.let { put("result", it) } }
                        is Outcome.Err -> { put("ok", false); put("error", LinkJson.encodeToJsonElement(LinkError.serializer(), outcome.error)) }
                    }
                }))
            }
        }
    }

    private fun reply(text: String) { sink?.invoke(text) }

    private fun <T> event(name: String, serializer: KSerializer<T>, value: T) {
        reply(LinkJson.encodeToString(JsonObject.serializer(), buildJsonObject {
            put("type", "event")
            put("event", name)
            put("data", LinkJson.encodeToJsonElement(serializer, value))
        }))
    }

    private sealed interface Outcome {
        data class Ok(val result: JsonElement? = null) : Outcome
        data class Err(val error: LinkError) : Outcome
    }

    private fun <T> ok(serializer: KSerializer<T>, value: T) = Outcome.Ok(LinkJson.encodeToJsonElement(serializer, value))
    private val done = Outcome.Ok()
    private val stale get() = Outcome.Err(LinkError(ErrorCodes.STALE, t.alreadyHandled))
    private val notInDemo get() = Outcome.Err(LinkError("not_in_demo", t.notInDemo))

    // MARK: Requests

    private fun handle(op: String, a: JsonObject): Outcome = when (op) {
        "home.subscribe" -> { later { pushHome() }; done }
        "chat.open" -> {
            val id = a.str("chatID")
            if (id != null) { open += id; chat(id)?.let { c -> later { pushChat(c) } } }
            done
        }
        "chat.close" -> { a.str("chatID")?.let { open -= it }; done }
        "chat.history" -> ok(HistoryPage.serializer(), HistoryPage())
        "chat.create" -> {
            val c = chat(a.str("chatID") ?: "") ?: createChat(a.str("productID") ?: "", a.str("chatID") ?: newID(), t.untitled)
            if (c == null) notInDemo else { pushHome(); ok(ChatSummary.serializer(), summary(c)) }
        }
        "chat.send" -> send(a)
        "chat.stop" -> { chat(a.str("chatID") ?: "")?.let { stop(it) }; done }
        "chat.rename" -> edit(a) { it.title = a.str("title")?.trim()?.takeIf { s -> s.isNotEmpty() } ?: it.title }
        "chat.archive" -> edit(a) { it.archived = a.bool("archived") ?: !it.archived }
        "chat.pin" -> edit(a) { it.pinned = a.bool("pinned") ?: !it.pinned }
        "entry.retry" -> done
        "entry.takeBack" -> takeBack(a.str("entryID") ?: "")
        "action.invoke" -> invoke(a.str("id") ?: "")
        "question.answer" -> answer(a)
        "upload.begin" -> {
            val id = "up-" + newID()
            uploads[id] = FileRef(name = a.str("name") ?: "file", kind = a.str("kind") ?: "file", size = a.long("size")) to ByteArray(0)
            ok(UploadStarted.serializer(), UploadStarted(id, 256 * 1024))
        }
        "upload.chunk" -> {
            val id = a.str("uploadID") ?: ""
            val current = uploads[id]
            if (current == null) notInDemo else {
                val bytes = Base64.decode(a.str("data") ?: "")
                uploads[id] = current.first to (current.second + bytes)
                ok(JsonObject.serializer(), buildJsonObject { put("received", (current.second.size + bytes.size).toLong()) })
            }
        }
        "upload.finish" -> {
            val (ref, bytes) = uploads.remove(a.str("uploadID") ?: "") ?: (null to null)
            if (ref == null || bytes == null) notInDemo else {
                val file = ref.copy(ref = "att:demo-" + newID(), size = bytes.size.toLong())
                files[file.ref!!] = file to bytes
                ok(FileRef.serializer(), file)
            }
        }
        "upload.cancel" -> { uploads.remove(a.str("uploadID") ?: ""); done }
        "file.read" -> read(a)
        "report.open" -> openReport(a.str("target") ?: "")
        // Files open on the Mac's own Wi-Fi, from the Mac: there is no Mac here to serve them.
        "file.open" -> notInDemo
        "report.decide" -> decide(a)
        "settings.set" -> {
            val group = a.str("group"); val value = a.str("value")
            // Only what the menus offer, as the Mac: an older phone's "Who answers" is out of date.
            val offered = composer().groups.firstOrNull { it.id == group }?.options.orEmpty()
            if (group != null && value != null && offered.any { it.id == value }) { selected[group] = value; pushHome(); done }
            else stale
        }
        "product.rename" -> product(a.str("productID"))?.let { p ->
            a.str("name")?.trim()?.takeIf { it.isNotEmpty() }?.let { p.name = it }
            pushHome(); done
        } ?: stale
        "product.pin" -> product(a.str("productID"))?.let { p -> p.pinned = a.bool("pinned") ?: !p.pinned; pushHome(); done } ?: stale
        "product.remove" -> product(a.str("productID"))?.let { p ->
            products.remove(p)
            for (c in chats.filter { it.productID == p.id }) {
                chats.remove(c); jobs.remove(c.id)?.cancel()
                if (c.id in open) event("chat.gone", ChatGone.serializer(), ChatGone(c.id))
            }
            pushHome(); done
        } ?: stale
        "commands.list" -> ok(ListSerializer(Option.serializer()), listOf(
            Option("/review", "/review", t.cmdReview), Option("/test", "/test", t.cmdTest), Option("/release-notes", "/release-notes", t.cmdNotes),
        ))
        "context.get" -> context(a.str("productID") ?: "", a.str("chatID"))
        "context.diff" -> ok(Diff.serializer(), Diff(if (a.str("ref") == DIFF_TEST) TEST_DIFF else SYNC_DIFF))
        "skills.get" -> ok(Skills.serializer(), skills(a.str("productID")))
        "push.register", "presence.set", "device.forget" -> done
        else -> notInDemo
    }

    /** After the answer to the current request, not before it: the phone expects replies in order. */
    private fun later(block: () -> Unit) { scope.launch { block() } }

    private fun edit(a: JsonObject, change: (DChat) -> Unit): Outcome {
        val c = chat(a.str("chatID") ?: "") ?: return stale
        change(c)
        pushHome()
        pushChat(c)
        return done
    }

    // MARK: Sending and answering

    private fun send(a: JsonObject): Outcome {
        val productID = a.str("productID") ?: return notInDemo
        val chatID = a.str("chatID") ?: return notInDemo
        val entryID = a.str("entryID") ?: return notInDemo
        val text = a.str("text")?.trim().orEmpty()
        val existing = chat(chatID)
        if (existing != null && existing.entries.any { it.id == entryID }) return ok(Sent.serializer(), Sent(entryID, duplicate = true))
        val c = existing ?: createChat(productID, chatID, text.lineSequence().firstOrNull()?.take(48)?.ifBlank { null } ?: t.untitled)
            ?: return stale
        val attachments = (a["attachments"]?.let { runCatching { it.jsonArray }.getOrNull() } ?: emptyList())
            .mapNotNull { (it as? JsonPrimitive)?.contentOrNull }.mapNotNull { files[it]?.first }
        c.entries += Entry(id = entryID, kind = "user", atMs = now(), author = t.you, text = text, attachments = attachments)
        c.updatedAt = now()
        val product = product(productID)?.name ?: ""
        pushHome()
        pushChat(c)
        stream(c, t.genericSteps, t.genericAnswer(product, text.take(80)), proposal = DemoReportKind.Generic, task = t.genericTask(text))
        return ok(Sent.serializer(), Sent(entryID))
    }

    private fun answer(a: JsonObject): Outcome {
        val entryID = a.str("entryID") ?: return stale
        val c = chats.firstOrNull { ch -> ch.entries.any { it.id == entryID } } ?: return stale
        val q = c.entries.first { it.id == entryID }
        if (q.question?.answerable != true) return stale
        val selections = runCatching { a["selections"]!!.jsonArray.map { s -> s.jsonArray.mapNotNull { it.jsonPrimitive.contentOrNull } } }.getOrDefault(emptyList())
        val typed = a.str("text")?.trim().orEmpty()
        val words = (selections.flatten() + listOfNotNull(typed.ifBlank { null })).joinToString(", ")
        if (words.isBlank()) return Outcome.Err(LinkError("bad_request", ""))
        replace(c, q.copy(question = q.question.copy(answerable = false)))
        c.entries += Entry(id = newID(), kind = "user", atMs = now(), author = t.you, text = words)
        pushChat(c)
        stream(c, t.shipAfterSteps, t.shipDone, then = { note(c, t.shipEvent, "good") })
        return done
    }

    private fun takeBack(entryID: String): Outcome {
        val c = chats.firstOrNull { ch -> ch.entries.any { it.id == entryID && it.kind == "user" } } ?: return stale
        val e = c.entries.first { it.id == entryID }
        c.entries.remove(e)
        pushHome()
        pushChat(c)
        return ok(TakenBack.serializer(), TakenBack(e.text, e.attachments))
    }

    // MARK: Buttons

    private fun invoke(id: String): Outcome {
        val parts = id.split(":")
        return when (parts.first()) {
            "stop" -> { chat(parts.getOrElse(1) { "" })?.let { stop(it) }; done }
            "demo.go", "demo.skip" -> {
                val c = chat(parts.getOrElse(1) { "" }) ?: return stale
                val e = c.entries.firstOrNull { it.id == parts.getOrElse(2) { "" } && it.actions.any { a -> a.id == id } } ?: return stale
                replace(c, e.copy(actions = emptyList()))
                if (parts.first() == "demo.skip") note(c, t.leftAsIs, "neutral")
                else {
                    val kind = DemoReportKind.entries.firstOrNull { it.name == parts.getOrElse(3) { "" } } ?: DemoReportKind.Generic
                    work(c, kind, taskTitle(kind, c))
                }
                done
            }
            "demo.trust" -> {
                val c = chat(parts.getOrElse(1) { "" }) ?: return stale
                val e = c.entries.firstOrNull { it.id == parts.getOrElse(2) { "" } && it.asks.isNotEmpty() } ?: return stale
                replace(c, e.copy(asks = emptyList(), delivery = null, actions = emptyList()))
                pushHome()
                stream(c, t.chartsSteps, t.chartsAnswer, proposal = DemoReportKind.Charts, task = t.chartsTask)
                done
            }
            "demo.merge" -> {
                val task = parts.getOrElse(1) { "" }
                if (task in merged || task !in reports) return stale
                merged += task
                for (c in chats) {
                    val card = c.entries.firstOrNull { it.card?.id == task } ?: continue
                    replace(c, card.copy(card = card.card!!.copy(
                        subtitle = t.statusMerged,
                        status = Status("merged", t.statusMerged, "good"),
                        actions = card.card.actions.filter { it.kind == "report" },
                    )))
                    note(c, t.merged, "good")
                }
                pushHome()
                done
            }
            "demo.chatReport" -> {
                val c = chat(parts.getOrElse(1) { "" }) ?: return stale
                if (c.archived) return stale
                if (c.id !in makingReport) {
                    makingReport += c.id
                    scope.launch {
                        pause(2500)
                        val task = "chat-report-" + newID()
                        reports[task] = DReport(DemoReportKind.Generic, c.title, product(c.productID)?.name ?: "")
                        chatReports.getOrPut(c.id) { mutableListOf() }.add(task)
                        makingReport -= c.id
                    }
                }
                done
            }
            "demo.access" -> {
                val res = parts.getOrElse(1) { "" }
                if (res !in access) return stale
                access[res] = if (access[res] == "workspace") "source" else "workspace"
                done
            }
            else -> notInDemo
        }
    }

    private fun taskTitle(kind: DemoReportKind, c: DChat) = when (kind) {
        DemoReportKind.Sync -> t.syncTask
        DemoReportKind.Charts -> t.chartsTask
        DemoReportKind.Landing -> t.landingTask
        else -> t.genericTask(c.entries.firstOrNull { it.kind == "user" }?.text ?: c.title)
    }

    // MARK: Running

    /** An answer that grows the way a real one does: steps first, then the words, a few at a time. */
    private fun stream(
        c: DChat, steps: List<String>, markdown: String,
        proposal: DemoReportKind? = null, task: String? = null, then: (() -> Unit)? = null,
    ) {
        jobs.remove(c.id)?.cancel()
        begin(c)
        c.activity = steps.firstOrNull() ?: t.writing
        pushHome()
        val id = newID()
        jobs[c.id] = scope.launch {
            val blocks = mutableListOf<Block>()
            for ((i, step) in steps.withIndex()) {
                c.activity = step
                blocks += Block("s$i", "activity", activity = Activity(step, "running"))
                upsert(c, agent(id, blocks, "", finished = false))
                pause(650)
                blocks[i] = blocks[i].copy(activity = Activity(step, "done"))
            }
            c.activity = t.writing
            val words = markdown.split(" ")
            var shown = 0
            while (shown < words.size) {
                shown = minOf(words.size, shown + 3)
                val text = words.take(shown).joinToString(" ")
                upsert(c, agent(id, blocks + Block("m", "markdown", text), text, finished = false))
                pause(40)
            }
            val actions = if (proposal != null) listOf(
                Action("demo.go:${c.id}:$id:${proposal.name}", t.yesDoIt, "primary"),
                Action("demo.skip:${c.id}:$id", t.notNow, "secondary"),
            ) else emptyList()
            end(c, "done", t.statusReplied)
            c.activity = null
            upsert(c, agent(id, blocks + Block("m", "markdown", markdown), markdown, finished = true, actions = actions))
            pushHome()
            jobs.remove(c.id)
            then?.invoke()
        }
    }

    /** A piece of work: its card shows it running, then becomes the report card with the Mac's buttons. */
    private fun work(c: DChat, kind: DemoReportKind, title: String) {
        val task = "task-" + newID()
        reports[task] = DReport(kind, title, product(c.productID)?.name ?: "")
        val cardID = newID()
        c.entries += Entry(id = cardID, kind = "report", atMs = now(), card = Card(task, title, t.workingOnIt, Status("running", t.statusRunning, "active", true)))
        begin(c)
        pushHome()
        pushChat(c)
        val steps = when (kind) {
            DemoReportKind.Sync -> t.syncWorkSteps
            DemoReportKind.Charts -> t.chartsWorkSteps
            else -> t.genericWorkSteps
        }
        jobs.remove(c.id)?.cancel()
        jobs[c.id] = scope.launch {
            for (step in steps) {
                c.activity = step
                pushChat(c)
                pause(1100)
            }
            end(c, "done", t.statusReportReady)
            c.activity = null
            c.entries.firstOrNull { it.id == cardID }?.let { e -> replace(c, e.copy(card = readyCard(task, title))) }
            pushHome()
            pushChat(c)
            jobs.remove(c.id)
        }
    }

    private fun readyCard(task: String, title: String) = Card(
        task, title, t.reviewedReady, Status("reportReady", t.statusReportReady, "good"),
        listOf(
            Action("card.report:$task", t.openReport, "primary", kind = "report", target = "demo.report:$task"),
            Action("card.changes:$task", t.askForChanges, "secondary", kind = "compose", input = ActionInput(t.askForChanges, required = true)),
            Action("demo.merge:$task", t.mergeIt, "secondary", confirm = t.mergeConfirm),
        ),
    )

    private fun stop(c: DChat) {
        val running = jobs.remove(c.id) ?: return
        running.cancel()
        end(c, "stopped", t.stopped)
        c.activity = null
        c.entries.lastOrNull { it.kind == "agent" && it.finished == false }?.let { replace(c, it.copy(finished = true)) }
        for (card in c.entries.filter { it.card?.status?.code == "running" }) c.entries.remove(card)
        note(c, t.stopped, "neutral")
        pushHome()
    }

    private fun note(c: DChat, text: String, tone: String) {
        c.entries += Entry(id = newID(), kind = "event", atMs = now(), text = text, tone = tone)
        c.updatedAt = now()
        pushChat(c)
    }

    private suspend fun pause(ms: Long) { if (pace > 0) delay(ms * pace) }

    // MARK: Reports and files

    private fun openReport(target: String): Outcome {
        val key = target.substringAfter(":")
        val spec = when {
            target.startsWith("demo.report:") -> reports[key]
            target.startsWith("demo.product:") -> product(key)?.let { DReport(DemoReportKind.Product, t.everythingSoFar, it.name) }
            else -> null
        } ?: return Outcome.Err(LinkError(ErrorCodes.NOT_FOUND, t.notInDemo))
        // Questions are answered, not merged.
        val mergeable = spec.kind != DemoReportKind.VariantA && spec.kind != DemoReportKind.VariantB && spec.kind != DemoReportKind.Questions
        val actions = if (target.startsWith("demo.report:") && key !in merged && mergeable) listOf(
            Action("demo.merge:$key", t.mergeIt, "primary", confirm = t.mergeConfirm),
            Action("report.changes:$key", t.askForChanges, "secondary", kind = "compose", input = ActionInput(t.askForChanges, required = true)),
        ) else emptyList()
        val decisions = if (spec.kind == DemoReportKind.Questions) planQuestions() else null
        return ok(Report.serializer(), Report(spec.title, DemoReport.html(spec.kind, spec.title, spec.product, t), "rep:demo", actions, decisions))
    }

    // MARK: Questions for you

    /** The answer given to the demo's questions, as the Mac keeps the last one sent. */
    private var planAnswer: DecisionSent? = null

    private fun planQuestions() = Decisions(
        ref = PLAN_REF, title = t.planQuestionsTitle, revision = "demo-1",
        items = listOf(
            DecisionItem("widgets", t.planWidgets, t.planWidgetsDetail, listOf(t.optTake, t.optLater, t.optNo), recommended = t.optTake),
            DecisionItem("export", t.planExport, t.planExportDetail, listOf(t.optTake, t.optLater, t.optNo), recommended = t.optTake),
            DecisionItem("family", t.planFamily, t.planFamilyDetail, listOf(t.optTake, t.optLater, t.optNo), recommended = t.optLater),
        ),
        latest = planAnswer,
    )

    /** `report.decide` for the demo's questions: kept as the answer, once per submission id. */
    private fun decide(a: JsonObject): Outcome {
        if (a.str("ref") != PLAN_REF) return notInDemo
        val id = a.str("submissionID") ?: return notInDemo
        if (planAnswer?.id == id) return ok(DecisionSent.serializer(), planAnswer!!)
        fun map(key: String) = (a[key] as? JsonObject)?.mapNotNull { (k, v) -> (v as? JsonPrimitive)?.contentOrNull?.let { k to it } }?.toMap().orEmpty()
        val sent = DecisionSent(id = id, sentAt = now(), device = "phone", choices = map("choices"), comments = map("comments"),
            general = a.str("general").orEmpty())
        planAnswer = sent
        pushHome()
        return ok(DecisionSent.serializer(), sent)
    }

    private fun read(a: JsonObject): Outcome {
        val ref = a.str("ref") ?: return notInDemo
        val (file, bytes) = files[ref] ?: return Outcome.Err(LinkError(ErrorCodes.NOT_FOUND, t.notInDemo))
        val offset = (a.long("offset") ?: 0).coerceIn(0, bytes.size.toLong()).toInt()
        val length = (a.long("length") ?: (512L * 1024)).coerceIn(0, 512L * 1024).toInt()
        val end = minOf(bytes.size, offset + length)
        return ok(FileChunk.serializer(), FileChunk(
            ref = ref, offset = offset.toLong(), total = bytes.size.toLong(),
            data = Base64.encode(bytes, offset, end), mime = if (file.kind == "image") "image/jpeg" else "application/octet-stream", name = file.name,
        ))
    }

    // MARK: Context and skills

    private fun context(productID: String, chatID: String?): Outcome {
        val p = product(productID) ?: return stale
        val here = chat(chatID ?: "")?.takeIf { it.productID == p.id }
        fun lock(res: String) = if (access[res] == "workspace") t.askBeforeEditing else t.canEdit
        fun label(res: String) = if (access[res] == "workspace") t.canEdit else t.askBeforeEditing
        val ledger = p.id == LEDGER
        val folder = if (ledger) "pocket-ledger" else "harbor-coffee"
        val resources = listOf(
            Resource(RES_FOLDER, folder, "folder", t.kindFolder, access[RES_FOLDER]!!, label(RES_FOLDER),
                path = "~/Developer/$folder", branch = "main", primary = true,
                actions = listOf(Action("demo.access:$RES_FOLDER", lock(RES_FOLDER)))),
            Resource(RES_SITE, if (ledger) "pocketledger.app" else "harborcoffee.shop", "website", t.kindWebsite, access[RES_SITE]!!, label(RES_SITE),
                url = if (ledger) "https://pocketledger.app" else "https://harborcoffee.shop",
                actions = listOf(Action("demo.access:$RES_SITE", lock(RES_SITE)))),
        )
        if (!ledger) return ok(Context.serializer(), Context(
            productID = p.id, resources = resources,
            instructions = Instructions(t.cafeSummary, t.cafeRules),
            chatReports = here?.let { chatReports(it) },
        ))
        val variants = listOf(t.variantA to DemoReportKind.VariantA, t.variantB to DemoReportKind.VariantB).mapIndexed { i, (title, kind) ->
            val task = "variant-$i"
            reports.getOrPut(task) { DReport(kind, title, p.name) }
            Card(task, title, t.reviewedReady, Status("reportReady", t.statusReportReady, "good"),
                listOf(Action("card.report:$task", t.openReport, "primary", kind = "report", target = "demo.report:$task")))
        }
        return ok(Context.serializer(), Context(
            productID = p.id,
            resources = resources,
            changes = listOf(
                Change(DIFF_SYNC, folder, "Sources/Sync/SyncEngine.swift", t.modified, 12, 3),
                Change(DIFF_TEST, folder, "Tests/SyncEngineTests.swift", t.added, 41, 0),
            ),
            checks = Checks("pass", listOf(Check(t.checkLastExpense, "pass", "SyncEngineTests"), Check(t.checkOldTests, "pass", t.checkPassedCount))),
            instructions = Instructions(t.ledgerSummary, t.ledgerRules),
            nowAndNext = listOf(Card("next-widgets", t.nextWidgets, null, Status("queued", t.statusNext, "neutral"))),
            work = listOf(Work("variants", t.variantsTitle, "variants", Status("reportReady", t.statusReportReady, "good"), variants)),
            report = Action("demo.product:${p.id}", t.everythingSoFar, "secondary", kind = "report", target = "demo.product:${p.id}"),
            chatReports = here?.let { chatReports(it) },
        ))
    }

    /**
     * A chat's reports, as the Mac's panel lists them: the report cards that came in the chat and
     * the ones made with "Create report", newest first — once the chat has been answered, as a
     * Mac chat has its session then.
     */
    private fun chatReports(c: DChat): ChatReports? {
        if (c.entries.none { it.kind == "agent" }) return null
        val fromCards = c.entries.mapNotNull { e -> e.card?.takeIf { it.status.code == "reportReady" || it.status.code == "merged" }?.let { it.id to it.title } }
        val made = chatReports[c.id].orEmpty().map { it to (reports[it]?.title ?: c.title) }
        val asked = if (c.id == PLAN_CHAT) listOf(PLAN_REPORT to t.planQuestionsTitle) else emptyList()
        val all = (asked + fromCards + made).asReversed()
        return ChatReports(
            items = all.mapIndexed { i, (task, title) ->
                if (reports[task]?.kind == DemoReportKind.Questions) {
                    ChatReport(t.questionsForYou, title,
                        Action("chat.report:$task", t.openQuestions, "secondary", kind = "report", target = "demo.report:$task"))
                } else {
                    ChatReport(if (i == 0) t.latestReport else t.oneReport, title,
                        Action("chat.report:$task", t.openReport, "secondary", kind = "report", target = "demo.report:$task"))
                }
            },
            generating = c.id in makingReport,
            create = if (c.archived) null else Action("demo.chatReport:${c.id}", t.createReport),
            note = t.reportNote,
        )
    }

    private fun skills(productID: String?) = Skills(
        skills = listOfNotNull(
            Skill("swiftui-review", "swiftui-review", "project", t.skillReview, uses = 12, usesHere = if (productID == LEDGER) 5 else null, lastUsed = t.twoDaysAgo),
            Skill("release-notes", "release-notes", "global", t.skillNotes, uses = 7, lastUsed = t.lastWeek).takeIf { productID == null || productID == LEDGER },
        ),
        servers = listOf(
            Server("github", "https://api.githubcopilot.com/mcp", "connected", "http", "user", t.serverGitHub, uses = 23, lastUsed = t.today),
            Server("xcode", "xcrun mcpbridge", "connected", "stdio", "project:pocket-ledger", t.serverXcode, uses = 9, lastUsed = t.twoDaysAgo),
        ),
        counted = true,
        transcripts = 214,
    )

    // MARK: What the phone is shown

    private fun desktop() = Desktop(id = "demo", name = t.macName, version = "demo", language = t.language)

    private fun pushHome() = event("home", Home.serializer(), home())

    private fun home(): Home {
        val attention = mutableListOf<Attention>()
        for (c in chats.filter { !it.archived }) for (e in c.entries) {
            e.question?.takeIf { it.answerable }?.let { q ->
                attention += Attention("q:${e.id}", c.productID, c.id, "question", c.title, q.headline, "attention", e.atMs)
            }
            for (ask in e.asks) attention += Attention(ask.id, c.productID, c.id, "ask", c.title, ask.title, "attention", e.atMs, ask.actions)
        }
        chat(PLAN_CHAT)?.takeIf { !it.archived && planAnswer == null }?.let { c ->
            attention += Attention("decide:$PLAN_CHAT", c.productID, c.id, "decide", c.title,
                t.waitsForDecisions.replace("%s", t.planQuestionsTitle), "attention", c.updatedAt,
                listOf(Action("decide.open", t.openQuestions, "primary", kind = "report", target = "demo.report:$PLAN_REPORT")))
        }
        // A report card nobody has merged yet is finished work waiting to be read, as on the Mac.
        val finished = chats.filter { !it.archived }.flatMap { c ->
            c.entries.mapNotNull { e ->
                val card = e.card?.takeIf { it.status.code == "reportReady" && it.id !in merged } ?: return@mapNotNull null
                Finished(
                    "done:${card.id}", c.productID, c.id, card.title, t.statusReportReady, e.atMs,
                    Action("done.report:${card.id}", t.openReport, "primary", kind = "report", target = "demo.report:${card.id}"),
                )
            }
        }.sortedByDescending { it.atMs }
        return Home(
            desktop = desktop(),
            products = products.map { p ->
                val mine = chats.filter { it.productID == p.id }.sortedWith(compareByDescending<DChat> { it.pinned }.thenByDescending { it.updatedAt })
                Product(
                    id = p.id, name = p.name, initials = p.initials, pinned = p.pinned, brief = p.brief,
                    status = if (mine.any { it.busy }) Status("running", t.statusRunning, "active", true) else null,
                    lastWorkedAtMs = mine.maxOfOrNull { it.updatedAt },
                    chats = mine.filter { !it.archived }.map { summary(it) },
                    archivedChats = mine.filter { it.archived }.map { summary(it) },
                )
            }.sortedByDescending { it.pinned },
            attention = attention.sortedByDescending { it.atMs },
            composer = composer(),
            readiness = listOf(
                Readiness("engine", t.readyEngine, state = "ready"),
                Readiness("claude", t.readyClaude, state = "ready"),
                Readiness("codex", t.readyCodex, state = "ready"),
            ),
            finished = finished,
            summary = Summary(working = chats.count { it.busy }, waiting = attention.size, ready = finished.size),
            live = Live(running = chats.filter { it.busy }.sortedByDescending { it.busySince }.map { line(it) },
                        ended = ended.toList(), over = chats.none { it.busy }),
            limits = limits(),
        )
    }

    /** The foot of the Mac's sidebar: Claude well into its week, Codex with room to spare. */
    private fun limits() = Limits(t.limits, listOf(
        // With the tick where an even pace would be: Claude has used more of its week than has passed.
        EngineLimits("Claude", used = 78, pressure = "tight", windows = listOf(
            LimitWindow(t.limitSession, 42, t.limitUsed.replace("%d", "42"), "comfortable", t.limitResetsSession,
                elapsed = 58, pace = t.paceRoom, paceKey = "behind"),
            LimitWindow(t.limitWeekly, 78, t.limitUsed.replace("%d", "78"), "tight", t.limitResetsWeekly,
                elapsed = 55, pace = t.paceAhead, paceKey = "ahead"),
        )),
        EngineLimits("Codex", used = 16, pressure = "comfortable", windows = listOf(
            LimitWindow(t.limitSession, 9, t.limitUsed.replace("%d", "9"), "comfortable", t.limitResetsCodex,
                elapsed = 12, pace = t.paceEven, paceKey = "even"),
            LimitWindow(t.limitWeekly, 16, t.limitUsed.replace("%d", "16"), "comfortable", t.limitResetsWeekly,
                elapsed = 55, pace = t.paceRoom, paceKey = "behind"),
        )),
    ))

    // MARK: The run control, as the Mac's

    /** Claude writes, Codex reviews: a page each, a model and a depth, the pill in the Mac's words. */
    private fun composer(): ComposerOptions {
        val claude = selected["claudeModel"] ?: "opus"
        val codex = selected["codexModel"] ?: ""
        fun level(id: String) = when (id) {
            "low" -> t.low; "medium" -> t.medium; "high" -> t.high; "xhigh" -> t.veryHigh; "max" -> t.maximum
            else -> t.automatic
        }
        fun depths(ids: List<String>, automatic: String) = ids.map { id ->
            Option(id, if (id == "auto") t.automaticAt.replace("%s", level(automatic)) else level(id))
        }
        val groups = mutableListOf(OptionGroup("claudeModel", "Claude", listOf(
            Option("auto", t.automatic),
            Option("opus", "Opus · Opus 5.5", section = t.newestOfEach),
            Option("sonnet", "Sonnet · Sonnet 5", section = t.newestOfEach),
            Option("haiku", "Haiku · Haiku 4.5", section = t.newestOfEach),
            Option("claude-opus-4-7", "Opus 4.7", section = t.fixedVersion),
        ), claude, engine = "claude", kind = "model"))
        // Haiku takes no depth, and a scale over a model that ignores it would be a control that lies.
        val claudeThinks = claude != "haiku"
        if (claudeThinks) groups += OptionGroup("claudeEffort", t.claudeThinks,
            depths(listOf("auto", "low", "medium", "high", "xhigh", "max"), "high"), selected["claudeEffort"], "claude", "depth")
        groups += OptionGroup("codexModel", "Codex", listOf(
            Option("", t.automatic), Option("gpt-5.5", "GPT-5.5"), Option("gpt-5.5-mini", "GPT-5.5 mini"),
        ), codex, engine = "codex", kind = "model")
        groups += OptionGroup("codexEffort", t.codexThinks,
            depths(listOf("auto", "low", "medium", "high", "xhigh"), "medium"), selected["codexEffort"], "codex", "depth")
        val claudeName = when (claude) {
            "auto" -> "Claude"; "opus" -> "Opus 5.5"; "sonnet" -> "Sonnet 5"; "haiku" -> "Haiku 4.5"; "claude-opus-4-7" -> "Opus 4.7"
            else -> claude
        }
        val codexName = when (codex) { "gpt-5.5" -> "GPT-5.5"; "gpt-5.5-mini" -> "GPT-5.5 mini"; else -> "Codex" }
        fun depthName(id: String?, automatic: String) = level(if (id == null || id == "auto") automatic else id)
        return ComposerOptions(groups, summary = listOf(
            RunPart("claude", "Claude", claudeName, if (claudeThinks) depthName(selected["claudeEffort"], "high") else null),
            RunPart("codex", "Codex", codexName, depthName(selected["codexEffort"], "medium")),
        ))
    }

    // MARK: The stretch of work

    private fun line(c: DChat) = LiveLine("chat:${c.id}", c.productID, c.id, c.title, product(c.productID)?.name ?: "", c.busySince)

    private fun begin(c: DChat) {
        // A new stretch starts from nothing, as on the Mac.
        if (chats.none { it.busy }) ended.clear()
        c.busy = true
        c.busySince = now()
    }

    private fun end(c: DChat, outcome: String, label: String) {
        if (!c.busy) return
        ended.removeAll { it.id == "chat:${c.id}" }
        ended.add(0, line(c).copy(outcome = outcome, label = label))
        while (ended.size > 3) ended.removeAt(ended.size - 1)
        c.busy = false
        c.busySince = null
    }

    private fun summary(c: DChat) = ChatSummary(c.id, c.productID, c.title, c.pinned, c.archived, c.createdAt, c.updatedAt, status(c))

    private fun status(c: DChat): Status = when {
        c.busy -> Status("working", t.statusWorking, "active", true)
        c.entries.any { it.question?.answerable == true } -> Status("needsAttention", t.statusNeedsAnswer, "attention")
        c.entries.any { it.asks.isNotEmpty() } -> Status("needsAttention", t.statusNeedsOk, "attention")
        c.entries.any { it.kind == "agent" } -> Status("ready", t.statusReplied, "good")
        else -> Status("new", "", "neutral")
    }

    private fun pushChat(c: DChat) {
        if (c.id !in open) return
        event("chat", ChatState.serializer(), ChatState(
            id = c.id, productID = c.productID, title = c.title, archived = c.archived, status = status(c),
            activity = c.activity, busy = c.busy, entries = c.entries.toList(),
            actions = if (c.busy) listOf(Action("stop:${c.id}", t.stop, "secondary")) else emptyList(),
        ))
    }

    private fun upsert(c: DChat, e: Entry) {
        val i = c.entries.indexOfFirst { it.id == e.id }
        if (i >= 0) c.entries[i] = e else c.entries += e
        c.updatedAt = now()
        pushChat(c)
    }

    private fun replace(c: DChat, e: Entry) {
        val i = c.entries.indexOfFirst { it.id == e.id }
        if (i >= 0) c.entries[i] = e
        pushChat(c)
    }

    private fun agent(id: String, blocks: List<Block>, text: String, finished: Boolean, actions: List<Action> = emptyList()) =
        Entry(id = id, kind = "agent", atMs = now(), author = t.bulava, text = text, blocks = blocks.toList(), finished = finished, actions = actions)

    private fun chat(id: String) = chats.firstOrNull { it.id == id }
    private fun product(id: String?) = products.firstOrNull { it.id == id }

    private fun createChat(productID: String, id: String, title: String): DChat? {
        product(productID) ?: return null
        return DChat(id, productID, title, now()).also { chats += it }
    }

    private fun newID(): String = "demo-${++seq}-${now() % 100000}"

    // MARK: The starting state

    private fun seed() {
        val t0 = now()
        products += DProduct(LEDGER, t.ledgerName, "PL", t.ledgerBrief, pinned = true)
        products += DProduct(CAFE, t.cafeName, "HC", t.cafeBrief, pinned = false)

        // An answered question with a proposal waiting to be accepted.
        DChat("demo-sync", LEDGER, t.syncTitle, t0 - 3 * HOUR).also { c ->
            c.updatedAt = t0 - 2 * HOUR
            c.entries += Entry("demo-sync-q", "user", t0 - 3 * HOUR, t.you, t.syncAsk)
            c.entries += Entry(
                "demo-sync-a", "agent", t0 - 3 * HOUR + 40_000, t.bulava, t.syncAnswer,
                blocks = t.syncSteps.mapIndexed { i, s -> Block("s$i", "activity", activity = Activity(s, "done")) } + Block("m", "markdown", t.syncAnswer),
                finished = true,
                actions = listOf(
                    Action("demo.go:demo-sync:demo-sync-a:${DemoReportKind.Sync.name}", t.yesDoIt, "primary"),
                    Action("demo.skip:demo-sync:demo-sync-a", t.notNow, "secondary"),
                ),
            )
            chats += c
        }
        // A worker's question with options.
        DChat("demo-ship", LEDGER, t.shipTitle, t0 - 40 * MINUTE).also { c ->
            c.updatedAt = t0 - 20 * MINUTE
            c.entries += Entry("demo-ship-q", "user", t0 - 40 * MINUTE, t.you, t.shipAsk)
            c.entries += Entry(
                "demo-ship-a", "agent", t0 - 38 * MINUTE, t.bulava, t.shipLead,
                blocks = t.shipSteps.mapIndexed { i, s -> Block("s$i", "activity", activity = Activity(s, "done")) } + Block("m", "markdown", t.shipLead),
                finished = true,
            )
            c.entries += Entry(
                "demo-ship-ask", "question", t0 - 20 * MINUTE, t.bulava, t.shipHeadline,
                question = Question(
                    eyebrow = t.shipEyebrow, headline = t.shipHeadline, situation = t.shipSituation,
                    recommendation = t.shipRecommendation, unblocks = t.shipUnblocks,
                    items = listOf(QuestionItem(t.shipItem, options = listOf(
                        Option(t.shipOption42, t.shipOption42, t.shipOption42Detail),
                        Option(t.shipOptionBump, t.shipOptionBump, t.shipOptionBumpDetail),
                    ))),
                ),
            )
            chats += c
        }
        // A message stopped until the folder is trusted.
        DChat("demo-charts", LEDGER, t.chartsTitle, t0 - 5 * MINUTE).also { c ->
            c.entries += Entry(
                "demo-charts-q", "user", t0 - 5 * MINUTE, t.you, t.chartsAsk,
                delivery = Delivery("failed", t.notDelivered),
                asks = listOf(Ask("demo.trust:demo-charts:demo-charts-q", "folderTrust", "attention", t.trustTitle,
                    code = "~/Developer/pocket-ledger",
                    actions = listOf(Action("demo.trust:demo-charts:demo-charts-q", t.trustAndSend, "primary")))),
                actions = listOf(Action("takeBack:demo-charts-q", t.edit, "secondary", kind = "takeBack", target = "demo-charts-q")),
            )
            chats += c
        }
        // Finished work with its report ready.
        DChat("demo-landing", CAFE, t.landingTitle, t0 - 26 * HOUR).also { c ->
            c.updatedAt = t0 - 25 * HOUR
            c.entries += Entry("demo-landing-q", "user", t0 - 26 * HOUR, t.you, t.landingAsk)
            c.entries += Entry(
                "demo-landing-a", "agent", t0 - 26 * HOUR + 60_000, t.bulava, t.landingAnswer,
                blocks = t.landingSteps.mapIndexed { i, s -> Block("s$i", "activity", activity = Activity(s, "done")) } + Block("m", "markdown", t.landingAnswer),
                finished = true,
            )
            reports["task-landing"] = DReport(DemoReportKind.Landing, t.landingTask, t.cafeName)
            c.entries += Entry("demo-landing-card", "report", t0 - 25 * HOUR, card = readyCard("task-landing", t.landingTask))
            chats += c
        }
        // An answer that is a set of questions: the Mac lists it as "Questions for you".
        DChat(PLAN_CHAT, LEDGER, t.planTitle, t0 - 3 * HOUR).also { c ->
            c.updatedAt = t0 - 2 * HOUR
            c.entries += Entry("demo-plan-q", "user", t0 - 3 * HOUR, t.you, t.planAsk)
            c.entries += Entry("demo-plan-a", "agent", t0 - 2 * HOUR, t.bulava, t.planAnswer,
                blocks = listOf(Block("m", "markdown", t.planAnswer)), finished = true)
            reports[PLAN_REPORT] = DReport(DemoReportKind.Questions, t.planQuestionsTitle, t.ledgerName)
            chats += c
        }
    }

    private class DProduct(val id: String, var name: String, val initials: String, val brief: String, var pinned: Boolean)

    private class DChat(val id: String, val productID: String, var title: String, val createdAt: Long) {
        var updatedAt = createdAt
        var pinned = false
        var archived = false
        var busy = false
        var busySince: Long? = null
        var activity: String? = null
        val entries = mutableListOf<Entry>()
    }

    private data class DReport(val kind: DemoReportKind, val title: String, val product: String)

    private fun JsonObject.str(key: String) = (this[key] as? JsonPrimitive)?.contentOrNull
    private fun JsonObject.bool(key: String) = (this[key] as? JsonPrimitive)?.booleanOrNull
    private fun JsonObject.long(key: String) = (this[key] as? JsonPrimitive)?.let { it.longOrNull ?: it.intOrNull?.toLong() }

    companion object {
        const val LEDGER = "demo-ledger"
        const val PLAN_REF = "dec:demo-plan"
        const val PLAN_CHAT = "demo-plan"
        const val PLAN_REPORT = "plan-questions"
        const val CAFE = "demo-cafe"
        private const val RES_FOLDER = "res-folder"
        private const val RES_SITE = "res-site"
        private const val DIFF_SYNC = "diff:sync"
        private const val DIFF_TEST = "diff:test"
        private const val MINUTE = 60_000L
        private const val HOUR = 60 * MINUTE

        private val SYNC_DIFF = """
            @@ -41,12 +41,21 @@ final class SyncEngine {
            -    private var lastSyncedAt: Date = .distantPast
            +    /// What iCloud last handed back. A date cannot tell apart two changes made in the same second.
            +    private var token: CKServerChangeToken?

                 func sync() async throws {
            -        let changes = try await store.changes(since: lastSyncedAt)
            +        let (changes, next) = try await store.changes(after: token)
                     try await apply(changes)
            -        lastSyncedAt = changes.last?.date ?? lastSyncedAt
            +        token = next
            +        try tokens.save(next)
                 }
        """.trimIndent()

        private val TEST_DIFF = """
            @@ -0,0 +1,18 @@
            +import XCTest
            +@testable import PocketLedger
            +
            +final class SyncEngineTests: XCTestCase {
            +    func testTheLastExpenseOfTheDaySyncs() async throws {
            +        let store = FakeCloudStore()
            +        let engine = SyncEngine(store: store)
            +        try await engine.sync()
            +
            +        store.add(Expense(amount: 3.20, note: "Coffee", date: .now))
            +        try await engine.sync()
            +
            +        XCTAssertEqual(engine.local.last?.note, "Coffee")
            +    }
            +}
        """.trimIndent()
    }
}
