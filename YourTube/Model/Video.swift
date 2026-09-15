import Foundation
import SwiftData

/// A single video from a subscribed channel.
///
/// `videoId` is the primary key throughout the app, which is what makes
/// feed refresh and classification idempotent — re-running either is a no-op
/// for videos we've already seen.
@Model
final class Video {
    @Attribute(.unique) var videoId: String
    var channelId: String
    var channelTitle: String
    var title: String
    var videoDescription: String
    var publishedAt: Date
    var durationSeconds: Int
    var thumbnailURL: String?
    /// Thumbnail aspect ratio, used by the Shorts heuristic. Nil if unknown.
    var thumbnailWidth: Int?
    var thumbnailHeight: Int?
    /// YouTube's own `snippet.categoryId` (`"25"` is News & Politics), read by
    /// `ShowDetector`. Nil for videos stored before it was fetched.
    var youtubeCategoryId: String?

    var isLikelyShort: Bool
    var isWatched: Bool
    /// When the user earmarked this video to Up Next; nil when it isn't there.
    /// Named for the Watch Later feature it predates so existing stores open
    /// without a migration. See `UpNextQueue`.
    var savedForLaterAt: Date?
    /// Position in Up Next. Nil for an entry saved before Up Next existed
    /// until `UpNextQueue.migrateLegacySaves()` places it.
    var upNextOrder: Int?
    /// Where playback stopped, in seconds. Nil when the video hasn't been
    /// started (a position under thirty seconds doesn't count). See
    /// `PlaybackProgress`.
    var resumePositionSeconds: Double?
    /// When playback last reported a position, which orders Continue Watching.
    var lastPlayedAt: Date?

    var collection: VideoCollection?
    /// Bumped when the classifier logic changes, to trigger re-classification.
    var classifierVersion: Int

    /// The title with the channel's boilerplate stripped, cached so the feed
    /// never waits on cleaning. Nil until `TitleCleaner` has been over this
    /// video, which is what `displayTitle` falls back to `title` for.
    /// The model rewrite (#27) writes the same field.
    var cleanedTitle: String?
    /// Episode numbering lifted out of the title, shown as a label rather
    /// than left as clutter. Nil when the title carried none.
    var seasonNumber: Int?
    var episodeNumber: Int?
    /// Bumped when the cleaning logic changes, to trigger re-cleaning of
    /// stored videos. Mirrors `classifierVersion`; see `TitleCleaner`.
    var titleCleanerVersion: Int = 0

    init(
        videoId: String,
        channelId: String,
        channelTitle: String,
        title: String,
        videoDescription: String,
        publishedAt: Date,
        durationSeconds: Int,
        thumbnailURL: String? = nil,
        thumbnailWidth: Int? = nil,
        thumbnailHeight: Int? = nil,
        youtubeCategoryId: String? = nil,
        isLikelyShort: Bool = false,
        isWatched: Bool = false,
        savedForLaterAt: Date? = nil,
        upNextOrder: Int? = nil,
        resumePositionSeconds: Double? = nil,
        lastPlayedAt: Date? = nil,
        classifierVersion: Int = 0,
        cleanedTitle: String? = nil,
        seasonNumber: Int? = nil,
        episodeNumber: Int? = nil,
        titleCleanerVersion: Int = 0
    ) {
        self.videoId = videoId
        self.channelId = channelId
        self.channelTitle = channelTitle
        self.title = title
        self.videoDescription = videoDescription
        self.publishedAt = publishedAt
        self.durationSeconds = durationSeconds
        self.thumbnailURL = thumbnailURL
        self.thumbnailWidth = thumbnailWidth
        self.thumbnailHeight = thumbnailHeight
        self.youtubeCategoryId = youtubeCategoryId
        self.isLikelyShort = isLikelyShort
        self.isWatched = isWatched
        self.savedForLaterAt = savedForLaterAt
        self.upNextOrder = upNextOrder
        self.resumePositionSeconds = resumePositionSeconds
        self.lastPlayedAt = lastPlayedAt
        self.classifierVersion = classifierVersion
        self.cleanedTitle = cleanedTitle
        self.seasonNumber = seasonNumber
        self.episodeNumber = episodeNumber
        self.titleCleanerVersion = titleCleanerVersion
    }

    var isInUpNext: Bool { savedForLaterAt != nil }

    /// What the UI shows wherever a title appears. A video that hasn't been
    /// cleaned yet — one that just arrived, or one stored before cleaning
    /// existed — shows its raw title, which is why cleaning can run in the
    /// background without the feed waiting for it.
    var displayTitle: String {
        guard let cleanedTitle, !cleanedTitle.isEmpty else { return title }
        return cleanedTitle
    }

    /// True when cleaning actually changed something, which is the only time
    /// the player shows the raw YouTube title underneath. Surrounding
    /// whitespace doesn't count: plenty of YouTube titles carry a trailing
    /// space, and dropping it isn't a change worth showing the original for.
    var hasCleanedTitle: Bool {
        displayTitle != title.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// "Ep. 142", or "S20 Ep. 4". Nil when the title carried no numbering.
    var episodeLabel: String? {
        TitleStripper.episodeLabel(season: seasonNumber, episode: episodeNumber)
    }

    var formattedDuration: String {
        let h = durationSeconds / 3600
        let m = (durationSeconds % 3600) / 60
        let s = durationSeconds % 60
        return h > 0
            ? String(format: "%d:%02d:%02d", h, m, s)
            : String(format: "%d:%02d", m, s)
    }
}
