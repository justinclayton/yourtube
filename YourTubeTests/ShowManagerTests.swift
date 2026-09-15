import XCTest
import SwiftData
@testable import YourTube

/// The show catalogue, driven through `ShowManager` against an in-memory
/// container the way `CategoryManagerTests` drives categories. `ShowDetector`'s
/// verdicts are handed in directly rather than computed (that's
/// `ShowDetectorTests`): what's under test here is that the user's decisions
/// survive a pass, and that a guess arrives with its reasons attached.
@MainActor
final class ShowManagerTests: XCTestCase {
    private var container: ModelContainer!
    private var context: ModelContext { container.mainContext }
    private var manager: ShowManager!

    override func setUp() async throws {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        container = try ModelContainer(
            for: Video.self, Subscription.self, VideoCollection.self, ChannelRule.self, Show.self,
            configurations: config
        )
        manager = ShowManager(modelContext: context)
    }

    @discardableResult
    private func subscribe(_ title: String, id: String? = nil) -> Subscription {
        let sub = Subscription(channelId: id ?? "UC-\(title)", title: title)
        context.insert(sub)
        return sub
    }

    @discardableResult
    private func video(
        _ id: String,
        channelId: String,
        daysAgo: Double,
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

    // MARK: - Flagging

    func testMarkingAChannelPutsItInTheCatalogueAndUnmarkingTakesItOut() throws {
        subscribe("Newsline", id: "UC-news")
        XCTAssertFalse(try manager.isShow(channelId: "UC-news"))

        let show = try manager.markAsShow(channelId: "UC-news", channelTitle: "Newsline")
        XCTAssertEqual(show.id, "channel:UC-news")
        XCTAssertEqual(show.source, .channel(id: "UC-news"))
        XCTAssertEqual(show.flagOrigin, .user)
        XCTAssertEqual(show.override, .forceShow)
        XCTAssertEqual(show.playOrder, .newestFirst, "newest first is the default")
        XCTAssertNil(show.retentionCount)
        XCTAssertEqual(show.artPreference, .channelArt)
        XCTAssertTrue(show.seasonNames.isEmpty)
        XCTAssertEqual(try manager.shows().map(\.title), ["Newsline"])
        XCTAssertTrue(try manager.isShow(channelId: "UC-news"))

        try manager.markAsNotAShow(channelId: "UC-news", channelTitle: "Newsline")
        XCTAssertTrue(try manager.shows().isEmpty)
        XCTAssertFalse(try manager.isShow(channelId: "UC-news"))
        let record = try XCTUnwrap(manager.record(forChannelId: "UC-news"))
        XCTAssertEqual(record.override, .forceNotShow, "the decision is kept, not forgotten")
    }

    func testMarkingTwiceIsOneShow() throws {
        try manager.markAsShow(channelId: "UC-news", channelTitle: "Newsline")
        try manager.markAsShow(channelId: "UC-news", channelTitle: "Newsline Nightly")
        XCTAssertEqual(try manager.allRecords().count, 1)
        XCTAssertEqual(try manager.shows().first?.title, "Newsline Nightly", "the title follows the channel")
        XCTAssertEqual(try manager.shows().first?.id, "channel:UC-news", "identity doesn't")
    }

    func testForgettingAChannelDropsTheOverrideToo() throws {
        try manager.markAsNotAShow(channelId: "UC-news", channelTitle: "Newsline")
        try manager.forget(channelId: "UC-news")
        XCTAssertNil(try manager.record(forChannelId: "UC-news"))
    }

    func testCatalogueIsAlphabetical() throws {
        try manager.markAsShow(channelId: "UC-c", channelTitle: "Zeta Report")
        try manager.markAsShow(channelId: "UC-a", channelTitle: "The Bellwether")
        try manager.markAsShow(channelId: "UC-b", channelTitle: "second take")
        XCTAssertEqual(try manager.shows().map(\.title), ["second take", "The Bellwether", "Zeta Report"])
    }

    // MARK: - Membership

    func testEpisodesAreEveryNonShortVideoFromTheChannel() throws {
        let show = try manager.markAsShow(channelId: "UC-news", channelTitle: "Newsline")
        video("full-1", channelId: "UC-news", daysAgo: 1, seconds: 3_000)
        video("segment-1", channelId: "UC-news", daysAgo: 1.1, seconds: 480)
        video("clip-short", channelId: "UC-news", daysAgo: 1.2, seconds: 42, short: true)
        video("full-2", channelId: "UC-news", daysAgo: 2, seconds: 3_100)
        video("elsewhere", channelId: "UC-other", daysAgo: 1)
        try context.save()

        let episodes = try manager.episodes(of: show)
        XCTAssertEqual(episodes.map(\.videoId), ["full-1", "segment-1", "full-2"],
                       "Shorts are never episodes, and neither is another channel's video")
    }

    func testEpisodesFollowThePlayOrder() throws {
        let show = try manager.markAsShow(channelId: "UC-pod", channelTitle: "Second Take")
        video("new", channelId: "UC-pod", daysAgo: 1)
        video("middle", channelId: "UC-pod", daysAgo: 8)
        video("old", channelId: "UC-pod", daysAgo: 15)
        try context.save()

        XCTAssertEqual(try manager.episodes(of: show).map(\.videoId), ["new", "middle", "old"])
        show.playOrder = .oldestFirst
        XCTAssertEqual(try manager.episodes(of: show).map(\.videoId), ["old", "middle", "new"],
                       "a backlog podcast is watched forwards")
    }

    func testRetentionWindowKeepsOnlyTheNewestEpisodes() throws {
        let show = try manager.markAsShow(channelId: "UC-news", channelTitle: "Newsline")
        for day in 1...6 {
            video("ep-\(day)", channelId: "UC-news", daysAgo: Double(day))
        }
        try context.save()
        XCTAssertEqual(try manager.episodes(of: show).count, 6)
        XCTAssertEqual(try manager.unwatchedCount(for: show), 6)

        show.retentionCount = 2
        XCTAssertEqual(try manager.episodes(of: show).map(\.videoId), ["ep-1", "ep-2"])
        XCTAssertEqual(try manager.unwatchedCount(for: show), 2, "hidden episodes don't nag")
    }

    // MARK: - Unwatched counts

    func testUnwatchedCountIgnoresWatchedAndShorts() throws {
        let show = try manager.markAsShow(channelId: "UC-news", channelTitle: "Newsline")
        video("new-1", channelId: "UC-news", daysAgo: 1)
        video("new-2", channelId: "UC-news", daysAgo: 2)
        video("seen", channelId: "UC-news", daysAgo: 3, watched: true)
        video("short", channelId: "UC-news", daysAgo: 4, seconds: 30, short: true)
        try context.save()

        XCTAssertEqual(try manager.unwatchedCount(for: show), 2)
    }

    func testUnwatchedCountIsZeroWhenCaughtUp() throws {
        let show = try manager.markAsShow(channelId: "UC-news", channelTitle: "Newsline")
        video("seen-1", channelId: "UC-news", daysAgo: 1, watched: true)
        video("seen-2", channelId: "UC-news", daysAgo: 2, watched: true)
        try context.save()

        XCTAssertEqual(try manager.unwatchedCount(for: show), 0, "no badge at zero")
    }

    /// The grid counts every poster from one live query, so the batch answer
    /// has to match the per-show one exactly.
    func testBatchedCountsMatchThePerShowCount() throws {
        let news = try manager.markAsShow(channelId: "UC-news", channelTitle: "Newsline")
        let pod = try manager.markAsShow(channelId: "UC-pod", channelTitle: "Second Take")
        let quiet = try manager.markAsShow(channelId: "UC-quiet", channelTitle: "Nothing Yet")
        video("n-1", channelId: "UC-news", daysAgo: 1)
        video("n-2", channelId: "UC-news", daysAgo: 2)
        video("n-3", channelId: "UC-news", daysAgo: 3, watched: true)
        video("n-short", channelId: "UC-news", daysAgo: 4, short: true)
        video("p-1", channelId: "UC-pod", daysAgo: 1)
        video("stray", channelId: "UC-unflagged", daysAgo: 1)
        try context.save()

        let all = try context.fetch(FetchDescriptor<Video>())
        let counts = ShowManager.unwatchedCounts(from: all, shows: try manager.shows())
        XCTAssertEqual(counts["channel:UC-news"], 2)
        XCTAssertEqual(counts["channel:UC-pod"], 1)
        XCTAssertEqual(counts["channel:UC-quiet"], 0)
        XCTAssertNil(counts["channel:UC-unflagged"], "a channel that isn't a show isn't counted")
        for show in [news, pod, quiet] {
            XCTAssertEqual(counts[show.id], try manager.unwatchedCount(for: show))
        }
    }

    func testBatchedCountsHonourTheRetentionWindow() throws {
        let show = try manager.markAsShow(channelId: "UC-news", channelTitle: "Newsline")
        show.retentionCount = 3
        for day in 1...5 {
            video("ep-\(day)", channelId: "UC-news", daysAgo: Double(day))
        }
        try context.save()

        let all = try context.fetch(FetchDescriptor<Video>())
        XCTAssertEqual(ShowManager.unwatchedCounts(from: all, shows: [show])[show.id], 3)
    }

    // MARK: - Surviving an automatic pass

    /// The stub detector: a hand-written set of verdicts standing in for the
    /// cadence-and-duration heuristic, which is tested on its own corpus.
    private func automaticPass(_ verdicts: (channelId: String, isShow: Bool)...) throws -> Int {
        try manager.applyAutomaticVerdicts(verdicts.map {
            ShowVerdict(channelId: $0.channelId, channelTitle: $0.channelId, isShow: $0.isShow,
                        reasons: ["stub"])
        })
    }

    func testHandFlaggedShowSurvivesAPassThatSaysItIsNotAShow() throws {
        try manager.markAsShow(channelId: "UC-news", channelTitle: "Newsline")

        try automaticPass((channelId: "UC-news", isShow: false))

        XCTAssertTrue(try manager.isShow(channelId: "UC-news"))
        let record = try XCTUnwrap(manager.record(forChannelId: "UC-news"))
        XCTAssertEqual(record.flagOrigin, .user)
        XCTAssertEqual(record.title, "Newsline", "the pass doesn't get to rename it either")
    }

    func testNotAShowSurvivesAPassThatSaysItIsAShow() throws {
        try manager.markAsNotAShow(channelId: "UC-vlog", channelTitle: "Berlin Vlogs")

        try automaticPass((channelId: "UC-vlog", isShow: true))

        XCTAssertFalse(try manager.isShow(channelId: "UC-vlog"))
        XCTAssertTrue(try manager.shows().isEmpty)
        XCTAssertEqual(try manager.record(forChannelId: "UC-vlog")?.override, .forceNotShow)
    }

    func testPassFlagsUntouchedChannelsAndCanChangeItsOwnMind() throws {
        try automaticPass(
            (channelId: "UC-news", isShow: true),
            (channelId: "UC-vlog", isShow: false)
        )
        XCTAssertEqual(try manager.shows().map(\.channelId), ["UC-news"])
        XCTAssertEqual(try manager.record(forChannelId: "UC-news")?.flagOrigin, .heuristic)
        XCTAssertNil(try manager.record(forChannelId: "UC-vlog"), "a plain no leaves no trace")

        // Its own earlier guess is its to withdraw.
        try automaticPass((channelId: "UC-news", isShow: false))
        XCTAssertTrue(try manager.shows().isEmpty)
        XCTAssertNil(try manager.record(forChannelId: "UC-news"))
    }

    func testUserCanCorrectAHeuristicGuessAndTheCorrectionSticks() throws {
        try automaticPass((channelId: "UC-vlog", isShow: true))
        XCTAssertTrue(try manager.isShow(channelId: "UC-vlog"))

        try manager.markAsNotAShow(channelId: "UC-vlog", channelTitle: "Berlin Vlogs")
        try automaticPass((channelId: "UC-vlog", isShow: true))

        XCTAssertFalse(try manager.isShow(channelId: "UC-vlog"))
    }

    /// A guess has to carry its reasons, or the show page can't say why the
    /// channel is there.
    func testAGuessKeepsItsReasonsAndAHandFlagHasNone() throws {
        try manager.applyAutomaticVerdicts([ShowVerdict(
            channelId: "UC-news", channelTitle: "Newsline", isShow: true,
            reasons: ["Episodes usually run 1 hr 5 min", "Posts on a regular schedule (Tue, Fri)"]
        )])
        let guessed = try XCTUnwrap(manager.record(forChannelId: "UC-news"))
        XCTAssertEqual(guessed.flagOrigin, .heuristic)
        XCTAssertEqual(guessed.detectorReasons.count, 2)

        // Taking the decision by hand makes the reasons moot.
        try manager.markAsShow(channelId: "UC-news", channelTitle: "Newsline")
        XCTAssertEqual(try manager.record(forChannelId: "UC-news")?.detectorReasons, [])
    }

    /// A later pass replaces the reasons rather than appending to them.
    func testASecondPassRefreshesTheReasons() throws {
        try manager.applyAutomaticVerdicts([ShowVerdict(
            channelId: "UC-news", channelTitle: "Newsline", isShow: true, reasons: ["Old reason"]
        )])
        try manager.applyAutomaticVerdicts([ShowVerdict(
            channelId: "UC-news", channelTitle: "Newsline", isShow: true, reasons: ["New reason"]
        )])
        XCTAssertEqual(try manager.record(forChannelId: "UC-news")?.detectorReasons, ["New reason"])
    }
}
