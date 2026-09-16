import Foundation

/// One hydrated video on its way into the store, with the signals its Shorts
/// verdict is judged from.
///
/// A value type so the two halves of storing a video can sit on different
/// actors: decoding and classification stay on `FeedRefresher`, which owns the
/// thumbnail session, while the row itself is only ever built and inserted on
/// `StoreWriter`'s context. Nothing of SwiftData's crosses between them.
struct VideoDraft: Sendable {
    var videoId: String
    var channelId: String
    var channelTitle: String
    var title: String
    var videoDescription: String
    var publishedAt: Date
    var durationSeconds: Int
    var thumbnailURL: String?
    var youtubeCategoryId: String?
    var signals: VideoSignals
    /// Filled in before the row is built: see `FeedRefresher.upsert`.
    var isLikelyShort = false

    /// Nil for anything that can't be stored yet. Live streams and premieres
    /// have no duration, and a 0-second video is one the Shorts heuristic
    /// can't judge, so they're skipped rather than stored unjudgeable.
    init?(item: YT.VideoItem) {
        guard let snippet = item.snippet else { return nil }
        guard let durationString = item.contentDetails?.duration,
              let duration = ISO8601Duration.seconds(from: durationString),
              duration > 0
        else { return nil }

        let thumbnail = snippet.thumbnails?.best
        videoId = item.id
        channelId = snippet.channelId ?? ""
        channelTitle = snippet.channelTitle ?? ""
        title = snippet.title ?? "Untitled"
        videoDescription = snippet.description ?? ""
        publishedAt = snippet.publishedAt ?? .now
        durationSeconds = duration
        thumbnailURL = thumbnail?.url
        youtubeCategoryId = snippet.categoryId
        signals = VideoSignals(
            durationSeconds: duration,
            title: snippet.title ?? "",
            description: snippet.description ?? "",
            thumbnailWidth: thumbnail?.width,
            thumbnailHeight: thumbnail?.height
        )
    }

    /// The row, carrying the verdict already reached for it.
    func makeVideo(classifierVersion: Int) -> Video {
        Video(
            videoId: videoId,
            channelId: channelId,
            channelTitle: channelTitle,
            title: title,
            videoDescription: videoDescription,
            publishedAt: publishedAt,
            durationSeconds: durationSeconds,
            thumbnailURL: thumbnailURL,
            thumbnailWidth: signals.thumbnailWidth,
            thumbnailHeight: signals.thumbnailHeight,
            youtubeCategoryId: youtubeCategoryId,
            isLikelyShort: isLikelyShort,
            classifierVersion: classifierVersion
        )
    }
}
