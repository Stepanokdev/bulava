import Foundation

/// Dictation from the phone, written down by the Mac's own Whisper.
///
/// The phone records and the Mac listens. A phone's own dictation answers in whatever language its
/// keyboard happens to be set to, and that is the failure Whisper was brought in to end on the Mac:
/// a wrong guess does not fail, it returns fluent nonsense. So the recording comes here, over the
/// same chunked upload a photo takes, and is decoded with the model and the language the Mac's
/// composer uses — his own dictation setting, never a locale.
///
/// What comes back is words for the phone's composer, never a message: the phone puts them in the
/// field of the chat it was recorded in and he sends them himself, or does not.
///
/// A request is named by the phone (`requestID`), and the name is what makes it safe to repeat.
/// A phone that lost the answer — the Wi‑Fi dropped, it gave up waiting while the model loaded —
/// asks again with the same name and gets the same words, from memory, without the recording being
/// heard twice; one that asks while the first is still being decoded waits for that one. Only words
/// are remembered: "the model is still on its way" or "nothing could be made out" is about this
/// moment, and asking again is how he finds out whether it changed.
@MainActor
final class LinkTranscriptions {

    nonisolated enum Outcome: Equatable, Sendable {
        case text(String)
        /// No Whisper to decode with — the reason, in the Mac's words.
        case unavailable(String)
        /// Whisper ran and made out nothing.
        case notTranscribed
    }

    /// Hears one recording in one language. `whisper` in the app; tests hand in their own.
    typealias Engine = @Sendable (_ audio: URL, _ language: String) async -> Outcome

    private var answered: [String: (text: String, at: Date)] = [:]
    private var running: [String: Task<Outcome, Never>] = [:]

    /// How long an answer is kept for a phone that asks again, and how many. A phone asks again
    /// within seconds or minutes; half an hour covers a Mac that slept in between.
    var keep: TimeInterval = 30 * 60
    var limit = 64

    /// Whether `requestID` is answered or being decoded right now: then no recording is needed.
    func knows(_ requestID: String) -> Bool {
        prune()
        return answered[requestID] != nil || running[requestID] != nil
    }

    /// The words of `requestID`.
    ///
    /// The first call that brings `audio` has it decoded, and the file is deleted once it has been
    /// heard, whatever came of it: it was never a message's attachment, and the phone keeps its own
    /// copy until the words are in its composer. A call for a request already answered, or being
    /// answered, gets that answer, and a recording it brought anyway is deleted unheard.
    ///
    /// Nil when the request was never heard of and there is nothing to hear — the phone sends the
    /// recording again.
    func transcribe(_ requestID: String, audio: URL?, language: String, engine: @escaping Engine) async -> Outcome? {
        prune()
        if let known = answered[requestID] {
            Self.delete(audio)
            return .text(known.text)
        }
        if let task = running[requestID] {
            Self.delete(audio)
            return await task.value
        }
        guard let audio else { return nil }
        let task = Task.detached(priority: .userInitiated) { await engine(audio, language) }
        running[requestID] = task
        let outcome = await task.value
        running[requestID] = nil
        Self.delete(audio)
        if case .text(let text) = outcome {
            answered[requestID] = (text, Date())
            prune()
        }
        return outcome
    }

    private func prune() {
        let now = Date()
        answered = answered.filter { now.timeIntervalSince($0.value.at) < keep }
        if answered.count > limit {
            for (id, _) in answered.sorted(by: { $0.value.at < $1.value.at }).prefix(answered.count - limit) {
                answered[id] = nil
            }
        }
    }

    nonisolated private static func delete(_ url: URL?) {
        guard let url else { return }
        try? FileManager.default.removeItem(at: url)
    }

    // MARK: Whisper

    /// The Mac composer's own engine: `WhisperTranscriber`, with a model that is already on disk.
    ///
    /// Apple's recogniser — the composer's fallback while no model is here — is not used for a
    /// phone. It asks for Speech Recognition permission in a dialog on the Mac, and a dialog nobody
    /// is sitting in front of answers nothing; the phone would wait for a prompt in another room.
    /// Without a model the phone is told so, and the model is fetched now, once, so asking again in
    /// a few minutes works. He asked for this from the phone; that is what the download is for.
    nonisolated static let whisper: Engine = { audio, language in
        #if canImport(WhisperKit)
        guard await WhisperTranscriber.shared.isReadyOffline(language: language) else {
            await LinkTranscriptions.fetchModel(language: language)
            return .unavailable(String(localized: "Your Mac is fetching its dictation model, once only. Try again in a few minutes."))
        }
        guard let text = await WhisperTranscriber.shared.transcribe(url: audio, language: language) else {
            return .notTranscribed
        }
        return .text(text)
        #else
        return .unavailable(String(localized: "This build of Bulava has no speech recognition."))
        #endif
    }

    #if canImport(WhisperKit)
    /// One download at a time, started and not waited for: the phone hears "try again in a few
    /// minutes" now rather than after six hundred megabytes.
    private static var fetching: Task<Void, Never>?

    private static func fetchModel(language: String) {
        guard fetching == nil else { return }
        fetching = Task {
            _ = await WhisperTranscriber.shared.install(language: language)
            fetching = nil
        }
    }
    #endif
}

/// The words of a recording, for the phone's composer.
nonisolated struct TranscriptDTO: Codable, Equatable, Sendable {
    var requestID: String
    /// The chat it was recorded in, as the phone named it — handed back so a phone that changed
    /// screens meanwhile still puts the words where they were spoken.
    var chatID: String?
    var text: String
}
