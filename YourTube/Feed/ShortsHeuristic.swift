import Foundation

/// The inputs the Shorts heuristic needs. Kept as a plain value type so the
/// heuristic is testable without SwiftData or the network.
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
}

/// Decides whether a video is a Short.
///
/// There is still no `isShort` field on the Data API in 2026, so this is
/// necessarily a heuristic. The most accurate signal available is probing
/// `youtube.com/shorts/{id}` and watching for a redirect (~99%), but that is an
/// undocumented endpoint that rate-limits aggressively and arguably violates the
/// API ToS — so we deliberately don't use it.
///
/// What's left is duration plus a corroborating signal. Duration alone
/// over-fires on trailers, clips and pre-2020 uploads that happen to be short,
/// which is why a bare duration check isn't enough on its own.
///
/// Corroborating signals, any one of which is sufficient:
/// - a `#shorts`-style tag in the title or description;
/// - a portrait thumbnail (rare: the API almost always reports 16:9);
/// - a pillarboxed thumbnail, i.e. vertical video with YouTube's blurred
///   side fill, detected by `ThumbnailAnalyzer`. This is what catches the
///   large majority of untagged Shorts in practice.
///
/// Because this is guesswork, Shorts are *hidden*, never deleted — a false
/// positive costs one toggle in Settings, not a lost video.
enum ShortsHeuristic {
    /// Bump when the decision logic changes so stored videos get re-classified
    /// on the next refresh (see `Video.classifierVersion`).
    static let version = 2

    /// Shorts were capped at 60s at launch; YouTube raised the cap to 3 minutes
    /// in October 2024 and creators use it. A wider gate is only tolerable
    /// because a corroborating signal is still required.
    static let maxShortDuration = 180

    static let shortsTags = ["#shorts", "#short", "#ytshorts", "#youtubeshorts"]

    static func isLikelyShort(_ signals: VideoSignals) -> Bool {
        guard isWithinDurationGate(signals) else { return false }
        return hasShortsTag(signals)
            || hasPortraitThumbnail(signals)
            || signals.hasPillarboxedThumbnail == true
    }

    /// Duration is a necessary condition. Nothing longer than the cap is a
    /// Short, regardless of how it's tagged. Callers use this to decide whether
    /// the (comparatively expensive) thumbnail analysis is worth running.
    static func isWithinDurationGate(_ signals: VideoSignals) -> Bool {
        signals.durationSeconds > 0 && signals.durationSeconds <= maxShortDuration
    }

    static func hasShortsTag(_ signals: VideoSignals) -> Bool {
        let haystack = (signals.title + " " + signals.description).lowercased()
        return shortsTags.contains { haystack.contains($0) }
    }

    /// Shorts are shot 9:16. Regular thumbnails are 16:9 or 4:3, so anything
    /// taller than it is wide is a strong signal.
    ///
    /// Note: the API reports 16:9 dimensions for Shorts almost without
    /// exception (the vertical frame is pillarboxed into a landscape image), so
    /// this rarely fires. It's kept because it's free and never wrong.
    static func hasPortraitThumbnail(_ signals: VideoSignals) -> Bool {
        guard let w = signals.thumbnailWidth, let h = signals.thumbnailHeight,
              w > 0, h > 0 else { return false }
        return h > w
    }
}
