import CoreGraphics

/// Whether the thread keeps following its own tail.
///
/// The first version of this asked one question — "is the reader at the bottom right now?" — and
/// that question cannot be answered while the answer is still being written. A streaming chunk
/// adds height at the bottom, so the instant it arrives the reader IS no longer at the bottom;
/// the geometry callback then set `atBottom = false`, and the scroll that was supposed to follow
/// was skipped by its own guard. One long chunk was enough to stop following for the rest of the
/// turn, which is exactly what he saw: the agent works, the text grows below the fold, and nothing
/// moves.
///
/// So the question here is the other one: *did the reader scroll away?* Content appended at the
/// bottom never lowers the scroll offset — only a hand on the trackpad does. That distinguishes
/// the two cases without asking the reader to be at any particular place.
nonisolated struct TailFollow: Equatable, Sendable {

    /// A reading of the scroll view, as the geometry callback sees it.
    struct Frame: Equatable, Sendable {
        var offsetY: CGFloat
        var contentHeight: CGFloat
        var viewportHeight: CGFloat

        var distanceFromBottom: CGFloat {
            max(0, contentHeight - viewportHeight - offsetY)
        }
    }

    /// A thread one line short of the end still counts as being at the end, so following does not
    /// stop over a rounding difference or a hairline.
    static let slack: CGFloat = 40

    /// Ignore sub-pixel jitter: a layout pass can move the offset by a fraction with nobody
    /// touching anything.
    static let deadband: CGFloat = 1

    private(set) var following = true

    init(following: Bool = true) { self.following = following }

    /// Take a new reading. Returns true when the thread should scroll to the end.
    @discardableResult
    mutating func advance(from old: Frame, to new: Frame) -> Bool {
        let shrank = new.contentHeight < old.contentHeight - 0.5
        let scrolledUp = new.offsetY < old.offsetY - Self.deadband

        if new.distanceFromBottom <= Self.slack {
            // Back at the end — by hand or because the tail caught up. Either way, follow again.
            following = true
        } else if scrolledUp && !shrank {
            // Content that collapses (a disclosure closing) drags the offset up on its own; that
            // is the layout moving, not the reader.
            following = false
        }
        return following
    }

    /// Their own message always brings them back, wherever they were reading.
    mutating func rejoin() { following = true }
}
