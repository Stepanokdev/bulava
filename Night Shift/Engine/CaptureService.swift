import Foundation
import ScreenCaptureKit
import AppKit
import CoreGraphics
import CoreImage

@MainActor
final class CaptureService {

    private let dir: URL
    private let service: URL
    private var timer: Task<Void, Never>?
    private var inFlight: Set<String> = []

    init(stateDir: URL) {
        dir = stateDir.appendingPathComponent("capture-requests", isDirectory: true)
        service = dir.appendingPathComponent("service.json")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    func start() {
        announce()
        timer = Task { [weak self] in
            var ticks = 0
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(400))
                await self?.drain()

                ticks += 1
                if ticks % 12 == 0 { await self?.announce() }
            }
        }
    }

    func stop() {
        timer?.cancel()
        timer = nil
        try? FileManager.default.removeItem(at: service)
    }

    func announce() {
        let payload: [String: Any] = ["pid": ProcessInfo.processInfo.processIdentifier,
                                      "since": Int(Date().timeIntervalSince1970)]
        if let data = try? JSONSerialization.data(withJSONObject: payload) {
            try? data.write(to: service)
        }
    }

    // MARK: - Serving

    private func drain() async {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else { return }
        for name in names where name.hasSuffix(".json") && name != "service.json" {
            let id = String(name.dropLast(5))
            guard !inFlight.contains(id) else { continue }
            let done = dir.appendingPathComponent("\(id).done")
            guard !FileManager.default.fileExists(atPath: done.path) else { continue }
            inFlight.insert(id)
            await serve(id: id, request: dir.appendingPathComponent(name), done: done)
            inFlight.remove(id)
        }
    }

    private func serve(id: String, request: URL, done: URL) async {
        guard let data = try? Data(contentsOf: request),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let out = obj["out"] as? String, !out.isEmpty else {
            answer(done, ok: false, error: "request is not readable")
            return
        }
        do {
            let image = try await capture(region: obj["region"] as? String,
                                         windowPID: (obj["window_pid"] as? NSNumber)?.int32Value)
            guard let png = png(from: image) else { throw CaptureError.encodingFailed }
            try png.write(to: URL(fileURLWithPath: out))
            answer(done, ok: true, path: out)
        } catch {
            answer(done, ok: false, error: describe(error))
        }
    }

    private func answer(_ done: URL, ok: Bool, path: String? = nil, error: String? = nil) {
        var payload: [String: Any] = ["ok": ok]
        if let path { payload["path"] = path }
        if let error { payload["error"] = error }
        if let data = try? JSONSerialization.data(withJSONObject: payload) {
            try? data.write(to: done)
        }
    }

    func captureNow(to path: String, region: String? = nil, windowPID: Int32? = nil) async throws {
        let image = try await capture(region: region, windowPID: windowPID)
        guard let data = png(from: image) else { throw CaptureError.encodingFailed }
        try data.write(to: URL(fileURLWithPath: path))
    }

    // MARK: - Capturing

    enum CaptureError: Error {
        case noDisplay
        case noWindow(pid: Int32)
        case encodingFailed
        case notPermitted
    }

    private func capture(region: String?, windowPID: Int32?) async throws -> CGImage {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)

        if let pid = windowPID {
            let windows = content.windows
                .filter { $0.owningApplication?.processID == pid && ($0.frame.width > 200) }
                .sorted { $0.frame.width * $0.frame.height > $1.frame.width * $1.frame.height }
            guard let window = windows.first else { throw CaptureError.noWindow(pid: pid) }
            let config = SCStreamConfiguration()
            config.width = Int(window.frame.width * 2)
            config.height = Int(window.frame.height * 2)
            config.showsCursor = false
            return try await SCScreenshotManager.captureImage(
                contentFilter: SCContentFilter(desktopIndependentWindow: window),
                configuration: config)
        }

        guard let display = content.displays.first else { throw CaptureError.noDisplay }
        let config = SCStreamConfiguration()
        config.showsCursor = false
        if let rect = Self.rect(from: region) {

            config.sourceRect = rect
            config.width = Int(rect.width * 2)
            config.height = Int(rect.height * 2)
        } else {
            config.width = display.width * 2
            config.height = display.height * 2
        }
        return try await SCScreenshotManager.captureImage(
            contentFilter: SCContentFilter(display: display, excludingWindows: []),
            configuration: config)
    }

    nonisolated static func rect(from region: String?) -> CGRect? {
        guard let region, !region.isEmpty else { return nil }
        let parts = region.split(separator: ",").map { Double($0.trimmingCharacters(in: .whitespaces)) }
        guard parts.count == 4, !parts.contains(where: { $0 == nil }) else { return nil }
        let (x, y, w, h) = (parts[0]!, parts[1]!, parts[2]!, parts[3]!)
        guard w > 0, h > 0 else { return nil }
        return CGRect(x: x, y: y, width: w, height: h)
    }

    private func png(from image: CGImage) -> Data? {
        let rep = NSBitmapImageRep(cgImage: image)
        return rep.representation(using: .png, properties: [:])
    }

    private func describe(_ error: Error) -> String {
        switch error {
        case CaptureError.noDisplay: "no display to capture"
        case CaptureError.noWindow(let pid): "no window found for pid \(pid)"
        case CaptureError.encodingFailed: "the frame could not be encoded as PNG"
        case CaptureError.notPermitted: "Bulava is not allowed to record the screen"
        default:
            refusal(error)
        }
    }

    /// What to say when macOS refuses, which is not one situation but two.
    ///
    /// ScreenCaptureKit answers `userDeclined` for both of them, and this used to pass its
    /// sentence straight through with "is Screen Recording granted to Bulava?" appended. The
    /// director read that, opened System Settings, found the switch for Bulava already on, and
    /// sent back a photograph of it — because the question the message asked had already been
    /// answered, and the real one had not been asked at all.
    ///
    /// `CGPreflightScreenCaptureAccess()` distinguishes them: it reads the same record System
    /// Settings draws that switch from. When the switch is off, say so and where it lives. When
    /// the switch is ON and the capture was still refused, the grant on file no longer matches
    /// this copy of Bulava — which is what happens after the entry was recorded against a
    /// differently-signed build of the same bundle identifier, a locally built one among them.
    /// Say that, and name the way out, instead of pointing at a switch that is already on.
    private func refusal(_ error: Error) -> String {
        let listed = CGPreflightScreenCaptureAccess()
        let what = (error as NSError).localizedDescription
        guard listed else {
            return "\(what) — Screen Recording is off for Bulava. "
                + "System Settings → Privacy & Security → Screen & System Audio Recording."
        }
        return "\(what) — and System Settings already lists Bulava as allowed, so the switch is "
            + "not the problem: the permission on file was recorded for a different build of "
            + "Bulava and no longer matches this one. Turn Screen Recording off and on again for "
            + "Bulava, or press “Ask macOS again” on Bulava's readiness screen."
    }
}
