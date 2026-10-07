import SwiftUI

// MARK: - The one place the prose styles are written down

/// The fonts and sizes the agent's prose is set in.
///
/// Read by `ProseDocument`, which draws the prose — tables and pictures included — as one
/// selectable text.
///
/// Marking the phrase Find is looking for is no longer a matter of redrawing a paragraph: the
/// prose is an `NSTextView`, and the marks are temporary attributes of its layout manager (see
/// `ProseNSTextView.mark`) — drawn over the text, never part of its layout, so typing a query
/// cannot move a line of the answer.
nonisolated enum ProseStyle {
    static let bodySize: CGFloat = 13.5
    static let inlineCodeSize: CGFloat = 12
    static let codeBlockSize: CGFloat = 11.5

    static let bodyLineSpacing = 0.22
    static let codeBlockLineSpacing = 0.2

    /// The point size MarkdownUI resolves a `FontSize` to: `Font.withProperties` takes
    /// `round(size * scale)`, so a `FontSize(13.5)` comes out as a 14pt face. The text view draws
    /// at the same rounded sizes, so a table drawn by the library and the paragraph above it
    /// drawn by the app are set in the same type.
    static func drawn(_ size: CGFloat) -> CGFloat { size.rounded() }

    static func headingSize(_ level: Int) -> CGFloat {
        switch level {
        case 1:  16
        case 2:  14.5
        default: 13.5
        }
    }
}
