import Foundation

/// Which Whisper model dictation uses, and whether it is already on this machine.
///
/// Three separate things were wrong with the old "just ask for `large-v3_turbo`":
///
///  * That name is ambiguous. WhisperKit resolves a model by globbing `*<name>/*` against the
///    catalogue, and `large-v3_turbo` matches both `openai_whisper-large-v3_turbo` and
///    `openai_whisper-large-v3_turbo_954MB`, so the lookup has to disambiguate or give up. Full
///    folder names are used here, and they match exactly one thing each.
///  * It ignored what was already downloaded. A model sitting on disk answers in seconds; asking
///    for a different one means a near-gigabyte download in the middle of dictating one sentence,
///    which is the "it thinks for ages" part of this being broken.
///  * Nothing kept English-only models out. `distil-whisper-*` and every `*.en` variant are
///    English-only, and a multilingual `language:` option is simply ignored by them: Ukrainian
///    speech comes back as fluent English. That is the other half of the bug, and no decoding
///    option can undo it — it has to be a model that speaks the language at all.
nonisolated enum WhisperModels {

    /// Where WhisperKit keeps its models. Matches its own default download base.
    static var installRoot: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Documents/huggingface/models/argmaxinc/whisperkit-coreml")
    }

    /// Multilingual variants, best first for dictation.
    ///
    /// `large-v3-v20240930` IS whisper-large-v3-turbo — four decoder layers instead of thirty-two,
    /// so several times faster at the same accuracy, and it is what WhisperKit itself recommends
    /// by default on Apple silicon. `large-v3` is last: correct but slow, and it is the one that
    /// happened to be on this machine already.
    static let preferred = [
        "openai_whisper-large-v3-v20240930_626MB",
        "openai_whisper-large-v3-v20240930_547MB",
        "openai_whisper-large-v3-v20240930",
        "openai_whisper-large-v3_947MB",
        "openai_whisper-large-v3",
        "openai_whisper-large-v2_949MB",
        "openai_whisper-medium",
        "openai_whisper-small",
    ]

    /// The one to download when nothing is installed: multilingual, and the smallest of the fast
    /// ones so a first dictation is not a gigabyte of waiting.
    static let toInstall = "openai_whisper-large-v3-v20240930_626MB"

    /// English-only models produce confident English from any language, so they are never used
    /// for anything but English.
    ///
    /// `.en` is OpenAI's own suffix for the English-only checkpoints; every `distil-whisper`
    /// release is English-only.
    static func speaksAnyLanguage(_ variant: String) -> Bool {
        let name = variant.lowercased()
        if name.hasPrefix("distil") || name.contains("distil-whisper") { return false }
        // `openai_whisper-small.en_217MB` — the marker is `.en`, wherever the size suffix sits.
        return !name.contains(".en")
    }

    /// A variant is usable only if all three model bundles are actually there. A download that
    /// died half-way leaves the folder present and the model unloadable, and the failure surfaces
    /// as "could not make out the dictation" with no hint that a file is missing.
    static func isComplete(_ folder: URL) -> Bool {
        let fm = FileManager.default
        for part in ["AudioEncoder.mlmodelc", "MelSpectrogram.mlmodelc", "TextDecoder.mlmodelc"] {
            let weights = folder.appendingPathComponent(part)
                .appendingPathComponent("weights/weight.bin")
            guard fm.fileExists(atPath: weights.path) else { return false }
        }
        return true
    }

    /// Every complete variant on disk, in no particular order.
    static func installed(root: URL? = nil) -> [String] {
        let base = root ?? installRoot
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: base.path) else {
            return []
        }
        return names.filter { name in
            !name.hasPrefix(".") && isComplete(base.appendingPathComponent(name))
        }
    }

    /// What to load for this language, and where it is.
    ///
    /// `folder` non-nil means nothing is downloaded — the answer comes back in seconds. Nil means
    /// the named variant has to be fetched first, and the caller has to SAY so rather than appear
    /// to hang.
    struct Choice: Equatable, Sendable {
        var variant: String
        var folder: URL?
        var needsDownload: Bool { folder == nil }
    }

    static func choose(language: String, root: URL? = nil) -> Choice {
        let base = root ?? installRoot
        let english = language.lowercased().hasPrefix("en")
        let onDisk = Set(installed(root: base))

        let usable: (String) -> Bool = { english || speaksAnyLanguage($0) }

        // Preference order first, so a better model that is present wins over a worse one.
        for variant in preferred where onDisk.contains(variant) && usable(variant) {
            return Choice(variant: variant, folder: base.appendingPathComponent(variant))
        }
        // Then anything else that is present and can speak the language at all.
        if let other = onDisk.filter(usable).sorted().first {
            return Choice(variant: other, folder: base.appendingPathComponent(other))
        }
        return Choice(variant: toInstall, folder: nil)
    }
}
