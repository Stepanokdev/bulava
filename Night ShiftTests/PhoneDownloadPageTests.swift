import XCTest
@testable import Bulava

/// "Open the download page" in the phone panel leads to the page in the Mac's own language.
///
/// The site renders the phone's page twice, `/mobile/` and `/uk/mobile/`, from
/// `site/mobile.template.html`. A Ukrainian Mac used to open the English one.
nonisolated final class PhoneDownloadPageTests: XCTestCase {

    private static let site = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("site")

    func testTheMacsLanguagePicksThePage() {
        XCTAssertEqual(LinkProtocol.downloadPage(for: "uk"), "https://bulava.app/uk/mobile/")
        XCTAssertEqual(LinkProtocol.downloadPage(for: "en"), "https://bulava.app/mobile/")
        XCTAssertEqual(LinkProtocol.downloadPage(for: "ru"), "https://bulava.app/mobile/",
                       "the site has no Russian page; English is its default")
        XCTAssertEqual(LinkProtocol.downloadPage(for: nil), "https://bulava.app/mobile/")
    }

    func testTheSiteRendersBothPages() throws {
        let render = Self.site.appendingPathComponent("render.py")
        guard FileManager.default.fileExists(atPath: render.path) else {
            throw XCTSkip("the site is not in this checkout")
        }
        let script = try String(contentsOf: render, encoding: .utf8)
        XCTAssertTrue(script.contains(#"os.path.join("mobile", "index.html")"#),
                      "render.py no longer renders /mobile/ — the panel's link would lead nowhere")
        XCTAssertTrue(script.contains(#""uk": "/uk/""#), "and the Ukrainian pages live under /uk/")
    }
}
