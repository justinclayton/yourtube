import XCTest
import SwiftData
@testable import YourTube

/// The counts the UI used to get from live queries over the whole `Video`
/// table, now read from the store a question at a time (issue #66). What's
/// under test is that the cheap answer is the same answer: the Channels
/// badges still ignore Shorts when Shorts are hidden, and the Your Shows
/// badges still respect segments and the retention window, because they still
/// run the same pure pass — just over a narrower fetch.
@MainActor
final class StoreCountsTests: XCTestCase {
    private var container: ModelContainer!
    private var context: ModelContext { container.mainContext }
    private var manager: ShowManager!

    override func setUp() async throws {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        container = try ModelContainer(
            for: Video.self, Subscription.self, VideoCollection.self, ChannelRule.self, Show.self,
            configurations: config
        )
        manager = ShowManager(modelContext: context, watchState: WatchState(modelContext: context))
    }

    @discardableResult
    private func video(
        _ id: String,
        channelId: String,
        daysAgo: Double = 1,
        seconds: Int = 2_400,
        short: Bool = false,
        watched: Bool = false
    ) -> Video {
        let video = Video(
            videoId: id,
            channelId: channelId,
            channelTitle: channelId,
            title: id,
            videoDescription: "",
            publishedAt: Date(timeIntervalSinceNow: -daysAgo * 86_400),
            durationSeconds: seconds,
            isLikelyShort: short,
            isWatched: watched
        )
        context.insert(video)
        return video
    }

    private func allVideos() throws -> [Video] {
        try context.fetch(FetchDescriptor<Video>())
    }

    // MARK: - Settings

    func testLibraryCountsEveryVideoAndSubscription() throws {
        context.insert(Subscription(channelId: "UC-a", title: "A"))
        context.insert(Subscription(channelId: "UC-b", title: "B"))
        video("v1", channelId: "UC-a")
        video("v2", channelId: "UC-a", short: true)
        video("v3", channelId: "UC-b", short: true)
        try context.save()

        let counts = try StoreCounts.library(in: context)

        XCTAssertEqual(counts.subscriptions, 2)
        XCTAssertEqual(counts.videos, 3)
        XCTAssertEqual(counts.shorts, 2)
    }

    func testLibraryCountsAreZeroOnAnEmptyStore() throws {
        XCTAssertEqual(try StoreCounts.library(in: context), LibraryCounts())
    }

    // MARK: - Channels

    func testUnwatchedByChannelCountsPerChannel() throws {
        video("a1", channelId: "UC-a")
        video("a2", channelId: "UC-a")
        video("a3", channelId: "UC-a", watched: true)
        video("b1", channelId: "UC-b")
        try context.save()

        let counts = try StoreCounts.unwatchedByChannel(in: context, includingShorts: false)

        XCTAssertEqual(counts["UC-a"], 2)
        XCTAssertEqual(counts["UC-b"], 1)
    }

    func testUnwatchedByChannelFollowsTheShortsSetting() throws {
        video("a1", channelId: "UC-a")
        video("a2", channelId: "UC-a", short: true)
        try context.save()

        XCTAssertEqual(
            try StoreCounts.unwatchedByChannel(in: context, includingShorts: false)["UC-a"],
            1
        )
        XCTAssertEqual(
            try StoreCounts.unwatchedByChannel(in: context, includingShorts: true)["UC-a"],
            2
        )
    }

    func testUnwatchedByChannelLeavesOutChannelsWithNothingUnwatched() throws {
        video("a1", channelId: "UC-a", watched: true)
        try context.save()

        XCTAssertNil(try StoreCounts.unwatchedByChannel(in: context, includingShorts: false)["UC-a"])
    }

    // MARK: - Your Shows badges

    func testShowBadgeCountsOnlyTheShowsOwnChannel() throws {
        let show = try manager.markAsShow(channelId: "UC-a", channelTitle: "A")
        video("a1", channelId: "UC-a")
        video("a2", channelId: "UC-a")
        video("a3", channelId: "UC-a", watched: true)
        video("a4", channelId: "UC-a", short: true)
        // A channel that isn't a show, with plenty unwatched, must not leak in.
        for i in 0..<20 { video("b\(i)", channelId: "UC-b") }
        try context.save()

        let counts = try manager.unwatchedCounts(for: [show])

        XCTAssertEqual(counts[show.id], 2)
        XCTAssertEqual(counts, ShowListing.unwatchedCounts(from: try allVideos(), shows: [show]))
    }

    func testShowBadgeRespectsSegmentsAndRetention() throws {
        let show = try manager.markAsShow(channelId: "UC-a", channelTitle: "A")
        // Three full episodes and two cut-downs, all unwatched. Segments are
        // never episodes, so the badge counts three.
        for i in 0..<3 { video("full\(i)", channelId: "UC-a", daysAgo: Double(i), seconds: 3_600) }
        for i in 0..<2 { video("clip\(i)", channelId: "UC-a", daysAgo: Double(i), seconds: 300) }
        try context.save()

        XCTAssertEqual(try manager.unwatchedCounts(for: [show])[show.id], 3)

        show.retentionCount = 1
        try context.save()

        XCTAssertEqual(try manager.unwatchedCounts(for: [show])[show.id], 1)
        XCTAssertEqual(
            try manager.unwatchedCounts(for: [show]),
            ShowListing.unwatchedCounts(from: try allVideos(), shows: [show])
        )
    }

    func testShowBadgeCountsAPlaylistBackedShowsMembersFromAnyChannel() throws {
        let show = Show(
            source: .playlist(id: "PL-1", channelId: "UC-a"),
            title: "Podcast",
            flagOrigin: .user
        )
        show.playlistItemIds = ["PL-1": ["guest1", "a1"]]
        context.insert(show)
        video("a1", channelId: "UC-a")
        video("guest1", channelId: "UC-guest")
        video("guest2", channelId: "UC-guest")
        video("a2", channelId: "UC-a", watched: true)
        try context.save()

        let counts = try manager.unwatchedCounts(for: [show])

        XCTAssertEqual(counts[show.id], 2)
        XCTAssertEqual(counts, ShowListing.unwatchedCounts(from: try allVideos(), shows: [show]))
    }

    func testShowBadgeCountsAreZeroWhenTheCatalogueHasNoVideosYet() throws {
        let show = try manager.markAsShow(channelId: "UC-a", channelTitle: "A")
        try context.save()

        XCTAssertEqual(try manager.unwatchedCounts(for: [show]), [show.id: 0])
    }

    func testShowBadgeCountsForAnEmptyCatalogue() throws {
        XCTAssertEqual(try manager.unwatchedCounts(for: []), [:])
    }
}
