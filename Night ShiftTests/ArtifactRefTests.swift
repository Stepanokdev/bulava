import XCTest
@testable import Bulava

nonisolated final class ArtifactRefTests: XCTestCase {

    private var base: URL!
    private var run: URL!

    override func setUpWithError() throws {
        base = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("bulava-artifact-\(UUID().uuidString)", isDirectory: true)
        run = base.appendingPathComponent("run-a", isDirectory: true)
        try FileManager.default.createDirectory(at: run, withIntermediateDirectories: true)
        try Data("frame".utf8).write(to: run.appendingPathComponent("after-1.png"))

        let other = base.appendingPathComponent("run-b", isDirectory: true)
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        try Data("secret".utf8).write(to: other.appendingPathComponent("private.txt"))
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: base)
    }

    func testARealFileInsideItsOwnRunResolves() {
        let ref = ArtifactRef(runID: "run-a", relativePath: "after-1.png")
        XCTAssertNotNil(ref.resolve(base: base))
        XCTAssertEqual(ref.kind, .image)
    }

    func testAnAbsolutePathIsRefused() {
        let ref = ArtifactRef(runID: "run-a", relativePath: "/etc/hosts")
        XCTAssertNil(ref.resolve(base: base))
    }

    func testClimbingOutWithDotDotIsRefused() {
        let ref = ArtifactRef(runID: "run-a", relativePath: "../run-b/private.txt")
        XCTAssertNil(ref.resolve(base: base))
    }

    func testARunIdThatIsItselfAPathIsRefused() {
        let ref = ArtifactRef(runID: "run-a/..", relativePath: "run-b/private.txt")
        XCTAssertNil(ref.resolve(base: base))
    }

    func testASymlinkIntoAnotherRunIsRefused() throws {
        try FileManager.default.createSymbolicLink(
            at: run.appendingPathComponent("neighbour.txt"),
            withDestinationURL: base.appendingPathComponent("run-b/private.txt"))
        let ref = ArtifactRef(runID: "run-a", relativePath: "neighbour.txt")
        XCTAssertNil(ref.resolve(base: base))
    }

    func testASymlinkPointingOutOfTheFenceIsRefused() throws {
        let outside = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("bulava-outside-\(UUID().uuidString).txt")
        try Data("elsewhere".utf8).write(to: outside)
        defer { try? FileManager.default.removeItem(at: outside) }

        try FileManager.default.createSymbolicLink(
            at: run.appendingPathComponent("escape.txt"), withDestinationURL: outside)

        let ref = ArtifactRef(runID: "run-a", relativePath: "escape.txt")
        XCTAssertNil(ref.resolve(base: base),
                     "a link inside the fence passes every string check there is")
    }

    func testAFileThatIsNoLongerThereResolvesToNothingRatherThanACrash() {
        let ref = ArtifactRef(runID: "run-a", relativePath: "gone.png")
        XCTAssertNil(ref.resolve(base: base))
    }

    func testKindIsReadFromTheName() {
        XCTAssertEqual(ArtifactRef(runID: "r", relativePath: "a/b.mp4").kind, .video)
        XCTAssertEqual(ArtifactRef(runID: "r", relativePath: "pack.zip").kind, .archive)
        XCTAssertEqual(ArtifactRef(runID: "r", relativePath: "notes.md").kind, .document)
        XCTAssertEqual(ArtifactRef(runID: "r", relativePath: "build.log").kind, .log)
        XCTAssertEqual(ArtifactRef(runID: "r", relativePath: "thing.weird").kind, .other)
    }

    func testAnUnknownBlockKindKeepsWhatItCarries() throws {
        let json = #"""
        {"id":"x1","kind":"hologram","text":"{\"some\":\"future thing\"}","artifacts":[{"runID":"run-a","relativePath":"after-1.png","displayName":"after-1.png","kind":"image"}]}
        """#
        let block = try JSONDecoder().decode(ConversationBlock.self, from: Data(json.utf8))
        XCTAssertEqual(block.kind, .unknown)
        XCTAssertFalse(block.text.isEmpty)
        XCTAssertEqual(block.artifacts.count, 1)
        XCTAssertTrue(block.isRenderable, "an unknown block is shown, never silently dropped")
    }

    func testUpsertReplacesByIdRatherThanAppending() {
        var blocks: [ConversationBlock] = []
        blocks.upsert(.markdown(id: "a", "one"))
        blocks.upsert(.markdown(id: "a", "one, corrected"))
        blocks.upsert(.markdown(id: "b", "two"))
        XCTAssertEqual(blocks.count, 2)
        XCTAssertEqual(blocks.first?.text, "one, corrected")
    }
}

nonisolated final class ArtifactRootFenceTests: XCTestCase {

    func testARunDirectoryThatIsItselfALinkOutIsRefused() throws {
        let fm = FileManager.default
        let base = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("bulava-fence-\(UUID().uuidString)", isDirectory: true)
        let elsewhere = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("bulava-elsewhere-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: base, withIntermediateDirectories: true)
        try fm.createDirectory(at: elsewhere, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: base); try? fm.removeItem(at: elsewhere) }

        try Data("private".utf8).write(to: elsewhere.appendingPathComponent("secret.txt"))
        try fm.createSymbolicLink(at: base.appendingPathComponent("run-x"),
                                  withDestinationURL: elsewhere)

        let ref = ArtifactRef(runID: "run-x", relativePath: "secret.txt")
        XCTAssertNil(ref.resolve(base: base),
                     "the run resolves to somewhere that is not inside reports at all")
    }
}
