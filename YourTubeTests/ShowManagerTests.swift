import XCTest
import SwiftData
@testable import YourTube

/// The show catalogue, driven through `ShowManager` against an in-memory
/// container the way `CategoryManagerTests` drives categories. `ShowDetector`'s
/// verdicts are handed in directly rather than computed (that's
/// `ShowDetectorTests`): what's under test here is that the user's decisions
/// survive a pass, and that a guess arrives with its reasons attached.
///
/// What a show *lists* is not here: that is `ShowListing`, a value type over
/// a show's settings and a pile of videos, tested container-free in
/// `ShowListingTests`. This suite keeps the store's own share of it — that
/// the fetching path hands the listing the same videos a live query would,
/// that membership writes land, and that "Mark all watched" reaches exactly
/// as far as the page does.
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
        manager = ShowManager(modelContext: context, watchState: WatchState(modelContext: context))
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

    // MARK: - Listing, fetched

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

    /// Hiding is presentation only, the same policy as Shorts: the feed and
    /// everything else still see every video.
    func testHiddenSegmentsAndOlderEpisodesAreStillInTheStore() throws {
        let show = try newsShow()
        show.retentionCount = 2

        XCTAssertEqual(try manager.listing(of: show).episodes.count, 2)
        XCTAssertEqual(try context.fetch(FetchDescriptor<Video>()).count, 20,
                       "nothing is deleted, so the feed still lists every one of them")
    }

    func testMarkAllWatchedLeavesSegmentsAlone() throws {
        let show = try newsShow()

        XCTAssertEqual(try manager.markAllWatched(of: show), 5)
        XCTAssertEqual(try manager.listing(of: show).unwatchedCount, 0)
        XCTAssertTrue(try manager.listing(of: show).segments.allSatisfy { !$0.isWatched },
                      "clearing a backlog doesn't reach behind the page")
    }

    /// The one thing the fetching path has to get right: it must hand
    /// `ShowListing` the same videos a view's live `@Query` would, so the
    /// page and the grid can't disagree about a show. Everything the listing
    /// then does with them is `ShowListingTests`, container-free.
    func testTheFetchedListingIsTheOneAViewWouldBuildFromALiveQuery() throws {
        let show = try newsShow(nights: 8)
        show.retentionCount = 3
        video("elsewhere", channelId: "UC-other", daysAgo: 1)
        video("a-short", channelId: "UC-news", daysAgo: 0.5, seconds: 30, short: true)
        try context.save()

        let fetched = try manager.listing(of: show)
        let handedIn = ShowListing(of: show, from: try context.fetch(FetchDescriptor<Video>()))

        XCTAssertEqual(fetched.episodes.map(\.videoId), handedIn.episodes.map(\.videoId))
        XCTAssertEqual(fetched.segments.map(\.videoId), handedIn.segments.map(\.videoId))
        XCTAssertEqual(fetched.hiddenByRetention, handedIn.hiddenByRetention)
        XCTAssertEqual(fetched.unwatchedCount, handedIn.unwatchedCount)
        XCTAssertEqual(fetched.unwatchedCount,
                       try manager.unwatchedCounts(for: [show])[show.id],
                       "and the grid's badge fetch agrees with both")
        XCTAssertEqual(fetched.episodes.map(\.videoId), ["ep-1", "ep-2", "ep-3"],
                       "another channel's video and a Short are no part of it")
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
        XCTAssertEqual(try manager.listing(of: show).unwatchedCount, 0)
        XCTAssertNil(try manager.listing(of: show).nextUp)
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
        XCTAssertEqual(try manager.listing(of: show).episodes.map(\.videoId),
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
        XCTAssertEqual(try manager.listing(of: show).episodes.map(\.videoId), ["ep"])
    }

    /// `ShowPageView`'s `channelVideos` query used to fetch every non-Short
    /// video in the store for a playlist-backed show, filtering to members in
    /// memory (issue #86). It now builds its predicate from the show's own
    /// `memberVideoIds`, the same narrowing `ShowManager+Badges.swift` got in
    /// #66 — checked here with a `fetchCount` of that exact predicate against
    /// a channel that also has uploads the playlist never picked up.
    func testShowPageViewsQueryFetchesOnlyThePlaylistsMembersNotTheWholeChannel() throws {
        video("friend-1", channelId: "UC-coco", daysAgo: 1)
        video("friend-2", channelId: "UC-coco", daysAgo: 8)
        video("non-member-upload", channelId: "UC-coco", daysAgo: 2)
        video("another-non-member-upload", channelId: "UC-coco", daysAgo: 3)
        video("guest-channel-cut", channelId: "UC-elsewhere", daysAgo: 4)
        try context.save()

        let show = try playlistShow(
            "Conan O'Brien Needs a Friend",
            channelId: "UC-coco",
            seasons: [(playlist: "PL-friend", name: "Conan O'Brien Needs a Friend",
                       videoIds: ["friend-1", "friend-2", "guest-channel-cut"])]
        )

        let predicate = ShowPageView.channelVideosPredicate(for: show)
        let fetchCount = try context.fetchCount(FetchDescriptor<Video>(predicate: predicate))

        XCTAssertEqual(fetchCount, 3,
                        "only the playlist's three members, not the channel's other two uploads")
        XCTAssertEqual(
            try context.fetch(FetchDescriptor<Video>(predicate: predicate)).map(\.videoId).sorted(),
            ["friend-1", "friend-2", "guest-channel-cut"]
        )
    }

    /// A channel-backed show's page still asks for its whole channel — the
    /// narrowing in #86 is for playlist-backed shows only.
    func testShowPageViewsQueryStillFetchesTheWholeChannelForAChannelBackedShow() throws {
        video("upload-1", channelId: "UC-coco", daysAgo: 1)
        video("upload-2", channelId: "UC-coco", daysAgo: 2)
        video("a-short", channelId: "UC-coco", daysAgo: 3, seconds: 30, short: true)
        video("other-channel", channelId: "UC-elsewhere", daysAgo: 1)
        try context.save()

        let show = try manager.markAsShow(channelId: "UC-coco", channelTitle: "Team Coco")

        let predicate = ShowPageView.channelVideosPredicate(for: show)
        let fetchCount = try context.fetchCount(FetchDescriptor<Video>(predicate: predicate))

        XCTAssertEqual(fetchCount, 2, "the channel's non-Short uploads, not the other channel's or the Short")
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
        XCTAssertEqual(try manager.listing(of: channelShow).episodes.map(\.videoId), ["upload", "podcast"])
        XCTAssertEqual(try manager.listing(of: show).episodes.map(\.videoId), ["podcast"])
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

        XCTAssertEqual(ShowManager.show(containing: podcast, in: try manager.allRecords())?.id,
                       channelShow.id,
                       "the channel show is the whole of what the channel puts out, so it wins")
    }

    func testShowContainingFindsAPlaylistShowForAGuestChannelsVideo() throws {
        let guestClip = video("guest-clip", channelId: "UC-guest", daysAgo: 1)
        try context.save()

        let show = try playlistShow("Needs a Friend", channelId: "UC-coco",
                                    seasons: [(playlist: "PL-f", name: "Needs a Friend",
                                               videoIds: ["guest-clip"])])

        XCTAssertEqual(ShowManager.show(containing: guestClip, in: try manager.allRecords())?.id, show.id,
                       "a playlist can hold a guest channel's video, and that video is still an episode of this show")
    }

    func testShowContainingIsNilForAVideoInNoShow() throws {
        let stray = video("stray", channelId: "UC-nowhere", daysAgo: 1)
        try context.save()

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
        let all = try manager.listing(of: show).episodes
        XCTAssertEqual(all.map(\.videoId), ["s2e2", "s2e1", "s1e2", "s1e1"],
                       "every season's episodes, newest first, until a season is picked")
        XCTAssertEqual(try manager.listing(of: show, season: 0).episodes.map(\.videoId),
                       ["s2e2", "s2e1"])
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
        XCTAssertEqual(try manager.listing(of: show).episodes.map(\.videoId), ["s2e1"])
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

        XCTAssertEqual(try manager.listing(of: show).unwatchedCount, 3)
        show.retentionCount = 2
        XCTAssertEqual(try manager.listing(of: show).episodes.map(\.videoId), ["e1", "e2"])
        XCTAssertEqual(try manager.listing(of: show).unwatchedCount, 2)
        XCTAssertEqual(try manager.unwatchedCounts(for: [show])[show.id], 2,
                       "the grid's badge fetch agrees with the page's")
    }

    func testPlayNextFollowsAPlaylistShowsPlayOrder() throws {
        video("e1", channelId: "UC-quiz", daysAgo: 1)
        video("e2", channelId: "UC-quiz", daysAgo: 8)
        video("e3", channelId: "UC-quiz", daysAgo: 15)
        try context.save()

        let show = try playlistShow("Quizmaster", channelId: "UC-quiz",
                                    seasons: [(playlist: "PL-s", name: "Quizmaster",
                                               videoIds: ["e1", "e2", "e3"])])
        XCTAssertEqual(try manager.listing(of: show).nextUp?.videoId, "e1")
        show.playOrder = .oldestFirst
        XCTAssertEqual(try manager.listing(of: show).nextUp?.videoId, "e3")
    }

    /// Unlike a channel, a playlist has no standing "not a show" decision to
    /// record: removing it leaves nothing behind. The channel's own show
    /// flag is a separate record, untouched by removing a playlist show
    /// filed under it.
    func testRemovingAPlaylistShowLeavesNoTombstone() throws {
        try manager.markAsShow(channelId: "UC-quiz", channelTitle: "Quizmaster Channel")
        let show = try playlistShow("Quizmaster", channelId: "UC-quiz",
                                    seasons: [(playlist: "PL-s", name: "Quizmaster", videoIds: [])])
        XCTAssertEqual(try manager.playlistShows(forChannelId: "UC-quiz").map(\.id), [show.id])

        try manager.removePlaylistShow(show)
        XCTAssertNil(try manager.record(id: show.id), "the playlist show itself is gone, no tombstone")
        XCTAssertTrue(try manager.playlistShows(forChannelId: "UC-quiz").isEmpty)
        XCTAssertTrue(try manager.isShow(channelId: "UC-quiz"),
                      "the channel's own show flag is a separate record and survives")
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
