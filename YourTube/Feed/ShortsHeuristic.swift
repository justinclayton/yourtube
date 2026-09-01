import Foundation

/// The inputs the Shorts heuristic needs. Kept as a plain value type so the
/// heuristic is testable without SwiftData or the network.
struct VideoSignals: Equatable {
    var durationSeconds: Int
    var title: String
    var description: String
    var thumbnailWidth: Int?
    var thumbnailHeight: Int?

    init(
        durationSeconds: Int,
        title: String = "",
        description: String = "",
        thumbnailWidth: Int? = nil,
        thumbnailHeight: Int? = nil
    ) {
        self.durationSeconds = durationSeconds
        self.title = title
        self.description = description
        self.thumbnailWidth = thumbnailWidth
        self.thumbnailHeight = thumbnailHeight
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
/// which is why a bare `<= 60s` isn't enough on its own.
///
/// Because this is guesswork, Shorts are *hidden*, never deleted — a false
/// positive costs one toggle in Settings, not a lost video.
enum ShortsHeuristic {
    /// YouTube Shorts were capped at 60s at launch and later raised to 3 minutes.
    /// We use 60s because the longer cap makes the signal too noisy to be useful:
    /// far too many ordinary videos are under 3 minutes.
    static let maxShortDuration = 60

    static let shortsTags = ["#shorts", "#short", "#ytshorts", "#youtubeshorts"]

    static func isLikelyShort(_ signals: VideoSignals) -> Bool {
        // Duration is a necessary condition. Nothing longer than the cap is a
        // Short, regardless of how it's tagged.
        guard signals.durationSeconds > 0,
              signals.durationSeconds <= maxShortDuration else {
            return false
        }
        return hasShortsTag(signals) || hasPortraitThumbnail(signals)
    }

    static func hasShortsTag(_ signals: VideoSignals) -> Bool {
        let haystack = (signals.title + " " + signals.description).lowercased()
        return shortsTags.contains { haystack.contains($0) }
    }

    /// Shorts are shot 9:16. Regular thumbnails are 16:9 or 4:3, so anything
    /// taller than it is wide is a strong signal.
    ///
    /// Note: YouTube often serves letterboxed 16:9 thumbnails even for Shorts,
    /// so this has poor recall on its own — it's here to catch untagged Shorts,
    /// with the tag check carrying the rest.
    static func hasPortraitThumbnail(_ signals: VideoSignals) -> Bool {
        guard let w = signals.thumbnailWidth, let h = signals.thumbnailHeight,
              w > 0, h > 0 else { return false }
        return h > w
    }
}
