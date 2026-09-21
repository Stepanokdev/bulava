import XCTest
@testable import Bulava

/// Ukrainian dictation came back as English. These pin down both halves of why.
nonisolated final class DictationSpeaksHisLanguageTests: XCTestCase {

    // MARK: - The language it decodes in

    /// The bug: dictation borrowed the INTERFACE language, and when that was "System" it fell
    /// through to `Locale.current` — `en_US` on this Mac. Ukrainian speech went to the English
    /// recogniser, which does not fail; it returns confident English nonsense.
    func testDictationLanguageIsNeverGuessedFromTheMachine() {
        XCTAssertEqual(DictationLanguage.uk.code(interface: .en), "uk",
                       "what he speaks is his choice, not the interface's")
        XCTAssertEqual(DictationLanguage.uk.code(interface: .system), "uk")
        XCTAssertEqual(DictationLanguage.ru.code(interface: .uk), "ru")
    }

    func testFollowingTheAppUsesTheAppsOwnLanguage() {
        XCTAssertEqual(DictationLanguage.interface.code(interface: .uk), "uk")
        XCTAssertEqual(DictationLanguage.interface.code(interface: .ru), "ru")
        XCTAssertEqual(DictationLanguage.interface.code(interface: .en), "en")
        // "System" is the one case with nothing to follow, and English is the honest default
        // there — but it is reached by a stated rule, not by reading the machine's locale.
        XCTAssertEqual(DictationLanguage.interface.code(interface: .system), "en")
    }

    func testTheChoiceSurvivesAPersistRoundTrip() throws {
        var settings = AppSettings.fallback
        settings.dictationLanguage = .uk
        let back = try JSONDecoder().decode(AppSettings.self,
                                            from: try JSONEncoder().encode(settings))
        XCTAssertEqual(back.dictationLanguage, .uk)
    }

    func testSettingsFromBeforeThisExistedOpenAsFollowingTheApp() throws {
        let json = #"{"stateDirPath":"/tmp","pollSeconds":4,"interfaceLanguage":"uk"}"#
        let settings = try JSONDecoder().decode(AppSettings.self, from: Data(json.utf8))
        XCTAssertEqual(settings.dictationLanguage, .interface)
        XCTAssertEqual(settings.dictationLanguage.code(interface: settings.interfaceLanguage), "uk")
    }

    // MARK: - Which model reads the audio

    /// The other half, and no decoding option can fix it: `distil-whisper` and every `.en`
    /// variant are English-only checkpoints. Handing one a `language: "uk"` option is ignored,
    /// and out comes fluent English.
    func testEnglishOnlyModelsAreRecognisedAsSuch() {
        for english in ["distil-whisper_distil-large-v3",
                        "distil-whisper_distil-large-v3_turbo_600MB",
                        "openai_whisper-small.en",
                        "openai_whisper-small.en_217MB",
                        "openai_whisper-tiny.en",
                        "openai_whisper-medium.en"] {
            XCTAssertFalse(WhisperModels.speaksAnyLanguage(english), english)
        }
        for multilingual in ["openai_whisper-large-v3",
                             "openai_whisper-large-v3-v20240930_626MB",
                             "openai_whisper-small",
                             "openai_whisper-medium"] {
            XCTAssertTrue(WhisperModels.speaksAnyLanguage(multilingual), multilingual)
        }
    }

    private func fixture(_ variants: [String], complete: Bool = true) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("whisper-models-\(UUID().uuidString)")
        for variant in variants {
            let parts = complete
                ? ["AudioEncoder.mlmodelc", "MelSpectrogram.mlmodelc", "TextDecoder.mlmodelc"]
                : ["AudioEncoder.mlmodelc"]
            for part in parts {
                let weights = root.appendingPathComponent(variant)
                    .appendingPathComponent(part).appendingPathComponent("weights")
                try FileManager.default.createDirectory(at: weights, withIntermediateDirectories: true)
                try Data().write(to: weights.appendingPathComponent("weight.bin"))
            }
        }
        return root
    }

    func testAModelAlreadyOnDiskIsUsedRatherThanDownloadingAnother() throws {
        let root = try fixture(["openai_whisper-large-v3"])
        defer { try? FileManager.default.removeItem(at: root) }

        let choice = WhisperModels.choose(language: "uk", root: root)
        XCTAssertEqual(choice.variant, "openai_whisper-large-v3")
        XCTAssertFalse(choice.needsDownload,
                       "downloading a gigabyte in the middle of one dictated sentence is the ‘it thinks for ages’ bug")
    }

    func testTheFasterModelWinsWhenBothArePresent() throws {
        let root = try fixture(["openai_whisper-large-v3",
                                "openai_whisper-large-v3-v20240930_626MB"])
        defer { try? FileManager.default.removeItem(at: root) }
        XCTAssertEqual(WhisperModels.choose(language: "uk", root: root).variant,
                       "openai_whisper-large-v3-v20240930_626MB")
    }

    /// The heart of it: an English-only model on disk must NOT be used for Ukrainian, even though
    /// using it would be faster and need no download.
    func testAnEnglishOnlyModelIsNeverUsedForUkrainian() throws {
        let root = try fixture(["distil-whisper_distil-large-v3_turbo_600MB",
                                "openai_whisper-small.en"])
        defer { try? FileManager.default.removeItem(at: root) }

        let choice = WhisperModels.choose(language: "uk", root: root)
        XCTAssertTrue(choice.needsDownload,
                      "better to fetch a model that speaks Ukrainian than to answer in English")
        XCTAssertTrue(WhisperModels.speaksAnyLanguage(choice.variant))
    }

    func testAnEnglishOnlyModelIsFineForEnglish() throws {
        let root = try fixture(["openai_whisper-small.en"])
        defer { try? FileManager.default.removeItem(at: root) }
        let choice = WhisperModels.choose(language: "en", root: root)
        XCTAssertEqual(choice.variant, "openai_whisper-small.en")
        XCTAssertFalse(choice.needsDownload)
    }

    /// A download that died half-way leaves the folder there and the model unloadable, and the
    /// failure surfaces as "could not make out the dictation" with no hint that a file is missing.
    func testAHalfDownloadedModelDoesNotCount() throws {
        let root = try fixture(["openai_whisper-large-v3"], complete: false)
        defer { try? FileManager.default.removeItem(at: root) }
        XCTAssertTrue(WhisperModels.installed(root: root).isEmpty)
        XCTAssertTrue(WhisperModels.choose(language: "uk", root: root).needsDownload)
    }

    func testNothingInstalledNamesAMultilingualModelToFetch() throws {
        let root = try fixture([])
        defer { try? FileManager.default.removeItem(at: root) }
        let choice = WhisperModels.choose(language: "uk", root: root)
        XCTAssertTrue(choice.needsDownload)
        XCTAssertEqual(choice.variant, WhisperModels.toInstall)
        XCTAssertTrue(WhisperModels.speaksAnyLanguage(choice.variant))
    }

    /// Every model the app is willing to ask for by name has to be one that speaks other
    /// languages, and has to be a full folder name — a short name like `large-v3_turbo` matches
    /// two entries in the catalogue and cannot be resolved.
    func testThePreferenceListIsMultilingualAndUnambiguous() {
        for variant in WhisperModels.preferred + [WhisperModels.toInstall] {
            XCTAssertTrue(WhisperModels.speaksAnyLanguage(variant), variant)
            XCTAssertTrue(variant.hasPrefix("openai_whisper-"),
                          "\(variant) is not a full catalogue folder name")
        }
    }

    // MARK: - Saying what it is doing

    func testTheWaitIsNamedRatherThanSilent() {
        XCTAssertTrue(VoiceRecorder.Phase.transcribing.isTranscribing)
        XCTAssertNil(VoiceRecorder.Phase.transcribing.note)
        XCTAssertEqual(VoiceRecorder.Phase.transcribing(note: "Готую модель").note, "Готую модель")
        XCTAssertFalse(VoiceRecorder.Phase.recording.isTranscribing)
        XCTAssertFalse(VoiceRecorder.Phase.idle.isTranscribing)
    }
}
