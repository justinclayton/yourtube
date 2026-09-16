import Foundation

/// What a show page lists and what it is holding back: the full episodes, the
/// cut-downs hidden behind the toggle, and the episodes the retention window
/// has aged out.
///
/// Both kinds of hiding are presentation only. Nothing is deleted and nothing
/// leaves the store, so every hidden video is still in the feed, still
/// searchable, and still counted by everything outside the show — the same
/// policy as Shorts hiding.
struct ShowListing {
    /// Full episodes, newest first, with the retention window applied.
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

    /// Episodes and segments together in air order: what the page lists once
    /// the toggle is on.
    var everything: [Video] {
        (episodes + segments).sorted { $0.publishedAt > $1.publishedAt }
    }

    /// The footer under the episode list, or nil when the page is showing
    /// everything it has. Says how many are hidden, why, and that they're
    /// still there.
    func hiddenSummary(revealingSegments: Bool) -> String? {
        var parts: [String] = []
        if !revealingSegments, !segments.isEmpty {
            parts.append(ShowListing.count(segments.count, "segment"))
        }
        if hiddenByRetention > 0 {
            parts.append(ShowListing.count(hiddenByRetention, "older episode"))
        }
        guard !parts.isEmpty else { return nil }
        return "\(parts.joined(separator: " and ")) hidden. Nothing is deleted — they're all still in the feed."
    }

    private static func count(_ n: Int, _ noun: String) -> String {
        "\(n) \(noun)\(n == 1 ? "" : "s")"
    }
}

/// Telling a show's episodes from its segments.
///
/// A news hour posts one full episode and then cuts it into clips: on
/// Newsline Nightly's channel three quarters of the uploads are cut-downs. A
/// segment is defined by length rather than by title, because the titles are
/// the one thing a channel changes without warning: **a video from a show's
/// source is a segment when it runs shorter than a fraction of the show's
/// typical episode.** The fraction is per show, adjustable from the show's
/// settings, and defaults to a half.
///
/// The hard part is "typical", and the plain median is no use for it: on a
/// channel that is three-quarters cut-downs the median *is* a cut-down, and
/// the rule would find no segments at all. The longest video is no use
/// either, because one three-hour election special would demote every
/// ordinary episode to a segment.
///
/// So "typical" is read in two steps, from the top down:
///
/// 1. **Set the long tail aside.** Sort by length and skip the longest tenth,
///    and never fewer than the two longest — long enough to swallow the odd
///    special, short enough that it can't eat a real episode. The next video
///    down is the yardstick.
/// 2. **Take the median of everything that measures up to it.** Keep the
///    videos at least `threshold` as long as the yardstick — on a
///    mostly-cut-down channel that is exactly the full episodes — and the
///    median of those is the typical episode.
///
/// Both steps are needed. Step one alone would let one unusually long or
/// short episode set the number; step two alone is the plain median again.
/// On a show with no cut-downs at all nothing is dropped in step two, so the
/// answer is the ordinary median and nothing is classified as a segment.
extension ShowManager {

    // MARK: - Listing a show

    /// Everything the show page needs from a set of videos the caller already
    /// has: the episodes it lists, the segments behind the toggle, and how
    /// many episodes the retention window is holding back.
    ///
    /// Order of operations matters and is the user's mental model: segments
    /// were never episodes, so "keep the last 5 episodes" keeps five full
    /// episodes rather than five of last night's clips.
    nonisolated static func listing(from videos: [Video], of show: Show) -> ShowListing {
        let source = sourceVideos(from: videos, of: show)
        guard show.hideSegments else {
            // The toggle is off: every source video is an episode, full
            // stop. No classification, so no typical duration either — the
            // settings caption reads that as "no gap", which is wrong here,
            // but the caption is only shown while the toggle is on.
            let retained = retained(source, count: show.retentionCount)
            return ShowListing(
                episodes: retained,
                segments: [],
                hiddenByRetention: source.count - retained.count,
                typicalEpisodeDuration: nil,
                sourceCount: source.count,
                segmentCount: 0,
                hasDurationData: source.contains { $0.durationSeconds > 0 }
            )
        }
        let threshold = show.segmentThreshold
        let typical = typicalEpisodeDuration(of: source, threshold: threshold)
        let split = split(source, threshold: threshold, typicalDuration: typical)
        let retained = retained(split.episodes, count: show.retentionCount)
        // A segment belongs to the episode it was cut from, so the window's
        // edge is the oldest episode still on the page.
        let segments: [Video]
        if let count = show.retentionCount, count >= 0 {
            segments = retained.last.map { edge in
                split.segments.filter { $0.publishedAt >= edge.publishedAt }
            } ?? []
        } else {
            segments = split.segments
        }
        return ShowListing(
            episodes: retained,
            segments: segments,
            hiddenByRetention: split.episodes.count - retained.count,
            typicalEpisodeDuration: typical,
            sourceCount: source.count,
            segmentCount: split.segments.count,
            hasDurationData: source.contains { $0.durationSeconds > 0 }
        )
    }

    /// Every video from the show's source, newest first: the raw material
    /// classification works on. Membership is `members(from:of:)`, so a
    /// playlist-backed show is classified over its playlist's items and a
    /// channel-backed one over its channel's uploads. Shorts are left out
    /// there and never come back — a Short is not an episode and not a
    /// segment of one.
    nonisolated static func sourceVideos(from videos: [Video], of show: Show) -> [Video] {
        members(from: videos, of: show).sorted { $0.publishedAt > $1.publishedAt }
    }

    // MARK: - Classification

    /// Splits a show's videos into full episodes and the cut-downs of them,
    /// each list keeping the order it came in.
    nonisolated static func split(
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

    /// Whether one video is a segment of the show it came from.
    nonisolated static func isSegment(_ video: Video, of show: Show, among videos: [Video]) -> Bool {
        split(sourceVideos(from: videos, of: show), threshold: show.segmentThreshold)
            .segments.contains { $0.videoId == video.videoId }
    }

    /// How much longer the shortest thing kept as an episode must run than
    /// the longest thing cut as a segment before the two are believed to be
    /// different kinds of video, rather than the same kind split arbitrarily
    /// by the threshold. A clips-only channel's clips run a continuous range
    /// of lengths with nothing under this ratio anywhere in it; a channel
    /// that really mixes full episodes and cut-downs has a real jump, well
    /// past it, between the two.
    private nonisolated static let minimumGapRatio = 1.5

    /// How long a full episode of this show runs, with the cut-downs kept out
    /// of the reckoning. Nil when nothing has a duration yet, or when the
    /// catalogue has no real gap to draw the line in (see `minimumGapRatio`):
    /// a channel that posts only clips shouldn't have the shortest of them
    /// hidden just because the median looks like an "episode".
    ///
    /// Skip the long tail, measure against what's left, take the median of
    /// whatever still measures up (see the type comment).
    nonisolated static func typicalEpisodeDuration(of videos: [Video], threshold: Double) -> TimeInterval? {
        let longestFirst = videos.map(\.durationSeconds).filter { $0 > 0 }.sorted(by: >)
        guard !longestFirst.isEmpty else { return nil }
        // The yardstick: the longest video that isn't in the long tail.
        let yardstick = longestFirst[min(max(2, longestFirst.count / 10), longestFirst.count - 1)]
        let shortest = TimeInterval(yardstick) * clamped(threshold)
        // Never empty: the yardstick itself always measures up to a fraction
        // of itself, whatever the threshold.
        let typical = median(of: longestFirst.filter { TimeInterval($0) >= shortest })
        let splitAtTypical = TimeInterval(typical) * clamped(threshold)
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

    /// The middle of a list ordered longest first. Even counts take the
    /// shorter of the two middles, so a typical length never overstates.
    private nonisolated static func median(of longestFirst: [Int]) -> TimeInterval {
        guard !longestFirst.isEmpty else { return 0 }
        return TimeInterval(longestFirst[longestFirst.count / 2])
    }

    private nonisolated static func clamped(_ threshold: Double) -> Double {
        min(max(threshold, Show.segmentThresholdRange.lowerBound), Show.segmentThresholdRange.upperBound)
    }

    // MARK: - Fetching

    /// The show's segments, newest first: the cut-downs the page hides.
    func segments(of show: Show) throws -> [Video] {
        Self.listing(from: try sourceVideos(of: show), of: show).segments
    }

    /// Everything the page can list — episodes and segments in air order —
    /// which is what it lists with the segment toggle on.
    func episodesAndSegments(of show: Show) throws -> [Video] {
        Self.listing(from: try sourceVideos(of: show), of: show).everything
    }

    /// The show's listing, fetched rather than handed in.
    func listing(of show: Show) throws -> ShowListing {
        Self.listing(from: try sourceVideos(of: show), of: show)
    }
}
