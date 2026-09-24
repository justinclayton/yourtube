import XCTest
@testable import YourTube

final class SubscriptionTests: XCTestCase {
    /// The UC -> UULF rewrite is what lets a feed refresh skip a
    /// `channels.list` call per channel and fetch only long-form uploads,
    /// with no Shorts or live streams ever entering the store. If YouTube
    /// ever changes this, refreshes break wholesale.
    func testUploadsPlaylistIdRewritesPrefix() {
        XCTAssertEqual(
            Subscription.uploadsPlaylistId(forChannelId: "UCBJycsmduvYEL83R_U4JriQ"),
            "UULFBJycsmduvYEL83R_U4JriQ"
        )
    }

    func testNonChannelIdIsLeftAlone() {
        XCTAssertEqual(Subscription.uploadsPlaylistId(forChannelId: "PLabc"), "PLabc")
        XCTAssertEqual(Subscription.uploadsPlaylistId(forChannelId: "UC"), "UC")
        XCTAssertEqual(Subscription.uploadsPlaylistId(forChannelId: ""), "")
    }
}
