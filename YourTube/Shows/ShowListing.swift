import Foundation

/// What a show page shows: one value type built from a show's settings, the
/// season being looked at, and a pile of videos, answering everything the
/// page, the grid badge and the player ask about a show.
///
/// It is the whole listing pipeline in one door. Membership, the season
/// narrowing, segment classification, the retention window, the play order,
/// the counts, "Play next", the cadence line and the footer are stages of one
/// derivation, and they were once nine public functions that callers composed
/// themselves — which is how the grid's badge and the page's header came to
/// count unwatched episodes with two different expressions. Here the stages
/// are private and the answers are properties, so the badge and the header
/// are equal by construction.
///
/// Nothing here touches the store: `ShowManager.listing(of:)` fetches the
/// videos and hands them in, and a view with a live `@Query` hands in its own.
/// Both get the same answers because there is only one derivation.
///
/// Both kinds of hiding — segments behind the toggle, older episodes behind
/// the retention window — are presentation only. Nothing is deleted and
/// nothing leaves the store, so every hidden video is still in the feed,
/// still searchable, and still counted by everything outside the show — the
/// same policy as Shorts hiding.
struct ShowListing {
    /// Full episodes in air order, newest first, with the retention window
    /// applied.
    ///
    /// The page lists them this way even for a show watched oldest first: an
    /// episode list is read newest first — that's where the new ones are —
    /// and it's "Play next" that walks the backlog forwards.
    var episodes: [Video] = []
    /// The cut-downs hidden by default, newest first. Only those inside the
    /// retention window: revealing segments shouldn't drag back the era the
    /// window is there to hide.
    var segments: [Video] = []
    /// How many episodes are older than the retention window.
    var hiddenByRetention: Int = 0
    /// The length classification measured this show by — the typical full
    /// episode, with the cut-downs kept out of the reckoning.
    var typicalEpisodeDuration: TimeInterval?
    /// How many videos the show's source holds in all, before anything is
    /// classified or hidden.
    var sourceCount: Int = 0
    /// How many of those are segments, the ones outside the retention window
    /// included — which `segments` is not, so the show's settings can say
    /// what the threshold is doing to the whole catalogue.
    var segmentCount: Int = 0
    /// Whether any source video has a known duration yet. Lets the settings
    /// caption tell "still loading, nothing measured yet" apart from "loaded,
    /// and there's no gap in the lengths to hide anything behind" — both of
    /// which leave `typicalEpisodeDuration` nil.
    var hasDurationData: Bool = false
    /// The show's play order, which decides what "Play next" opens. Carried
    /// rather than applied, because the page lists in air order regardless.
    var playOrder: PlayOrder = .newestFirst

    // MARK: - Building one

    /// The listing for a show, from videos the caller already holds.
    ///
    /// `videos` may hold anything: Shorts and videos outside the show's
    /// source are filtered out here, so a caller's query doesn't have to be
    /// exact.
    ///
    /// The season is applied *before* classification rather than after, so
    /// the whole listing is about one thing: the segments behind the toggle,
    /// the retention window and the footer all describe the season in front
    /// of you. Filtering afterwards would leave an older series empty on a
    /// show told to keep only its last few episodes, which is not what
    /// picking that series means.
    init(of show: Show, season: Int? = nil, from videos: [Video]) {
        self.init(
            source: Self.sourceVideos(from: videos, of: show, inSeason: season),
            hideSegments: show.hideSegments,
            threshold: show.segmentThreshold,
            retentionCount: show.retentionCount,
            playOrder: show.playOrder
        )
    }

    /// An empty listing, for a show with nothing to list yet.
    init() {}

    /// The derivation itself, over settings rather than a `Show`, so the
    /// stages below read as the rules they are.
    ///
    /// Order of operations matters and is the user's mental model: segments
    /// were never episodes, so "keep the last 5 episodes" keeps five full
    /// episodes rather than five of last night's clips.
    private init(
        source: [Video],
        hideSegments: Bool,
        threshold: Double,
        retentionCount: Int?,
        playOrder: PlayOrder
    ) {
        self.playOrder = playOrder
        self.sourceCount = source.count
        self.hasDurationData = source.contains { $0.durationSeconds > 0 }

        guard hideSegments else {
            // The toggle is off: every source video is an episode, full
            // stop. No classification, so no typical duration either — the
            // settings caption reads that as "no gap", which is wrong here,
            // but the caption is only shown while the toggle is on.
            let retained = Self.retained(source, count: retentionCount)
            self.episodes = retained
            self.hiddenByRetention = source.count - retained.count
            return
        }

        let typical = Self.typicalEpisodeDuration(of: source, threshold: threshold)
        let split = Self.split(source, threshold: threshold, typicalDuration: typical)
        let retained = Self.retained(split.episodes, count: retentionCount)
        self.episodes = retained
        self.hiddenByRetention = split.episodes.count - retained.count
        self.typicalEpisodeDuration = typical
        self.segmentCount = split.segments.count
        // A segment belongs to the episode it was cut from, so the window's
        // edge is the oldest episode still on the page.
        if let count = retentionCount, count >= 0 {
            self.segments = retained.last.map { edge in
                split.segments.filter { $0.publishedAt >= edge.publishedAt }
            } ?? []
        } else {
            self.segments = split.segments
        }
    }

    // MARK: - What the page lists

    /// Episodes and segments together in air order: what the page lists once
    /// the toggle is on.
    var everything: [Video] {
        (episodes + segments).sorted { $0.publishedAt > $1.publishedAt }
    }

    /// The same episodes in the show's play order, which is what decides
    /// which one "Play next" opens — newest first for a daily news show,
    /// oldest first for a backlog watched forwards.
    var episodesInPlayOrder: [Video] {
        playOrder == .newestFirst ? episodes : Array(episodes.reversed())
    }

    /// How many of the listed episodes are still unwatched: the number in the
    /// page's header and on the grid's badge, which are therefore the same
    /// number. Segments and the episodes the retention window hides are not
    /// counted — a badge should only ever ask for what the show page is
    /// offering. Zero means the grid draws no badge at all.
    var unwatchedCount: Int {
        episodes.filter { !$0.isWatched }.count
    }

    /// The footer under the episode list, or nil when the page is showing
    /// everything it has. Says how many are hidden.
    func hiddenSummary(revealingSegments: Bool) -> String? {
        var parts: [String] = []
        if !revealingSegments, !segments.isEmpty {
            parts.append(Self.count(segments.count, "segment"))
        }
        if hiddenByRetention > 0 {
            parts.append(Self.count(hiddenByRetention, "older episode"))
        }
        guard !parts.isEmpty else { return nil }
        return "\(parts.joined(separator: " and ")) hidden, not deleted."
    }

    // MARK: - Play next

    /// The episode "Play next" opens, or nil when the show is caught up.
    ///
    /// An episode you're partway through always wins: whatever the play order
    /// says, the thing you actually want is the one you walked away from.
    /// Otherwise the play order decides.
    var nextUp: Video? {
        let pending = episodesInPlayOrder.filter { !$0.isWatched }
        let resumable = pending.filter { WatchState.resumePosition(for: $0) != nil }
        if !resumable.isEmpty {
            // More than one half-watched episode is rare; when it happens the
            // one you touched last is the one you meant, the same rule that
            // orders Continue Watching.
            return resumable.max { ($0.lastPlayedAt ?? .distantPast) < ($1.lastPlayedAt ?? .distantPast) }
        }
        return pending.first
    }

    /// Whether "Play next" should read "Resume": this episode has a stored
    /// position to pick up from.
    static func isResumable(_ video: Video) -> Bool {
        WatchState.resumePosition(for: video) != nil
    }

    // MARK: - Cadence and typical duration

    /// The header's one line of habit: "Posts Tue, Fri · about 1 hr 15 min".
    /// Nil when the show has told us nothing yet, so a brand new show gets no
    /// line rather than an empty one.
    ///
    /// Computed on every read and never stored, so a show that changes its
    /// habits stops lying about them as soon as the new episodes land. It
    /// reads the same listed episodes as everything else here, which is what
    /// makes the retention window and segment hiding apply to it for free —
    /// the typical length of a news hour is the length of the hour, not of
    /// the clips cut from it.
    func cadenceDescription(calendar: Calendar = .current) -> String? {
        var parts: [String] = []
        let weekdays = cadenceWeekdays(calendar: calendar)
        if !weekdays.isEmpty {
            let symbols = calendar.shortWeekdaySymbols
            parts.append("Posts " + weekdays.map { symbols[$0 - 1] }.joined(separator: ", "))
        }
        if let typicalDuration, let length = Self.approximateLength(typicalDuration) {
            // Without a weekday the sentence needs a subject of its own.
            parts.append(weekdays.isEmpty ? "Episodes about \(length)" : "about \(length)")
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// The weekdays a show has posted on at least twice (`Calendar`
    /// numbering, 1 = Sunday), in week order.
    ///
    /// Twice is the bar because one Sunday upload is an accident and two is a
    /// habit; it's also what keeps a show that moved night from claiming both
    /// forever once the old episodes age out of the retention window.
    func cadenceWeekdays(calendar: Calendar = .current) -> [Int] {
        let counts = episodes.reduce(into: [Int: Int]()) { counts, video in
            counts[calendar.component(.weekday, from: video.publishedAt), default: 0] += 1
        }
        return counts.filter { $0.value >= 2 }.keys
            .sorted { Self.weekOffset($0, calendar: calendar) < Self.weekOffset($1, calendar: calendar) }
    }

    /// How long a listed episode usually runs, in seconds, or nil when the
    /// show has no episodes yet. The median rather than the mean: one
    /// three-hour special shouldn't move the number the show is described by.
    var typicalDuration: TimeInterval? {
        Self.median(of: episodes.map(\.durationSeconds))
    }

    /// "1 hr", "1 hr 15 min", "45 min": rounded to five minutes, because a
    /// typical length is a shape, not a measurement.
    static func approximateLength(_ seconds: TimeInterval) -> String? {
        guard seconds > 0 else { return nil }
        let minutes = max(Int((seconds / 300).rounded()) * 5, 5)
        guard minutes >= 60 else { return "\(minutes) min" }
        let (hours, remainder) = (minutes / 60, minutes % 60)
        return remainder == 0 ? "\(hours) hr" : "\(hours) hr \(remainder) min"
    }

    // MARK: - Badges

    /// Unwatched counts for several shows at once, keyed by show ID, from
    /// videos the caller already has — the same number each show's page puts
    /// in its header, since it comes from the same listing.
    ///
    /// Grouping by channel first only narrows the work for channel-backed
    /// shows; a playlist's members can come from anywhere.
    static func unwatchedCounts(from videos: [Video], shows: [Show]) -> [String: Int] {
        let candidates = videos.filter { !$0.isLikelyShort }
        let byChannel = Dictionary(grouping: candidates, by: \.channelId)
        return shows.reduce(into: [String: Int]()) { counts, show in
            let pool: [Video]
            switch show.source {
            case .channel(let channelId):
                pool = byChannel[channelId] ?? []
            case .playlist:
                pool = candidates
            }
            counts[show.id] = ShowListing(of: show, from: pool).unwatchedCount
        }
    }

    // MARK: - Membership

    /// Which of `videos` belong to the show, newest first, narrowed to one
    /// season: the raw material everything above is derived from, and the one
    /// place a show's membership rule is written down.
    ///
    /// A channel-backed show's videos are every non-Short upload from its
    /// channel; a playlist-backed show's are the ones its playlists hold, as
    /// of the last membership refresh. Shorts are never episodes of anything
    /// either way — a playlist can contain one, and it still isn't an episode
    /// — and they never come back as segments either: a Short is not an
    /// episode and not a cut-down of one.
    ///
    /// A nil season is "All seasons", which is also what a show without
    /// seasons always gets.
    static func sourceVideos(from videos: [Video], of show: Show, inSeason season: Int? = nil) -> [Video] {
        var members: [Video]
        switch show.source {
        case .channel(let channelId):
            members = videos.filter { $0.channelId == channelId && !$0.isLikelyShort }
        case .playlist:
            let ids = Set(show.memberVideoIds)
            members = videos.filter { ids.contains($0.videoId) && !$0.isLikelyShort }
        }
        if let season, show.hasSeasons {
            let ids = Set(show.videoIds(inSeason: season))
            members = members.filter { ids.contains($0.videoId) }
        }
        return members.sorted { $0.publishedAt > $1.publishedAt }
    }

    // MARK: - Classification
    //
    // Telling a show's episodes from its segments.
    //
    // A news hour posts one full episode and then cuts it into clips: on
    // Newsline Nightly's channel three quarters of the uploads are cut-downs.
    // A segment is defined by length rather than by title, because the titles
    // are the one thing a channel changes without warning: **a video from a
    // show's source is a segment when it runs shorter than a fraction of the
    // show's typical episode.** The fraction is per show, adjustable from the
    // show's settings, and defaults to a half.
    //
    // The hard part is "typical", and the plain median is no use for it: on a
    // channel that is three-quarters cut-downs the median *is* a cut-down,
    // and the rule would find no segments at all. The longest video is no use
    // either, because one three-hour election special would demote every
    // ordinary episode to a segment.
    //
    // So "typical" is read in two steps, from the top down:
    //
    // 1. **Set the long tail aside.** Sort by length and skip the longest
    //    tenth, and never fewer than the two longest — long enough to swallow
    //    the odd special, short enough that it can't eat a real episode. The
    //    next video down is the yardstick.
    // 2. **Take the median of everything that measures up to it.** Keep the
    //    videos at least `threshold` as long as the yardstick — on a
    //    mostly-cut-down channel that is exactly the full episodes — and the
    //    median of those is the typical episode.
    //
    // Both steps are needed. Step one alone would let one unusually long or
    // short episode set the number; step two alone is the plain median again.
    // On a show with no cut-downs at all nothing is dropped in step two, so
    // the answer is the ordinary median and nothing is classified as a
    // segment.

    /// "Keep the last N": the newest N episodes, given a newest-first list.
    private static func retained(_ newestFirst: [Video], count: Int?) -> [Video] {
        guard let count, count >= 0 else { return newestFirst }
        return Array(newestFirst.prefix(count))
    }

    /// Splits a show's videos into full episodes and the cut-downs of them,
    /// each list keeping the order it came in.
    static func split(
        _ videos: [Video],
        threshold: Double,
        typicalDuration: TimeInterval? = nil
    ) -> (episodes: [Video], segments: [Video]) {
        let typical = typicalDuration ?? typicalEpisodeDuration(of: videos, threshold: threshold)
        guard let typical else { return (videos, []) }
        let shortest = typical * clamped(threshold)
        var episodes: [Video] = []
        var segments: [Video] = []
        for video in videos {
            // A video of unknown length is an episode: the app would rather
            // list something it can't measure than hide it.
            if video.durationSeconds > 0, Double(video.durationSeconds) < shortest {
                segments.append(video)
            } else {
                episodes.append(video)
            }
        }
        return (episodes, segments)
    }

    /// How much longer the shortest thing kept as an episode must run than
    /// the longest thing cut as a segment before the two are believed to be
    /// different kinds of video, rather than the same kind split arbitrarily
    /// by the threshold. A clips-only channel's clips run a continuous range
    /// of lengths with nothing under this ratio anywhere in it; a channel
    /// that really mixes full episodes and cut-downs has a real jump, well
    /// past it, between the two.
    private static let minimumGapRatio = 1.5

    /// How long a full episode of this show runs, with the cut-downs kept out
    /// of the reckoning. Nil when nothing has a duration yet, or when the
    /// catalogue has no real gap to draw the line in (see `minimumGapRatio`):
    /// a channel that posts only clips shouldn't have the shortest of them
    /// hidden just because the median looks like an "episode".
    ///
    /// Skip the long tail, measure against what's left, take the median of
    /// whatever still measures up (see the section comment).
    static func typicalEpisodeDuration(of videos: [Video], threshold: Double) -> TimeInterval? {
        let longestFirst = videos.map(\.durationSeconds).filter { $0 > 0 }.sorted(by: >)
        guard !longestFirst.isEmpty else { return nil }
        // The yardstick: the longest video that isn't in the long tail.
        let yardstick = longestFirst[min(max(2, longestFirst.count / 10), longestFirst.count - 1)]
        let shortest = TimeInterval(yardstick) * clamped(threshold)
        // Never nil: the yardstick itself always measures up to a fraction
        // of itself, whatever the threshold.
        guard let typical = median(of: longestFirst.filter { TimeInterval($0) >= shortest }) else {
            return nil
        }
        let splitAtTypical = typical * clamped(threshold)
        let episodeDurations = longestFirst.filter { TimeInterval($0) >= splitAtTypical }
        let segmentDurations = longestFirst.filter { TimeInterval($0) < splitAtTypical }
        // Nothing would be hidden anyway, so there's no gap to check.
        guard let shortestEpisode = episodeDurations.min(),
              let longestSegment = segmentDurations.max() else {
            return typical
        }
        guard TimeInterval(shortestEpisode) >= TimeInterval(longestSegment) * minimumGapRatio else {
            // No real jump between the two groups: the split was the
            // threshold drawing an arbitrary line through one continuous
            // cluster of lengths, not finding two different kinds of video.
            return nil
        }
        return typical
    }

    /// The one median the listing measures lengths with, in seconds, or nil
    /// when nothing has a duration yet. Zero-length videos — not measured
    /// yet — don't vote.
    ///
    /// Even counts take the shorter of the two middles, so a typical length
    /// never overstates: "about 45 min" that turns out to be an hour is a
    /// better surprise than the reverse, and the classification below draws
    /// its line at a fraction of this number, where overstating would start
    /// hiding real episodes.
    ///
    /// `ShowDetector` keeps a median of its own (the mean of the two middles,
    /// over day gaps rather than durations); sharing this one would move its
    /// verdicts, which a listing refactor has no business doing.
    static func median(of durations: [Int]) -> TimeInterval? {
        let sorted = durations.filter { $0 > 0 }.sorted()
        guard !sorted.isEmpty else { return nil }
        return TimeInterval(sorted[(sorted.count - 1) / 2])
    }

    private static func clamped(_ threshold: Double) -> Double {
        min(max(threshold, Show.segmentThresholdRange.lowerBound), Show.segmentThresholdRange.upperBound)
    }

    private static func weekOffset(_ weekday: Int, calendar: Calendar) -> Int {
        (weekday - calendar.firstWeekday + 7) % 7
    }

    private static func count(_ n: Int, _ noun: String) -> String {
        "\(n) \(noun)\(n == 1 ? "" : "s")"
    }
}
