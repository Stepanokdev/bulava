import XCTest
@testable import Bulava

nonisolated final class ProjectIconScannerTests: XCTestCase {

    private var root: URL!

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("icon-scan-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func write(_ relative: String, bytes: Int = 800) {
        let url = root.appendingPathComponent(relative)
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try? Data(repeating: 0x7F, count: bytes).write(to: url)
    }

    private func candidates() -> [String] {
        let marker = root.lastPathComponent + "/"
        return ProjectIconScanner.candidates(in: [root.path]).map { path in
            guard let cut = path.range(of: marker) else { return path }
            return String(path[cut.upperBound...])
        }
    }

    func testAnIconSetContributesOnlyItsLargestImage() {
        write("Assets.xcassets/AppIcon.appiconset/icon-16.png", bytes: 400)
        write("Assets.xcassets/AppIcon.appiconset/icon-256.png", bytes: 900)
        write("Assets.xcassets/AppIcon.appiconset/icon-1024.png", bytes: 4_000)
        let found = candidates()
        XCTAssertEqual(found, ["Assets.xcassets/AppIcon.appiconset/icon-1024.png"])
    }

    func testBuildAndDependencyFoldersAreNeverSearched() {
        write("node_modules/some-pkg/logo.png")
        write("build/AppIcon.png")
        write(".build/checkouts/thing/icon.png")
        write("Pods/Lib/logo.png")
        XCTAssertEqual(candidates(), [])
    }

    func testOnlyIconishNamesAreCandidates() {
        write("Resources/screenshot.png")
        write("Resources/hero-banner.png")
        write("Resources/logo.png")
        XCTAssertEqual(candidates(), ["Resources/logo.png"])
    }

    func testRankingPrefersTheShallowLogoOverAFavicon() {
        write("logo.png")
        write("public/favicon.ico")
        write("web/static/assets/app-icon.png")
        let found = candidates()
        XCTAssertEqual(found.first, "logo.png")
        XCTAssertEqual(found.last, "public/favicon.ico")
        XCTAssertEqual(found.count, 3)
    }

    func testAbsurdlySizedFilesAreIgnored() {
        write("icon-empty.png", bytes: 10)
        write("logo.png", bytes: 900)
        XCTAssertEqual(candidates(), ["logo.png"])
    }

    func testAMissingFolderYieldsNothing() {
        XCTAssertEqual(ProjectIconScanner.candidates(in: ["/nope/not/here"]), [])
    }
}
