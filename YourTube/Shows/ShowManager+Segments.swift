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
/// The hard part is "typical" — the plain median is useless here, because on
/// a channel that is mostly cut-downs the median *is* a cut-down. So the
/// baseline is seeded from the top quartile, which survives a majority of
/// segments, and then relaxed: classify with it, take the median of the
/// episodes that survive, classify again, until it settles. The relaxation is
/// monotone (a lower baseline only ever keeps more videos), so it always
/// settles, and on a show with no segments at all it walks straight back down
/// to the plain median and classifies nothing. Seeding from the top quartile
/// rather than the maximum is what keeps one three-hour special from
/// demoting every ordinary episode to a segment.
extension ShowManager {
    /// A video shorter than half a typical episode is a cut-down of one. Half
    /// is low enough that a short episode is still an episode and high enough
    /// to catch a twenty-minute extract from an hour.
    static let defaultSegmentThreshold = 0.5

    /// What the settings slider offers: a tenth of an episode is as
    /// permissive as the rule can get before every clip is an episode, nine
    /// tenths as strict as it can get before every episode is a clip.
    static let segmentThresholdRange = 0.1...0.9

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
            typicalEpisodeDuration: typical
        )
    }

    /// Every video from the show's source, newest first: the raw material
    /// classification works on. Shorts are left out here and never come back
    /// — a Short is not an episode and not a segment of one.
    nonisolated static func sourceVideos(from videos: [Video], of show: Show) -> [Video] {
        videos
            .filter { $0.channelId == show.channelId && !$0.isLikelyShort }
            .sorted { $0.publishedAt > $1.publishedAt }
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

    /// How long a full episode of this show runs, with the cut-downs kept out
    /// of the reckoning. Nil when nothing has a duration yet.
    ///
    /// Seeded from the top quartile, then relaxed to the median of whatever
    /// still counts as an episode until it settles (see the type comment).
    nonisolated static func typicalEpisodeDuration(of videos: [Video], threshold: Double) -> TimeInterval? {
        let durations = videos.map(\.durationSeconds).filter { $0 > 0 }.sorted()
        guard !durations.isEmpty else { return nil }
        let fraction = clamped(threshold)
        var baseline = median(of: Array(durations[(durations.count * 3) / 4...]))
        // The sequence only ever descends, so it settles; the bound is a
        // guard against a rounding cycle, not a real iteration count.
        for _ in 0..<8 {
            let shortest = baseline * fraction
            // Never empty: the baseline is at most the longest video, and the
            // fraction is under one, so the longest video always survives.
            let kept = durations.filter { Double($0) >= shortest }
            let next = median(of: kept)
            if next == baseline { break }
            baseline = next
        }
        return baseline
    }

    private nonisolated static func median(of sortedDurations: [Int]) -> TimeInterval {
        guard !sortedDurations.isEmpty else { return 0 }
        return TimeInterval(sortedDurations[sortedDurations.count / 2])
    }

    private nonisolated static func clamped(_ threshold: Double) -> Double {
        min(max(threshold, segmentThresholdRange.lowerBound), segmentThresholdRange.upperBound)
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
