import XCTest
@testable import Bulava

/// The Markdown an agent writes for the director, as a page a phone can read — and never a page
/// that runs anything.
nonisolated final class MarkdownHTMLTests: XCTestCase {

    func testTheShapesAReportUses() {
        let html = MarkdownHTML.body("""
        # Підсумок

        Перший абзац з **жирним**, *курсивом*, `кодом` і ~~закресленим~~.
        Другий рядок того ж абзацу.

        ## Таблиця

        | Що | Результат | Час |
        |---|:---:|---:|
        | Профіль | ✅ | 33 мс |
        | Пайп `a\\|b` | ✅ | 2 мс |

        - перше
          - вкладене
        - друге

        1. раз
        2. два

        > цитата

        ```swift
        let x = "<b>"
        ```

        ---
        """)
        XCTAssertTrue(html.contains("<h1>Підсумок</h1>"))
        XCTAssertTrue(html.contains("<strong>жирним</strong>"))
        XCTAssertTrue(html.contains("<em>курсивом</em>"))
        XCTAssertTrue(html.contains("<code>кодом</code>"))
        XCTAssertTrue(html.contains("<del>закресленим</del>"))
        XCTAssertTrue(html.contains("<p>Перший абзац"), html)
        XCTAssertTrue(html.contains("<th style=\"text-align:center\">Результат</th>"))
        XCTAssertTrue(html.contains("<td style=\"text-align:right\">33 мс</td>"))
        XCTAssertTrue(html.contains("<code>a|b</code>"), "a pipe inside code stays in its cell")
        XCTAssertTrue(html.contains("<ul><li>перше<ul><li>вкладене</li></ul></li><li>друге</li></ul>"), html)
        XCTAssertTrue(html.contains("<ol><li>раз</li><li>два</li></ol>"))
        XCTAssertTrue(html.contains("<blockquote><p>цитата</p></blockquote>"))
        XCTAssertTrue(html.contains("<pre><code class=\"language-swift\">let x = &quot;&lt;b&gt;&quot;</code></pre>"))
        XCTAssertTrue(html.contains("<hr>"))
    }

    func testNothingInTheSourceBecomesMarkup() {
        let html = MarkdownHTML.body("""
        <script>alert(1)</script>

        [click](javascript:alert(1)) [data](data:text/html,x) [root](/etc/passwd) [ok](notes/plan.md)

        ![pic](javascript:alert(1)) ![shot](shots/a.png) <javascript:alert(1)> <https://bulava.app>

        snake_case_name stays as it is
        """)
        XCTAssertFalse(html.contains("<script"), html)
        XCTAssertTrue(html.contains("&lt;script&gt;"))
        let lower = html.lowercased()
        XCTAssertFalse(lower.contains("href=\"javascript") || lower.contains("src=\"javascript"),
                       "no javascript: address survives as one (as text it is only text): \(html)")
        XCTAssertTrue(MarkdownHTML.body("[wiki](https://en.wikipedia.org/wiki/Bulava_(missile))")
            .contains("href=\"https://en.wikipedia.org/wiki/Bulava_(missile)\""), "parentheses inside an address")
        XCTAssertFalse(html.contains("href=\"data:"))
        XCTAssertFalse(html.contains("href=\"/etc/passwd\""), "nothing addressed from the server's root")
        XCTAssertTrue(html.contains("<a href=\"notes/plan.md\">ok</a>"))
        XCTAssertTrue(html.contains("<img src=\"shots/a.png\" alt=\"shot\""))
        XCTAssertTrue(html.contains("<a href=\"https://bulava.app\">https://bulava.app</a>"))
        XCTAssertTrue(html.contains("snake_case_name stays"), html)
    }

    func testAPageIsSelfContained() {
        let page = MarkdownHTML.page(title: "План <нічний>", markdown: "# Привіт")
        XCTAssertTrue(page.hasPrefix("<!doctype html>"))
        XCTAssertTrue(page.contains("<title>План &lt;нічний&gt;</title>"))
        XCTAssertTrue(page.contains("<meta name=\"viewport\""))
        XCTAssertFalse(page.contains("<script"), "a rendered note runs nothing")
        XCTAssertFalse(page.contains("http://") || page.contains("https://"), "and loads nothing from anywhere")
    }

    func testSafeURLs() {
        XCTAssertEqual(MarkdownHTML.safeURL("https://x.y/z"), "https://x.y/z")
        XCTAssertEqual(MarkdownHTML.safeURL("mailto:a@b.c"), "mailto:a@b.c")
        XCTAssertEqual(MarkdownHTML.safeURL("#part"), "#part")
        XCTAssertEqual(MarkdownHTML.safeURL("img/a b.png"), "img/a b.png")
        XCTAssertNil(MarkdownHTML.safeURL("JavaScript:alert(1)"))
        XCTAssertNil(MarkdownHTML.safeURL("vbscript:x"))
        XCTAssertNil(MarkdownHTML.safeURL("file:///etc/passwd"))
        XCTAssertNil(MarkdownHTML.safeURL("//evil.example/x"))
        XCTAssertNil(MarkdownHTML.safeURL("/abs"))
    }
}
