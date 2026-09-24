import Foundation

/// One video, as the show detector sees it. A plain value type, like
/// `VideoSignals`, so the detector is testable without SwiftData or the
/// network.
struct EpisodeSignals: Sendable, Equatable {
    var durationSeconds: Int
    var publishedAt: Date
    var title: String
    var description: String
    /// YouTube's own `snippet.categoryId`, e.g. `"25"` for News & Politics.
    /// Nil for videos stored before the field was fetched.
    var categoryId: String?

    init(
        durationSeconds: Int,
        publishedAt: Date,
        title: String = "",
        description: String = "",
        categoryId: String? = nil
    ) {
        self.durationSeconds = durationSeconds
        self.publishedAt = publishedAt
        self.title = title
        self.description = description
        self.categoryId = categoryId
    }
}

/// Everything the detector is given about one channel: who it is, and the
/// non-Short videos we've stored from it.
struct ChannelEvidence: Sendable, Equatable {
    var channelId: String
    var channelTitle: String
    var videos: [EpisodeSignals]
}

/// Decides whether a channel is a show.
///
/// The YouTube API has no notion of a show, so this is guesswork of the same
/// kind as `ShortsHeuristic` — and it's answered the same way: a gate that
/// rules out what can't be a show, then several weak signals summed against a
/// threshold. Every signal that fires becomes a sentence the user can read on
/// the show page, so a wrong guess can be understood and corrected rather than
/// just overturned.
///
/// The gate is that a show has full-length instalments: a handful of uploads
/// we've seen, several of them over twenty minutes. It's what keeps a clips
/// channel out no matter how punctually it posts, and it's why the daily news
/// show — whose median upload is a five-minute cut-down — still gets through:
/// its full episodes are there underneath the segments.
///
/// The gate also asks that the channel is still posting. A channel that once
/// had a slot but hasn't uploaded in months — cancelled, on hiatus, or its
/// host no longer able to — isn't a recurring thing to auto-add someone to
/// today, whatever its back catalogue looks like. This is re-checked every
/// pass, not just once, and marks its verdict `dormant` rather than plain
/// `false`: a channel that never looked like a show is silently skipped, but
/// one that was already flagged and has gone quiet is a question for the
/// user, not a verdict the detector gets to act on unasked — see
/// `ShowManager.applyAutomaticVerdicts`.
///
/// The signals, weighted equally:
/// - a median duration over twenty minutes: the channel's ordinary upload is
///   an episode, not a clip;
/// - a regular cadence: a show has a slot, whether that's Tuesdays and
///   Fridays or every weekday;
/// - numbered titles (`#147`, `Ep. 31`, `S20 E4`): only a series counts;
/// - "podcast" or "episode" in the descriptions;
/// - YouTube's own category being News & Politics.
///
/// The threshold is two: no single signal is trusted alone, but any two
/// agreeing is enough. Because the guess is only ever a `Show` row the user
/// can flip, a false positive costs one swipe — and one that the detector
/// may never undo.
enum ShowDetector {
    /// Bump when the decision logic changes, so every channel is examined
    /// again on the next pass (see `ShowDetectionRunner`).
    static let version = 4

    // MARK: - Gate

    /// Below this we haven't seen enough of a channel to have an opinion.
    static let minimumVideos = 6
    /// "Full length" — also the median-duration signal's bar. The PRD's twenty
    /// minutes.
    static let longFormSeconds = 1_200
    /// How many full-length uploads a show has to have among what we've seen.
    static let minimumLongFormVideos = 3
    /// A channel silent for longer than this isn't a recurring thing to
    /// auto-add someone to, whatever its history looks like. Four months
    /// covers an ordinary hiatus (a season break, a summer off) without
    /// covering a cancellation or a host who's gone.
    static let maximumDormantDays = 120

    // MARK: - Scoring

    static let threshold = 2
    static let medianDurationPoints = 1
    static let cadencePoints = 1
    static let numberedTitlePoints = 1
    static let categoryPoints = 1
    static let descriptionPoints = 1

    /// Distinct days the channel posted on before a cadence is worth reading.
    static let minimumPostingDays = 4
    /// A slot further apart than this isn't a rhythm we can see in a refresh's
    /// worth of uploads.
    static let maximumMedianGapDays = 8
    /// Share of gaps that must sit within a day of the median for the
    /// schedule to count as regular.
    static let cadenceRegularityShare = 0.7
    /// A show posts on a few weekdays; a channel that posts every day of the
    /// week is a firehose, not a slot.
    static let maximumPostingWeekdays = 5
    static let numberedTitleShare = 0.6
    static let descriptionKeywordShare = 0.5

    /// YouTube category IDs that tilt toward "show", by their API names.
    static let showCategoryNames = ["25": "News & Politics"]

    static let descriptionKeywords = ["podcast", "episode"]

    /// Title patterns that mean "instalment N of a series".
    static let episodeNumberPatterns = [
        #"#\s?\d+"#,
        #"\bep(isode)?\.?\s*#?\s*\d+"#,
        #"\bs\d{1,2}\s*ep?\.?\s*\d+"#,
    ]

    // MARK: - Verdict

    /// The whole detector: channel in, verdict out, no state.
    ///
    /// Reasons are the signals that actually fired, in strength order. They're
    /// recorded for a "not a show" verdict too — a channel that scored two out
    /// of three is worth being able to look at — but only a flagged show shows
    /// them to the user.
    static func verdict(for evidence: ChannelEvidence, calendar: Calendar = .current, now: Date = .now) -> ShowVerdict {
        func answer(_ isShow: Bool, _ reasons: [String], dormant: Bool = false) -> ShowVerdict {
            ShowVerdict(
                channelId: evidence.channelId,
                channelTitle: evidence.channelTitle,
                isShow: isShow,
                reasons: reasons,
                dormant: dormant
            )
        }

        let videos = evidence.videos
        guard videos.count >= minimumVideos else {
            return answer(false, ["Too few uploads stored to judge (\(videos.count))"])
        }
        let longForm = videos.filter { $0.durationSeconds > longFormSeconds }.count
        guard longForm >= minimumLongFormVideos else {
            return answer(false, ["Nothing long enough to be an episode (\(longForm) uploads over twenty minutes)"])
        }
        let newestUpload = videos.map(\.publishedAt).max() ?? .distantPast
        let daysSinceLastUpload = calendar.dateComponents([.day], from: newestUpload, to: now).day ?? 0
        guard daysSinceLastUpload <= maximumDormantDays else {
            return answer(false, ["Hasn't posted in \(daysSinceLastUpload) days"], dormant: true)
        }

        var score = 0
        var reasons: [String] = []

        if let median = median(videos.map(\.durationSeconds)), median > longFormSeconds {
            score += medianDurationPoints
            reasons.append("Episodes usually run \(durationPhrase(median))")
        }
        if let cadence = cadenceReason(videos, calendar: calendar) {
            score += cadencePoints
            reasons.append(cadence)
        }
        if share(of: videos, where: { hasEpisodeNumber($0.title) }) >= numberedTitleShare {
            score += numberedTitlePoints
            reasons.append("Titles are numbered episodes")
        }
        if let category = dominantShowCategory(videos) {
            score += categoryPoints
            reasons.append("YouTube files it under \(category)")
        }
        if share(of: videos, where: { mentionsEpisodeOrPodcast($0.description) }) >= descriptionKeywordShare {
            score += descriptionPoints
            reasons.append("Descriptions call it a podcast or name the episode")
        }

        return answer(score >= threshold, reasons)
    }

    // MARK: - Signals

    /// A regular slot, phrased for the show page, or nil when the channel
    /// posts whenever it feels like it.
    ///
    /// Read off the days the channel posted on, not the uploads: a news hour
    /// that also posts three cut-downs every evening still keeps one slot.
    static func cadenceReason(_ videos: [EpisodeSignals], calendar: Calendar = .current) -> String? {
        let days = Set(videos.map { calendar.startOfDay(for: $0.publishedAt) }).sorted()
        guard days.count >= minimumPostingDays else { return nil }

        let gaps = zip(days.dropFirst(), days).map {
            calendar.dateComponents([.day], from: $1, to: $0).day ?? 0
        }
        guard let medianGap = median(gaps),
              medianGap >= 1, medianGap <= maximumMedianGapDays else { return nil }
        let regular = gaps.filter { abs($0 - medianGap) <= 1 }.count
        guard Double(regular) / Double(gaps.count) >= cadenceRegularityShare else { return nil }

        let weekdays = Set(days.map { calendar.component(.weekday, from: $0) }).sorted()
        guard weekdays.count <= maximumPostingWeekdays else { return nil }

        // Naming two or three days is useful; naming five is just "weekdays".
        guard weekdays.count <= 3 else { return "Posts on a regular weekday schedule" }
        let symbols = calendar.shortWeekdaySymbols
        let names = weekdays.compactMap { $0 >= 1 && $0 <= symbols.count ? symbols[$0 - 1] : nil }
        return "Posts on a regular schedule (\(names.joined(separator: ", ")))"
    }

    static func hasEpisodeNumber(_ title: String) -> Bool {
        episodeNumberPatterns.contains { pattern in
            title.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil
        }
    }

    static func mentionsEpisodeOrPodcast(_ description: String) -> Bool {
        let haystack = description.lowercased()
        return descriptionKeywords.contains { haystack.contains($0) }
    }

    /// The channel's usual YouTube category, when that category is the one
    /// this counts as evidence. Videos with no stored category don't vote, so
    /// a half-migrated store degrades to "no signal".
    static func dominantShowCategory(_ videos: [EpisodeSignals]) -> String? {
        let counts = videos.compactMap(\.categoryId).reduce(into: [String: Int]()) {
            $0[$1, default: 0] += 1
        }
        let ranked = counts.sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }
        guard let top = ranked.first?.key else { return nil }
        return showCategoryNames[top]
    }

    // MARK: - Helpers

    static func median(_ values: [Int]) -> Int? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        let middle = sorted.count / 2
        return sorted.count.isMultiple(of: 2)
            ? (sorted[middle - 1] + sorted[middle]) / 2
            : sorted[middle]
    }

    private static func share(
        of videos: [EpisodeSignals],
        where matches: (EpisodeSignals) -> Bool
    ) -> Double {
        guard !videos.isEmpty else { return 0 }
        return Double(videos.filter(matches).count) / Double(videos.count)
    }

    /// "1 hr 15 min", for a reason the user reads.
    static func durationPhrase(_ seconds: Int) -> String {
        let hours = seconds / 3600
        let minutes = (seconds % 3600) / 60
        if hours > 0 && minutes > 0 { return "\(hours) hr \(minutes) min" }
        if hours > 0 { return "\(hours) hr" }
        return "\(minutes) min"
    }
}
