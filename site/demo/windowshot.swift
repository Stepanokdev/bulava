// Photograph one application's window, from a process macOS already trusts to record the screen.
//
//   windowshot <pid> <out.png>
//
// Bulava normally takes its own pictures, and for the website it cannot: the privacy grant is
// recorded against the responsible process, and every path that starts Bulava from a script gives
// it a responsible process with no such grant. The switch in System Settings reads ON and
// ScreenCaptureKit answers "the user declined", which is true and unhelpful.
//
// Terminal holds the grant. Run from a `.command` file that Terminal opens, this inherits it —
// and asks for exactly one window, so nothing else on the desktop is in the frame. That matters
// more than convenience here: the desktop this runs on has other people's work on it.
import AppKit
import Foundation
import ScreenCaptureKit

func fail(_ message: String) -> Never {
    FileHandle.standardError.write((message + "\n").data(using: .utf8)!)
    exit(1)
}

let args = CommandLine.arguments
guard args.count == 3, let pid = Int32(args[1]) else {
    fail("usage: windowshot <pid> <out.png>")
}
let out = URL(fileURLWithPath: args[2])

// ScreenCaptureKit talks to the window server, and a plain command-line tool has not connected
// to it — the first call aborts with CGS_REQUIRE_INIT. Touching NSApplication makes the
// connection without putting anything on screen.
_ = NSApplication.shared

let done = DispatchSemaphore(value: 0)
var failure: String?

Task {
    defer { done.signal() }
    do {
        let content = try await SCShareableContent.excludingDesktopWindows(false,
                                                                          onScreenWindowsOnly: true)
        // The biggest window this process owns. An application has helper windows — a tooltip, a
        // popover — and the largest one is the document window every time.
        let windows = content.windows
            .filter { $0.owningApplication?.processID == pid && $0.frame.width > 200 }
            .sorted { $0.frame.width * $0.frame.height > $1.frame.width * $1.frame.height }
        guard let window = windows.first else {
            failure = "no window belongs to pid \(pid) — is it running, and has it opened one?"
            return
        }

        let config = SCStreamConfiguration()
        config.width = Int(window.frame.width * 2)
        config.height = Int(window.frame.height * 2)
        config.showsCursor = false
        // Captured on its own, not as part of the screen: whatever else is on this desktop stays
        // out of the frame rather than being cropped out afterwards and hoped about.
        let image = try await SCScreenshotManager.captureImage(
            contentFilter: SCContentFilter(desktopIndependentWindow: window),
            configuration: config)

        guard let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
        else {
            failure = "the frame could not be encoded as PNG"
            return
        }
        try data.write(to: out)
        print("\(Int(window.frame.width * 2))x\(Int(window.frame.height * 2)) → \(out.path)")
    } catch {
        failure = "\((error as NSError).localizedDescription)"
    }
}

done.wait()
if let failure { fail(failure) }
