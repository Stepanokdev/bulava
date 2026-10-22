import Foundation
import Darwin

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

    /// The download base handed to WhisperKit: models land in `models/argmaxinc/whisperkit-coreml`
    /// under it, the tokenizer in `models/openai/…`.
    ///
    /// Not WhisperKit's default, `~/Documents/huggingface`. On a Mac with iCloud "Desktop &
    /// Documents" that folder is synced, macOS offloads the 600 MB of weights to iCloud, and every
    /// later load waited for them to come back down — or, with the file only a placeholder, decided
    /// the model was missing and downloaded it again. That was "it thinks for ages and keeps
    /// fetching the model" on the Mac, and the phone's endless "taking too long" (22.10).
    /// Application Support is neither synced nor purged.
    static var downloadBase: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Bulava/whisper", isDirectory: true)
    }

    static var installRoot: URL {
        downloadBase.appendingPathComponent("models/argmaxinc/whisperkit-coreml", isDirectory: true)
    }

    /// Where models used to go, and where one may still be waiting to be moved.
    static var legacyBase: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Documents/huggingface")
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
    ///
    /// "There" means its bytes are on this disk. A file iCloud has offloaded still exists — it is a
    /// placeholder flagged dataless — and loading it starts a download of hundreds of megabytes in
    /// the middle of a sentence; counted as present, that is exactly the wait it was meant to avoid.
    static func isComplete(_ folder: URL) -> Bool {
        for part in ["AudioEncoder.mlmodelc", "MelSpectrogram.mlmodelc", "TextDecoder.mlmodelc"] {
            let weights = folder.appendingPathComponent(part)
                .appendingPathComponent("weights/weight.bin")
            guard isLocal(weights) else { return false }
        }
        return true
    }

    /// A regular file with bytes, and those bytes here rather than in iCloud.
    static func isLocal(_ file: URL) -> Bool {
        var info = stat()
        guard lstat(file.path, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG, info.st_size > 0 else {
            return false
        }
        return info.st_flags & UInt32(SF_DATALESS) == 0
    }

    /// Moves a model from the old place in `~/Documents` to `downloadBase`, once, so a model that
    /// is already on this Mac is not downloaded a second time. Only one whose bytes are all local:
    /// moving an offloaded one would only download it in another way. The tokenizer goes with it.
    /// Returns whether anything was moved.
    @discardableResult
    static func adoptLegacy(legacy: URL? = nil, base: URL? = nil) -> Bool {
        let fm = FileManager.default
        let oldBase = legacy ?? legacyBase, newBase = base ?? downloadBase
        let oldRoot = oldBase.appendingPathComponent("models/argmaxinc/whisperkit-coreml")
        let newRoot = newBase.appendingPathComponent("models/argmaxinc/whisperkit-coreml")
        guard installed(root: newRoot).isEmpty else { return false }
        let candidates = installed(root: oldRoot)
        guard let variant = preferred.first(where: candidates.contains) ?? candidates.sorted().first else {
            return false
        }
        do {
            try fm.createDirectory(at: newRoot, withIntermediateDirectories: true)
            try fm.moveItem(at: oldRoot.appendingPathComponent(variant), to: newRoot.appendingPathComponent(variant))
        } catch { return false }
        let oldTokenizers = oldBase.appendingPathComponent("models/openai")
        let newTokenizers = newBase.appendingPathComponent("models/openai")
        if let names = try? fm.contentsOfDirectory(atPath: oldTokenizers.path) {
            try? fm.createDirectory(at: newTokenizers, withIntermediateDirectories: true)
            for name in names where !name.hasPrefix(".") {
                let from = oldTokenizers.appendingPathComponent(name)
                let files = (try? fm.contentsOfDirectory(at: from, includingPropertiesForKeys: nil)) ?? []
                // A tokenizer is a few small files: worth taking only if all of them are here.
                guard !files.isEmpty, files.allSatisfy({ $0.hasDirectoryPath || isLocal($0) }) else { continue }
                try? fm.moveItem(at: from, to: newTokenizers.appendingPathComponent(name))
            }
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
