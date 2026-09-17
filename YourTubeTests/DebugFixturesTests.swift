import XCTest
import SwiftData
@testable import YourTube

/// The fixture store is what a simulator run without a login sees, so it has
/// to open cleanly and contain the awkward cases search is meant to handle.
///
/// The fixtures go in through the app's own doors — `VideoIntake` for videos,
/// `ShowManager` for shows, `WatchState` for watched and Up Next — so what
/// these tests assert on is what came through them. Asserting that a
/// hand-stamped `isLikelyShort` is the value it was stamped with would be
/// testing the duplicate rather than the door.
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
        let manager = ShowManager(modelContext: context, watchState: WatchState(modelContext: context))
        let shows = try manager.shows()
        XCTAssertGreaterThanOrEqual(shows.count, 3, "the grid has to have something in it")
        XCTAssertTrue(shows.allSatisfy { $0.flagOrigin == .user })

        for show in shows {
            let listing = try manager.listing(of: show)
            XCTAssertFalse(listing.episodes.isEmpty, "\(show.title) has no episodes")
            XCTAssertFalse(listing.episodes.contains(where: \.isLikelyShort))
            XCTAssertGreaterThan(listing.unwatchedCount, 0,
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

// MARK: - What came through the door

extension DebugFixturesTests {
    /// Every fixture video's Shorts verdict is the heuristic's, reached from
    /// the signals the fixture describes. "Späti tour" carries no `#shorts`
    /// tag and no portrait thumbnail, so the only thing that can have flagged
    /// it is the thumbnail verdict — which is to say, the fixtures went
    /// through the classification the feed goes through.
    func testFixtureShortsAreClassifiedRatherThanStamped() throws {
        let container = try DebugFixtures.makeContainer()
        let context = container.mainContext
        let videos = try context.fetch(FetchDescriptor<Video>())

        XCTAssertTrue(
            videos.allSatisfy { $0.classifierVersion == ShortsHeuristic.version },
            "a fixture video was stored without being judged by the current heuristic"
        )
        XCTAssertEqual(
            Set(videos.filter(\.isLikelyShort).map(\.videoId)),
            ["UC-teamcoco-2", "UC-berlin-1", "UC-nasa-4"]
        )
        let untagged = try XCTUnwrap(videos.first { $0.videoId == "UC-berlin-1" })
        XCTAssertFalse(ShortsHeuristic.hasShortsTag(VideoSignals(untagged)))
        XCTAssertFalse(ShortsHeuristic.hasPortraitThumbnail(VideoSignals(untagged)))
        XCTAssertTrue(untagged.isLikelyShort)
    }

    /// Watched, Up Next and partway-through are `WatchState`'s to write, so
    /// the fixture store has to read back through `WatchState` as a real one
    /// would: two entries in the declared order, neither watched, and one
    /// card in Continue Watching.
    func testFixtureWatchStateReadsBackThroughWatchState() throws {
        let container = try DebugFixtures.makeContainer()
        let context = container.mainContext
        let watchState = WatchState(modelContext: context)

        let upNext = try watchState.entries()
        XCTAssertEqual(upNext.map(\.videoId), ["UC-teamcoco-1", "UC-nasa-3"])
        XCTAssertEqual(upNext.compactMap(\.upNextOrder), [1, 2])
        XCTAssertTrue(upNext.allSatisfy { !$0.isWatched })
        XCTAssertEqual(try watchState.inProgress().map(\.videoId), ["UC-lmnc-0"])
        XCTAssertGreaterThan(
            try context.fetch(FetchDescriptor<Video>()).filter(\.isWatched).count, 0
        )
    }

    /// A playlist-backed show's membership is what `ShowManager
    /// .addPlaylistShow` and `setPlaylistItems` recorded — the same two calls
    /// a real membership refresh makes — not fields assigned by hand.
    func testFixturePlaylistShowsCarryTheMembershipShowManagerRecorded() throws {
        let container = try DebugFixtures.makeContainer()
        let context = container.mainContext
        let manager = ShowManager(
            modelContext: context, watchState: WatchState(modelContext: context)
        )
        let shows = try manager.shows()

        let quizmaster = try XCTUnwrap(shows.first { $0.title == "Quizmaster" })
        XCTAssertTrue(quizmaster.isPlaylistBacked)
        XCTAssertEqual(
            quizmaster.backingPlaylistIds,
            ["PL-quizmaster-s14", "PL-quizmaster-s13", "PL-quizmaster-s12"]
        )
        XCTAssertEqual(quizmaster.seasonNames, ["Series 14", "Series 13", "Series 12"])
        XCTAssertNotNil(quizmaster.membershipRefreshedAt)
        XCTAssertEqual(try manager.episodes(of: quizmaster).count, 15)

        // One playlist is one show with nothing to pick between, so no seasons.
        let conan = try XCTUnwrap(shows.first { $0.title == "Conan O'Brien Needs a Friend" })
        XCTAssertTrue(conan.seasonNames.isEmpty)
        XCTAssertEqual(try manager.episodes(of: conan).count, 6)
    }
}
