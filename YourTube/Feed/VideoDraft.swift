import Foundation

/// One hydrated video on its way into the store.
///
/// A value type so the two halves of storing a video can sit on different
/// actors: decoding stays on `VideoIntake`, while the row itself is only ever
/// built and inserted on `StoreWriter`'s context. Nothing of SwiftData's
/// crosses between them.
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

    /// Nil for anything that can't be stored yet. Live streams and premieres
    /// have no duration, so they're skipped rather than stored unjudgeable.
    init?(item: YT.VideoItem) {
        guard let snippet = item.snippet else { return nil }
        guard let durationString = item.contentDetails?.duration,
              let duration = ISO8601Duration.seconds(from: durationString),
              duration > 0
        else { return nil }

        videoId = item.id
        channelId = snippet.channelId ?? ""
        channelTitle = snippet.channelTitle ?? ""
        title = snippet.title ?? "Untitled"
        videoDescription = snippet.description ?? ""
        publishedAt = snippet.publishedAt ?? .now
        durationSeconds = duration
        thumbnailURL = snippet.thumbnails?.best?.url
        youtubeCategoryId = snippet.categoryId
    }

    /// The row.
    func makeVideo() -> Video {
        Video(
            videoId: videoId,
            channelId: channelId,
            channelTitle: channelTitle,
            title: title,
            videoDescription: videoDescription,
            publishedAt: publishedAt,
            durationSeconds: durationSeconds,
            thumbnailURL: thumbnailURL,
            youtubeCategoryId: youtubeCategoryId
        )
    }
}
