import XCTest
@testable import YourTube

/// Covers the pure latch logic `FeedVideoRow` relies on for issue #68's
/// Done-when: a visible feed row's title does not change while it stays on
/// screen during a rewrite batch. The SwiftUI row itself just wires this
/// into `@State`/`onAppear`, so the behaviour worth pinning down here is the
/// latch, independent of the view lifecycle.
final class TitleLatchTests: XCTestCase {
    func testBeforeCaptureDisplaysTheCurrentTitle() {
        let latch = TitleLatch()
        XCTAssertEqual(latch.displayTitle(current: "Raw Title"), "Raw Title")
    }

    func testCaptureLatchesTheTitleAtThatMoment() {
        var latch = TitleLatch()
        latch.capture("Cleaned Title")
        XCTAssertEqual(latch.displayTitle(current: "Cleaned Title"), "Cleaned Title")
    }

    /// The Done-when itself: once latched, a rewrite that changes the
    /// underlying title doesn't change what the row displays.
    func testDisplayIgnoresLaterChangesToCurrentOnceLatched() {
        var latch = TitleLatch()
        latch.capture("Original Cleaned Title")
        XCTAssertEqual(latch.displayTitle(current: "Rewritten Title"), "Original Cleaned Title")
    }

    /// A row that scrolls onto screen again without being recreated should
    /// not re-latch onto whatever title happens to be current then either —
    /// `capture` is a no-op once a value is set.
    func testCaptureIsIdempotent() {
        var latch = TitleLatch()
        latch.capture("First")
        latch.capture("Second")
        XCTAssertEqual(latch.displayTitle(current: "Third"), "First")
    }

    /// A fresh `TitleLatch` is what a recreated row gets (new `@State`
    /// storage), so the new title should show — this is the "list recreates
    /// the row" half of the Done-when.
    func testAFreshLatchPicksUpTheNewTitle() {
        let recreated = TitleLatch()
        XCTAssertEqual(recreated.displayTitle(current: "Rewritten Title"), "Rewritten Title")
    }
}
