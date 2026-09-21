import XCTest
@testable import Bulava

nonisolated final class ReportIsOneDocumentTests: XCTestCase {

    private func manifest(_ json: String) -> ReportManifest {
        try! JSONDecoder().decode(ReportManifest.self, from: Data(json.utf8))
    }

    func testAVisualReportStillPrintsItsWrittenAccount() {
        let m = manifest("""
        {"format":"photos","title":"Фідбек","summary":"Коротко",
         "body":"## Що не закрито\\n\\nМультивибір типів рішень заблокований бекендом.",
         "items":[{"caption":"крок 4","before":"b.png","after":"a.png"}]}
        """)
        let html = ReportHTML.page(m, fallbackTitle: "—")
        XCTAssertTrue(html.contains("Мультивибір типів рішень заблокований бекендом"),
                      "the written report was dropped from a report that had frames")
        XCTAssertTrue(html.contains("<h2>Що не закрито</h2>"), "a heading did not render as a heading")
        XCTAssertTrue(html.contains("b.png") && html.contains("a.png"), "the frames were lost")
        XCTAssertFalse(html.contains("Nothing visual"), "an honest report was called empty")
    }

    func testANumberedListKeepsTheNumbersHeWrote() {
        let m = manifest("""
        {"format":"notes","title":"t",
         "body":"7. Ціни — заблоковано: ASC-ключ дає 401.\\n8. Кнопка «Новий пошук» — закрито."}
        """)
        let html = ReportHTML.page(m, fallbackTitle: "—")
        XCTAssertTrue(html.contains("<ol start=\"7\">"),
                      "the list restarted at 1, so «7» stopped meaning step seven")
        XCTAssertTrue(html.contains("ASC-ключ дає 401"))
    }

    func testWhatNeedsHisDecisionIsRenderedFirst() {
        let m = manifest("""
        {"format":"photos","title":"t","body":"текст",
         "attention":["Влити гілку в main чи лишити як є?"],
         "items":[{"caption":"c","after":"a.png"}]}
        """)
        let html = ReportHTML.page(m, fallbackTitle: "—")
        let attn = html.range(of: "Влити гілку в main")
        let prose = html.range(of: "текст")
        XCTAssertNotNil(attn, "the decision he has to make is not in the document")
        XCTAssertTrue(attn!.lowerBound < prose!.lowerBound, "it is buried below the account")
    }

    func testATableRendersAsATable() {
        let m = manifest("""
        {"format":"notes","title":"t",
         "body":"| Магазин | Тариф | Ціна |\\n|---|---|---|\\n| Google Play | Pro | 499 UAH |"}
        """)
        let html = ReportHTML.page(m, fallbackTitle: "—")
        XCTAssertTrue(html.contains("<table class=\"doc\">"), "the price table came out as prose")
        XCTAssertTrue(html.contains("<th>Магазин</th>"))
        XCTAssertTrue(html.contains("<td>499 UAH</td>"))
        XCTAssertFalse(html.contains("|---|"), "the markdown separator row leaked into the page")
    }

    func testMarkupIsRenderedAndHTMLIsNot() {
        let m = manifest("""
        {"format":"notes","title":"t",
         "body":"**Головне**: `decision_type` — скаляр.\\n\\n<script>alert(1)</script>"}
        """)
        let html = ReportHTML.page(m, fallbackTitle: "—")
        XCTAssertTrue(html.contains("<strong>Головне</strong>"))
        XCTAssertTrue(html.contains("<code>decision_type</code>"))
        XCTAssertFalse(html.contains("<script>alert"), "worker text was allowed to inject HTML")
        XCTAssertTrue(html.contains("&lt;script&gt;"), "and it should still be visible as text")
    }

    func testEvidenceIsDrivenByWhatExistsNotByTheLabel() {
        let m = manifest("""
        {"format":"notes","title":"t","body":"розповідь",
         "video":"demo.mp4","items":[{"caption":"c","before":"b.png","after":"a.png"}]}
        """)
        let html = ReportHTML.page(m, fallbackTitle: "—")
        XCTAssertTrue(html.contains("demo.mp4"), "a recording labelled otherwise was dropped")
        XCTAssertTrue(html.contains("b.png"), "frames labelled otherwise were dropped")
        XCTAssertTrue(html.contains("розповідь"))
    }

    func testAnEmptyReportSaysSo() {
        let html = ReportHTML.page(manifest("{\"format\":\"notes\",\"title\":\"t\"}"), fallbackTitle: "—")
        XCTAssertTrue(html.contains("class=\"empty\""))
    }

    func testAWrittenReportCountsAsContent() {
        XCTAssertTrue(manifest("{\"format\":\"photos\",\"body\":\"є що сказати\"}").hasContent)
        XCTAssertFalse(manifest("{\"format\":\"photos\"}").hasContent)
    }

    // MARK: - Answered item by item, in his numbers

    func testEachThingHeAskedForIsItsOwnAnsweredSection() {
        let m = manifest("""
        {"format":"photos","title":"Фідбек",
         "sections":[
          {"ref":"3","title":"Зірочки в цитатах","status":"closed","body":"Було сиро, стало курсивом.",
           "items":[{"caption":"пункт 3","before":"b3.png","after":"a3.png"}]},
          {"ref":"5","title":"PDF, Word і копіювання","status":"закрито",
           "body":"Вирівнювання по ширині в обох. Кадру немає: це вивантажений файл, не екран."},
          {"ref":"10","title":"Синхронізація засідань","status":"заблоковано",
           "body":"Роут не задеплоєний на прод — 404."}]}
        """)
        let html = ReportHTML.page(m, fallbackTitle: "—")
        XCTAssertTrue(html.contains("<span class=\"num\">3. Зірочки в цитатах</span>"),
                      "his own number is not the heading")
        XCTAssertTrue(html.contains("5. PDF, Word і копіювання"), "the item he could not find is still not findable")

        XCTAssertTrue(html.contains("answer closed"))
        XCTAssertTrue(html.contains("answer blocked"), "«заблоковано» was not understood as blocked")

        let five = html.range(of: "5. PDF")!.lowerBound
        let three = html.range(of: "b3.png")!.lowerBound
        XCTAssertTrue(three < five, "the frame for item 3 was moved away from item 3")
    }

    func testEvidenceIsNotShownTwice() {
        let m = manifest("""
        {"format":"photos","title":"t",
         "sections":[{"ref":"1","status":"closed","items":[{"caption":"c","before":"b.png","after":"a.png"}]}],
         "items":[{"caption":"c","before":"b.png","after":"a.png"},
                  {"caption":"інше","after":"z.png"}]}
        """)
        let html = ReportHTML.page(m, fallbackTitle: "—")
        XCTAssertEqual(html.components(separatedBy: "a.png").count - 1, 1,
                       "the same frame was printed under its answer AND in the gallery")
        XCTAssertTrue(html.contains("z.png"), "a frame that belongs to no answer was dropped")
    }

    func testAnUnknownStatusIsNotAPass() {
        let m = manifest("{\"format\":\"notes\",\"sections\":[{\"ref\":\"9\",\"status\":\"хтозна\"}]}")
        XCTAssertEqual(m.sections?.first?.status, .unknown)
        XCTAssertFalse(ReportHTML.page(m, fallbackTitle: "—").contains("answer closed"))
    }

    func testBoldAndCodeInTheSameLineBothClose() {
        let m = manifest("""
        {"format":"notes","title":"t",
         "body":"**Вирівнювання по ширині зроблено в обох каналах** (`f0513ec`):"}
        """)
        let html = ReportHTML.page(m, fallbackTitle: "—")
        XCTAssertTrue(html.contains("<strong>Вирівнювання по ширині зроблено в обох каналах</strong>"),
                      "the bold run did not close")
        XCTAssertTrue(html.contains("<code>f0513ec</code>"))
        XCTAssertFalse(html.contains("**"), "raw asterisks were printed — in a report about raw asterisks")
    }

    func testAnUnmatchedMarkerStaysAsText() {
        let html = ReportHTML.page(manifest("{\"format\":\"notes\",\"body\":\"2 ** 8 = 256\"}"),
                                   fallbackTitle: "—")
        XCTAssertTrue(html.contains("2 ** 8 = 256"))
        XCTAssertFalse(html.contains("<strong>"))
    }

    func testBoldSurvivesALineWrap() {
        let m = manifest("""
        {"format":"notes","body":"Тобто **спільного\\nсерверного сховища не існує**, і це наслідок."}
        """)
        let html = ReportHTML.page(m, fallbackTitle: "—")
        XCTAssertTrue(html.contains("<strong>спільного<br>серверного сховища не існує</strong>"),
                      "a bold run wrapped across lines printed its asterisks")
        XCTAssertFalse(html.contains("**"))
    }
}
