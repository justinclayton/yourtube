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

    var isLikelyShort: Bool
    var isWatched: Bool
    var savedForLaterAt: Date?

    var collection: VideoCollection?
    /// Bumped when the classifier logic changes, to trigger re-classification.
    var classifierVersion: Int

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
        isLikelyShort: Bool = false,
        isWatched: Bool = false,
        savedForLaterAt: Date? = nil,
        classifierVersion: Int = 0
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
        self.isLikelyShort = isLikelyShort
        self.isWatched = isWatched
        self.savedForLaterAt = savedForLaterAt
        self.classifierVersion = classifierVersion
    }

    var isSavedForLater: Bool { savedForLaterAt != nil }

    var formattedDuration: String {
        let h = durationSeconds / 3600
        let m = (durationSeconds % 3600) / 60
        let s = durationSeconds % 60
        return h > 0
            ? String(format: "%d:%02d:%02d", h, m, s)
            : String(format: "%d:%02d", m, s)
    }
}
