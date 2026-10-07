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
        /// How wide the thread is. A change of width re-measures every row — see `advance`.
        var viewportWidth: CGFloat = 0

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

    /// Find took the reader to a result and they are to stay on it.
    ///
    /// Stronger than "they scrolled away", and it has to be: a result forty points from the end
    /// is inside the slack, so the ordinary rule would decide the reader is at the bottom and the
    /// next chunk of the answer would drag the thread straight back down. Only three things
    /// release it: closing Find, their own message, and their own hand on the trackpad.
    private(set) var pinned = false

    init(following: Bool = true) { self.following = following }

    /// Take a new reading. Returns true when the thread should scroll to the end.
    ///
    /// A lazy thread re-measures rows it had only estimated: its content height jumps, and a
    /// reading later the offset is pulled up with nobody touching anything. Read as the reader
    /// leaving, that stopped the thread following its own answer for good. So an offset that drops
    /// in the reading right after the height changed is the layout settling — unless a hand is on
    /// the trackpad (`byHand`). A hand that starts scrolling while nothing is being re-measured is
    /// believed at once: its phase arrives a frame or two after the offset has already moved.
    private var heightJustChanged = false

    /// Readings still to come of a thread re-measuring itself after its width changed.
    ///
    /// A narrower window, or the side panel opening, re-measures every row at once: over the next
    /// several readings the content height and the offset jump together, by thousands of points in
    /// a long chat. "Both at once" is otherwise how a hand scrolling while the answer grows looks,
    /// so the thread stopped following its own answer every time the window changed width — and,
    /// when the lazy stack went blank on the way, was put back in the middle instead of at the end.
    /// A width change is never his hand; his hand is still believed through its scroll phase.
    private var relayoutReadings = 0
    static let relayoutWindow = 12

    @discardableResult
    mutating func advance(from old: Frame, to new: Frame, byHand: Bool = false) -> Bool {
        guard !pinned else { return false }
        let resized = abs(new.contentHeight - old.contentHeight) > 0.5
        let shrank = new.contentHeight < old.contentHeight - 0.5
        let scrolledUp = new.offsetY < old.offsetY - Self.deadband
        // The pattern is two readings: the height moves, then the offset follows it. A reading that
        // moves both at once is a hand scrolling while the answer grows, and that is believed.
        let settling = heightJustChanged && !resized
        heightJustChanged = resized
        if abs(new.viewportWidth - old.viewportWidth) > 0.5 { relayoutReadings = Self.relayoutWindow }
        let relayingOut = relayoutReadings > 0
        if relayoutReadings > 0 { relayoutReadings -= 1 }

        if new.distanceFromBottom <= Self.slack {
            // Back at the end — by hand or because the tail caught up. Either way, follow again.
            following = true
        } else if scrolledUp && !shrank && (byHand || (!settling && !relayingOut)) {
            // Content that collapses (a disclosure closing) drags the offset up on its own; that
            // is the layout moving, not the reader.
            following = false
        }
        return following
    }

    /// Their own message always brings them back, wherever they were reading — and whatever Find
    /// had pinned them to.
    mutating func rejoin() {
        pinned = false
        following = true
    }

    /// Hold the thread where a find jump put it.
    mutating func pin() {
        pinned = true
        following = false
    }

    /// Hand the thread back to the ordinary rule: the next reading decides whether the reader is
    /// at the end and the answer may follow again.
    mutating func unpin() { pinned = false }
}
