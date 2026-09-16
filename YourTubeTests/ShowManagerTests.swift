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

    @discardableResult
    private func videoPublished(
        _ id: String,
        channelId: String,
        on date: Date,
        seconds: Int = 2_400,
        watched: Bool = false
    ) -> Video {
        let video = Video(
            videoId: id,
            channelId: channelId,
            channelTitle: channelId,
            title: id,
            videoDescription: "",
            publishedAt: date,
            durationSeconds: seconds,
            isWatched: watched
        )
        context.insert(video)
        return video
    }

    /// Noon on the given weekday (`Calendar` numbering, 1 = Sunday), that
    /// many weeks back. Cadence is read off real weekdays, so the tests have
    /// to post on them rather than at round intervals — and relative to the
    /// day the suite runs, so a Tuesday show is a Tuesday show on any Tuesday.
    private func weekday(_ weekday: Int, weeksAgo: Int, calendar: Calendar = .current) -> Date {
        var day = calendar.startOfDay(for: .now)
        while calendar.component(.weekday, from: day) != weekday {
            day = calendar.date(byAdding: .day, value: -1, to: day)!
        }
        return calendar.date(byAdding: .day, value: -7 * weeksAgo, to: day)!
            .addingTimeInterval(12 * 3_600)
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

    func testEpisodesAreEveryFullLengthNonShortVideoFromTheChannel() throws {
        let show = try manager.markAsShow(channelId: "UC-news", channelTitle: "Newsline")
        video("full-1", channelId: "UC-news", daysAgo: 1, seconds: 3_000)
        video("segment-1", channelId: "UC-news", daysAgo: 1.1, seconds: 480)
        video("clip-short", channelId: "UC-news", daysAgo: 1.2, seconds: 42, short: true)
        video("full-2", channelId: "UC-news", daysAgo: 2, seconds: 3_100)
        video("elsewhere", channelId: "UC-other", daysAgo: 1)
        try context.save()

        let episodes = try manager.episodes(of: show)
        XCTAssertEqual(episodes.map(\.videoId), ["full-1", "full-2"],
                       "Shorts are never episodes, nor is another channel's video, nor a cut-down")
        XCTAssertEqual(try manager.segments(of: show).map(\.videoId), ["segment-1"])
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

        show.retentionCount = nil
        XCTAssertEqual(try manager.episodes(of: show).count, 6, "clearing it restores the full list")
    }

    // MARK: - Segments

    /// A news hour, the shape the rule exists for: one full episode a night,
    /// each trailed by clips cut out of it, so the cut-downs outnumber the
    /// episodes three to one and the plain median of the channel is a clip.
    @discardableResult
    private func newsShow(
        nights: Int = 5,
        episodeSeconds: Int = 3_180,
        segmentSeconds: [Int] = [620, 480, 405]
    ) throws -> Show {
        let show = try manager.markAsShow(channelId: "UC-news", channelTitle: "Newsline Nightly")
        for night in 1...nights {
            video("ep-\(night)", channelId: "UC-news", daysAgo: Double(night), seconds: episodeSeconds)
            for (index, seconds) in segmentSeconds.enumerated() {
                video("ep-\(night)-seg-\(index)", channelId: "UC-news",
                      daysAgo: Double(night) - 0.1 * Double(index + 1), seconds: seconds)
            }
        }
        try context.save()
        return show
    }

    func testCutDownsAreSegmentsEvenWhenTheyOutnumberTheEpisodes() throws {
        let show = try newsShow()

        XCTAssertEqual(try manager.episodes(of: show).map(\.videoId),
                       ["ep-1", "ep-2", "ep-3", "ep-4", "ep-5"],
                       "the full episodes, and only those, even though they're a quarter of the channel")
        XCTAssertEqual(try manager.segments(of: show).count, 15)
        XCTAssertEqual(try manager.listing(of: show).typicalEpisodeDuration, 3_180,
                       "the typical length of a news hour is the hour, not the clips cut from it")
        XCTAssertEqual(try manager.episodesAndSegments(of: show).count, 20,
                       "the toggle reveals them; nothing is lost")
    }

    /// Hiding is presentation only, the same policy as Shorts: the feed and
    /// everything else still see every video.
    func testHiddenSegmentsAndOlderEpisodesAreStillInTheStore() throws {
        let show = try newsShow()
        show.retentionCount = 2

        XCTAssertEqual(try manager.episodes(of: show).count, 2)
        XCTAssertEqual(try context.fetch(FetchDescriptor<Video>()).count, 20,
                       "nothing is deleted, so the feed still lists every one of them")
    }

    /// The rule's edge, which is where a per-show threshold has to be exact:
    /// half of a typical episode to the second.
    func testAVideoIsASegmentJustUnderTheThresholdAndAnEpisodeAtIt() throws {
        let show = try manager.markAsShow(channelId: "UC-news", channelTitle: "Newsline")
        for night in 1...5 {
            video("ep-\(night)", channelId: "UC-news", daysAgo: Double(night), seconds: 3_000)
        }
        let candidate = video("candidate", channelId: "UC-news", daysAgo: 0.5, seconds: 1_499)
        try context.save()

        XCTAssertEqual(try manager.listing(of: show).typicalEpisodeDuration, 3_000)
        XCTAssertEqual(try manager.segments(of: show).map(\.videoId), ["candidate"],
                       "a second under half an episode is a cut-down of one")

        candidate.durationSeconds = 1_500
        XCTAssertTrue(try manager.segments(of: show).isEmpty)
        XCTAssertTrue(try manager.episodes(of: show).contains { $0.videoId == "candidate" },
                      "exactly half is still an episode")
    }

    func testChangingTheThresholdReclassifiesImmediately() throws {
        let show = try manager.markAsShow(channelId: "UC-news", channelTitle: "Newsline")
        for night in 1...5 {
            video("ep-\(night)", channelId: "UC-news", daysAgo: Double(night), seconds: 3_000)
        }
        video("half-hour", channelId: "UC-news", daysAgo: 0.5, seconds: 1_800)
        try context.save()

        XCTAssertEqual(show.segmentThreshold, 0.5, "half by default")
        XCTAssertTrue(try manager.segments(of: show).isEmpty, "a half-length instalment is an episode")
        XCTAssertEqual(try manager.unwatchedCount(for: show), 6)

        show.segmentThreshold = 0.7
        XCTAssertEqual(try manager.segments(of: show).map(\.videoId), ["half-hour"],
                       "a stricter show calls it a cut-down")
        XCTAssertEqual(try manager.unwatchedCount(for: show), 5, "and stops counting it")

        show.segmentThreshold = 0.5
        XCTAssertTrue(try manager.segments(of: show).isEmpty, "and back again")
    }

    /// The reason "typical" isn't the longest episode: a show that runs one
    /// election special mustn't spend the rest of the year calling its
    /// ordinary episodes clips.
    func testOneFeatureLengthSpecialDoesNotDemoteTheOrdinaryEpisodes() throws {
        let show = try manager.markAsShow(channelId: "UC-news", channelTitle: "Newsline")
        for (index, seconds) in [1_500, 1_800, 2_100, 2_400, 21_600].enumerated() {
            video("ep-\(index)", channelId: "UC-news", daysAgo: Double(index + 1), seconds: seconds)
        }
        try context.save()

        XCTAssertTrue(try manager.segments(of: show).isEmpty)
        XCTAssertEqual(try manager.episodes(of: show).count, 5)
    }

    func testAShowWhoseEpisodesAreAllOfALengthHasNoSegments() throws {
        let show = try manager.markAsShow(channelId: "UC-pod", channelTitle: "Second Take")
        for (index, seconds) in [5_700, 6_240, 5_100, 6_600, 5_460, 5_880].enumerated() {
            video("ep-\(index)", channelId: "UC-pod", daysAgo: Double(index + 1), seconds: seconds)
        }
        try context.save()

        XCTAssertTrue(try manager.segments(of: show).isEmpty)
        XCTAssertEqual(try manager.listing(of: show).typicalEpisodeDuration, 5_700)
    }

    /// An unmeasured video is listed rather than hidden: the app would rather
    /// show something it can't measure than quietly bury it.
    func testAVideoWithNoDurationYetIsAnEpisode() throws {
        let show = try newsShow()
        video("unmeasured", channelId: "UC-news", daysAgo: 0.1, seconds: 0)
        try context.save()

        XCTAssertTrue(try manager.episodes(of: show).contains { $0.videoId == "unmeasured" })
    }

    func testUnwatchedCountAndBadgesCountEpisodesOnly() throws {
        let show = try newsShow()

        XCTAssertEqual(try manager.unwatchedCount(for: show), 5,
                       "five nights, not twenty videos")
        let all = try context.fetch(FetchDescriptor<Video>())
        XCTAssertEqual(ShowManager.unwatchedCounts(from: all, shows: [show])[show.id], 5,
                       "the grid's batched count agrees with the page's")
    }

    func testUnwatchedCountUnderARetentionWindowCountsOnlyWhatThePageLists() throws {
        let show = try newsShow(nights: 8)
        show.retentionCount = 3

        let listing = try manager.listing(of: show)
        XCTAssertEqual(listing.episodes.map(\.videoId), ["ep-1", "ep-2", "ep-3"])
        XCTAssertEqual(listing.hiddenByRetention, 5)
        XCTAssertEqual(try manager.unwatchedCount(for: show), 3)

        let all = try context.fetch(FetchDescriptor<Video>())
        XCTAssertEqual(ShowManager.unwatchedCounts(from: all, shows: [show])[show.id], 3)
        XCTAssertEqual(listing.segments.count, 9,
                       "revealing segments doesn't drag back the era the window hides")
    }

    /// The footer under the list: how many are hidden, why, and that they're
    /// still there.
    func testTheFooterSaysWhatIsHiddenAndWhy() throws {
        let show = try newsShow(nights: 8)
        show.retentionCount = 3
        let listing = try manager.listing(of: show)

        let hidden = try XCTUnwrap(listing.hiddenSummary(revealingSegments: false))
        XCTAssertTrue(hidden.hasPrefix("9 segments and 5 older episodes hidden."), hidden)
        XCTAssertTrue(hidden.contains("still in the feed"), hidden)

        let revealed = try XCTUnwrap(listing.hiddenSummary(revealingSegments: true))
        XCTAssertTrue(revealed.hasPrefix("5 older episodes hidden."), revealed)

        show.retentionCount = nil
        XCTAssertNil(try manager.listing(of: show).hiddenSummary(revealingSegments: true),
                     "a page showing everything it has says nothing")
    }

    func testPlayNextAndNextEpisodeSkipSegments() throws {
        let show = try newsShow()
        let all = try context.fetch(FetchDescriptor<Video>())
        let segment = try XCTUnwrap(all.first { $0.videoId == "ep-2-seg-0" })

        XCTAssertEqual(try manager.nextUp(of: show)?.videoId, "ep-1",
                       "Play next opens the newest full episode, not the clip posted after it")
        XCTAssertEqual(try manager.nextEpisode(after: segment)?.videoId, "ep-1",
                       "watching a clip moves you on to the next full episode")

        let episode = try XCTUnwrap(all.first { $0.videoId == "ep-3" })
        XCTAssertEqual(try manager.nextEpisode(after: episode)?.videoId, "ep-2",
                       "and an episode is followed by an episode")
    }

    func testMarkAllWatchedLeavesSegmentsAlone() throws {
        let show = try newsShow()

        XCTAssertEqual(try manager.markAllWatched(of: show), 5)
        XCTAssertEqual(try manager.unwatchedCount(for: show), 0)
        XCTAssertTrue(try manager.segments(of: show).allSatisfy { !$0.isWatched },
                      "clearing a backlog doesn't reach behind the page")
    }

    // MARK: - Next episode

    /// The player's "Next episode" action: chronologically after the current
    /// video within its own show, regardless of play order.
    func testNextEpisodeIsTheOneReleasedImmediatelyAfterWithinTheSameShow() throws {
        let show = try manager.markAsShow(channelId: "UC-news", channelTitle: "Newsline Nightly")
        let oldest = video("ep-old", channelId: "UC-news", daysAgo: 3)
        let middle = video("ep-middle", channelId: "UC-news", daysAgo: 2)
        let newest = video("ep-new", channelId: "UC-news", daysAgo: 1)
        try context.save()

        XCTAssertEqual(try manager.nextEpisode(after: oldest)?.videoId, middle.videoId,
                       "the middle episode, not the newest, follows the oldest")
        XCTAssertEqual(try manager.nextEpisode(after: middle)?.videoId, newest.videoId)
        XCTAssertNil(try manager.nextEpisode(after: newest), "nothing follows the newest episode")
        XCTAssertEqual(show.playOrder, .newestFirst, "resolution doesn't depend on play order")
    }

    func testNextEpisodeIgnoresAnotherChannelsVideoWithTheSameId() throws {
        try manager.markAsShow(channelId: "UC-news", channelTitle: "Newsline")
        let stray = video("elsewhere", channelId: "UC-other", daysAgo: 1)
        try context.save()

        XCTAssertNil(try manager.nextEpisode(after: stray), "not a show, and not this show's episode")
    }

    func testNextEpisodeIsNilForAVideoFromAChannelThatIsNotAShow() throws {
        let notAShow = video("standalone", channelId: "UC-plain", daysAgo: 1)
        try context.save()

        XCTAssertNil(try manager.nextEpisode(after: notAShow))
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

    // MARK: - Play next

    /// The show page's one button, so what it opens is worth pinning under
    /// both play orders and against a half-watched episode.
    func testPlayNextIsTheNewestUnwatchedWhenTheShowPlaysNewestFirst() throws {
        let show = try manager.markAsShow(channelId: "UC-news", channelTitle: "Newsline")
        video("newest", channelId: "UC-news", daysAgo: 1)
        video("middle", channelId: "UC-news", daysAgo: 2)
        video("oldest", channelId: "UC-news", daysAgo: 3)
        try context.save()

        XCTAssertEqual(try manager.nextUp(of: show)?.videoId, "newest")
    }

    func testPlayNextIsTheOldestUnwatchedWhenTheShowPlaysOldestFirst() throws {
        let show = try manager.markAsShow(channelId: "UC-pod", channelTitle: "Second Take")
        show.playOrder = .oldestFirst
        video("newest", channelId: "UC-pod", daysAgo: 1)
        video("middle", channelId: "UC-pod", daysAgo: 2)
        video("oldest", channelId: "UC-pod", daysAgo: 3, watched: true)
        try context.save()

        XCTAssertEqual(try manager.nextUp(of: show)?.videoId, "middle",
                       "a backlog is walked forwards, but not back over what's watched")
    }

    func testAnEpisodeInProgressWinsUnderEitherPlayOrder() throws {
        let show = try manager.markAsShow(channelId: "UC-news", channelTitle: "Newsline")
        video("newest", channelId: "UC-news", daysAgo: 1)
        let started = video("middle", channelId: "UC-news", daysAgo: 2)
        video("oldest", channelId: "UC-news", daysAgo: 3)
        started.resumePositionSeconds = 900
        started.lastPlayedAt = Date(timeIntervalSinceNow: -3_600)
        try context.save()

        XCTAssertEqual(try manager.nextUp(of: show)?.videoId, "middle")
        show.playOrder = .oldestFirst
        XCTAssertEqual(try manager.nextUp(of: show)?.videoId, "middle",
                       "the one you walked away from is the one you meant")
    }

    /// The thirty-second rule from `PlaybackProgress`: a glance isn't a start,
    /// so it mustn't hijack Play next either.
    func testAGlanceAtAnEpisodeDoesNotCountAsInProgress() throws {
        let show = try manager.markAsShow(channelId: "UC-news", channelTitle: "Newsline")
        video("newest", channelId: "UC-news", daysAgo: 1)
        let glanced = video("middle", channelId: "UC-news", daysAgo: 2)
        glanced.resumePositionSeconds = 12
        glanced.lastPlayedAt = .now
        try context.save()

        XCTAssertEqual(try manager.nextUp(of: show)?.videoId, "newest")
    }

    func testPlayNextIsNothingWhenTheShowIsCaughtUp() throws {
        let show = try manager.markAsShow(channelId: "UC-news", channelTitle: "Newsline")
        video("seen-1", channelId: "UC-news", daysAgo: 1, watched: true)
        video("seen-2", channelId: "UC-news", daysAgo: 2, watched: true)
        try context.save()

        XCTAssertNil(try manager.nextUp(of: show))
    }

    /// The show page lists episodes in air order even for a backlog watched
    /// forwards: the list is read newest first, and Play next is the thing
    /// that walks the other way.
    func testThePageListsNewestFirstWhateverThePlayOrder() throws {
        let show = try manager.markAsShow(channelId: "UC-pod", channelTitle: "Second Take")
        show.playOrder = .oldestFirst
        video("newest", channelId: "UC-pod", daysAgo: 1)
        video("middle", channelId: "UC-pod", daysAgo: 2)
        video("oldest", channelId: "UC-pod", daysAgo: 3)
        video("short", channelId: "UC-pod", daysAgo: 1.5, short: true)
        video("elsewhere", channelId: "UC-other", daysAgo: 1)
        try context.save()

        let all = try context.fetch(FetchDescriptor<Video>())
        XCTAssertEqual(ShowManager.episodesNewestFirst(from: all, of: show).map(\.videoId),
                       ["newest", "middle", "oldest"])
        XCTAssertEqual(ShowManager.episodes(from: all, of: show).map(\.videoId),
                       try manager.episodes(of: show).map(\.videoId),
                       "the live-query path and the fetching one agree")
    }

    // MARK: - Mark all watched

    func testMarkAllWatchedClearsTheBadgeAndTheEarmarks() throws {
        let show = try manager.markAsShow(channelId: "UC-news", channelTitle: "Newsline")
        let earmarked = video("ep-1", channelId: "UC-news", daysAgo: 1)
        earmarked.savedForLaterAt = .now
        earmarked.upNextOrder = 1
        let started = video("ep-2", channelId: "UC-news", daysAgo: 2)
        started.resumePositionSeconds = 900
        video("ep-3", channelId: "UC-news", daysAgo: 3, watched: true)
        try context.save()

        XCTAssertEqual(try manager.markAllWatched(of: show), 2, "the watched one needed nothing")
        XCTAssertEqual(try manager.unwatchedCount(for: show), 0)
        XCTAssertNil(try manager.nextUp(of: show))
        XCTAssertFalse(earmarked.isInUpNext, "a finished episode has no business waiting")
        XCTAssertNil(started.resumePositionSeconds)
    }

    func testMarkAllWatchedLeavesEpisodesTheRetentionWindowHides() throws {
        let show = try manager.markAsShow(channelId: "UC-news", channelTitle: "Newsline")
        show.retentionCount = 2
        for day in 1...4 {
            video("ep-\(day)", channelId: "UC-news", daysAgo: Double(day))
        }
        try context.save()

        XCTAssertEqual(try manager.markAllWatched(of: show), 2)
        let hidden = try XCTUnwrap(context.fetch(FetchDescriptor<Video>()).first { $0.videoId == "ep-4" })
        XCTAssertFalse(hidden.isWatched, "clearing a backlog doesn't reach behind the page")
    }

    // MARK: - Cadence and typical duration

    func testCadenceIsTheWeekdaysTheShowHasPostedOnAtLeastTwice() throws {
        let show = try manager.markAsShow(channelId: "UC-news", channelTitle: "The Bellwether")
        for week in 0..<3 {
            videoPublished("tue-\(week)", channelId: "UC-news", on: weekday(3, weeksAgo: week + 1))
            videoPublished("fri-\(week)", channelId: "UC-news", on: weekday(6, weeksAgo: week + 1))
        }
        // One Sunday special is an accident, not a habit.
        videoPublished("sun", channelId: "UC-news", on: weekday(1, weeksAgo: 2))
        try context.save()

        XCTAssertEqual(try manager.cadenceWeekdays(of: show), [3, 6])
    }

    func testCadenceIsEmptyUntilAShowHasAHabit() throws {
        let show = try manager.markAsShow(channelId: "UC-new", channelTitle: "Brand New")
        videoPublished("one", channelId: "UC-new", on: weekday(3, weeksAgo: 1))
        try context.save()

        XCTAssertTrue(try manager.cadenceWeekdays(of: show).isEmpty)
    }

    func testCadenceOnlyCountsEpisodesTheRetentionWindowKeeps() throws {
        let show = try manager.markAsShow(channelId: "UC-news", channelTitle: "Newsline")
        for week in 0..<3 {
            videoPublished("tue-\(week)", channelId: "UC-news", on: weekday(3, weeksAgo: week + 1))
        }
        for week in 0..<3 {
            videoPublished("sat-\(week)", channelId: "UC-news", on: weekday(7, weeksAgo: week + 4))
        }
        try context.save()
        XCTAssertEqual(try manager.cadenceWeekdays(of: show), [3, 7])

        show.retentionCount = 3
        XCTAssertEqual(try manager.cadenceWeekdays(of: show), [3],
                       "a show that moved night stops claiming the old one")
    }

    func testTypicalDurationIsTheMedianEpisodeLength() throws {
        let show = try manager.markAsShow(channelId: "UC-news", channelTitle: "Newsline")
        // One feature-length special mustn't move the number the show is
        // described by, which is why it's the median and not the mean.
        for (index, seconds) in [1_500, 1_800, 2_100, 2_400, 21_600].enumerated() {
            video("ep-\(index)", channelId: "UC-news", daysAgo: Double(index + 1), seconds: seconds)
        }
        try context.save()

        XCTAssertEqual(try manager.typicalDuration(of: show), 2_100)
    }

    func testTypicalDurationIsNothingForAShowWithNoEpisodes() throws {
        let show = try manager.markAsShow(channelId: "UC-quiet", channelTitle: "Nothing Yet")
        XCTAssertNil(try manager.typicalDuration(of: show))
        XCTAssertNil(try manager.cadenceDescription(of: show))
    }

    func testCadenceLineNamesTheWeekdaysAndTheTypicalLength() throws {
        let show = try manager.markAsShow(channelId: "UC-news", channelTitle: "The Bellwether")
        for week in 0..<2 {
            videoPublished("tue-\(week)", channelId: "UC-news", on: weekday(3, weeksAgo: week + 1), seconds: 4_500)
            videoPublished("fri-\(week)", channelId: "UC-news", on: weekday(6, weeksAgo: week + 1), seconds: 4_500)
        }
        try context.save()

        let symbols = Calendar.current.shortWeekdaySymbols
        XCTAssertEqual(try manager.cadenceDescription(of: show),
                       "Posts \(symbols[2]), \(symbols[5]) · about 1 hr 15 min")
    }

    /// A typical length is a shape, not a measurement: it rounds.
    func testApproximateLengthRoundsToFiveMinutes() {
        XCTAssertEqual(ShowManager.approximateLength(3_540), "1 hr")
        XCTAssertEqual(ShowManager.approximateLength(3_780), "1 hr 5 min")
        XCTAssertEqual(ShowManager.approximateLength(2_580), "45 min")
        XCTAssertEqual(ShowManager.approximateLength(45), "5 min", "nothing rounds away to nothing")
        XCTAssertNil(ShowManager.approximateLength(0))
    }

    func testCadenceLineStandsAloneWhenTheShowHasNoRegularDay() {
        let line = ShowManager.cadenceDescription(weekdays: [], typicalDuration: 2_700)
        XCTAssertEqual(line, "Episodes about 45 min")
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

    // MARK: - Going dormant

    /// Gone quiet isn't the detector's decision to make alone: the row stays,
    /// flagged for the user to answer, rather than disappearing.
    func testADormantVerdictHoldsTheShowForReviewInsteadOfDroppingIt() throws {
        try automaticPass((channelId: "UC-news", isShow: true))

        try manager.applyAutomaticVerdicts([ShowVerdict(
            channelId: "UC-news", channelTitle: "Newsline", isShow: false,
            reasons: ["Hasn't posted in 130 days"], dormant: true
        )])

        XCTAssertTrue(try manager.isShow(channelId: "UC-news"), "still in the catalogue until the user answers")
        let record = try XCTUnwrap(manager.record(forChannelId: "UC-news"))
        XCTAssertTrue(record.pendingDormancyReview)
        XCTAssertEqual(record.detectorReasons, ["Hasn't posted in 130 days"])
    }

    /// A user-flagged show can't be touched by a plain "no" pass; a dormant
    /// one is no different.
    func testHandFlaggedShowSurvivesADormantVerdictToo() throws {
        try manager.markAsShow(channelId: "UC-news", channelTitle: "Newsline")

        try manager.applyAutomaticVerdicts([ShowVerdict(
            channelId: "UC-news", channelTitle: "Newsline", isShow: false, dormant: true
        )])

        XCTAssertTrue(try manager.isShow(channelId: "UC-news"))
        let record = try XCTUnwrap(manager.record(forChannelId: "UC-news"))
        XCTAssertEqual(record.flagOrigin, .user)
        XCTAssertFalse(record.pendingDormancyReview)
    }

    func testMarkAsShowResolvesADormancyReviewByKeepingIt() throws {
        try automaticPass((channelId: "UC-news", isShow: true))
        try manager.applyAutomaticVerdicts([ShowVerdict(
            channelId: "UC-news", channelTitle: "Newsline", isShow: false, dormant: true
        )])

        try manager.markAsShow(channelId: "UC-news", channelTitle: "Newsline")

        let record = try XCTUnwrap(manager.record(forChannelId: "UC-news"))
        XCTAssertFalse(record.pendingDormancyReview)
        XCTAssertEqual(record.flagOrigin, .user)
        XCTAssertEqual(record.override, .forceShow)
        XCTAssertTrue(try manager.isShow(channelId: "UC-news"))
    }

    func testMarkAsNotAShowResolvesADormancyReviewByDroppingIt() throws {
        try automaticPass((channelId: "UC-news", isShow: true))
        try manager.applyAutomaticVerdicts([ShowVerdict(
            channelId: "UC-news", channelTitle: "Newsline", isShow: false, dormant: true
        )])

        try manager.markAsNotAShow(channelId: "UC-news", channelTitle: "Newsline")

        let record = try XCTUnwrap(manager.record(forChannelId: "UC-news"))
        XCTAssertFalse(record.pendingDormancyReview)
        XCTAssertEqual(record.override, .forceNotShow)
        XCTAssertFalse(try manager.isShow(channelId: "UC-news"))
    }

    /// The channel posting again before the user gets to it answers the
    /// question on its own.
    func testAChannelThatPostsAgainResolvesItsOwnDormancyReview() throws {
        try automaticPass((channelId: "UC-news", isShow: true))
        try manager.applyAutomaticVerdicts([ShowVerdict(
            channelId: "UC-news", channelTitle: "Newsline", isShow: false, dormant: true
        )])
        XCTAssertTrue(try XCTUnwrap(manager.record(forChannelId: "UC-news")).pendingDormancyReview)

        try manager.applyAutomaticVerdicts([ShowVerdict(
            channelId: "UC-news", channelTitle: "Newsline", isShow: true,
            reasons: ["Posts on a regular schedule (Tue, Fri)"]
        )])

        let record = try XCTUnwrap(manager.record(forChannelId: "UC-news"))
        XCTAssertFalse(record.pendingDormancyReview)
        XCTAssertEqual(record.flagOrigin, .heuristic)
    }

    func testShowsPendingDormancyReviewListsOnlyThoseAwaitingAnAnswer() throws {
        try automaticPass((channelId: "UC-news", isShow: true), (channelId: "UC-vlog", isShow: true))
        try manager.applyAutomaticVerdicts([ShowVerdict(
            channelId: "UC-news", channelTitle: "Newsline", isShow: false, dormant: true
        )])

        XCTAssertEqual(try manager.showsPendingDormancyReview().map(\.channelId), ["UC-news"])
    }

    // MARK: - Playlist-backed shows

    /// The picker hands `addPlaylistShow` choices; the refresher hands
    /// `setPlaylistItems` what the playlist held. Both together are how a
    /// playlist-backed show gets its membership, so the tests go through them
    /// rather than writing the record by hand.
    @discardableResult
    private func playlistShow(
        _ title: String,
        channelId: String,
        seasons: [(playlist: String, name: String, videoIds: [String])]
    ) throws -> Show {
        let show = try manager.addPlaylistShow(
            seasons.map { PlaylistChoice(playlistId: $0.playlist, title: $0.name) },
            channelId: channelId,
            title: title
        )
        for season in seasons {
            try manager.setPlaylistItems(season.videoIds, playlistId: season.playlist, of: show)
        }
        return show
    }

    func testAPlaylistBackedShowsEpisodesAreThePlaylistsItems() throws {
        subscribe("Team Coco", id: "UC-coco")
        video("friend-1", channelId: "UC-coco", daysAgo: 1)
        video("friend-2", channelId: "UC-coco", daysAgo: 8)
        video("a-clip", channelId: "UC-coco", daysAgo: 2)
        video("a-short", channelId: "UC-coco", daysAgo: 3, seconds: 40, short: true)
        video("guest-channel-cut", channelId: "UC-elsewhere", daysAgo: 4)
        try context.save()

        let show = try playlistShow(
            "Conan O'Brien Needs a Friend",
            channelId: "UC-coco",
            seasons: [(playlist: "PL-friend", name: "Conan O'Brien Needs a Friend",
                       videoIds: ["friend-2", "a-short", "friend-1", "guest-channel-cut"])]
        )

        XCTAssertEqual(show.id, "playlist:PL-friend")
        XCTAssertEqual(show.source, .playlist(id: "PL-friend", channelId: "UC-coco"))
        XCTAssertEqual(try manager.episodes(of: show).map(\.videoId),
                       ["friend-1", "guest-channel-cut", "friend-2"],
                       "the playlist's items, newest first; the channel's other videos are not episodes")
    }

    /// A playlist can hold a video from another channel, and a Short is never
    /// an episode however it got into the playlist.
    func testAPlaylistItemThatIsAShortIsStillNotAnEpisode() throws {
        video("ep", channelId: "UC-coco", daysAgo: 1)
        video("promo-short", channelId: "UC-coco", daysAgo: 2, seconds: 30, short: true)
        try context.save()

        let show = try playlistShow("Friend", channelId: "UC-coco",
                                    seasons: [(playlist: "PL-f", name: "Friend",
                                               videoIds: ["ep", "promo-short"])])
        XCTAssertEqual(try manager.episodes(of: show).map(\.videoId), ["ep"])
    }

    /// A network channel can be a show and host one too; they are two rows,
    /// and the channel's show still sees everything the channel puts out.
    func testAChannelShowAndAPlaylistShowOnTheSameChannelAreDifferentShows() throws {
        video("upload", channelId: "UC-coco", daysAgo: 1)
        video("podcast", channelId: "UC-coco", daysAgo: 2)
        try context.save()

        let channelShow = try manager.markAsShow(channelId: "UC-coco", channelTitle: "Team Coco")
        let show = try playlistShow("Needs a Friend", channelId: "UC-coco",
                                    seasons: [(playlist: "PL-f", name: "Needs a Friend",
                                               videoIds: ["podcast"])])

        XCTAssertNotEqual(channelShow.id, show.id)
        XCTAssertEqual(try manager.shows().count, 2)
        XCTAssertEqual(try manager.episodes(of: channelShow).map(\.videoId), ["upload", "podcast"])
        XCTAssertEqual(try manager.episodes(of: show).map(\.videoId), ["podcast"])
    }

    /// `EpisodeCard` resolves its caption and art preference through the
    /// pure, catalogue-in-hand overload rather than a fresh fetch, so it
    /// needs to agree with the stored-catalogue version exactly.
    func testShowContainingPrefersTheChannelShowOverAPlaylistShowOnTheSameChannel() throws {
        video("upload", channelId: "UC-coco", daysAgo: 1)
        let podcast = video("podcast", channelId: "UC-coco", daysAgo: 2)
        try context.save()

        let channelShow = try manager.markAsShow(channelId: "UC-coco", channelTitle: "Team Coco")
        _ = try playlistShow("Needs a Friend", channelId: "UC-coco",
                              seasons: [(playlist: "PL-f", name: "Needs a Friend", videoIds: ["podcast"])])

        XCTAssertEqual(try manager.show(containing: podcast)?.id, channelShow.id,
                       "the channel show is the whole of what the channel puts out, so it wins")
        XCTAssertEqual(ShowManager.show(containing: podcast, in: try manager.allRecords())?.id, channelShow.id,
                       "the catalogue-in-hand overload agrees with the fetching one")
    }

    func testShowContainingFindsAPlaylistShowForAGuestChannelsVideo() throws {
        let guestClip = video("guest-clip", channelId: "UC-guest", daysAgo: 1)
        try context.save()

        let show = try playlistShow("Needs a Friend", channelId: "UC-coco",
                                    seasons: [(playlist: "PL-f", name: "Needs a Friend",
                                               videoIds: ["guest-clip"])])

        XCTAssertEqual(try manager.show(containing: guestClip)?.id, show.id,
                       "a playlist can hold a guest channel's video, and that video is still an episode of this show")
        XCTAssertEqual(ShowManager.show(containing: guestClip, in: try manager.allRecords())?.id, show.id)
    }

    func testShowContainingIsNilForAVideoInNoShow() throws {
        let stray = video("stray", channelId: "UC-nowhere", daysAgo: 1)
        try context.save()

        XCTAssertNil(try manager.show(containing: stray))
        XCTAssertNil(ShowManager.show(containing: stray, in: try manager.allRecords()))
    }

    /// Categories and Priority are the channel's, read through its rule. The
    /// manager writes no rule of its own, so there is nothing to file twice.
    func testAPlaylistShowCarriesItsChannelAndCreatesNoRuleOfItsOwn() throws {
        let show = try playlistShow("Needs a Friend", channelId: "UC-coco",
                                    seasons: [(playlist: "PL-f", name: "Needs a Friend", videoIds: [])])
        XCTAssertEqual(show.channelId, "UC-coco")
        XCTAssertTrue(try context.fetch(FetchDescriptor<ChannelRule>()).isEmpty)
    }

    func testOnePlaylistIsAShowWithNothingToPickBetween() throws {
        let show = try playlistShow("Needs a Friend", channelId: "UC-coco",
                                    seasons: [(playlist: "PL-f", name: "Needs a Friend", videoIds: [])])
        XCTAssertFalse(show.hasSeasons)
        XCTAssertTrue(show.seasonNames.isEmpty)
        XCTAssertEqual(show.backingPlaylistIds, ["PL-f"])
    }

    func testSeveralPlaylistsBecomeOneShowWithASeasonEach() throws {
        video("s2e1", channelId: "UC-quiz", daysAgo: 7)
        video("s2e2", channelId: "UC-quiz", daysAgo: 1)
        video("s1e1", channelId: "UC-quiz", daysAgo: 60)
        video("s1e2", channelId: "UC-quiz", daysAgo: 53)
        try context.save()

        let show = try playlistShow("Quizmaster", channelId: "UC-quiz", seasons: [
            (playlist: "PL-s2", name: "Series 2", videoIds: ["s2e1", "s2e2"]),
            (playlist: "PL-s1", name: "Series 1", videoIds: ["s1e1", "s1e2"]),
        ])

        XCTAssertTrue(show.hasSeasons)
        XCTAssertEqual(show.seasonNames, ["Series 2", "Series 1"])
        XCTAssertEqual(try manager.episodes(of: show).map(\.videoId),
                       ["s2e2", "s2e1", "s1e2", "s1e1"],
                       "every season's episodes, newest first, until a season is picked")

        let all = try manager.episodes(of: show)
        XCTAssertEqual(ShowManager.episodes(all, inSeason: 0, of: show).map(\.videoId), ["s2e2", "s2e1"])
        XCTAssertEqual(ShowManager.episodes(all, inSeason: 1, of: show).map(\.videoId), ["s1e2", "s1e1"])
        XCTAssertEqual(ShowManager.episodes(all, inSeason: nil, of: show).count, 4, "nil is all seasons")
        XCTAssertEqual(ShowManager.episodes(all, inSeason: 9, of: show), [], "a season the show hasn't got")
        XCTAssertEqual(ShowManager.seasonIndex(of: all[0], in: show), 0)
        XCTAssertEqual(ShowManager.seasonIndex(of: all[3], in: show), 1)
    }

    /// Re-adding with fewer playlists drops the ones left out, membership and
    /// all, so a removed season can't linger in the episode list.
    func testDroppingASeasonDropsItsEpisodesToo() throws {
        video("s2e1", channelId: "UC-quiz", daysAgo: 1)
        video("s1e1", channelId: "UC-quiz", daysAgo: 60)
        try context.save()

        try playlistShow("Quizmaster", channelId: "UC-quiz", seasons: [
            (playlist: "PL-s2", name: "Series 2", videoIds: ["s2e1"]),
            (playlist: "PL-s1", name: "Series 1", videoIds: ["s1e1"]),
        ])
        let show = try manager.addPlaylistShow(
            [PlaylistChoice(playlistId: "PL-s2", title: "Series 2")],
            channelId: "UC-quiz"
        )

        XCTAssertFalse(show.hasSeasons)
        XCTAssertEqual(show.playlistItemIds.keys.sorted(), ["PL-s2"])
        XCTAssertEqual(try manager.episodes(of: show).map(\.videoId), ["s2e1"])
    }

    func testPlaylistShowsCountAndRetainLikeChannelShows() throws {
        video("e1", channelId: "UC-quiz", daysAgo: 1)
        video("e2", channelId: "UC-quiz", daysAgo: 8)
        video("e3", channelId: "UC-quiz", daysAgo: 15, watched: true)
        video("e4", channelId: "UC-quiz", daysAgo: 22)
        try context.save()

        let show = try playlistShow("Quizmaster", channelId: "UC-quiz",
                                    seasons: [(playlist: "PL-s", name: "Quizmaster",
                                               videoIds: ["e1", "e2", "e3", "e4"])])

        XCTAssertEqual(try manager.unwatchedCount(for: show), 3)
        show.retentionCount = 2
        XCTAssertEqual(try manager.episodes(of: show).map(\.videoId), ["e1", "e2"])
        XCTAssertEqual(try manager.unwatchedCount(for: show), 2)

        let all = try context.fetch(FetchDescriptor<Video>())
        XCTAssertEqual(ShowManager.unwatchedCounts(from: all, shows: [show])[show.id], 2,
                       "the grid's batched count agrees with the per-show one")
    }

    func testPlayNextFollowsAPlaylistShowsPlayOrder() throws {
        video("e1", channelId: "UC-quiz", daysAgo: 1)
        video("e2", channelId: "UC-quiz", daysAgo: 8)
        video("e3", channelId: "UC-quiz", daysAgo: 15)
        try context.save()

        let show = try playlistShow("Quizmaster", channelId: "UC-quiz",
                                    seasons: [(playlist: "PL-s", name: "Quizmaster",
                                               videoIds: ["e1", "e2", "e3"])])
        XCTAssertEqual(try manager.nextUp(of: show)?.videoId, "e1")
        show.playOrder = .oldestFirst
        XCTAssertEqual(try manager.nextUp(of: show)?.videoId, "e3")
    }

    /// The player's Next episode stays inside a playlist-backed show too,
    /// even though the channel behind it isn't a show.
    func testNextEpisodeStaysWithinAPlaylistShow() throws {
        let older = video("e2", channelId: "UC-quiz", daysAgo: 8)
        video("e1", channelId: "UC-quiz", daysAgo: 1)
        let stranger = video("loose", channelId: "UC-quiz", daysAgo: 4)
        try context.save()

        try playlistShow("Quizmaster", channelId: "UC-quiz",
                         seasons: [(playlist: "PL-s", name: "Quizmaster", videoIds: ["e1", "e2"])])

        XCTAssertEqual(try manager.nextEpisode(after: older)?.videoId, "e1")
        XCTAssertNil(try manager.nextEpisode(after: stranger),
                     "a video the playlist doesn't hold belongs to no show")
    }

    /// Unlike a channel, a playlist has no standing "not a show" decision to
    /// record: removing it leaves nothing behind.
    func testRemovingAPlaylistShowLeavesNoTombstone() throws {
        let show = try playlistShow("Quizmaster", channelId: "UC-quiz",
                                    seasons: [(playlist: "PL-s", name: "Quizmaster", videoIds: [])])
        XCTAssertEqual(try manager.playlistShows(forChannelId: "UC-quiz").map(\.id), [show.id])

        try manager.removePlaylistShow(show)
        XCTAssertTrue(try manager.allRecords().isEmpty)
        XCTAssertTrue(try manager.playlistShows(forChannelId: "UC-quiz").isEmpty)
    }

    /// A hand-made playlist show is the user's decision, so an automatic pass
    /// over its channel can't disturb it.
    func testAnAutomaticPassLeavesPlaylistShowsAlone() throws {
        let show = try playlistShow("Quizmaster", channelId: "UC-quiz",
                                    seasons: [(playlist: "PL-s", name: "Quizmaster", videoIds: [])])
        try manager.applyAutomaticVerdicts([ShowVerdict(
            channelId: "UC-quiz", channelTitle: "Quizmaster Extra", isShow: false
        )])
        XCTAssertNotNil(try manager.record(id: show.id))
        XCTAssertEqual(try manager.shows().map(\.title), ["Quizmaster"])
    }

    func testAddingNoPlaylistIsRefused() {
        XCTAssertThrowsError(try manager.addPlaylistShow([], channelId: "UC-quiz"))
    }
}
