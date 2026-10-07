package com.stepanok.bulava.state

import com.stepanok.bulava.link.CallResult
import com.stepanok.bulava.link.ErrorCodes
import com.stepanok.bulava.link.LinkJson
import com.stepanok.bulava.link.Transcript
import com.stepanok.bulava.platform.MicPermission
import com.stepanok.bulava.platform.VoiceRecorder
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch
import kotlinx.serialization.Serializable
import kotlinx.serialization.builtins.ListSerializer
import kotlinx.serialization.builtins.serializer
import kotlin.uuid.ExperimentalUuidApi
import kotlin.uuid.Uuid

/**
 * A voice note on its way to words: recorded here, heard by the Mac's Whisper, put into the
 * composer of the chat it was recorded in.
 *
 * Kept on the phone — the record here and the file it names — until its words are in that
 * composer or he throws it away. A Mac that is asleep, out of reach, still fetching its model or
 * simply slow does not lose what he said: the note stays, says why, and offers to try again.
 */
@Serializable
data class VoiceNote(
    /** Chosen here, once, and kept across every attempt: the Mac hears each request once. */
    val requestID: String,
    val productID: String,
    val chatID: String,
    val path: String,
    val durationMs: Long,
    val atMs: Long,
    /** The Mac's name for the uploaded file, once it has it. Spent when the Mac hears it. */
    val ref: String? = null,
    val stage: Stage = Stage.Sending,
    /** Why it stopped: an [ErrorCodes] value, or one of [Dictation]'s own. */
    val failure: String? = null,
    /** The Mac's own words for it, when it said any. */
    val message: String? = null,
) {
    enum class Stage { Sending, Transcribing, Failed }

    /** Whether trying again can come to anything: not for a file that is gone or too big to send. */
    val retryable: Boolean get() = stage == Stage.Failed && failure != Dictation.GONE && failure != ErrorCodes.TOO_LARGE
}

/** The microphone while it is on: which chat it is for and since when. */
data class Recording(val productID: String, val chatID: String, val path: String, val startedAtMs: Long)

/**
 * Dictation the Mac transcribes. The phone records an M4A, sends it over the link's upload, and
 * asks `audio.transcribe` for its words; nothing here sends a message. The words land in the draft
 * of the chat the note was recorded in, once, however many times the request went out.
 */
@OptIn(ExperimentalUuidApi::class)
class Dictation internal constructor(
    private val controller: AppController,
    private val scope: CoroutineScope,
    private val now: () -> Long,
) {
    private val platform = controller.platform
    val recorder: VoiceRecorder? get() = platform.voice

    private val _recording = MutableStateFlow<Recording?>(null)
    val recording: StateFlow<Recording?> = _recording

    private val _notes = MutableStateFlow(load())
    /** Every note not yet in a composer — sending, being transcribed, or stopped with a reason. */
    val notes: StateFlow<List<VoiceNote>> = _notes

    /** Requests whose words are already in a composer. A late answer to one of them is dropped. */
    private var inserted: List<String> =
        platform.prefs.get(INSERTED)?.let { runCatching { LinkJson.decodeFromString(ListSerializer(String.serializer()), it) }.getOrNull() }
            ?: emptyList()

    /** What stops a forgotten recording ([MAX_RECORDING_MS]). */
    private var cap: Job? = null

    /** Requests with an attempt on the wire right now; a second press of "try again" waits for it. */
    private val inFlight = mutableSetOf<String>()

    /** Whether the Mac this phone talks to can hear recordings. While offline, what it said last. */
    val macCanTranscribe: Boolean get() = controller.can(CAPABILITY)

    init {
        // A note that was being sent when the app was closed is said to have stopped, not left
        // spinning: the person decides whether to send it again.
        if (_notes.value.any { it.stage != VoiceNote.Stage.Failed }) {
            _notes.update { list -> list.map { if (it.stage == VoiceNote.Stage.Failed) it else it.copy(stage = VoiceNote.Stage.Failed, failure = ErrorCodes.OFFLINE) } }
            persist()
        }
    }

    // MARK: The microphone

    enum class Start { Started, NeedsPermission, Denied, Failed, Busy, Unavailable }

    /**
     * Turns the microphone on for [chatID]. A permission not yet asked for is asked for here, and
     * recording starts once it is given; [onAsked] hears how that went.
     */
    fun start(productID: String, chatID: String, onAsked: (Start) -> Unit = {}): Start {
        val voice = recorder ?: return Start.Unavailable
        if (_recording.value != null) return Start.Busy
        return when (voice.permission()) {
            MicPermission.Denied -> Start.Denied
            MicPermission.NotAsked -> {
                voice.requestPermission { allowed -> onAsked(if (allowed) begin(voice, productID, chatID) else Start.Denied) }
                Start.NeedsPermission
            }
            MicPermission.Granted -> begin(voice, productID, chatID)
        }
    }

    private fun begin(voice: VoiceRecorder, productID: String, chatID: String): Start {
        if (_recording.value != null) return Start.Busy
        val path = voice.newRecordingPath()
        if (!voice.start(path)) {
            voice.delete(path)
            return Start.Failed
        }
        val recording = Recording(productID, chatID, path, now())
        _recording.value = recording
        cap?.cancel()
        cap = scope.launch {
            delay(MAX_RECORDING_MS)
            if (_recording.value == recording) finish()
        }
        return Start.Started
    }

    /** How loud it is now, 0…1, while recording. */
    fun level(): Float = if (_recording.value != null) recorder?.level() ?: 0f else 0f

    /** Stops, keeps the note, and sends it to the Mac. */
    fun finish() {
        val voice = recorder ?: return
        val r = _recording.value ?: return
        _recording.value = null
        cap?.cancel()
        val duration = now() - r.startedAtMs
        if (!voice.stop() || !voice.exists(r.path) || duration < MIN_MS) {
            // Nothing worth sending: a tap that was not meant as dictation, a recorder that wrote nothing.
            voice.delete(r.path)
            return
        }
        val note = VoiceNote(
            requestID = Uuid.random().toString().uppercase(), productID = r.productID, chatID = r.chatID,
            path = r.path, durationMs = duration, atMs = now(),
        )
        _notes.update { it + note }
        persist()
        scope.launch { process(note.requestID) }
    }

    /** Stops and throws the recording away. */
    fun cancelRecording() {
        val voice = recorder ?: return
        val r = _recording.value ?: return
        _recording.value = null
        cap?.cancel()
        voice.cancel()
        voice.delete(r.path)
    }

    // MARK: Notes

    fun retry(requestID: String) {
        val note = note(requestID) ?: return
        if (!note.retryable) return
        replace(note.copy(stage = if (note.ref == null) VoiceNote.Stage.Sending else VoiceNote.Stage.Transcribing, failure = null, message = null))
        scope.launch { process(requestID) }
    }

    /** Throws the note away, file and all. Whatever the Mac answers later about it goes nowhere. */
    fun discard(requestID: String) {
        val note = note(requestID) ?: return
        recorder?.delete(note.path)
        _notes.update { list -> list.filter { it.requestID != requestID } }
        remember(requestID)
        persist()
    }

    /** One attempt: the recording up, if the Mac does not have it yet, then its words back. */
    internal suspend fun process(requestID: String) {
        if (!inFlight.add(requestID)) return
        try {
            attempt(requestID)
        } finally {
            inFlight.remove(requestID)
        }
    }

    private suspend fun attempt(requestID: String) {
        var note = note(requestID) ?: return
        if (!controller.link.isConnected) return fail(note, ErrorCodes.OFFLINE)
        if (!macCanTranscribe) return fail(note, MAC_TOO_OLD)
        var uploadedNow = false
        if (note.ref == null) {
            note = upload(note) ?: return
            uploadedNow = true
        }
        var result = transcribe(note)
        // The Mac no longer has the file — it was restarted, or it heard an earlier copy and that
        // attempt failed. Once more, with the recording sent again; never more than once.
        if (!uploadedNow && result is CallResult.Failed && result.error.code == ErrorCodes.NOT_FOUND) {
            note = upload(note.copy(ref = null)) ?: return
            result = transcribe(note)
        }
        when (result) {
            is CallResult.Ok -> {
                val words = result.result?.let { runCatching { LinkJson.decodeFromJsonElement(Transcript.serializer(), it) }.getOrNull() }
                insert(note, words?.text.orEmpty())
            }
            is CallResult.Failed -> {
                // The Mac deletes a recording once it has heard it, whatever came of it; only a
                // request that never got an answer may still be in its hands.
                val spent = result.error.code !in setOf(ErrorCodes.OFFLINE, ErrorCodes.TIMEOUT)
                val current = note(requestID) ?: return
                fail(if (spent) current.copy(ref = null) else current, result.error.code, result.error.message)
            }
        }
    }

    private suspend fun upload(note: VoiceNote): VoiceNote? {
        replace(note.copy(stage = VoiceNote.Stage.Sending))
        val bytes = recorder?.read(note.path)
        if (bytes == null || bytes.isEmpty()) { fail(note, GONE); return null }
        if (bytes.size > MAX_BYTES) { fail(note, ErrorCodes.TOO_LARGE); return null }
        val (ref, error) = controller.uploadBytes(fileName(note), "audio", bytes)
        if (ref?.ref == null) {
            fail(note, error?.code ?: ErrorCodes.OFFLINE, error?.message)
            return null
        }
        if (note(note.requestID) == null) return null // discarded while it went up
        val sent = note.copy(ref = ref.ref, stage = VoiceNote.Stage.Transcribing)
        replace(sent)
        return sent
    }

    private suspend fun transcribe(note: VoiceNote): CallResult {
        replace(note.copy(stage = VoiceNote.Stage.Transcribing))
        return controller.link.call("audio.transcribe", AppController.args(
            "requestID" to note.requestID, "ref" to note.ref, "chatID" to note.chatID,
        ), TRANSCRIBE_TIMEOUT)
    }

    /**
     * The words go into the draft of the chat they were spoken in, after whatever is written there,
     * and the note and its file go. Once: a request already inserted, or thrown away meanwhile,
     * puts nothing anywhere.
     */
    private fun insert(note: VoiceNote, text: String) {
        if (note.requestID in inserted || note(note.requestID) == null) return
        val words = text.trim()
        if (words.isEmpty()) return fail(note, ErrorCodes.NOT_TRANSCRIBED)
        val draft = controller.draft(note.chatID)
        controller.setDraft(note.chatID, draft.copy(text = appended(draft.text, words)))
        recorder?.delete(note.path)
        _notes.update { list -> list.filter { it.requestID != note.requestID } }
        remember(note.requestID)
        persist()
    }

    private fun fail(note: VoiceNote, code: String, message: String? = null) {
        if (note(note.requestID) == null) return
        replace(note.copy(stage = VoiceNote.Stage.Failed, failure = code, message = message?.ifBlank { null }))
    }

    private fun note(requestID: String) = _notes.value.firstOrNull { it.requestID == requestID }

    private fun replace(note: VoiceNote) {
        _notes.update { list -> list.map { if (it.requestID == note.requestID) note else it } }
        persist()
    }

    private fun remember(requestID: String) {
        inserted = (inserted + requestID).takeLast(64)
        platform.prefs.put(INSERTED, LinkJson.encodeToString(ListSerializer(String.serializer()), inserted))
    }

    private fun persist() =
        platform.prefs.put(NOTES, LinkJson.encodeToString(ListSerializer(VoiceNote.serializer()), _notes.value))

    private fun load(): List<VoiceNote> =
        platform.prefs.get(NOTES)?.let { runCatching { LinkJson.decodeFromString(ListSerializer(VoiceNote.serializer()), it) }.getOrNull() }
            ?: emptyList()

    /** Forgets every note, files and all — the phone was unpaired. */
    internal fun clear() {
        cancelRecording()
        for (n in _notes.value) recorder?.delete(n.path)
        _notes.value = emptyList()
        inserted = emptyList()
        platform.prefs.remove(NOTES)
        platform.prefs.remove(INSERTED)
    }

    companion object {
        const val CAPABILITY = "audio.transcribe"
        /** The file is no longer on the phone. Only throwing the note away is left. */
        const val GONE = "gone"
        /** The Mac does not offer transcription: Bulava there is older than this. */
        const val MAC_TOO_OLD = "mac_too_old"
        /** What the link takes from a phone. */
        const val MAX_BYTES = 50L * 1024 * 1024
        /** A tap that let go at once is not a recording. */
        const val MIN_MS = 600L
        /**
         * How long the phone waits for the words. The Mac's first transcription after a restart
         * loads the model, which takes a while; past this the note offers to try again, and trying
         * again joins the transcription already under way on the Mac rather than starting another.
         */
        const val TRANSCRIBE_TIMEOUT = 150_000L
        /**
         * A recording that has run this long was forgotten rather than meant: it stops by itself
         * and is kept, well under what the link takes (AAC at 64 kbps is about half a megabyte a
         * minute).
         */
        const val MAX_RECORDING_MS = 30L * 60 * 1000
        private const val NOTES = "bulava.voice.notes"
        private const val INSERTED = "bulava.voice.inserted"

        /** The words after what is already written, on a line of their own, as the Mac's composer puts them. */
        fun appended(draft: String, words: String): String = when {
            draft.isBlank() -> words
            draft.endsWith("\n") -> draft + words
            else -> draft + "\n" + words
        }

        private fun fileName(note: VoiceNote) = "dictation-${note.requestID.take(8).lowercase()}.m4a"
    }
}
