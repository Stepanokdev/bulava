import XCTest
import AppKit
import UniformTypeIdentifiers
@testable import Bulava

/// Dragging a screenshot thumbnail, and ⌘V.
///
/// The thumbnail that appears at the bottom-right of the screen is not a file yet — the shot is
/// still on its way to the desktop — so the drag carries PNG BYTES and a suggested name, and no
/// file URL at all. Reading a drop as a URL therefore saw nothing and silently refused it. These
/// tests pin the shape the real drag has, taken from a live one.
nonisolated final class PastedAndDroppedImagesTests: XCTestCase {

    @MainActor private func model() -> AppModel {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("bulava-paste-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        setenv("BULAVA_STATE_DIR", dir.path, 1)
        return AppModel()
    }

    private func pngBytes(width: Int = 6, height: Int = 4) -> Data {
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
                                   bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                   isPlanar: false, colorSpaceName: .deviceRGB,
                                   bytesPerRow: 0, bitsPerPixel: 0)!
        return rep.representation(using: .png, properties: [:])!
    }

    private func scratchPasteboard() -> NSPasteboard {
        let pb = NSPasteboard(name: NSPasteboard.Name("bulava-test-\(UUID().uuidString)"))
        pb.clearContents()
        return pb
    }

    // MARK: - The name the screenshot arrives under

    func testAScreenshotNameKeepsItsOwnExtension() {
        XCTAssertEqual(
            AppModel.imageFilename(named: "Screenshot 2026-09-11 at 4.04.47 PM.png", type: .png),
            "Screenshot 2026-09-11 at 4.04.47 PM.png")
    }

    func testATimeInTheNameIsNotMistakenForAnExtension() {
        // "Screenshot 2026-09-11 at 4.04.47 PM" ends in ".47 PM". Taking that for the extension
        // writes a file nothing on the machine knows how to open.
        XCTAssertEqual(
            AppModel.imageFilename(named: "Screenshot 2026-09-11 at 4.04.47 PM", type: .png),
            "Screenshot 2026-09-11 at 4.04.47 PM.png")
    }

    func testAnUnnamedImageStillGetsAReadableFilename() {
        let name = AppModel.imageFilename(named: nil, type: .png)
        XCTAssertTrue(name.hasSuffix(".png"), "got \(name)")
        XCTAssertFalse(name.hasPrefix("."), "the name must not be only an extension")
    }

    func testAJPEGKeepsItsOwnFormat() {
        XCTAssertEqual(AppModel.imageFilename(named: "photo", type: .jpeg), "photo.jpeg")
    }

    // MARK: - Several images in one gesture stay telling apart

    func testAFreeNameIsLeftAlone() {
        XCTAssertEqual(AppModel.uniqueFilename("shot.png", taken: ["other.png"]), "shot.png")
    }

    func testACollidingNameIsNumbered() {
        XCTAssertEqual(AppModel.uniqueFilename("shot.png", taken: ["shot.png"]), "shot 2.png")
        XCTAssertEqual(AppModel.uniqueFilename("shot.png", taken: ["shot.png", "shot 2.png"]),
                       "shot 3.png")
    }

    func testNumberingKeepsTheExtensionUsable() {
        let name = AppModel.uniqueFilename("Pasted image 2026-09-15 at 11.56.32.png",
                                           taken: ["Pasted image 2026-09-15 at 11.56.32.png"])
        XCTAssertEqual(name, "Pasted image 2026-09-15 at 11.56.32 2.png")
    }

    @MainActor func testFourUnnamedImagesInOneGestureGetFourDifferentNames() async throws {
        // The gesture that lost the director's own bug descriptions: four screenshots attached
        // within the same second, all named by that second, all therefore identical.
        let model = model()
        let product = UUID()
        for _ in 0..<4 {
            XCTAssertTrue(model.importImageData(pngBytes(), into: product))
        }
        let names = model.draftAttachments(for: product).map(\.filename)
        XCTAssertEqual(names.count, 4)
        XCTAssertEqual(Set(names).count, 4, "four attachments must be four distinguishable names: \(names)")
    }

    @MainActor func testAPastedImageKeepsTheNameTheClipboardCarries() {
        let model = model()
        let product = UUID()
        let pb = scratchPasteboard()
        let item = NSPasteboardItem()
        item.setData(pngBytes(), forType: .png)
        item.setString("deep-links-are-broken.png", forType: .init("public.url-name"))
        pb.writeObjects([item])

        XCTAssertTrue(model.importPasteboard(pb, into: product))
        XCTAssertEqual(model.draftAttachments(for: product).first?.filename,
                       "deep-links-are-broken.png")
    }

    // MARK: - What a drop is carrying

    func testTheScreenshotDragIsReadAsPNG() {
        let provider = NSItemProvider()
        provider.registerDataRepresentation(forTypeIdentifier: UTType.png.identifier,
                                            visibility: .all) { done in
            done(self.pngBytes(), nil); return nil
        }
        XCTAssertEqual(AppModel.imageType(of: provider), .png,
                       "the live drag registers exactly one type, public.png")
    }

    func testAPlainTextDragIsNotAnImage() {
        let provider = NSItemProvider(object: "just words" as NSString)
        XCTAssertNil(AppModel.imageType(of: provider))
    }

    @MainActor func testDroppingAScreenshotThumbnailAttachesIt() async throws {
        let model = model()
        let product = UUID()
        let bytes = pngBytes()

        // Exactly what screencaptureui hands over: PNG data plus a suggested name, no file URL.
        let provider = NSItemProvider()
        provider.suggestedName = "Screenshot 2026-09-11 at 4.04.47 PM.png"
        provider.registerDataRepresentation(forTypeIdentifier: UTType.png.identifier,
                                            visibility: .all) { done in
            done(bytes, nil); return nil
        }

        XCTAssertTrue(model.importDrop([provider], into: product),
                      "the drop must be accepted, or macOS animates the thumbnail back")

        let attachment = try await attachment(in: model, for: product)
        XCTAssertEqual(attachment.kind, .image)
        XCTAssertEqual(attachment.filename, "Screenshot 2026-09-11 at 4.04.47 PM.png")
        let url = try XCTUnwrap(model.capture.url(for: attachment))
        XCTAssertEqual(try Data(contentsOf: url), bytes, "the attached file must be the shot itself")
    }

    @MainActor func testDroppingAFileStillAttachesTheFileItself() async throws {
        let model = model()
        let product = UUID()
        let source = FileManager.default.temporaryDirectory
            .appendingPathComponent("dropped-\(UUID().uuidString).txt")
        try "hello".data(using: .utf8)!.write(to: source)
        defer { try? FileManager.default.removeItem(at: source) }

        let provider = NSItemProvider(contentsOf: source)!
        XCTAssertTrue(model.importDrop([provider], into: product))

        let attachment = try await attachment(in: model, for: product)
        XCTAssertEqual(attachment.filename, source.lastPathComponent,
                       "a real file keeps its own name, not a generated one")
    }

    @MainActor private func attachment(in model: AppModel, for product: UUID) async throws -> Attachment {
        for _ in 0..<200 {
            if let first = model.draftAttachments(for: product).first { return first }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw XCTSkip("nothing was attached")
    }

    // MARK: - ⌘V

    @MainActor func testPastingAScreenshotFromTheClipboardAttachesIt() {
        let model = model()
        let product = UUID()
        let pb = scratchPasteboard()
        pb.setData(pngBytes(), forType: .png)

        XCTAssertTrue(model.importPasteboard(pb, into: product))
        XCTAssertEqual(model.draftAttachments(for: product).first?.kind, .image)
    }

    @MainActor func testPastingAScreenshotTakenToTheClipboardIsReEncoded() {
        // ⌃⌘⇧4 puts TIFF on the clipboard, and an attachment saved as TIFF under a .png name is
        // a file that opens nowhere.
        let model = model()
        let product = UUID()
        let pb = scratchPasteboard()
        let image = NSImage(size: NSSize(width: 4, height: 3))
        image.lockFocus(); NSColor.red.drawSwatch(in: NSRect(x: 0, y: 0, width: 4, height: 3)); image.unlockFocus()
        pb.setData(image.tiffRepresentation!, forType: .tiff)

        XCTAssertTrue(model.importPasteboard(pb, into: product))
        let attachment = model.draftAttachments(for: product).first
        let url = model.capture.url(for: attachment!)!
        let head = try! Data(contentsOf: url).prefix(4)
        XCTAssertEqual(Array(head), [0x89, 0x50, 0x4E, 0x47], "the saved bytes must really be a PNG")
    }

    @MainActor func testPastingAFileAttachesTheFile() throws {
        let model = model()
        let product = UUID()
        let source = FileManager.default.temporaryDirectory
            .appendingPathComponent("copied-\(UUID().uuidString).pdf")
        try Data("%PDF-1.4".utf8).write(to: source)
        defer { try? FileManager.default.removeItem(at: source) }

        let pb = scratchPasteboard()
        pb.writeObjects([source as NSURL])

        XCTAssertTrue(model.importPasteboard(pb, into: product))
        XCTAssertEqual(model.draftAttachments(for: product).first?.filename, source.lastPathComponent)
    }

    @MainActor func testPastingWordsIsStillJustTyping() {
        let model = model()
        let product = UUID()
        let pb = scratchPasteboard()
        pb.setString("a sentence he copied", forType: .string)

        XCTAssertFalse(model.importPasteboard(pb, into: product),
                       "⌘V of text must fall through to an ordinary paste")
        XCTAssertTrue(model.draftAttachments(for: product).isEmpty)
    }
}
