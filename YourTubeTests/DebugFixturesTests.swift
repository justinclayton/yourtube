import XCTest
import SwiftData
@testable import YourTube

/// The fixture store is what a simulator run without a login sees, so it has
/// to open cleanly and contain the awkward cases search is meant to handle.
@MainActor
final class DebugFixturesTests: XCTestCase {
    func testFixturesSeedSubscriptionsRulesAndVideos() throws {
        let container = try DebugFixtures.makeContainer()
        let context = container.mainContext
        XCTAssertGreaterThan(try context.fetchCount(FetchDescriptor<Subscription>()), 0)
        XCTAssertGreaterThan(try context.fetchCount(FetchDescriptor<ChannelRule>()), 0)
        XCTAssertGreaterThan(try context.fetchCount(FetchDescriptor<Video>()), 0)
        // The defaults plus the built-in Priority tag.
        XCTAssertEqual(
            try context.fetchCount(FetchDescriptor<VideoCollection>()),
            CategoryManager.defaultCategoryNames.count + 1
        )
        let priority = try context.fetch(FetchDescriptor<VideoCollection>()).filter(\.isPriority)
        XCTAssertEqual(priority.count, 1)
        XCTAssertTrue(priority.first?.rules.isEmpty == false, "a fixture channel is marked Priority")
    }

    /// One fixture channel stands for an automatically-filed one, so the
    /// Categories sheet's "Why" section has something to show on a device
    /// where the on-device model can't run — and its two categories come from
    /// two sources, which is what that section exists to explain.
    func testFixturesIncludeAnAutomaticallyFiledChannelWithSplitEvidence() throws {
        let container = try DebugFixtures.makeContainer()
        let context = container.mainContext
        let rules = try context.fetch(FetchDescriptor<ChannelRule>())
        let automatic = try XCTUnwrap(rules.first { !$0.isUserSet && $0.classifiedAt != nil })
        XCTAssertEqual(automatic.channelTitle, "NASA")
        XCTAssertEqual(automatic.classifierModelCategory, "Science & Explainers")
        XCTAssertEqual(automatic.classifierYouTubeCategory, "Tech & Engineering")
        XCTAssertEqual(automatic.classifierYouTubeReason, "YouTube files most of its videos under Science & Technology")
        XCTAssertEqual(automatic.classifierDominantCategoryId, "28")
        XCTAssertEqual(Set(automatic.topicCollections.map(\.name)), ["Science & Explainers", "Tech & Engineering"])
    }

    func testSearchOverFixturesFindsChannelAndVideosByDiacriticFreeQuery() throws {
        let container = try DebugFixtures.makeContainer()
        let context = container.mainContext
        let subscriptions = try context.fetch(FetchDescriptor<Subscription>())
        let videos = try context.fetch(FetchDescriptor<Video>(
            sortBy: [SortDescriptor(\.publishedAt, order: .reverse)]
        ))

        let channels = LocalSearch.filter(subscriptions, query: "beyonce") { [$0.title] }
        XCTAssertEqual(channels.map(\.title), ["Beyoncé"])

        let hits = LocalSearch.filter(videos, query: "conan") { [$0.title, $0.channelTitle] }
        XCTAssertFalse(hits.isEmpty)
        // Newest-first order survives filtering.
        XCTAssertEqual(hits.map(\.publishedAt), hits.map(\.publishedAt).sorted(by: >))
        // A channel-name match pulls in that channel's videos too.
        XCTAssertTrue(hits.contains { $0.channelTitle == "Conan Clips Archive" })
    }

    /// Your Shows needs something to draw, and the slices after this one
    /// (show page, cadence, title cleaning) lean on these three shapes.
    func testFixturesSeedShowShapedChannels() throws {
        let container = try DebugFixtures.makeContainer()
        let context = container.mainContext
        let manager = ShowManager(modelContext: context)
        let shows = try manager.shows()
        XCTAssertGreaterThanOrEqual(shows.count, 3, "the grid has to have something in it")
        XCTAssertTrue(shows.allSatisfy { $0.flagOrigin == .user })

        for show in shows {
            let episodes = try manager.episodes(of: show)
            XCTAssertFalse(episodes.isEmpty, "\(show.title) has no episodes")
            XCTAssertFalse(episodes.contains(where: \.isLikelyShort))
            XCTAssertGreaterThan(try manager.unwatchedCount(for: show), 0,
                                 "\(show.title) should show a badge")
        }

        // A daily show with cut-down segments, so the show page has something
        // to hide behind its segment toggle: the channel is mostly clips, and
        // the page is meant to list the news hours alone.
        let newsline = try XCTUnwrap(shows.first { $0.title == "Newsline Nightly" })
        let listing = try manager.listing(of: newsline)
        XCTAssertGreaterThan(listing.segments.count, listing.episodes.count,
                             "more cut-downs than full episodes")
        XCTAssertTrue(listing.episodes.allSatisfy { $0.durationSeconds > 1_800 })
        XCTAssertTrue(listing.segments.allSatisfy { $0.durationSeconds < 900 })
        // A backlog podcast is watched forwards.
        let podcast = try XCTUnwrap(shows.first { $0.title == "Second Take" })
        XCTAssertEqual(podcast.playOrder, .oldestFirst)
    }
}
