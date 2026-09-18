import XCTest
@testable import YourTube

/// What a show lists, counts, hides and plays next — the whole derivation,
/// driven the way the app drives it: a show's settings, a season, and a pile
/// of videos in, one `ShowListing` out.
///
/// No `ModelContainer` anywhere in here. The listing never touches the store
/// (that's `ShowManager.listing(of:)`, one fetch), so these tests build the
/// videos they mean and read the answers off the value, the way
/// `ShowDetectorTests` does with `EpisodeSignals`. What used to need a
/// five-model container to assert arithmetic over six scalar fields is now
/// arithmetic over six scalar fields.
final class ShowListingTests: XCTestCase {

    // MARK: - Fixtures

    private func show(
        _ title: String = "Newsline",
        channelId: String = "UC-news",
        playOrder: PlayOrder = .newestFirst,
        retentionCount: Int? = nil,
        segmentThreshold: Double = Show.defaultSegmentThreshold,
        hideSegments: Bool = true
    ) -> Show {
        Show(
            source: .channel(id: channelId),
            title: title,
            flagOrigin: .user,
            override: .forceShow,
            playOrder: playOrder,
            retentionCount: retentionCount,
            segmentThreshold: segmentThreshold,
            hideSegments: hideSegments
        )
    }

    /// A playlist-backed show with its membership already recorded, as
    /// `addPlaylistShow` + `setPlaylistItems` would leave it. Several seasons
    /// make a show with a picker; one makes a show with nothing to pick.
    private func playlistShow(
        _ title: String = "Quizmaster",
        channelId: String = "UC-quiz",
        seasons: [(playlist: String, name: String, videoIds: [String])]
    ) -> Show {
        let show = Show(
            source: .playlist(id: seasons[0].playlist, channelId: channelId),
            title: title,
            flagOrigin: .user,
            override: .forceShow
        )
        show.seasonPlaylistIds = seasons.map(\.playlist)
        show.seasonNames = seasons.count > 1 ? seasons.map(\.name) : []
        show.playlistItemIds = Dictionary(
            uniqueKeysWithValues: seasons.map { ($0.playlist, $0.videoIds) }
        )
        return show
    }

    private func video(
        _ id: String,
        channelId: String = "UC-news",
        daysAgo: Double,
        seconds: Int = 2_400,
        watched: Bool = false
    ) -> Video {
        Video(
            videoId: id,
            channelId: channelId,
            channelTitle: channelId,
            title: id,
            videoDescription: "",
            publishedAt: Date(timeIntervalSinceNow: -daysAgo * 86_400),
            durationSeconds: seconds,
            isWatched: watched
        )
    }

    private func videoPublished(
        _ id: String,
        channelId: String = "UC-news",
        on date: Date,
        seconds: Int = 2_400
    ) -> Video {
        Video(
            videoId: id,
            channelId: channelId,
            channelTitle: channelId,
            title: id,
            videoDescription: "",
            publishedAt: date,
            durationSeconds: seconds
        )
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

    /// A news hour, the shape the segment rule exists for: one full episode a
    /// night, each trailed by clips cut out of it, so the cut-downs outnumber
    /// the episodes three to one and the plain median of the channel is a
    /// clip.
    private func newsNights(
        _ nights: Int = 5,
        episodeSeconds: Int = 3_180,
        segmentSeconds: [Int] = [620, 480, 405]
    ) -> [Video] {
        var videos: [Video] = []
        for night in 1...nights {
            videos.append(video("ep-\(night)", daysAgo: Double(night), seconds: episodeSeconds))
            for (index, seconds) in segmentSeconds.enumerated() {
                videos.append(video(
                    "ep-\(night)-seg-\(index)",
                    daysAgo: Double(night) - 0.1 * Double(index + 1),
                    seconds: seconds
                ))
            }
        }
        return videos
    }

    // MARK: - Membership

    func testEpisodesAreEveryFullLengthVideoFromTheChannel() {
        let listing = ShowListing(of: show(), from: [
            video("full-1", daysAgo: 1, seconds: 3_000),
            video("segment-1", daysAgo: 1.1, seconds: 480),
            video("full-2", daysAgo: 2, seconds: 3_100),
            video("elsewhere", channelId: "UC-other", daysAgo: 1),
        ])

        XCTAssertEqual(listing.episodes.map(\.videoId), ["full-1", "full-2"],
                       "another channel's video is never an episode, nor is a cut-down")
        XCTAssertEqual(listing.segments.map(\.videoId), ["segment-1"])
    }

    func testTheListIsAirOrderAndPlayNextFollowsThePlayOrder() {
        let videos = [
            video("new", daysAgo: 1),
            video("middle", daysAgo: 8),
            video("old", daysAgo: 15),
        ]

        let newestFirst = ShowListing(of: show(), from: videos)
        XCTAssertEqual(newestFirst.episodes.map(\.videoId), ["new", "middle", "old"])
        XCTAssertEqual(newestFirst.episodesInPlayOrder.map(\.videoId), ["new", "middle", "old"])

        let oldestFirst = ShowListing(of: show(playOrder: .oldestFirst), from: videos)
        XCTAssertEqual(oldestFirst.episodes.map(\.videoId), ["new", "middle", "old"],
                       "the page is read newest first whatever the play order")
        XCTAssertEqual(oldestFirst.episodesInPlayOrder.map(\.videoId), ["old", "middle", "new"],
                       "a backlog podcast is watched forwards")
    }

    func testRetentionWindowKeepsOnlyTheNewestEpisodes() {
        let videos = (1...6).map { video("ep-\($0)", daysAgo: Double($0)) }

        let all = ShowListing(of: show(), from: videos)
        XCTAssertEqual(all.episodes.count, 6)
        XCTAssertEqual(all.unwatchedCount, 6)
        XCTAssertEqual(all.hiddenByRetention, 0)

        let kept = ShowListing(of: show(retentionCount: 2), from: videos)
        XCTAssertEqual(kept.episodes.map(\.videoId), ["ep-1", "ep-2"])
        XCTAssertEqual(kept.hiddenByRetention, 4)
        XCTAssertEqual(kept.unwatchedCount, 2, "hidden episodes don't nag")
    }

    func testAPlaylistBackedShowsEpisodesAreItsPlaylistsItems() {
        let show = playlistShow(
            "Conan O'Brien Needs a Friend",
            channelId: "UC-coco",
            seasons: [(playlist: "PL-friend", name: "Friend",
                       videoIds: ["friend-2", "friend-1", "guest-channel-cut"])]
        )
        let listing = ShowListing(of: show, from: [
            video("friend-1", channelId: "UC-coco", daysAgo: 1),
            video("friend-2", channelId: "UC-coco", daysAgo: 8),
            video("non-member-upload", channelId: "UC-coco", daysAgo: 2),
            video("guest-channel-cut", channelId: "UC-elsewhere", daysAgo: 4),
        ])

        XCTAssertEqual(listing.episodes.map(\.videoId), ["friend-1", "guest-channel-cut", "friend-2"],
                       "the playlist's items, newest first, guest channel included; a non-member never")
    }

    // MARK: - Seasons

    /// The season is applied before classification, so everything the page
    /// says — the list, the retention window, the segment toggle, the footer
    /// — is about the season in front of you.
    func testASeasonNarrowsTheWholeListingAndNotJustTheList() {
        let show = playlistShow(seasons: [
            (playlist: "PL-s2", name: "Series 2", videoIds: ["s2e1", "s2e2", "s2clip"]),
            (playlist: "PL-s1", name: "Series 1", videoIds: ["s1e1", "s1e2"]),
        ])
        let videos = [
            video("s2e2", channelId: "UC-quiz", daysAgo: 1, seconds: 3_000),
            video("s2clip", channelId: "UC-quiz", daysAgo: 2, seconds: 600),
            video("s2e1", channelId: "UC-quiz", daysAgo: 7, seconds: 3_000),
            video("s1e2", channelId: "UC-quiz", daysAgo: 53, seconds: 3_000),
            video("s1e1", channelId: "UC-quiz", daysAgo: 60, seconds: 3_000),
        ]

        XCTAssertEqual(ShowListing(of: show, from: videos).episodes.map(\.videoId),
                       ["s2e2", "s2e1", "s1e2", "s1e1"],
                       "every season's episodes until a season is picked")

        let series2 = ShowListing(of: show, season: 0, from: videos)
        XCTAssertEqual(series2.episodes.map(\.videoId), ["s2e2", "s2e1"])
        XCTAssertEqual(series2.segments.map(\.videoId), ["s2clip"])
        XCTAssertEqual(series2.sourceCount, 3, "the season's videos, not the show's")

        let series1 = ShowListing(of: show, season: 1, from: videos)
        XCTAssertEqual(series1.episodes.map(\.videoId), ["s1e2", "s1e1"])
        XCTAssertEqual(series1.unwatchedCount, 2)

        XCTAssertEqual(ShowListing(of: show, season: nil, from: videos).episodes.count, 4,
                       "nil is all seasons")
        XCTAssertTrue(ShowListing(of: show, season: 9, from: videos).episodes.isEmpty,
                      "a season the show hasn't got")
    }

    /// Picking a season on a show with a retention window keeps the last N of
    /// *that* season — the whole point of narrowing before the window rather
    /// than after, which would leave an older series empty.
    func testASeasonsRetentionWindowIsTheSeasonsOwn() {
        let show = playlistShow(seasons: [
            (playlist: "PL-s2", name: "Series 2", videoIds: ["s2e1", "s2e2", "s2e3"]),
            (playlist: "PL-s1", name: "Series 1", videoIds: ["s1e1", "s1e2"]),
        ])
        show.retentionCount = 2
        let videos = [
            video("s2e3", channelId: "UC-quiz", daysAgo: 1),
            video("s2e2", channelId: "UC-quiz", daysAgo: 8),
            video("s2e1", channelId: "UC-quiz", daysAgo: 15),
            video("s1e2", channelId: "UC-quiz", daysAgo: 53),
            video("s1e1", channelId: "UC-quiz", daysAgo: 60),
        ]

        XCTAssertTrue(ShowListing(of: show, from: videos).episodes
            .allSatisfy { $0.videoId.hasPrefix("s2") }, "the window alone hides the older series")

        let series1 = ShowListing(of: show, season: 1, from: videos)
        XCTAssertEqual(series1.episodes.map(\.videoId), ["s1e2", "s1e1"],
                       "picking a series shows it, rather than the last two episodes of the show")
        XCTAssertEqual(series1.hiddenByRetention, 0)
    }

    // MARK: - Segments

    func testCutDownsAreSegmentsEvenWhenTheyOutnumberTheEpisodes() {
        let listing = ShowListing(of: show(), from: newsNights())

        XCTAssertEqual(listing.episodes.map(\.videoId), ["ep-1", "ep-2", "ep-3", "ep-4", "ep-5"],
                       "the full episodes, and only those, even though they're a quarter of the channel")
        XCTAssertEqual(listing.segments.count, 15)
        XCTAssertEqual(listing.segmentCount, 15)
        XCTAssertEqual(listing.sourceCount, 20)
        XCTAssertEqual(listing.typicalEpisodeDuration, 3_180,
                       "the typical length of a news hour is the hour, not the clips cut from it")
        XCTAssertEqual(listing.everything.count, 20, "the toggle reveals them; nothing is lost")
    }

    /// The rule's edge, which is where a per-show threshold has to be exact:
    /// half of a typical episode to the second.
    func testAVideoIsASegmentJustUnderTheThresholdAndAnEpisodeAtIt() {
        let nights = (1...5).map { video("ep-\($0)", daysAgo: Double($0), seconds: 3_000) }

        let justUnder = ShowListing(of: show(), from: nights + [video("candidate", daysAgo: 0.5, seconds: 1_499)])
        XCTAssertEqual(justUnder.typicalEpisodeDuration, 3_000)
        XCTAssertEqual(justUnder.segments.map(\.videoId), ["candidate"],
                       "a second under half an episode is a cut-down of one")

        let exactlyHalf = ShowListing(of: show(), from: nights + [video("candidate", daysAgo: 0.5, seconds: 1_500)])
        XCTAssertTrue(exactlyHalf.segments.isEmpty)
        XCTAssertTrue(exactlyHalf.episodes.contains { $0.videoId == "candidate" },
                      "exactly half is still an episode")
    }

    func testChangingTheThresholdReclassifiesImmediately() {
        let videos = (1...5).map { video("ep-\($0)", daysAgo: Double($0), seconds: 3_000) }
            + [video("half-hour", daysAgo: 0.5, seconds: 1_800)]

        let byDefault = ShowListing(of: show(), from: videos)
        XCTAssertEqual(Show.defaultSegmentThreshold, 0.5, "half by default")
        XCTAssertTrue(byDefault.segments.isEmpty, "a half-length instalment is an episode")
        XCTAssertEqual(byDefault.unwatchedCount, 6)

        let stricter = ShowListing(of: show(segmentThreshold: 0.7), from: videos)
        XCTAssertEqual(stricter.segments.map(\.videoId), ["half-hour"],
                       "a stricter show calls it a cut-down")
        XCTAssertEqual(stricter.unwatchedCount, 5, "and stops counting it")
    }

    /// The per-show override for when the app still gets classification
    /// wrong: turning "Hide segments" off lists everything as an episode,
    /// whatever the threshold would otherwise do.
    func testHideSegmentsOffListsEverythingAsAnEpisode() {
        let listing = ShowListing(of: show(hideSegments: false), from: newsNights())

        XCTAssertTrue(listing.segments.isEmpty)
        XCTAssertEqual(listing.episodes.count, 20, "every source video, episodes and clips alike")
        XCTAssertNil(listing.typicalEpisodeDuration)
    }

    /// The reason "typical" isn't the longest episode: a show that runs one
    /// election special mustn't spend the rest of the year calling its
    /// ordinary episodes clips.
    func testOneFeatureLengthSpecialDoesNotDemoteTheOrdinaryEpisodes() {
        let listing = ShowListing(of: show(), from: [1_500, 1_800, 2_100, 2_400, 21_600]
            .enumerated().map { video("ep-\($0.offset)", daysAgo: Double($0.offset + 1), seconds: $0.element) })

        XCTAssertTrue(listing.segments.isEmpty)
        XCTAssertEqual(listing.episodes.count, 5)
    }

    func testAShowWhoseEpisodesAreAllOfALengthHasNoSegments() {
        let listing = ShowListing(of: show(), from: [5_700, 6_240, 5_100, 6_600, 5_460, 5_880]
            .enumerated().map { video("ep-\($0.offset)", daysAgo: Double($0.offset + 1), seconds: $0.element) })

        XCTAssertTrue(listing.segments.isEmpty)
        XCTAssertEqual(listing.typicalEpisodeDuration, 5_700)
    }

    /// Breaking Points posts only clips — its full episodes go to a paid feed
    /// — so its uploads run a continuous range of lengths with no real gap
    /// anywhere in them. The old rule still drew a line through the middle of
    /// that range and called the shorter half segments; the gap check is what
    /// stops it, per issue #90.
    func testAChannelOfClipsOnlyWithNoGapHidesNothing() {
        let seconds = [2799, 843, 1041, 1445, 850, 1331, 1530, 766, 627, 696, 1218, 780, 2127, 588,
                       720, 915, 2340, 1740, 1689, 1198, 1233, 1846, 693, 1475, 895, 640, 1860, 1613,
                       1515, 2298]
        let listing = ShowListing(of: show(), from: seconds.enumerated()
            .map { video("bp-\($0.offset)", daysAgo: Double($0.offset + 1), seconds: $0.element) })

        XCTAssertTrue(listing.segments.isEmpty,
                      "no gap between any group of lengths, so nothing is a segment of anything else")
        XCTAssertEqual(listing.episodes.count, 30)
        XCTAssertNil(listing.typicalEpisodeDuration)
    }

    /// Neal Brennan really does mix full episodes with clips cut from them —
    /// four hour-plus episodes against twenty-six short ones — and the gap
    /// between the two groups is real, so the gap check must still find it.
    func testAChannelWithARealGapStillSplitsEpisodesFromClips() {
        let seconds = [343, 551, 930, 369, 595, 4_926, 536, 501, 1_007, 440, 473, 408, 5_301, 335,
                       610, 602, 398, 500, 307, 5_075, 223, 1_192, 741, 275, 738, 663, 5_690, 497,
                       495, 509]
        let listing = ShowListing(of: show(), from: seconds.enumerated()
            .map { video("nb-\($0.offset)", daysAgo: Double($0.offset + 1), seconds: $0.element) })

        XCTAssertEqual(listing.episodes.count, 4, "the four hour-plus episodes")
        XCTAssertEqual(listing.segments.count, 26, "everything cut from them")
    }

    /// Team Coco splits twelve hour-long shows from eighteen shorter clips —
    /// a smaller but still real gap, which the check must not be too strict
    /// to find.
    func testAChannelWithASmallerRealGapStillSplitsEpisodesFromClips() {
        let seconds = [4_237, 467, 482, 3_964, 371, 4_022, 295, 1_337, 602, 3_586, 615, 462, 4_488,
                       659, 3_553, 1_246, 4_269, 463, 592, 4_097, 394, 3_431, 1_440, 4_088, 725, 606,
                       4_331, 511, 3_051, 1_200]
        let listing = ShowListing(of: show(), from: seconds.enumerated()
            .map { video("coco-\($0.offset)", daysAgo: Double($0.offset + 1), seconds: $0.element) })

        XCTAssertEqual(listing.episodes.count, 12, "the twelve hour-long shows")
        XCTAssertEqual(listing.segments.count, 18, "everything shorter")
    }

    /// An unmeasured video is listed rather than hidden: the app would rather
    /// show something it can't measure than quietly bury it.
    func testAVideoWithNoDurationYetIsAnEpisode() {
        let listing = ShowListing(of: show(), from: newsNights() + [video("unmeasured", daysAgo: 0.1, seconds: 0)])

        XCTAssertTrue(listing.episodes.contains { $0.videoId == "unmeasured" })
    }

    /// The retention edge for segments: a clip belongs to the episode it was
    /// cut from, so revealing segments must not drag back the era the window
    /// is there to hide — while the settings sheet still counts every clip
    /// the threshold is hiding, window or no window.
    func testRevealingSegmentsStopsAtTheOldestListedEpisode() {
        let listing = ShowListing(of: show(retentionCount: 3), from: newsNights(8))

        XCTAssertEqual(listing.episodes.map(\.videoId), ["ep-1", "ep-2", "ep-3"])
        XCTAssertEqual(listing.hiddenByRetention, 5)
        XCTAssertEqual(listing.segments.count, 9, "three nights' clips, not eight nights'")
        XCTAssertTrue(listing.segments.allSatisfy { segment in
            segment.publishedAt >= listing.episodes.last!.publishedAt
        }, "nothing older than the oldest episode still on the page")
        XCTAssertEqual(listing.segmentCount, 24,
                       "the settings sheet still says what the threshold does to the whole catalogue")
        XCTAssertEqual(listing.everything.count, 12)
    }

    /// The window's edge moves with the window: with every episode kept,
    /// every clip comes back.
    func testWithNoRetentionWindowEveryClipIsRevealable() {
        let listing = ShowListing(of: show(), from: newsNights(8))

        XCTAssertEqual(listing.segments.count, 24)
        XCTAssertEqual(listing.hiddenByRetention, 0)
    }

    // MARK: - Counts

    func testUnwatchedCountIgnoresWatchedAndSegments() {
        let listing = ShowListing(of: show(), from: [
            video("new-1", daysAgo: 1, seconds: 3_000),
            video("new-2", daysAgo: 2, seconds: 3_000),
            video("seen", daysAgo: 3, seconds: 3_000, watched: true),
            video("clip", daysAgo: 5, seconds: 400),
        ])

        XCTAssertEqual(listing.unwatchedCount, 2)
    }

    func testUnwatchedCountIsZeroWhenCaughtUp() {
        let listing = ShowListing(of: show(), from: [
            video("seen-1", daysAgo: 1, watched: true),
            video("seen-2", daysAgo: 2, watched: true),
        ])

        XCTAssertEqual(listing.unwatchedCount, 0, "no badge at zero")
        XCTAssertNil(listing.nextUp)
    }

    /// The grid's badge and the page's header are the same number because
    /// they are the same listing. The batch answer is checked against the
    /// per-show one for every show, retention window and all.
    func testTheGridsBadgeIsThePagesCount() {
        let news = show("Newsline", channelId: "UC-news", retentionCount: 3)
        let pod = show("Second Take", channelId: "UC-pod")
        let quiet = show("Nothing Yet", channelId: "UC-quiet")
        let friend = playlistShow("Friend", channelId: "UC-coco",
                                  seasons: [(playlist: "PL-f", name: "Friend",
                                             videoIds: ["guest-clip", "coco-1"])])
        let videos = (1...5).map { video("n-\($0)", daysAgo: Double($0)) } + [
            video("n-seen", daysAgo: 6, watched: true),
            video("n-old", daysAgo: 7),
            video("p-1", channelId: "UC-pod", daysAgo: 1),
            video("guest-clip", channelId: "UC-guest", daysAgo: 1),
            video("coco-1", channelId: "UC-coco", daysAgo: 2, watched: true),
            video("stray", channelId: "UC-unflagged", daysAgo: 1),
        ]

        let shows = [news, pod, quiet, friend]
        let counts = ShowListing.unwatchedCounts(from: videos, shows: shows)
        XCTAssertEqual(counts["channel:UC-news"], 3, "the retention window applies to the badge too")
        XCTAssertEqual(counts["channel:UC-pod"], 1)
        XCTAssertEqual(counts["channel:UC-quiet"], 0)
        XCTAssertEqual(counts["playlist:PL-f"], 1, "a guest channel's video still counts")
        XCTAssertNil(counts["channel:UC-unflagged"], "a channel that isn't a show isn't counted")
        for show in shows {
            XCTAssertEqual(counts[show.id], ShowListing(of: show, from: videos).unwatchedCount,
                           "\(show.title): the badge promises exactly what the page lists")
        }
    }

    // MARK: - Play next

    func testPlayNextIsTheNewestUnwatchedWhenTheShowPlaysNewestFirst() {
        let listing = ShowListing(of: show(), from: [
            video("newest", daysAgo: 1),
            video("middle", daysAgo: 2),
            video("oldest", daysAgo: 3),
        ])

        XCTAssertEqual(listing.nextUp?.videoId, "newest")
    }

    func testPlayNextIsTheOldestUnwatchedWhenTheShowPlaysOldestFirst() {
        let listing = ShowListing(of: show(playOrder: .oldestFirst), from: [
            video("newest", daysAgo: 1),
            video("middle", daysAgo: 2),
            video("oldest", daysAgo: 3, watched: true),
        ])

        XCTAssertEqual(listing.nextUp?.videoId, "middle",
                       "a backlog is walked forwards, but not back over what's watched")
    }

    func testAnEpisodeInProgressWinsUnderEitherPlayOrder() {
        let started = video("middle", daysAgo: 2)
        started.resumePositionSeconds = 900
        started.lastPlayedAt = Date(timeIntervalSinceNow: -3_600)
        let videos = [video("newest", daysAgo: 1), started, video("oldest", daysAgo: 3)]

        XCTAssertEqual(ShowListing(of: show(), from: videos).nextUp?.videoId, "middle")
        XCTAssertEqual(ShowListing(of: show(playOrder: .oldestFirst), from: videos).nextUp?.videoId,
                       "middle", "the one you walked away from is the one you meant")
        XCTAssertTrue(ShowListing.isResumable(started), "so the button reads Resume")
    }

    /// Two half-watched episodes is rare, but when it happens the one you
    /// touched last is the one you meant — the rule that orders Continue
    /// Watching.
    func testTheMostRecentlyPlayedHalfWatchedEpisodeWins() {
        let older = video("older-start", daysAgo: 4)
        older.resumePositionSeconds = 600
        older.lastPlayedAt = Date(timeIntervalSinceNow: -86_400)
        let recent = video("recent-start", daysAgo: 2)
        recent.resumePositionSeconds = 300
        recent.lastPlayedAt = Date(timeIntervalSinceNow: -600)

        let listing = ShowListing(of: show(), from: [video("newest", daysAgo: 1), recent, older])
        XCTAssertEqual(listing.nextUp?.videoId, "recent-start")
    }

    /// The thirty-second rule from `WatchState`: a glance isn't a start, so
    /// it mustn't hijack Play next either.
    func testAGlanceAtAnEpisodeDoesNotCountAsInProgress() {
        let glanced = video("middle", daysAgo: 2)
        glanced.resumePositionSeconds = 12
        glanced.lastPlayedAt = .now

        let listing = ShowListing(of: show(), from: [video("newest", daysAgo: 1), glanced])
        XCTAssertEqual(listing.nextUp?.videoId, "newest")
        XCTAssertFalse(ShowListing.isResumable(glanced))
    }

    func testPlayNextOpensAnEpisodeAndNeverAClip() {
        let listing = ShowListing(of: show(), from: newsNights())

        XCTAssertEqual(listing.nextUp?.videoId, "ep-1",
                       "the newest full episode, not the clip posted after it")
    }

    func testPlayNextStaysInsideTheRetentionWindow() {
        let videos = (1...6).map { day in
            video("ep-\(day)", daysAgo: Double(day), watched: day <= 2)
        }
        let listing = ShowListing(of: show(retentionCount: 2), from: videos)

        XCTAssertNil(listing.nextUp, "the page is caught up, whatever the window hides behind it")
    }

    // MARK: - Footer

    func testTheFooterSaysWhatIsHiddenAndWhy() throws {
        let listing = ShowListing(of: show(retentionCount: 3), from: newsNights(8))

        let hidden = try XCTUnwrap(listing.hiddenSummary(revealingSegments: false))
        XCTAssertTrue(hidden.hasPrefix("9 segments and 5 older episodes hidden,"), hidden)
        XCTAssertTrue(hidden.contains("not deleted"), hidden)

        let revealed = try XCTUnwrap(listing.hiddenSummary(revealingSegments: true))
        XCTAssertTrue(revealed.hasPrefix("5 older episodes hidden,"), revealed)

        XCTAssertNil(ShowListing(of: show(), from: newsNights(8).filter { $0.durationSeconds > 1_000 })
            .hiddenSummary(revealingSegments: true),
            "a page showing everything it has says nothing")
    }

    func testTheFooterCountsOneHiddenThingInTheSingular() throws {
        let videos = (1...4).map { video("ep-\($0)", daysAgo: Double($0)) }
        let listing = ShowListing(of: show(retentionCount: 3), from: videos)

        XCTAssertEqual(listing.hiddenSummary(revealingSegments: false),
                       "1 older episode hidden, not deleted.")
    }

    // MARK: - Cadence and typical duration

    func testCadenceIsTheWeekdaysTheShowHasPostedOnAtLeastTwice() {
        var videos = (0..<3).flatMap { week in
            [videoPublished("tue-\(week)", on: weekday(3, weeksAgo: week + 1)),
             videoPublished("fri-\(week)", on: weekday(6, weeksAgo: week + 1))]
        }
        // One Sunday special is an accident, not a habit.
        videos.append(videoPublished("sun", on: weekday(1, weeksAgo: 2)))

        XCTAssertEqual(ShowListing(of: show(), from: videos).cadenceWeekdays(), [3, 6])
    }

    func testCadenceIsEmptyUntilAShowHasAHabit() {
        let listing = ShowListing(of: show(), from: [videoPublished("one", on: weekday(3, weeksAgo: 1))])

        XCTAssertTrue(listing.cadenceWeekdays().isEmpty)
    }

    func testCadenceOnlyCountsEpisodesTheRetentionWindowKeeps() {
        let videos = (0..<3).map { videoPublished("tue-\($0)", on: weekday(3, weeksAgo: $0 + 1)) }
            + (0..<3).map { videoPublished("sat-\($0)", on: weekday(7, weeksAgo: $0 + 4)) }

        XCTAssertEqual(ShowListing(of: show(), from: videos).cadenceWeekdays(), [3, 7])
        XCTAssertEqual(ShowListing(of: show(retentionCount: 3), from: videos).cadenceWeekdays(), [3],
                       "a show that moved night stops claiming the old one")
    }

    func testTypicalDurationIsTheMedianEpisodeLength() {
        // One feature-length special mustn't move the number the show is
        // described by, which is why it's the median and not the mean.
        let listing = ShowListing(of: show(), from: [1_500, 1_800, 2_100, 2_400, 21_600]
            .enumerated().map { video("ep-\($0.offset)", daysAgo: Double($0.offset + 1), seconds: $0.element) })

        XCTAssertEqual(listing.typicalDuration, 2_100)
    }

    /// One median, one tie-break: an even count takes the shorter of the two
    /// middles, so the number a show is described by never overstates — and
    /// the line the segment rule draws at a fraction of it never creeps up
    /// into real episodes.
    func testAnEvenNumberOfEpisodesTakesTheShorterMiddle() {
        let listing = ShowListing(of: show(), from: [1_800, 2_400, 3_000, 3_600]
            .enumerated().map { video("ep-\($0.offset)", daysAgo: Double($0.offset + 1), seconds: $0.element) })

        XCTAssertEqual(listing.typicalDuration, 2_400)
        XCTAssertEqual(ShowListing.median(of: [1_800, 2_400, 3_000, 3_600]), 2_400)
        XCTAssertEqual(ShowListing.median(of: [1_800, 2_400, 3_000]), 2_400)
        XCTAssertNil(ShowListing.median(of: []))
        XCTAssertNil(ShowListing.median(of: [0, 0]), "nothing measured yet is not a length of zero")
    }

    func testTypicalDurationIsNothingForAShowWithNoEpisodes() {
        let listing = ShowListing(of: show(), from: [])

        XCTAssertNil(listing.typicalDuration)
        XCTAssertNil(listing.cadenceDescription())
        XCTAssertEqual(listing.unwatchedCount, 0)
        XCTAssertNil(listing.nextUp)
    }

    func testCadenceLineNamesTheWeekdaysAndTheTypicalLength() {
        let videos = (0..<2).flatMap { week in
            [videoPublished("tue-\(week)", on: weekday(3, weeksAgo: week + 1), seconds: 4_500),
             videoPublished("fri-\(week)", on: weekday(6, weeksAgo: week + 1), seconds: 4_500)]
        }

        let symbols = Calendar.current.shortWeekdaySymbols
        XCTAssertEqual(ShowListing(of: show(), from: videos).cadenceDescription(),
                       "Posts \(symbols[2]), \(symbols[5]) · about 1 hr 15 min")
    }

    func testCadenceLineStandsAloneWhenTheShowHasNoRegularDay() {
        let videos = [
            videoPublished("mon", on: weekday(2, weeksAgo: 1), seconds: 2_700),
            videoPublished("wed", on: weekday(4, weeksAgo: 2), seconds: 2_700),
            videoPublished("sat", on: weekday(7, weeksAgo: 3), seconds: 2_700),
        ]

        XCTAssertEqual(ShowListing(of: show(), from: videos).cadenceDescription(),
                       "Episodes about 45 min")
    }

    /// A typical length is a shape, not a measurement: it rounds.
    func testApproximateLengthRoundsToFiveMinutes() {
        XCTAssertEqual(ShowListing.approximateLength(3_540), "1 hr")
        XCTAssertEqual(ShowListing.approximateLength(3_780), "1 hr 5 min")
        XCTAssertEqual(ShowListing.approximateLength(2_580), "45 min")
        XCTAssertEqual(ShowListing.approximateLength(45), "5 min", "nothing rounds away to nothing")
        XCTAssertNil(ShowListing.approximateLength(0))
    }
}
