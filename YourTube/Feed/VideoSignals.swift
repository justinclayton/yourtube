import Foundation

/// The inputs the Shorts heuristic needs. A plain value type, so the
/// heuristic is testable without SwiftData or the network.
///
/// Both ways of arriving at a set of signals live here: off a hydrated DTO on
/// its way in, and off a stored row being re-judged. They used to be spelled
/// out separately at the two call sites, which is how the two halves of one
/// decision get to drift apart — a field added to the heuristic and read on
/// only one of the paths judges a new video and an old one differently.
struct VideoSignals: Equatable {
    var durationSeconds: Int
    var title: String
    var description: String
    var thumbnailWidth: Int?
    var thumbnailHeight: Int?
    /// Result of `ThumbnailAnalyzer` on the thumbnail image, if it was run.
    /// Nil means "not analysed", which is treated as no evidence either way.
    var hasPillarboxedThumbnail: Bool?

    init(
        durationSeconds: Int,
        title: String = "",
        description: String = "",
        thumbnailWidth: Int? = nil,
        thumbnailHeight: Int? = nil,
        hasPillarboxedThumbnail: Bool? = nil
    ) {
        self.durationSeconds = durationSeconds
        self.title = title
        self.description = description
        self.thumbnailWidth = thumbnailWidth
        self.thumbnailHeight = thumbnailHeight
        self.hasPillarboxedThumbnail = hasPillarboxedThumbnail
    }

    /// A video arriving through `VideoIntake`. The duration is passed in
    /// already parsed, because the caller has had to parse it to know the
    /// video is storable at all.
    init(
        snippet: YT.VideoItem.Snippet,
        durationSeconds: Int,
        thumbnail: YT.Thumbnail?
    ) {
        self.init(
            durationSeconds: durationSeconds,
            title: snippet.title ?? "",
            description: snippet.description ?? "",
            thumbnailWidth: thumbnail?.width,
            thumbnailHeight: thumbnail?.height
        )
    }

    /// A stored video being re-judged by a newer version of the heuristic.
    init(_ video: Video) {
        self.init(
            durationSeconds: video.durationSeconds,
            title: video.title,
            description: video.videoDescription,
            thumbnailWidth: video.thumbnailWidth,
            thumbnailHeight: video.thumbnailHeight
        )
    }
}
