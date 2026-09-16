import XCTest
@testable import YourTube

/// The show detector guesses, so it gets a corpus rather than examples.
///
/// NOTE: the corpus below is hand-written to sit on the decision boundary, not
/// captured from live API responses — the same caveat as
/// `ShortsHeuristicTests`. It's built from the six shapes the PRD names as the
/// hard cases: a twice-weekly hour-long news show, a weekly numbered podcast,
/// and a daily news show (all shows); a maker channel with irregular long
/// videos, a vlog channel, and a clips channel (all not). Replace it with
/// captured `videos.list` output before trusting any precision figure.
final class ShowDetectorTests: XCTestCase {
    /// Fixed so a test never depends on what day it is run.
    private static let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        calendar.locale = Locale(identifier: "en_US_POSIX")
        return calendar
    }()

    /// A fixed Thursday (2026-01-01), so a corpus built by counting days back
    /// lands on the same weekdays every run.
    private static let reference = Date(timeIntervalSince1970: 1_767_225_600)

    private func verdict(_ channel: ChannelEvidence, now: Date = ShowDetectorTests.reference) -> ShowVerdict {
        ShowDetector.verdict(for: channel, calendar: Self.calendar, now: now)
    }

    // MARK: - Corpus

    /// A channel posting on `weekdays` (1 = Sunday), newest first, each upload
    /// titled and sized by `episode`.
    private static func channel(
        id: String,
        title: String,
        weekdays: [Int],
        count: Int,
        categoryId: String? = nil,
        description: String = "",
        episode: (Int) -> (title: String, seconds: Int)
    ) -> ChannelEvidence {
        var videos: [EpisodeSignals] = []
        var day = calendar.startOfDay(for: reference)
        var index = 0
        while videos.count < count {
            if weekdays.contains(calendar.component(.weekday, from: day)) {
                let (episodeTitle, seconds) = episode(index)
                videos.append(EpisodeSignals(
                    durationSeconds: seconds,
                    publishedAt: day,
                    title: episodeTitle,
                    description: description,
                    categoryId: categoryId
                ))
                index += 1
            }
            day = calendar.date(byAdding: .day, value: -1, to: day)!
        }
        return ChannelEvidence(channelId: id, channelTitle: title, videos: videos)
    }

    /// Uploads at exactly the given day offsets, for channels with no rhythm.
    private static func channel(
        id: String,
        title: String,
        dayOffsets: [Int],
        categoryId: String? = nil,
        description: String = "",
        episode: (Int) -> (title: String, seconds: Int)
    ) -> ChannelEvidence {
        let videos = dayOffsets.enumerated().map { index, offset -> EpisodeSignals in
            let (episodeTitle, seconds) = episode(index)
            return EpisodeSignals(
                durationSeconds: seconds,
                publishedAt: calendar.date(byAdding: .day, value: -offset, to: reference)!,
                title: episodeTitle,
                description: description,
                categoryId: categoryId
            )
        }
        return ChannelEvidence(channelId: id, channelTitle: title, videos: videos)
    }

    /// Tuesdays and Fridays, an hour and a bit each time.
    private var twiceWeeklyNewsShow: ChannelEvidence {
        Self.channel(
            id: "UC-bellwether", title: "The Bellwether",
            weekdays: [3, 6], count: 10, categoryId: "25",
            description: "The Bellwether is a twice-weekly interview programme."
        ) { index in ("Guest \(index) on what comes next | The Bellwether", 3_900 + index * 60) }
    }

    /// Wednesdays, numbered, an hour and a half.
    private var weeklyNumberedPodcast: ChannelEvidence {
        Self.channel(
            id: "UC-secondtake", title: "Second Take",
            weekdays: [4], count: 8, categoryId: "22",
            description: "A podcast about the films we got wrong."
        ) { index in ("#\(147 - index) — Guest \(index) — Second Take", 5_400 + index * 120) }
    }

    /// Weekdays: one full hour plus three cut-downs each evening, which is why
    /// its median upload is a five-minute clip and it still has to be a show.
    private var dailyNewsShowWithSegments: ChannelEvidence {
        let base = Self.channel(
            id: "UC-newsline", title: "Newsline Nightly",
            weekdays: [2, 3, 4, 5, 6], count: 10, categoryId: "25",
            description: "Tonight's programme."
        ) { _ in ("Newsline Nightly — FULL EPISODE", 3_180) }
        var videos = base.videos
        for episode in base.videos {
            for offset in 1...3 {
                videos.append(EpisodeSignals(
                    durationSeconds: 420 + offset * 60,
                    publishedAt: episode.publishedAt.addingTimeInterval(Double(offset) * 2_700),
                    title: "Newsline Nightly: segment \(offset)",
                    description: episode.description,
                    categoryId: "25"
                ))
            }
        }
        return ChannelEvidence(channelId: base.channelId, channelTitle: base.channelTitle, videos: videos)
    }

    /// Long videos, no schedule: the case the threshold exists for.
    private var makerChannel: ChannelEvidence {
        Self.channel(
            id: "UC-lmnc", title: "Look Mum No Computer",
            dayOffsets: [2, 19, 26, 48, 55, 79, 96, 130], categoryId: "26",
            description: "I built a thing in the bunker."
        ) { index in ("Building a synth from a \(index) key toy", 1_500 + index * 220) }
    }

    /// Short, chatty, whenever.
    private var vlogChannel: ChannelEvidence {
        Self.channel(
            id: "UC-berlin", title: "Berlin Vlogs",
            dayOffsets: [1, 3, 8, 9, 17, 24, 25, 40], categoryId: "22",
            description: "A week in Kreuzberg."
        ) { index in ("Straße walk, day \(index)", 600 + index * 90) }
    }

    /// Several a day, every day, none of them long.
    private var clipsChannel: ChannelEvidence {
        var videos: [EpisodeSignals] = []
        for day in 0..<12 {
            for slot in 0..<3 {
                videos.append(EpisodeSignals(
                    durationSeconds: 300 + slot * 45,
                    publishedAt: Self.calendar.date(byAdding: .day, value: -day, to: Self.reference)!
                        .addingTimeInterval(Double(slot) * 3_600),
                    title: "Best of the week: clip \(day)-\(slot)",
                    description: "Clips from the show.",
                    categoryId: "24"
                ))
            }
        }
        return ChannelEvidence(channelId: "UC-clips", channelTitle: "Conan Clips Archive", videos: videos)
    }

    // MARK: - The corpus, end to end

    func testCorpusVerdicts() {
        let corpus: [(channel: ChannelEvidence, isShow: Bool)] = [
            (twiceWeeklyNewsShow, true),
            (weeklyNumberedPodcast, true),
            (dailyNewsShowWithSegments, true),
            (makerChannel, false),
            (vlogChannel, false),
            (clipsChannel, false),
        ]
        for (channel, expected) in corpus {
            let verdict = verdict(channel)
            XCTAssertEqual(verdict.isShow, expected,
                           "\(channel.channelTitle): \(verdict.reasons.joined(separator: "; "))")
            XCTAssertEqual(verdict.channelId, channel.channelId)
            XCTAssertEqual(verdict.channelTitle, channel.channelTitle)
        }
    }

    /// Every flagged channel has to be able to say why, or the user can't
    /// trust or correct the guess.
    func testEveryShowVerdictReportsItsReasons() {
        for channel in [twiceWeeklyNewsShow, weeklyNumberedPodcast, dailyNewsShowWithSegments] {
            let reasons = verdict(channel).reasons
            XCTAssertFalse(reasons.isEmpty, "\(channel.channelTitle) was flagged with no reason")
            XCTAssertFalse(reasons.contains { $0.isEmpty })
        }
    }

    // MARK: - Which signals fired

    func testTwiceWeeklyNewsShowIsFlaggedOnLengthCadenceAndCategory() {
        let reasons = verdict(twiceWeeklyNewsShow).reasons
        XCTAssertTrue(reasons.contains { $0.hasPrefix("Episodes usually run") }, "\(reasons)")
        XCTAssertTrue(reasons.contains { $0.hasPrefix("Posts on a regular schedule") }, "\(reasons)")
        XCTAssertTrue(reasons.contains("YouTube files it under News & Politics"), "\(reasons)")
    }

    func testNumberedPodcastIsFlaggedOnItsNumbering() {
        let reasons = verdict(weeklyNumberedPodcast).reasons
        XCTAssertTrue(reasons.contains("Titles are numbered episodes"), "\(reasons)")
        XCTAssertTrue(reasons.contains { $0.contains("podcast") }, "\(reasons)")
        // People & Blogs is no evidence either way.
        XCTAssertFalse(reasons.contains { $0.hasPrefix("YouTube files it under") }, "\(reasons)")
    }

    /// The case that kills a naive median-duration rule: three quarters of the
    /// uploads are five-minute cut-downs.
    func testDailyNewsShowSurvivesItsOwnSegments() {
        let channel = dailyNewsShowWithSegments
        let median = ShowDetector.median(channel.videos.map(\.durationSeconds))
        XCTAssertLessThan(median ?? 0, ShowDetector.longFormSeconds)
        let reasons = verdict(channel).reasons
        XCTAssertFalse(reasons.contains { $0.hasPrefix("Episodes usually run") }, "\(reasons)")
        XCTAssertEqual(reasons.first, "Posts on a regular weekday schedule")
        XCTAssertTrue(verdict(channel).isShow)
    }

    /// Long videos alone aren't a show, which is the whole reason for a
    /// threshold rather than any-signal-wins.
    func testMakerChannelIsLongFormButStillNotAShow() {
        let result = verdict(makerChannel)
        XCTAssertFalse(result.isShow)
        XCTAssertTrue(result.reasons.contains { $0.hasPrefix("Episodes usually run") }, "\(result.reasons)")
        XCTAssertFalse(result.reasons.contains { $0.hasPrefix("Posts on a regular") }, "\(result.reasons)")
        XCTAssertFalse(result.dormant, "scoring below the threshold isn't the same as going quiet")
    }

    func testClipsChannelIsRejectedForHavingNoFullLengthUploads() {
        let result = verdict(clipsChannel)
        XCTAssertFalse(result.isShow)
        XCTAssertEqual(result.reasons.count, 1)
        XCTAssertTrue(result.reasons[0].contains("over twenty minutes"), "\(result.reasons)")
        XCTAssertFalse(result.dormant)
    }

    // MARK: - Gate

    func testAChannelWeHaveBarelySeenIsNotJudged() {
        var channel = twiceWeeklyNewsShow
        channel.videos = Array(channel.videos.prefix(ShowDetector.minimumVideos - 1))
        let result = verdict(channel)
        XCTAssertFalse(result.isShow)
        XCTAssertTrue(result.reasons[0].contains("Too few uploads"), "\(result.reasons)")
        XCTAssertFalse(result.dormant, "never having enough evidence isn't the same as going quiet")
    }

    func testAShowIsStillAShowWithTheFewestUploadsTheGateAllows() {
        var channel = twiceWeeklyNewsShow
        channel.videos = Array(channel.videos.prefix(ShowDetector.minimumVideos))
        XCTAssertTrue(verdict(channel).isShow)
    }

    /// A channel that's gone dark — cancelled, on hiatus, or its host no
    /// longer able to post — isn't a recurring thing to auto-add someone to,
    /// however show-shaped its back catalogue is.
    func testADormantChannelIsNoLongerAShow() {
        let newest = twiceWeeklyNewsShow.videos.map(\.publishedAt).max()!
        let asOf = Self.calendar.date(byAdding: .day, value: ShowDetector.maximumDormantDays + 1, to: newest)!
        let result = verdict(twiceWeeklyNewsShow, now: asOf)
        XCTAssertFalse(result.isShow)
        XCTAssertTrue(result.reasons.contains { $0.hasPrefix("Hasn't posted in") }, "\(result.reasons)")
        XCTAssertTrue(result.dormant, "this false has to be distinguishable from never having looked like a show")
    }

    func testAShowOnAnOrdinaryHiatusIsStillAShow() {
        let newest = twiceWeeklyNewsShow.videos.map(\.publishedAt).max()!
        let asOf = Self.calendar.date(byAdding: .day, value: ShowDetector.maximumDormantDays, to: newest)!
        XCTAssertTrue(verdict(twiceWeeklyNewsShow, now: asOf).isShow)
    }

    // MARK: - Signals in isolation

    func testEpisodeNumberPatterns() {
        for title in ["#147 — Guest — Second Take", "Ep. 31: the long way round",
                      "Episode 4 — pilots", "S20 Ep.4 Taskmaster", "Ep31 the short way"] {
            XCTAssertTrue(ShowDetector.hasEpisodeNumber(title), title)
        }
        for title in ["Building a synth from a Furby", "Straße walk in Kreuzberg",
                      "Conan tries the world's hottest wing #shorts", "Top 10 mistakes"] {
            XCTAssertFalse(ShowDetector.hasEpisodeNumber(title), title)
        }
    }

    func testCadenceNamesTheDaysWhenThereAreFewEnoughToName() {
        let reason = ShowDetector.cadenceReason(twiceWeeklyNewsShow.videos, calendar: Self.calendar)
        XCTAssertEqual(reason, "Posts on a regular schedule (Tue, Fri)")
    }

    func testCadenceIgnoresHowManyTimesADayAChannelPosts() {
        // Three uploads an evening, one slot.
        let reason = ShowDetector.cadenceReason(dailyNewsShowWithSegments.videos, calendar: Self.calendar)
        XCTAssertEqual(reason, "Posts on a regular weekday schedule")
    }

    func testMinorityCategoryDoesNotDecideTheChannel() {
        var videos = vlogChannel.videos
        videos[0].categoryId = "25"
        XCTAssertNil(ShowDetector.dominantShowCategory(videos))
    }

    func testChannelsWithNoStoredCategoryGiveNoSignal() {
        let videos = vlogChannel.videos.map { video -> EpisodeSignals in
            var video = video
            video.categoryId = nil
            return video
        }
        XCTAssertNil(ShowDetector.dominantShowCategory(videos))
    }
}
