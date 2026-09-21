import XCTest
import SwiftUI
import AppKit
@testable import Bulava

nonisolated final class ProseFitsTests: XCTestCase {

    @MainActor private func demandedWidth(_ text: String, offered width: CGFloat) -> CGFloat {

        let host = NSHostingView(rootView: MarkdownProse(text: text))
        host.frame = NSRect(x: 0, y: 0, width: width, height: 4000)
        host.layoutSubtreeIfNeeded()
        func deepest(_ view: NSView, offset: CGFloat) -> CGFloat {
            view.subviews.reduce(offset + view.frame.maxX) { widest, sub in
                max(widest, deepest(sub, offset: offset + view.frame.minX))
            }
        }
        return host.subviews.reduce(0) { max($0, deepest($1, offset: 0)) }
    }

    @MainActor private func renderedWidth(_ text: String, offered width: CGFloat) throws -> CGFloat {
        demandedWidth(text, offered: width)
    }

    private static let longCodeLine = """
    Ось що вийде:

    ```swift
    guard moment.visibleEvents > 0, moment.connectivity != .offline, let last = moment.lastPromptDate, days(last, moment.now) >= minDaysBetweenPrompts else { return .hold(.tooSoonAfterLastPrompt) }
    ```
    """

    private static let wideTable = """
    | Було | Стало | Чому | Де | Ким перевірено |
    |---|---|---|---|---|
    | `.ascii` повертав nil на кирилиці | `.utf8` з BOM | Excel на Windows читає cp1251 | ExportService.swift | рантайм-прогоном на реальному файлі |
    """

    private static let longPath = """
    Шлях: `/Users/dev/Developer/Projects/Weather Alerts/Weather Alerts/Services/RatingPromptService+Diagnostics.swift`
    """

    // MARK: -

    @MainActor
    func testAVeryLongCodeLineStaysInsideTheColumn() throws {
        let offered: CGFloat = 420
        let width = try renderedWidth(Self.longCodeLine, offered: offered)
        XCTAssertLessThanOrEqual(width, offered + 1,
                                 "a fenced line \(Int(width))pt wide in a \(Int(offered))pt column pushes the window's own panels off screen")
    }

    @MainActor
    func testAWideTableStaysInsideTheColumn() throws {
        let offered: CGFloat = 420
        let width = try renderedWidth(Self.wideTable, offered: offered)
        XCTAssertLessThanOrEqual(width, offered + 1, "a five-column table decided how wide the window is")
    }

    @MainActor
    func testAnUnbreakableFilePathStaysInsideTheColumn() throws {
        let offered: CGFloat = 420
        let width = try renderedWidth(Self.longPath, offered: offered)
        XCTAssertLessThanOrEqual(width, offered + 1, "a long path with no spaces widened the column")
    }

    @MainActor
    func testOrdinaryProseRendersSomething() throws {
        let width = try renderedWidth("Полагодив: `.utf8` замість `.ascii`, плюс тест.", offered: 420)
        XCTAssertGreaterThan(width, 100)
    }
}
