import XCTest
@testable import Bulava

nonisolated final class FilePathLinkTests: XCTestCase {

    private var root: URL!
    private var outside: URL!

    override func setUpWithError() throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("bulava-links-\(UUID().uuidString)")
        root = base.appendingPathComponent("project")
        outside = base.appendingPathComponent("elsewhere")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("src"),
                                                withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try "hi".write(to: root.appendingPathComponent("src/main.swift"), atomically: true, encoding: .utf8)
        try "secret".write(to: outside.appendingPathComponent("id_rsa"), atomically: true, encoding: .utf8)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root.deletingLastPathComponent())
    }

    private func rewrite(_ text: String) -> String {
        FilePathLinks.rewrite(text, roots: [root])
    }

    // MARK: - What becomes a link

    func testARealPathInsideTheProjectBecomesALink() {
        let out = rewrite("wrote `\(root.path)/src/main.swift` just now")
        XCTAssertTrue(out.contains("(\(FilePathLinks.scheme)://"), "expected a link, got: \(out)")
    }

    func testTheVisibleTextIsUnchanged() {
        let path = "\(root.path)/src/main.swift"
        let out = rewrite("wrote `\(path)` just now")
        XCTAssertTrue(out.contains("[`\(path)`]"), out)
        XCTAssertTrue(out.hasPrefix("wrote "))
        XCTAssertTrue(out.hasSuffix(" just now"))
    }

    func testAFolderInsideTheProjectBecomesALink() {
        XCTAssertTrue(rewrite("see `\(root.path)/src`").contains(FilePathLinks.host))
    }

    // MARK: - What does not

    func testARealPathOutsideEveryRootStaysPlainText() {
        let out = rewrite("look at `\(outside.path)/id_rsa`")
        XCTAssertFalse(out.contains(FilePathLinks.host),
                       "a real file outside the product's folders must not become a button")
    }

    func testAPathThatDoesNotExistStaysPlainText() {
        let out = rewrite("I wrote `\(root.path)/src/imaginary.swift`")
        XCTAssertFalse(out.contains(FilePathLinks.host))
    }

    func testASymlinkOutOfTheProjectIsRefused() throws {
        let link = root.appendingPathComponent("escape")
        try FileManager.default.createSymbolicLink(at: link,
                                                   withDestinationURL: outside.appendingPathComponent("id_rsa"))
        let out = rewrite("see `\(link.path)`")
        XCTAssertFalse(out.contains(FilePathLinks.host),
                       "a symlink is only as safe as where it points")
    }

    func testWithoutRootsNothingIsLinked() {
        let text = "wrote `\(root.path)/src/main.swift`"
        XCTAssertEqual(FilePathLinks.rewrite(text, roots: []), text)
    }

    func testTheRootDirectoryIsNotAnAcceptableRoot() {
        let text = "see `\(outside.path)/id_rsa`"
        XCTAssertEqual(FilePathLinks.rewrite(text, roots: [URL(fileURLWithPath: "/")]), text)
    }

    func testAWebAddressIsNotAPath() {
        let text = "see https://example.com/a/b for details"
        XCTAssertEqual(rewrite(text), text)
    }

    func testProseWithSlashesIsLeftAlone() {
        for text in ["and/or", "read the docs / then decide", "3/4 of the work"] {
            XCTAssertFalse(rewrite(text).contains(FilePathLinks.host), text)
        }
    }

    // MARK: - Addressing

    func testAPathWithSpacesAndNonAsciiSurvivesTheRoundTrip() throws {
        let odd = root.appendingPathComponent("Night Shift #1 звіт.md")
        try "x".write(to: odd, atomically: true, encoding: .utf8)

        let out = rewrite("see `\(odd.path)`")

        let opener = "](https://" + FilePathLinks.host + "/"
        let start = try XCTUnwrap(out.range(of: opener))
        let end = try XCTUnwrap(out.range(of: ")", range: start.upperBound..<out.endIndex))
        let raw = "https://" + FilePathLinks.host + "/" + out[start.upperBound..<end.lowerBound]
        let url = try XCTUnwrap(URL(string: raw))

        XCTAssertEqual(FilePathLinks.target(of: url, roots: [root])?.path,
                       odd.resolvingSymlinksInPath().path)
    }

    func testForeignSchemesAreNotTargets() {
        for raw in ["https://example.com", "file:///etc/passwd", "x-devonthink://open", "https://bulava-file.invalid.evil.com/AAAA"] {
            XCTAssertNil(FilePathLinks.target(of: URL(string: raw)!, roots: [root]), raw)
        }
    }

    // MARK: - A link the model wrote itself

    func testAForgedLinkToAFileOutsideTheRootsIsRefused() throws {
        let secret = outside.appendingPathComponent("id_rsa")
        let forged = try XCTUnwrap(URL(string: try XCTUnwrap(FilePathLinks.link(for: secret))))

        XCTAssertNil(FilePathLinks.target(of: forged, roots: [root]),
                     "a link the model wrote itself must be re-checked, not trusted for its scheme")
    }

    func testAForgedLinkToASystemFileIsRefused() throws {
        let passwd = URL(fileURLWithPath: "/etc/passwd")
        let forged = try XCTUnwrap(URL(string: try XCTUnwrap(FilePathLinks.link(for: passwd))))

        XCTAssertNil(FilePathLinks.target(of: forged, roots: [root]))
    }

    func testALinkToAFileInsideTheRootsStillResolves() throws {
        let real = root.appendingPathComponent("src/main.swift")
        let url = try XCTUnwrap(URL(string: try XCTUnwrap(FilePathLinks.link(for: real))))

        XCTAssertEqual(FilePathLinks.target(of: url, roots: [root])?.path,
                       real.resolvingSymlinksInPath().path)
    }

    func testWithoutRootsNoLinkResolves() throws {
        let real = root.appendingPathComponent("src/main.swift")
        let url = try XCTUnwrap(URL(string: try XCTUnwrap(FilePathLinks.link(for: real))))

        XCTAssertNil(FilePathLinks.target(of: url, roots: []))
    }

    // MARK: - One product cannot reach into another

    func testAForgedLinkIntoAnotherProductsReportIsRefused() throws {
        let reports = root.deletingLastPathComponent().appendingPathComponent("reports")
        let mine = reports.appendingPathComponent("aaaa1111")
        let theirs = reports.appendingPathComponent("bbbb2222")
        try FileManager.default.createDirectory(at: mine, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: theirs, withIntermediateDirectories: true)
        let theirShot = theirs.appendingPathComponent("screen.png")
        try Data([0x89]).write(to: theirShot)

        let forged = try XCTUnwrap(URL(string: try XCTUnwrap(FilePathLinks.link(for: theirShot))))
        XCTAssertNil(FilePathLinks.target(of: forged, roots: [root, mine]),
                     "another product's report must not resolve from this conversation")

        let myShot = mine.appendingPathComponent("screen.png")
        try Data([0x89]).write(to: myShot)
        let ok = try XCTUnwrap(URL(string: try XCTUnwrap(FilePathLinks.link(for: myShot))))
        XCTAssertEqual(FilePathLinks.target(of: ok, roots: [root, mine])?.path,
                       myShot.resolvingSymlinksInPath().path)
    }

    func testTheParentReportsDirectoryWouldHaveLeaked() throws {
        let reports = root.deletingLastPathComponent().appendingPathComponent("reports2")
        let theirs = reports.appendingPathComponent("bbbb2222")
        try FileManager.default.createDirectory(at: theirs, withIntermediateDirectories: true)
        let theirShot = theirs.appendingPathComponent("screen.png")
        try Data([0x89]).write(to: theirShot)

        let forged = try XCTUnwrap(URL(string: try XCTUnwrap(FilePathLinks.link(for: theirShot))))
        XCTAssertNotNil(FilePathLinks.target(of: forged, roots: [reports]),
                        "documents why the whole reports directory is not an acceptable root")
    }

    // MARK: - Markdown syntax

    func testImageSyntaxIsNotMangled() throws {
        let shot = root.appendingPathComponent("src/shot.png")
        try Data([0x89, 0x50, 0x4E, 0x47]).write(to: shot)

        let out = rewrite("![shot](\(shot.path))")
        XCTAssertTrue(out.hasPrefix("![shot]("), out)
        XCTAssertFalse(out.contains("]([" ), "a nested link inside the image target is broken markup")
        XCTAssertTrue(out.contains(FilePathLinks.host), "an in-scope image should be addressable")
    }

    func testARemoteImageTargetIsUntouched() {
        let text = "![logo](https://example.com/a.png)"
        XCTAssertEqual(rewrite(text), text)
    }

    func testALinkTargetInScopeIsRewritten() {
        let out = rewrite("[the file](\(root.path)/src/main.swift)")
        XCTAssertTrue(out.hasPrefix("[the file]("), out)
        XCTAssertTrue(out.contains(FilePathLinks.host))
    }

    func testALinkTargetOutOfScopeIsUntouched() {
        let text = "[secret](\(outside.path)/id_rsa)"
        XCTAssertEqual(rewrite(text), text)
    }

    func testARealPathInsideALinkLabelIsLeftAlone() {
        let real = "\(root.path)/src/main.swift"
        let text = "[\(real)](https://example.com)"
        XCTAssertEqual(rewrite(text), text, "a label is text, not a mention to rewrite")
    }

    func testARealPathInsideAnImageLabelIsLeftAlone() {
        let real = "\(root.path)/src/main.swift"
        let text = "![\(real)](https://example.com/a.png)"
        XCTAssertEqual(rewrite(text), text)
    }

    func testATitledImageKeepsItsTitle() throws {
        let shot = root.appendingPathComponent("src/shot.png")
        try Data([0x89, 0x50, 0x4E, 0x47]).write(to: shot)

        let out = rewrite("![alt](\(shot.path) \"a title\")")
        XCTAssertTrue(out.contains("\"a title\""), out)
        XCTAssertTrue(out.contains(FilePathLinks.host), out)
        XCTAssertFalse(out.contains(shot.path), "the destination should have been replaced")
    }

    func testEscapedBracketsAreNotNodes() {
        let text = "\\[not a link\\] and plain words"
        XCTAssertEqual(rewrite(text), text)
    }

    func testALabelWithNestedBracketsIsHandledWhole() {
        let real = "\(root.path)/src/main.swift"
        let text = "[a [b] c](https://example.com) then `\(real)`"
        let out = rewrite(text)
        XCTAssertTrue(out.hasPrefix("[a [b] c](https://example.com)"), out)
        XCTAssertTrue(out.contains(FilePathLinks.host), "the mention outside the node still links")
    }

    func testAnUnclosedBracketDoesNotEatTheParagraph() {
        let real = "\(root.path)/src/main.swift"
        let out = rewrite("[unclosed and `\(real)`")
        XCTAssertTrue(out.contains(FilePathLinks.host), out)
    }

    func testOnlyImageExtensionsCountAsImages() {
        XCTAssertTrue(FilePathLinks.isImage(URL(fileURLWithPath: "/a/b.PNG")))
        XCTAssertTrue(FilePathLinks.isImage(URL(fileURLWithPath: "/a/b.heic")))
        XCTAssertFalse(FilePathLinks.isImage(URL(fileURLWithPath: "/a/b.swift")))
        XCTAssertFalse(FilePathLinks.isImage(URL(fileURLWithPath: "/a/b")))
    }

    func testAMixedParagraphLinksOnlyWhatItShould() {
        let real = "\(root.path)/src/main.swift"
        let fake = "\(root.path)/src/nope.swift"
        let out = rewrite("changed `\(real)`, left `\(fake)` alone, and `\(outside.path)/id_rsa` untouched")

        XCTAssertEqual(out.components(separatedBy: FilePathLinks.host).count - 1, 1,
                       "exactly one of the three is openable")
        XCTAssertTrue(out.contains(fake), "the others must still be readable")
        XCTAssertTrue(out.contains("\(outside.path)/id_rsa"))
    }
}
