import Foundation
import AVFoundation
@preconcurrency import Speech
import Observation

@MainActor
@Observable
final class VoiceRecorder {
    nonisolated enum Phase: Equatable, Sendable {
        case idle
        case recording
        /// Reading the words. `note` says WHAT it is doing when that is not instant — loading a
        /// model, or fetching one the first time — because a silent minute reads as a hang.
        case transcribing(note: String?)

        static var transcribing: Phase { .transcribing(note: nil) }

        var isTranscribing: Bool {
            if case .transcribing = self { return true }
            return false
        }

        var note: String? {
            if case .transcribing(let note) = self { return note }
            return nil
        }
    }

    var phase: Phase = .idle
    var level: CGFloat = 0
    var elapsed: TimeInterval = 0

    private var recorder: AVAudioRecorder?
    private var tempURL: URL?
    private var meterTimer: Timer?
    private var startedAt: Date?

    var isRecording: Bool { phase == .recording }

    // MARK: Recording

    enum StartFailure: Equatable {
        case alreadyRecording
        case permissionDenied
        case recorderFailed(String)
    }

    func start() async -> StartFailure? {
        guard phase == .idle else { return .alreadyRecording }
        guard await requestMic() else { return .permissionDenied }

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("nightshift-voice-\(UUID().uuidString).m4a")
        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
            AVSampleRateKey: 44100,
            AVNumberOfChannelsKey: 1,
            AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue,
        ]
        do {
            let rec = try AVAudioRecorder(url: url, settings: settings)
            rec.isMeteringEnabled = true
            guard rec.record() else { return .recorderFailed("the recorder refused to start") }
            recorder = rec
            tempURL = url
            startedAt = Date()
            phase = .recording
            startMeter()
            return nil
        } catch {
            return .recorderFailed(error.localizedDescription)
        }
    }

    func stop() -> (url: URL, duration: TimeInterval)? {
        guard let recorder, let tempURL else { return nil }
        let duration = recorder.currentTime
        recorder.stop()
        stopMeter()
        self.recorder = nil
        phase = .idle
        return (tempURL, max(duration, 0.1))
    }

    func cancel() {
        recorder?.stop()
        recognitionTask?.cancel(); recognitionTask = nil
        if let tempURL { try? FileManager.default.removeItem(at: tempURL) }
        recorder = nil; tempURL = nil
        stopMeter()
        phase = .idle
    }

    private func startMeter() {
        elapsed = 0
        meterTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tickMeter() }
        }
    }

    private func tickMeter() {
        guard let recorder, let startedAt else { return }
        recorder.updateMeters()
        let power = recorder.averagePower(forChannel: 0)
        let normalized = max(0, (power + 55) / 55)
        level = CGFloat(min(1, normalized))
        elapsed = Date().timeIntervalSince(startedAt)
    }

    private func stopMeter() { meterTimer?.invalidate(); meterTimer = nil; level = 0 }

    // MARK: Transcription (on-device where available)

    private var recognitionTask: SFSpeechRecognitionTask?

    /// Dictation, in the language he chose, by Whisper when Whisper is here.
    ///
    /// Whisper goes FIRST whenever its model is already on disk. That is what he asked for, and it
    /// is also the honest order: Apple's recogniser is faster but it answers in whatever locale it
    /// was handed, and a wrong locale does not fail — it returns fluent nonsense in the wrong
    /// language, which is exactly what he kept getting. Whisper with an explicit `language` either
    /// transcribes what was said or returns nothing.
    ///
    /// Apple stays as the fallback for the case where no model has been downloaded yet, because a
    /// second-long imperfect answer beats a 600MB wait he did not ask for.
    ///
    /// - Parameter language: `uk`, `ru`, `en` — his own dictation setting, never guessed.
    func transcribe(url: URL, language: String, timeout: TimeInterval = 30) async -> String? {
        #if canImport(WhisperKit)
        if WhisperTranscriber.isReadyOffline(language: language) {
            phase = .transcribing
            let text = await WhisperTranscriber.shared.transcribe(url: url, language: language) {
                [weak self] stage in
                Task { @MainActor in self?.phase = .transcribing(note: Self.note(for: stage)) }
            }
            phase = .idle
            if let text { return text }
        }
        #endif

        if let text = await transcribeApple(url: url, language: language, timeout: timeout) {
            return text
        }

        #if canImport(WhisperKit)
        // Nothing on disk and Apple could not do it either: now the download is worth it, and it
        // is announced rather than endured.
        phase = .transcribing
        let text = await WhisperTranscriber.shared.transcribe(url: url, language: language) {
            [weak self] stage in
            Task { @MainActor in self?.phase = .transcribing(note: Self.note(for: stage)) }
        }
        phase = .idle
        if let text { return text }
        #endif
        return nil
    }

    #if canImport(WhisperKit)
    /// Download the dictation model now, so the first sentence he dictates is not the download.
    func prepareDictation(language: String) async -> Bool {
        phase = .transcribing
        defer { phase = .idle }
        return await WhisperTranscriber.shared.install(language: language) { [weak self] stage in
            Task { @MainActor in self?.phase = .transcribing(note: Self.note(for: stage)) }
        }
    }

    nonisolated private static func note(for stage: WhisperTranscriber.Stage) -> String? {
        switch stage {
        case .idle, .listening: nil
        case .downloading:      String(localized: "Fetching the dictation model — once only")
        case .loading:          String(localized: "Preparing the dictation model")
        }
    }
    #endif

    private func transcribeApple(url: URL, language: String,
                                 timeout: TimeInterval = 30) async -> String? {
        phase = .transcribing
        defer { phase = .idle; recognitionTask = nil }
        guard await requestSpeech() else { return nil }
        guard let recognizer = Self.recognizer(for: language), recognizer.isAvailable else {
            return nil
        }

        let request = SFSpeechURLRecognitionRequest(url: url)
        request.requiresOnDeviceRecognition = recognizer.supportsOnDeviceRecognition
        request.taskHint = .dictation

        return await withCheckedContinuation { (cont: CheckedContinuation<String?, Never>) in
            let box = ResumeOnce()

            let task = recognizer.recognitionTask(with: request) { result, error in
                if error != nil {
                    box.resume(cont, with: nil); return
                }
                guard let result, result.isFinal else { return }
                let s = result.bestTranscription.formattedString.trimmingCharacters(in: .whitespacesAndNewlines)
                box.resume(cont, with: s.isEmpty ? nil : s)
            }
            recognitionTask = task
            nonisolated(unsafe) let cancelTask = task
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                if box.resume(cont, with: nil) { cancelTask.cancel() }
            }
        }
    }

    /// A recogniser for a language code, resolved against what this Mac actually supports.
    ///
    /// `SFSpeechRecognizer(locale:)` answers nil for a locale that is not in its supported list,
    /// and the list holds full locales — `uk-UA`, not `uk`. Asking for the bare code therefore
    /// failed and fell through to the interface language, which is how Ukrainian speech came back
    /// as English text. The language is matched here, and the region is whichever one this Mac
    /// happens to ship for it.
    private static func recognizer(for language: String) -> SFSpeechRecognizer? {
        let wanted = Locale(identifier: language).language.languageCode?.identifier
            ?? String(language.prefix(2))
        let supported = SFSpeechRecognizer.supportedLocales()
        let exact = supported.first { $0.identifier.replacingOccurrences(of: "_", with: "-") == language }
        // Prefer this Mac's own region for the language: asking for "en" on the supported list as
        // it comes back picks en-IN, which is a different accent model than an English speaker
        // here would expect.
        let region = Locale.current.region?.identifier
        let sameLanguageHere = supported.first {
            $0.language.languageCode?.identifier == wanted && $0.region?.identifier == region
        }
        let sameLanguage = supported.first { $0.language.languageCode?.identifier == wanted }
        if let locale = exact ?? sameLanguageHere ?? sameLanguage {
            return SFSpeechRecognizer(locale: locale)
        }
        // Nothing on this Mac speaks it. Falling back to another language would produce fluent
        // nonsense, so the caller is told no and the local model gets its turn instead.
        return nil
    }

    // MARK: Permissions

    private func requestMic() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return true
        case .notDetermined:
            return await withCheckedContinuation { cont in
                AVCaptureDevice.requestAccess(for: .audio) { cont.resume(returning: $0) }
            }
        default: return false
        }
    }

    private func requestSpeech() async -> Bool {
        switch SFSpeechRecognizer.authorizationStatus() {
        case .authorized: return true
        case .notDetermined:
            return await withCheckedContinuation { cont in
                SFSpeechRecognizer.requestAuthorization { cont.resume(returning: $0 == .authorized) }
            }
        default: return false
        }
    }
}

private final class ResumeOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false
    @discardableResult
    func resume(_ cont: CheckedContinuation<String?, Never>, with value: String?) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard !done else { return false }
        done = true
        cont.resume(returning: value)
        return true
    }
}
