import AVFoundation
import OSLog
import Shared

// MARK: - Dictation

/// The microphone, for a voice note the Mac's Whisper turns into words. The shared code decides
/// when to record and what becomes of the file; this only records it.
extension BulavaHost {
    func micPermission() -> Int32 {
        switch AVAudioApplication.shared.recordPermission {
        case .granted: return 0
        case .denied: return 1
        default: return 2
        }
    }

    /// Asked when the mic in the composer is first pressed — the moment the question makes sense —
    /// and answered on the main thread, where the shared code lives.
    func requestMicrophone(onResult: @escaping (KotlinBoolean) -> Void) {
        AVAudioApplication.requestRecordPermission { allowed in
            DispatchQueue.main.async { onResult(KotlinBoolean(value: allowed)) }
        }
    }

    func startRecording(path: String) -> Bool { DictationRecorder.shared.start(URL(fileURLWithPath: path)) }
    func recordingLevel() -> Float { DictationRecorder.shared.level() }
    func stopRecording() -> Bool { DictationRecorder.shared.stop() }
    func cancelRecording() { DictationRecorder.shared.cancel() }
}

/// `AVAudioRecorder` writing AAC into an M4A, mono at 16 kHz.
///
/// 16 kHz mono because that is what Whisper hears anyway — it resamples everything to it before
/// listening — so anything more is only a longer upload. The audio session is taken for recording
/// while the note runs and given back after, so music paused for dictation comes back.
final class DictationRecorder {
    static let shared = DictationRecorder()
    private var recorder: AVAudioRecorder?
    private let log = Logger(subsystem: "com.stepanok.bulava", category: "dictation")

    func start(_ url: URL) -> Bool {
        guard recorder == nil else { return false }
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.record, mode: .default)
            try session.setActive(true)
            let settings: [String: Any] = [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: 16_000,
                AVNumberOfChannelsKey: 1,
                AVEncoderAudioQualityKey: AVAudioQuality.medium.rawValue,
            ]
            let r = try AVAudioRecorder(url: url, settings: settings)
            r.isMeteringEnabled = true
            guard r.record() else {
                release()
                return false
            }
            recorder = r
            return true
        } catch {
            log.error("dictation did not start: \(error.localizedDescription, privacy: .public)")
            release()
            return false
        }
    }

    /// The average power in decibels, from −50 (nothing) to 0 (as loud as it goes), as 0…1.
    func level() -> Float {
        guard let r = recorder else { return 0 }
        r.updateMeters()
        return max(0, min(1, (r.averagePower(forChannel: 0) + 50) / 50))
    }

    func stop() -> Bool {
        guard let r = recorder else { return false }
        let recorded = r.currentTime > 0
        r.stop()
        recorder = nil
        release()
        return recorded
    }

    func cancel() {
        guard let r = recorder else { return }
        r.stop()
        r.deleteRecording()
        recorder = nil
        release()
    }

    private func release() {
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }
}
