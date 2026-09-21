import XCTest
import AVFoundation
@testable import Bulava

/// The microphone is gated TWICE on this platform, and only one of the two gates is the one a
/// person can see.
///
/// The permission in System Settings is the visible gate. The hardened runtime — which
/// notarisation requires — is the other, and it refuses the microphone unless the app is signed
/// with `com.apple.security.device.audio-input`. Bulava was not, so
/// `AVCaptureDevice.authorizationStatus(for: .audio)` answered "denied" whatever the Privacy pane
/// said: the readiness row read "Dictation does not work", dictation refused to start, and
/// removing and re-granting the permission could not help, because the permission was never what
/// was refusing.
///
/// A build that loses this entitlement looks exactly like a build that has it until somebody tries
/// to speak, so it is asserted here rather than trusted.
nonisolated final class DictationNeedsItsEntitlementTests: XCTestCase {

    private var repoRoot: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    }

    private func entitlements() throws -> [String: Any] {
        let url = repoRoot.appendingPathComponent("Night Shift/Bulava.entitlements")
        let data = try Data(contentsOf: url)
        let plist = try PropertyListSerialization.propertyList(from: data, format: nil)
        return try XCTUnwrap(plist as? [String: Any])
    }

    func testTheAppIsSignedForAudioInput() throws {
        let keys = try entitlements()
        XCTAssertEqual(keys["com.apple.security.device.audio-input"] as? Bool, true,
                       "without this the hardened runtime refuses the microphone and no amount of "
                       + "granting the permission in System Settings changes it")
    }

    /// The entitlement that was already there, so adding one did not quietly displace it: the
    /// hardened runtime blocks Apple Events too, and that is how "open Terminal on this run" works.
    func testTheAppleEventsEntitlementIsStillThere() throws {
        XCTAssertEqual(try entitlements()["com.apple.security.automation.apple-events"] as? Bool,
                       true)
    }

    /// An entitlement is half of it. Without the usage strings macOS never shows the prompt, and
    /// asking for the microphone without one is a crash on this platform.
    func testTheReasonShownToAPersonIsDeclared() throws {
        let pbxproj = try String(
            contentsOf: repoRoot.appendingPathComponent("Night Shift.xcodeproj/project.pbxproj"),
            encoding: .utf8)
        for key in ["INFOPLIST_KEY_NSMicrophoneUsageDescription",
                    "INFOPLIST_KEY_NSSpeechRecognitionUsageDescription"] {
            XCTAssertTrue(pbxproj.contains(key), "\(key) is what macOS shows when it asks")
        }
    }

    /// Both surfaces that tell him about dictation read the same one value, so a wrong answer from
    /// it is a wrong answer in two places at once — the readiness row and the composer's toast.
    func testBothSurfacesReadTheSameAuthorisation() throws {
        let sources = ["Night Shift/Features/Preflight/Preflight.swift",
                       "Night Shift/Features/Inbox/VoiceRecorder.swift"]
        for path in sources {
            let text = try String(contentsOf: repoRoot.appendingPathComponent(path),
                                  encoding: .utf8)
            XCTAssertTrue(text.contains("authorizationStatus(for: .audio)"),
                          "\(path) is expected to ask AVCaptureDevice, not guess")
        }
    }
}
