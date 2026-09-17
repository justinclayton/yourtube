import Foundation

/// One video, as the show detector sees it. A plain value type, like
/// `VideoSignals`, so the detector is testable without SwiftData or the
/// network.
///
/// In its own file rather than `ShowDetector.swift` because
/// `YouTubeCategorySignal` reads it too, and both are compiled standalone by
/// `scripts/category-agreement.sh` — the detector proper drags in types that
/// harness has no use for.
struct EpisodeSignals: Sendable, Equatable {
    var durationSeconds: Int
    var publishedAt: Date
    var title: String
    var description: String
    /// YouTube's own `snippet.categoryId`, e.g. `"25"` for News & Politics.
    /// Nil for videos stored before the field was fetched.
    var categoryId: String?

    init(
        durationSeconds: Int,
        publishedAt: Date,
        title: String = "",
        description: String = "",
        categoryId: String? = nil
    ) {
        self.durationSeconds = durationSeconds
        self.publishedAt = publishedAt
        self.title = title
        self.description = description
        self.categoryId = categoryId
    }
}
