import XCTest
@testable import Bulava

/// The thread has to keep following an answer that is still being written.
///
/// The bug this pins down: an answer grows at the bottom, so the reader is momentarily no longer
/// "at the bottom", and the old check read that as "he scrolled up" and stopped following for the
/// rest of the turn. Every one of these cases is a sequence of scroll-geometry readings — the same
/// readings SwiftUI hands the view — so the decision can be tested without a window.
nonisolated final class TailFollowsTheAnswerTests: XCTestCase {

    /// Viewport 500pt tall, pinned to the end of a thread `height` tall.
    private func atEnd(_ height: CGFloat, viewport: CGFloat = 500) -> TailFollow.Frame {
        TailFollow.Frame(offsetY: max(0, height - viewport), contentHeight: height,
                         viewportHeight: viewport)
    }

    func testAGrowingAnswerKeepsFollowing() {
        var follow = TailFollow()
        var frame = atEnd(1000)

        // Twenty chunks of streamed text, 60pt each — more than the slack, which is what broke it.
        for _ in 0..<20 {
            let grown = TailFollow.Frame(offsetY: frame.offsetY,
                                         contentHeight: frame.contentHeight + 60,
                                         viewportHeight: frame.viewportHeight)
            XCTAssertTrue(follow.advance(from: frame, to: grown),
                          "a chunk of the answer must not be read as the reader scrolling away")
            // Following means it caught up, so the next reading is pinned again.
            frame = atEnd(grown.contentHeight)
            XCTAssertTrue(follow.advance(from: grown, to: frame))
        }
        XCTAssertTrue(follow.following)
    }

    func testScrollingUpToReadStopsTheThreadMovingUnderHim() {
        var follow = TailFollow()
        let pinned = atEnd(2000)
        let scrolledBack = TailFollow.Frame(offsetY: pinned.offsetY - 700,
                                            contentHeight: 2000, viewportHeight: 500)
        XCTAssertFalse(follow.advance(from: pinned, to: scrolledBack))
        XCTAssertFalse(follow.following)

        // And it stays put while the answer keeps growing below him.
        let grew = TailFollow.Frame(offsetY: scrolledBack.offsetY, contentHeight: 2600,
                                    viewportHeight: 500)
        XCTAssertFalse(follow.advance(from: scrolledBack, to: grew))
    }

    func testScrollingUpWhileTheAnswerGrowsIsStillTheReader() {
        var follow = TailFollow()
        let pinned = atEnd(2000)
        // One reading that carries both: he dragged up 300pt and 80pt of text arrived.
        let both = TailFollow.Frame(offsetY: pinned.offsetY - 300, contentHeight: 2080,
                                    viewportHeight: 500)
        XCTAssertFalse(follow.advance(from: pinned, to: both))
    }

    func testComingBackToTheEndFollowsAgain() {
        var follow = TailFollow(following: false)
        let away = TailFollow.Frame(offsetY: 800, contentHeight: 2000, viewportHeight: 500)
        XCTAssertTrue(follow.advance(from: away, to: atEnd(2000)))
        XCTAssertTrue(follow.following)
    }

    func testCollapsingSomethingDoesNotCountAsScrollingAway() {
        var follow = TailFollow()
        let pinned = atEnd(3000)
        // A disclosure closes: the thread gets shorter and the offset is clamped down with it.
        let collapsed = TailFollow.Frame(offsetY: 1200, contentHeight: 1700, viewportHeight: 500)
        XCTAssertTrue(follow.advance(from: pinned, to: collapsed),
                      "the layout shrinking is not a hand on the trackpad")
    }

    func testSubPixelJitterIsIgnored() {
        var follow = TailFollow()
        let pinned = TailFollow.Frame(offsetY: 1500.0, contentHeight: 2000, viewportHeight: 500)
        let jittered = TailFollow.Frame(offsetY: 1499.6, contentHeight: 2000, viewportHeight: 500)
        XCTAssertTrue(follow.advance(from: pinned, to: jittered))
    }

    func testHisOwnMessageBringsHimBack() {
        var follow = TailFollow(following: false)
        follow.rejoin()
        XCTAssertTrue(follow.following)
    }

    func testAThreadShorterThanTheViewportIsAlwaysAtTheEnd() {
        var follow = TailFollow(following: false)
        let short = TailFollow.Frame(offsetY: 0, contentHeight: 200, viewportHeight: 500)
        XCTAssertTrue(follow.advance(from: short, to: short))
    }
}
