import AppKit
import WebKit
import XCTest
@testable import Bulava

/// "Save as PDF" on a report nobody scrolled: every picture is on the paper.
///
/// A report's pictures load lazily, and the PDF used to be taken of the page as it stood — so a
/// report opened and saved straight away came out with its first frame and empty panels under it,
/// and the director learnt to scroll to the end before saving. The page is now walked to the end and
/// every picture decoded first (`ReportDocumentView.everythingOnPaper`).
nonisolated final class ReportPDFTests: XCTestCase {

    @MainActor
    func testEveryPictureIsLoadedBeforeThePaperIsMade() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("report-pdf-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        // Eight different phone-sized frames, each after a long stretch of text: all but the first
        // are well below the first screen.
        var sections = ""
        for i in 1...8 {
            try Self.png(width: 660, height: 1434, shade: CGFloat(i) / 9).write(to: dir.appendingPathComponent("p\(i).png"))
            let text = String(repeating: "<p>A paragraph of text that takes room on the page, as a report does.</p>", count: 40)
            sections += "<section>\(text)<img src=\"p\(i).png\" loading=\"lazy\" style=\"width:320px\"></section>"
        }
        let page = dir.appendingPathComponent("index.html")
        try "<!doctype html><html><body>\(sections)</body></html>".write(to: page, atomically: true, encoding: .utf8)

        let web = WKWebView(frame: NSRect(x: 0, y: 0, width: 1200, height: 900))
        let window = NSWindow(contentRect: web.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = web
        window.orderFrontRegardless()
        let loaded = Loaded()
        web.navigationDelegate = loaded
        web.loadFileURL(page, allowingReadAccessTo: dir)
        try await loaded.wait()
        try await Task.sleep(for: .milliseconds(800))

        let before = try await Self.loadedPictures(web)
        // The same call the report view makes. Its `async` form returns before the page's promise
        // settles; the completion-handler one waits for it.
        let counted: Int = await withCheckedContinuation { done in
            web.callAsyncJavaScript(ReportDocumentView.everythingOnPaper, arguments: [:], in: nil, in: .defaultClient) {
                done.resume(returning: ((try? $0.get()) as? NSNumber)?.intValue ?? -1)
            }
        }
        XCTAssertEqual(counted, 8, "the preparation ran to its end")
        let after = try await Self.loadedPictures(web)

        XCTAssertEqual(after, 8, "every picture is loaded before the PDF is made (as the page stood: \(before) of 8)")
        let top = try await web.evaluateJavaScript("(document.scrollingElement || document.documentElement).scrollTop") as? Double
        XCTAssertEqual(top, 0, "and the report is put back where the reader was")
        window.close()
    }

    @MainActor
    private static func loadedPictures(_ web: WKWebView) async throws -> Int {
        let n = try await web.evaluateJavaScript(
            "Array.from(document.images).filter(p => p.complete && p.naturalWidth > 0).length")
        return (n as? Int) ?? Int((n as? Double) ?? -1)
    }

    @MainActor
    private static func png(width: Int, height: Int, shade: CGFloat) -> Data {
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8,
                                   samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                   bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSColor(calibratedRed: shade, green: 0.4, blue: 1 - shade, alpha: 1).setFill()
        NSRect(x: 0, y: 0, width: width, height: height).fill()
        NSGraphicsContext.restoreGraphicsState()
        return rep.representation(using: .png, properties: [:])!
    }

    @MainActor
    private final class Loaded: NSObject, WKNavigationDelegate {
        private var done: CheckedContinuation<Void, Error>?
        private var finished = false
        func wait() async throws {
            if finished { return }
            try await withCheckedThrowingContinuation { done = $0 }
        }
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            finished = true; done?.resume(); done = nil
        }
        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            done?.resume(throwing: error); done = nil
        }
    }
}
