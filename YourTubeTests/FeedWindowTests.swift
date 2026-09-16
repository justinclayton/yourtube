import XCTest
@testable import YourTube

/// The feed's paging arithmetic (issue #66): how many inbox rows the list asks
/// the store for, and when it offers the row that asks for more.
final class FeedWindowTests: XCTestCase {
    func testStartsAtOnePage() {
        XCTAssertEqual(FeedWindow().limit, FeedWindow.pageSize)
    }

    func testShowingOlderAddsAPage() {
        var window = FeedWindow()
        window.showOlder()
        XCTAssertEqual(window.limit, FeedWindow.pageSize * 2)
        window.showOlder()
        XCTAssertEqual(window.limit, FeedWindow.pageSize * 3)
    }

    func testOffersOlderOnlyWhenThePageCameBackFull() {
        let window = FeedWindow()
        XCTAssertFalse(window.hasOlder(loaded: 0))
        XCTAssertFalse(window.hasOlder(loaded: FeedWindow.pageSize - 1))
        XCTAssertTrue(window.hasOlder(loaded: FeedWindow.pageSize))
    }

    func testAnOpenedWindowStopsOfferingOlderOnceTheStoreRunsOut() {
        var window = FeedWindow()
        window.showOlder()
        XCTAssertFalse(window.hasOlder(loaded: FeedWindow.pageSize))
        XCTAssertTrue(window.hasOlder(loaded: FeedWindow.pageSize * 2))
    }
}
