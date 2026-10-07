package com.stepanok.bulava.link

import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject

// The wire contract with Bulava on the Mac. The Mac's side is `Night Shift/MobileLink/LinkWire.swift`;
// the rules both follow are in `link-protocol/README.md`.
//
// Every field has a default, and nothing here is an enum: codes arrive as strings and anything this
// build does not recognise is drawn as "something the Mac knows about" rather than failing to decode.
// A newer Mac can therefore add fields and values without breaking a phone installed months ago.

object LinkProtocol {
    const val VERSION = 1
    const val MINIMUM_VERSION = 1
    const val PAIRING_PAGE = "https://bulava.app/pair"
    const val DOWNLOAD_PAGE = "https://bulava.app/mobile"
    const val BONJOUR_TYPE = "_bulava-link._tcp"

    /**
     * What this build of the phone uses. Each must be in `link-protocol/contract.json`; a Mac that
     * does not offer one gets that part of the screen hidden, not a button that fails.
     */
    val USED_CAPABILITIES = setOf(
        "home", "chat.read", "chat.history", "chat.send", "chat.create", "chat.rename", "chat.archive",
        "chat.pin", "chat.stop", "entry.retry", "entry.takeBack", "actions", "questions",
        "attachments.upload", "files", "reports", "settings.models", "attention", "products.manage", "commands", "context", "skills", "push",
        "finished", "liveActivity", "audio.transcribe", "files.open", "reports.decide",
    )
}

val LinkJson = Json {
    ignoreUnknownKeys = true
    explicitNulls = false
    encodeDefaults = true
    isLenient = true
    coerceInputValues = true
}

// MARK: Handshake

@Serializable
data class Hello(
    val type: String = "hello",
    val protocolVersion: Int = LinkProtocol.VERSION,
    val minimumVersion: Int = LinkProtocol.MINIMUM_VERSION,
    val app: ClientApp,
    val pairing: Pairing? = null,
    val credential: Credential? = null,
) {
    @Serializable
    data class Pairing(val token: String)
}

@Serializable
data class ClientApp(
    val platform: String,
    val version: String,
    val deviceName: String,
    val osVersion: String? = null,
)

@Serializable
data class Credential(val deviceID: String, val secret: String)

@Serializable
data class Desktop(
    val id: String = "",
    val name: String = "",
    val version: String = "",
    val language: String = "en",
)

/** The Mac's answer to a hello: `welcome` or `refused`, told apart by [type]. */
@Serializable
data class HandshakeReply(
    val type: String = "",
    val protocolVersion: Int = 0,
    val desktop: Desktop? = null,
    val capabilities: List<String> = emptyList(),
    val deviceID: String? = null,
    val credential: Credential? = null,
    val code: String? = null,
    val message: String? = null,
    val desktopVersion: String? = null,
    /** In a refusal from a newer Mac: the newest phone app bulava.app offers, for "update to …". */
    val phoneApps: PhoneApps? = null,
)

/**
 * The newest phone app bulava.app offers, per platform, as the Mac last read it. The phone looks
 * nothing up on the internet itself: the Mac is its only connection, so the Mac reads it.
 */
@Serializable
data class PhoneApps(
    val android: PhoneApp? = null,
    val ios: PhoneApp? = null,
) {
    fun forPlatform(platform: String): PhoneApp? = if (platform == "ios") ios else android
}

@Serializable
data class PhoneApp(
    val version: String = "",
    /** Only ever rises; an update is decided by it, not by the version's words. */
    val build: Int = 0,
    /** The APK on bulava.app, the TestFlight invitation. */
    val url: String = "",
)

object ErrorCodes {
    const val UNAUTHORIZED = "unauthorized"
    const val REVOKED = "revoked"
    const val PAIRING_EXPIRED = "pairing_expired"
    const val PAIRING_USED = "pairing_used"
    const val PROTOCOL_TOO_OLD = "protocol_too_old"
    const val PROTOCOL_TOO_NEW = "protocol_too_new"
    const val STALE = "stale"
    const val NOT_FOUND = "not_found"
    const val NOT_ON_PHONE = "not_on_phone"
    const val TOO_LARGE = "too_large"
    const val OFFLINE = "offline"
    const val TIMEOUT = "timeout"
    /** No Whisper on the Mac to hear a recording with — none in this build, or its model is still on its way. */
    const val DICTATION_UNAVAILABLE = "dictation_unavailable"
    /** Whisper made out no words in the recording. */
    const val NOT_TRANSCRIBED = "not_transcribed"
    const val BAD_REQUEST = "bad_request"
    const val UNKNOWN_OPERATION = "unknown_operation"
    /** The report's questions changed since the phone read them; nothing was sent. */
    const val DECISIONS_CHANGED = "decisions_changed"
    /** Another device answered the report meanwhile; nothing was sent. */
    const val DECISIONS_CONFLICT = "decisions_conflict"
}

// MARK: Frames

@Serializable
data class Request(
    val type: String = "request",
    val id: String,
    val op: String,
    val args: JsonObject = JsonObject(emptyMap()),
)

/** Any frame from the Mac after the handshake, read just far enough to route it. */
@Serializable
data class Incoming(
    val type: String = "",
    val id: String? = null,
    val ok: Boolean? = null,
    val result: JsonElement? = null,
    val error: LinkError? = null,
    val event: String? = null,
    val data: JsonElement? = null,
)

@Serializable
data class LinkError(val code: String = "failed", val message: String = "")

// MARK: Home

@Serializable
data class Home(
    val desktop: Desktop = Desktop(),
    val products: List<Product> = emptyList(),
    val attention: List<Attention> = emptyList(),
    val composer: ComposerOptions = ComposerOptions(),
    val readiness: List<Readiness> = emptyList(),
    /** Work that finished and waits to be read. */
    val finished: List<Finished> = emptyList(),
    /** How much is going on, at a glance: what a Live Activity shows. */
    val summary: Summary = Summary(),
    /** What is working right now by name, and what stopped since the stretch began. Null from an older Mac. */
    val live: Live? = null,
    /** Claude's and Codex's usage, as the foot of the Mac's sidebar shows it. Null while neither is known. */
    val limits: Limits? = null,
    /** The newest phone app bulava.app offers, as the Mac last read it. Null from an older Mac. */
    val phoneApps: PhoneApps? = null,
    /** This calendar week as the Mac's widgets show it, every word in the Mac's language. Null until the Mac has counted it, and from an older Mac. */
    val week: Week? = null,
)

/** The sidebar's "Limits", in the Mac's words: each engine it has heard from, with its windows. */
@Serializable
data class Limits(
    val title: String = "",
    val engines: List<EngineLimits> = emptyList(),
)

@Serializable
data class EngineLimits(
    val name: String = "",
    /** The tightest window's share used, for the folded line; null while none is known. */
    val used: Int? = null,
    /** comfortable | tight | nearlyOut. */
    val pressure: String = "comfortable",
    val windows: List<LimitWindow> = emptyList(),
    /** Said in place of the windows while none is known yet. */
    val note: String? = null,
    /** Read over half an hour ago, or never: the meters are dimmed. */
    val stale: Boolean = false,
    /** How long ago it was read, when stale and known. */
    val readAgo: String? = null,
)

@Serializable
data class LimitWindow(
    /** "Session" or "Weekly". */
    val label: String = "",
    /** 0..100. */
    val used: Int = 0,
    /** "34% used". */
    val usedLabel: String = "",
    val pressure: String = "comfortable",
    /** When it comes back: "2h 5m". */
    val resets: String? = null,
    /** How much of the window has passed, 0..100: where an even pace would stand. Null from an older Mac or when the reset is unknown. */
    val elapsed: Int? = null,
    /** The pace in the Mac's words: "ahead of an even pace". */
    val pace: String? = null,
    /** ahead | even | behind. */
    val paceKey: String? = null,
)

/**
 * The stretch of work going on now, as the Mac tells it: [running] by name, [ended] with how each
 * stopped, and [over] once nothing has run for a while. What the Lock Screen says.
 */
@Serializable
data class Live(
    val running: List<LiveLine> = emptyList(),
    val ended: List<LiveLine> = emptyList(),
    val over: Boolean = true,
)

@Serializable
data class LiveLine(
    val id: String,
    val productID: String = "",
    val chatID: String? = null,
    val title: String = "",
    val product: String = "",
    val sinceMs: Long? = null,
    /** For an ended line: done | attention | failed | stopped. */
    val outcome: String? = null,
    /** For an ended line, the Mac's words for where it stopped: "Night Shift replied". */
    val label: String? = null,
)

@Serializable
data class Finished(
    val id: String,
    val productID: String = "",
    val chatID: String? = null,
    val title: String = "",
    val body: String = "",
    val atMs: Long = 0,
    /** Opens the report. */
    val report: Action? = null,
)

/** Runs working by themselves, things waiting for the director, reports ready to read. */
@Serializable
data class Summary(val working: Int = 0, val waiting: Int = 0, val ready: Int = 0)

@Serializable
data class Product(
    val id: String,
    val name: String = "",
    val initials: String = "",
    val pinned: Boolean = false,
    val brief: String = "",
    val icon: FileRef? = null,
    val status: Status? = null,
    val lastWorkedAtMs: Long? = null,
    val chats: List<ChatSummary> = emptyList(),
    val archivedChats: List<ChatSummary> = emptyList(),
)

@Serializable
data class ChatSummary(
    val id: String,
    val productID: String = "",
    val title: String = "",
    val pinned: Boolean = false,
    val archived: Boolean = false,
    val createdAtMs: Long = 0,
    val updatedAtMs: Long = 0,
    val status: Status = Status(),
)

@Serializable
data class Status(
    val code: String = "",
    val label: String = "",
    /** neutral | active | attention | problem | good — or newer. */
    val tone: String = "neutral",
    val active: Boolean = false,
)

@Serializable
data class Attention(
    val id: String,
    val productID: String = "",
    val chatID: String? = null,
    val kind: String = "",
    val title: String = "",
    val body: String = "",
    val tone: String = "attention",
    val atMs: Long = 0,
    val actions: List<Action> = emptyList(),
    /** What it is about, as the Mac's dialog lists it: files, servers, a folder. */
    val code: String? = null,
)

@Serializable
data class ComposerOptions(
    val groups: List<OptionGroup> = emptyList(),
    /** What the Mac's composer pill says: each engine in the order they work, with model and depth. */
    val summary: List<RunPart>? = null,
)

@Serializable
data class OptionGroup(
    val id: String,
    val title: String = "",
    val options: List<Option> = emptyList(),
    val selected: String? = null,
    /** claude | codex — the Mac's panel has a page per engine. Null from an older Mac. */
    val engine: String? = null,
    /** model | depth. */
    val kind: String? = null,
)

@Serializable
data class Option(
    val id: String,
    val label: String = "",
    val detail: String? = null,
    /** The heading it sits under in the Mac's menu. */
    val section: String? = null,
)

/** One engine in the pill: "Opus 5.5 · Very high". */
@Serializable
data class RunPart(
    val engine: String,
    val name: String = "",
    val model: String = "",
    val depth: String? = null,
)

@Serializable
data class Readiness(
    val id: String,
    val title: String = "",
    val detail: String = "",
    /** ready | attention | problem | checking */
    val state: String = "",
    val actions: List<Action> = emptyList(),
)

// MARK: Chat

@Serializable
data class ChatState(
    val id: String,
    val productID: String = "",
    val title: String = "",
    val archived: Boolean = false,
    val status: Status = Status(),
    val activity: String? = null,
    val degradation: String? = null,
    val queueCount: Int = 0,
    val busy: Boolean = false,
    val entries: List<Entry> = emptyList(),
    val hasEarlier: Boolean = false,
    val actions: List<Action> = emptyList(),
    /** This chat's own run control — the Mac keeps model and depth per chat. Null from an older Mac. */
    val composer: ComposerOptions? = null,
)

@Serializable
data class ChatDelta(
    val id: String,
    val header: ChatHeader = ChatHeader(),
    val upserts: List<Entry> = emptyList(),
    val removed: List<String> = emptyList(),
    val order: List<String>? = null,
)

@Serializable
data class ChatHeader(
    val title: String = "",
    val archived: Boolean = false,
    val status: Status = Status(),
    val activity: String? = null,
    val degradation: String? = null,
    val queueCount: Int = 0,
    val busy: Boolean = false,
    val hasEarlier: Boolean = false,
    val actions: List<Action> = emptyList(),
    val composer: ComposerOptions? = null,
)

@Serializable
data class ChatGone(val id: String)

@Serializable
data class Entry(
    val id: String,
    /** user | agent | codex | event | question | decision | report | unknown */
    val kind: String = "unknown",
    val atMs: Long = 0,
    val author: String = "",
    val text: String = "",
    val blocks: List<Block> = emptyList(),
    val attachments: List<FileRef> = emptyList(),
    val tone: String = "neutral",
    val delivery: Delivery? = null,
    val asks: List<Ask> = emptyList(),
    val actions: List<Action> = emptyList(),
    val question: Question? = null,
    val card: Card? = null,
    val finished: Boolean? = null,
    val explanation: Explanation? = null,
)

@Serializable
data class Explanation(
    val brief: String? = null,
    val stepByStep: String? = null,
    val running: Boolean = false,
    val stale: Boolean = false,
    val failure: String? = null,
    val actions: List<Action> = emptyList(),
)

@Serializable
data class Delivery(val code: String = "", val label: String = "")

@Serializable
data class Block(
    val id: String,
    /** markdown | activity | consult | file | gallery | error | unknown */
    val kind: String = "unknown",
    val text: String = "",
    val activity: Activity? = null,
    val files: List<FileRef> = emptyList(),
    /** Files the text names that the Mac lets the phone open (`file.open`). */
    val links: List<FileRef> = emptyList(),
)

@Serializable
data class Activity(val sentence: String = "", val status: String = "done", val detail: String? = null)

/** What `file.open` answers: where the phone opens it, on the Mac's home Wi-Fi. */
@Serializable
data class FileOpen(val url: String = "", val title: String = "", val scope: String = "file")

@Serializable
data class FileRef(
    val ref: String? = null,
    val name: String = "",
    val kind: String = "other",
    val size: Long? = null,
    val url: String? = null,
)

@Serializable
data class Ask(
    val id: String,
    val kind: String = "",
    val tone: String = "attention",
    val title: String = "",
    val detail: String? = null,
    val code: String? = null,
    val actions: List<Action> = emptyList(),
)

@Serializable
data class Action(
    val id: String,
    val label: String = "",
    /** primary | secondary | destructive */
    val style: String = "secondary",
    /** invoke | compose | report | takeBack | mac — anything else is shown and not pressed. */
    val kind: String = "invoke",
    val confirm: String? = null,
    val input: ActionInput? = null,
    val target: String? = null,
    val disabledReason: String? = null,
)

@Serializable
data class ActionInput(
    val placeholder: String = "",
    val required: Boolean = false,
    val value: String? = null,
    /**
     * When the Mac asks for this in a sheet of its own — «Commit as me…» — what that sheet shows:
     * its heading, the lines above and below the field, the words on its button, and why it cannot
     * be done as it stands. Null from an older Mac, and for a plain line of text.
     */
    val title: String? = null,
    val above: List<InputNote>? = null,
    val below: List<InputNote>? = null,
    val submit: String? = null,
    val blocked: String? = null,
) {
    /** Whether this is the Mac's sheet rather than a line of text. */
    val isSheet: Boolean get() = title != null || !above.isNullOrEmpty() || !below.isNullOrEmpty()
}

/** One line of such a sheet: tone null (secondary) | faint | attention | problem; mono for a file list. */
@Serializable
data class InputNote(val text: String = "", val tone: String? = null, val mono: Boolean? = null)

@Serializable
data class Question(
    val eyebrow: String = "",
    val headline: String = "",
    val situation: String? = null,
    val recommendation: String? = null,
    val ifUnanswered: String? = null,
    val unblocks: String? = null,
    val items: List<QuestionItem> = emptyList(),
    val answerable: Boolean = true,
)

@Serializable
data class QuestionItem(
    val question: String = "",
    val header: String? = null,
    val options: List<Option> = emptyList(),
    val multiSelect: Boolean = false,
)

@Serializable
data class Card(
    val id: String,
    val title: String = "",
    val subtitle: String? = null,
    val status: Status = Status(),
    val actions: List<Action> = emptyList(),
)

// MARK: Results

@Serializable
data class HistoryPage(val entries: List<Entry> = emptyList(), val hasEarlier: Boolean = false)

@Serializable
data class Sent(val entryID: String = "", val duplicate: Boolean = false)

@Serializable
data class TakenBack(val text: String = "", val attachments: List<FileRef> = emptyList())

@Serializable
data class UploadStarted(val uploadID: String = "", val chunkSize: Int = 256 * 1024)

/** The words of a recording, heard by the Mac's Whisper, for the composer of [chatID]. */
@Serializable
data class Transcript(val requestID: String = "", val chatID: String? = null, val text: String = "")

@Serializable
data class FileChunk(
    val ref: String = "",
    val offset: Long = 0,
    val total: Long = 0,
    val data: String = "",
    val mime: String = "application/octet-stream",
    val name: String = "",
)

@Serializable
data class Report(
    val title: String = "",
    val html: String = "",
    val root: String = "",
    val actions: List<Action> = emptyList(),
    /** What the report asks to decide — drawn by the phone itself, never by the page. Null from an older Mac. */
    val decisions: Decisions? = null,
)

/** A report's questions, and the answer last sent to them from anywhere. */
@Serializable
data class Decisions(
    /** What `report.decide` names: the report itself. */
    val ref: String = "",
    val title: String = "",
    /** The questions as read; an answer carries it back. */
    val revision: String = "",
    val items: List<DecisionItem> = emptyList(),
    val latest: DecisionSent? = null,
)

@Serializable
data class DecisionItem(
    val id: String = "",
    val title: String = "",
    val detail: String? = null,
    val options: List<String> = emptyList(),
    /** The agent's advice: marked beside its option, never chosen for the reader. */
    val recommended: String? = null,
    val comment: Boolean = true,
)

@Serializable
data class DecisionSent(
    val id: String = "",
    val sentAt: Long = 0,
    val device: String = "",
    val choices: Map<String, String> = emptyMap(),
    val comments: Map<String, String> = emptyMap(),
    val general: String = "",
)

/** What the QR code on the Mac carries, after the `#`. */
@Serializable
data class PairingCode(
    val v: Int = 1,
    val id: String = "",
    val n: String = "",
    val k: String = "",
    val p: Int = 0,
    val h: List<String> = emptyList(),
    val t: String = "",
    val e: Long = 0,
)

// MARK: Context of a product

@Serializable
data class Context(
    val productID: String = "",
    val resources: List<Resource> = emptyList(),
    val changes: List<Change> = emptyList(),
    val checks: Checks? = null,
    val instructions: Instructions? = null,
    val nowAndNext: List<Card> = emptyList(),
    val work: List<Work> = emptyList(),
    val report: Action? = null,
    /** This chat's reports, as the Mac's panel lists them. Null before the chat has a session, and from an older Mac. */
    val chatReports: ChatReports? = null,
)

@Serializable
data class ChatReports(
    /** Newest first. */
    val items: List<ChatReport> = emptyList(),
    val generating: Boolean = false,
    /** "Create report"; null for an archived chat. */
    val create: Action? = null,
    /** Where the report is saved, in the Mac's words. */
    val note: String = "",
)

@Serializable
data class ChatReport(val title: String = "", val detail: String = "", val open: Action)

@Serializable
data class Resource(
    val id: String,
    val name: String = "",
    val kind: String = "",
    val kindLabel: String = "",
    val access: String = "",
    val accessLabel: String = "",
    val path: String? = null,
    val url: String? = null,
    val branch: String? = null,
    val primary: Boolean = false,
    val live: Boolean = true,
    val actions: List<Action> = emptyList(),
)

@Serializable
data class Change(
    val ref: String,
    val project: String = "",
    val path: String = "",
    val kindLabel: String = "",
    val added: Int? = null,
    val removed: Int? = null,
)

@Serializable
data class Checks(val status: String = "unknown", val items: List<Check> = emptyList())

@Serializable
data class Check(val criterion: String = "", val status: String = "unknown", val note: String = "")

@Serializable
data class Instructions(val summary: String = "", val brief: String = "")

@Serializable
data class Work(
    val id: String,
    val title: String = "",
    val kind: String = "job",
    val status: Status = Status(),
    val parts: List<Card> = emptyList(),
    val missing: Int = 0,
    val report: Action? = null,
)

@Serializable
data class Diff(val text: String = "")

// MARK: Skills and MCP servers

@Serializable
data class Skills(
    val skills: List<Skill> = emptyList(),
    val servers: List<Server> = emptyList(),
    val counted: Boolean = false,
    val transcripts: Int = 0,
)

@Serializable
data class Skill(
    val id: String,
    val name: String = "",
    val scope: String = "",
    val description: String = "",
    val uses: Int = 0,
    val usesHere: Int? = null,
    val lastUsed: String? = null,
    val source: String? = null,
    val actions: List<Action> = emptyList(),
)

@Serializable
data class Server(
    val name: String = "",
    val target: String = "",
    val health: String = "unknown",
    val transport: String = "",
    val scope: String = "",
    val description: String = "",
    val uses: Int = 0,
    val lastUsed: String? = null,
)

// MARK: - The week

/**
 * One calendar week of Bulava's work, as the Mac's `WeekSnapshot` writes it, key for key. Every word
 * is the Mac's; the phone's widgets lay it out and never format a number of their own.
 */
@Serializable
data class Week(
    val v: Int = 1,
    /** When the Mac computed it, ms since 1970. The newest one wins. */
    val generatedMs: Long = 0,
    /** "2026-W41". */
    val week: String = "",
    /** "5–11 жовт.". */
    val period: String = "",
    /** Monday first. */
    val days: List<String> = emptyList(),
    /** Which day is today; later days are still ahead. */
    val today: Int = 0,
    /** Statistics switched off on the Mac. */
    val off: Boolean = false,
    val words: WeekWords = WeekWords(),
    val autonomy: AutonomyFace = AutonomyFace(),
    val outcomes: OutcomesFace = OutcomesFace(),
    val receipt: ReceiptFace = ReceiptFace(),
    val rhythm: RhythmFace = RhythmFace(),
    val volume: VolumeFace = VolumeFace(),
    val limits: LimitsFace = LimitsFace(),
    val now: NowFace = NowFace(),
)

@Serializable
data class WeekWords(
    val off: String = "",
    val offHint: String = "",
    val turnOn: String = "",
    val appClosed: String = "",
    val macAway: String = "",
    val week: String = "",
    val now: String = "",
)

@Serializable
data class WeekLine(val strong: String? = null, val text: String = "")

@Serializable
data class WeekKV(val label: String = "", val value: String = "")

@Serializable
data class WeekLegend(
    /** passed | debt | waiting. */
    val key: String = "",
    val text: String = "",
)

@Serializable
data class AutonomyFace(
    val title: String = "",
    val hero: String = "",
    val unit: String = "",
    val lines: List<WeekLine> = emptyList(),
    /** Agent minutes per day; null for a day still ahead. */
    val perDay: List<Int?> = emptyList(),
    val facts: List<WeekKV> = emptyList(),
    val empty: String? = null,
    val spoken: String = "",
)

@Serializable
data class OutcomesFace(
    val title: String = "",
    val hero: String = "",
    val unit: String = "",
    val legend: List<WeekLegend> = emptyList(),
    /** Per day [passed, debt, waiting]; null for a day still ahead. */
    val perDay: List<List<Int>?> = emptyList(),
    val lines: List<WeekLine> = emptyList(),
    val facts: List<WeekKV> = emptyList(),
    val empty: String? = null,
    val spoken: String = "",
)

@Serializable
data class ReceiptFace(
    val title: String = "",
    val longTitle: String = "",
    val caption: String = "",
    val hero: String = "",
    val rows: List<WeekKV> = emptyList(),
    val total: WeekKV = WeekKV(),
    val note: String = "",
    val tokens: String = "",
    val perDay: List<Double?> = emptyList(),
    val footer: String = "",
    val spoken: String = "",
)

@Serializable
data class RhythmFace(
    val title: String = "",
    val longTitle: String = "",
    /** Agent minutes in each hour, [day][hour]; null for a day still ahead. */
    val heat: List<List<Int>?> = emptyList(),
    val peakLabel: String = "",
    val peak: String = "",
    val activeLabel: String = "",
    val active: String = "",
    val activeOf: String = "",
    val line: String = "",
    val spoken: String = "",
)

@Serializable
data class VolumeFace(
    val title: String = "",
    val longTitle: String = "",
    val added: String = "",
    val removed: String = "",
    val line: String = "",
    val detail: String = "",
    /** Per day [added, removed]; null for a day still ahead. */
    val perDay: List<List<Int>?> = emptyList(),
    val spoken: String = "",
)

@Serializable
data class LimitsFace(
    val title: String = "",
    val meters: List<WeekMeter> = emptyList(),
    val line: String = "",
    val empty: String? = null,
    val spoken: String = "",
)

@Serializable
data class WeekMeter(
    val engine: String = "",
    val label: String = "",
    val weekly: Boolean = false,
    val used: Int = 0,
    val usedText: String = "",
    val elapsed: Int? = null,
    val pace: String? = null,
    /** ahead | even | behind. */
    val paceKey: String? = null,
    /** ok | warn | bad. */
    val severity: String = "ok",
    val resets: String? = null,
)

@Serializable
data class NowFace(
    val title: String = "",
    val longTitle: String = "",
    val count: String = "",
    val unit: String = "",
    val runs: List<WeekRun> = emptyList(),
    val waiting: String? = null,
    val empty: String = "",
    val spoken: String = "",
)

@Serializable
data class WeekRun(
    val name: String = "",
    val time: String = "",
    val waiting: Boolean = false,
    val sinceMs: Long? = null,
)
