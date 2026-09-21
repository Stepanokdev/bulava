#if canImport(WhisperKit)
import Foundation
import WhisperKit

/// Dictation, on this machine, in the language he actually spoke.
///
/// He asked for Whisper, and the reasons are the two failures he saw. Apple's own recogniser was
/// tried first and its answer depended on a locale the app derived rather than one he chose — on a
/// Mac whose `Locale.current` is `en_US`, Ukrainian speech went to the English recogniser and came
/// back as confident English nonsense. And the Whisper fallback asked for a model by an ambiguous
/// short name and downloaded it mid-sentence, which is where "it thinks for ages" came from.
///
/// So: a model that is already here, chosen for the language, loaded once and kept. See
/// `WhisperModels` for why the variant matters more than any decoding option.
actor WhisperTranscriber {
    static let shared = WhisperTranscriber()

    /// What it is busy with, so the composer can say so instead of showing nothing for a minute.
    nonisolated enum Stage: Equatable, Sendable {
        case idle
        /// First use: the model is being fetched. Named, because a 600MB download is not a pause.
        case downloading(String)
        /// Core ML is specialising the model for this chip. Once per model, per OS update.
        case loading(String)
        case listening
    }

    private var pipe: WhisperKit?
    private var loaded: String?

    /// True when dictation can answer without touching the network.
    static func isReadyOffline(language: String) -> Bool {
        !WhisperModels.choose(language: language).needsDownload
    }

    func transcribe(url: URL, language: String,
                    stage: (@Sendable (Stage) -> Void)? = nil) async -> String? {
        let choice = WhisperModels.choose(language: language)
        guard let pipe = await ready(choice, stage: stage) else { return nil }

        stage?(.listening)
        defer { stage?(.idle) }
        do {
            let options = DecodingOptions(
                task: .transcribe,          // never .translate: he dictates, he does not ask for English
                language: language,
                detectLanguage: false,
                skipSpecialTokens: true,
                withoutTimestamps: true)
            let results = try await pipe.transcribe(audioPath: url.path, decodeOptions: options)
            let text = results.map(\.text).joined(separator: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty ? nil : text
        } catch {
            return nil
        }
    }

    /// Fetch the model into place without transcribing anything.
    ///
    /// Separate so the download can happen when he asks for it, rather than inside the first
    /// sentence he tries to dictate.
    func install(language: String, stage: (@Sendable (Stage) -> Void)? = nil) async -> Bool {
        await ready(WhisperModels.choose(language: language), stage: stage) != nil
    }

    private func ready(_ choice: WhisperModels.Choice,
                       stage: (@Sendable (Stage) -> Void)?) async -> WhisperKit? {
        if let pipe, loaded == choice.variant { return pipe }

        stage?(choice.needsDownload ? .downloading(choice.variant) : .loading(choice.variant))
        do {
            // `modelFolder` when it is already here: that skips the catalogue lookup entirely, so
            // an ambiguous name cannot send it to the network for a model sitting on disk.
            let kit = try await WhisperKit(
                model: choice.variant,
                modelFolder: choice.folder?.path,
                verbose: false,
                logLevel: .error,
                prewarm: false,
                load: true,
                download: choice.needsDownload)
            pipe = kit
            loaded = choice.variant
            return kit
        } catch {
            stage?(.idle)
            pipe = nil
            loaded = nil
            return nil
        }
    }
}
#endif
