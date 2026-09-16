import Foundation
import SwiftData

/// Progress from a background pass: rows done, out of how many. Called from
/// the writer's context, so a manager hands it on to the main actor rather
/// than touching its status directly.
typealias StoreWriterProgress = @Sendable (Int, Int) -> Void

/// The writing half of every pass that goes over the store in bulk.
///
/// SwiftData's `@Query` observes the main context live, unsaved edits
/// included, so a batch pass that wrote through that context made every live
/// query in the app re-fetch once per row. On the real store (6,000 videos,
/// 629 channels) that cost the main thread 55% of its time in the feed's body
/// while the launch title rewrite ran, and dropped around eight frames a
/// second; saving every twenty rows did not help, because the change
/// notification fires per edit and not per save.
///
/// So the batch passes — title cleaning, category classification, show
/// detection, and storing what a refresh found — run here instead, on a
/// context of their own, and save in chunks. The main context sees one merge
/// per chunk: tens of interruptions over a long run rather than thousands.
///
/// One writer rather than one per pass, because the passes overlap. A launch
/// starts classification, cleaning and detection at once, and cleaning and
/// Shorts re-classification write the same `Video` rows. Sharing a context
/// keeps those serialized, the way sharing the main context used to, instead
/// of leaving two contexts to collide over a row at save time.
///
/// Each pass lives in an extension beside the manager that drives it. The
/// managers keep what they always had: the settings, the decision about when
/// to run, and the observable status the views bind to.
@ModelActor
actor StoreWriter {
    /// Rows written between saves. Small enough that being killed mid-run
    /// loses little, large enough that a long run merges into the main context
    /// tens of times rather than thousands.
    static let chunkSize = 25

    /// How often a pass reports progress: at most a hundred updates per run,
    /// however long it is. A progress figure is cheap to draw but not free —
    /// it invalidates the body it sits in — and nobody can read more than that.
    static func progressInterval(total: Int) -> Int { max(1, total / 100) }
}

/// Reasons a pass can't run, phrased for the status line the user sees.
enum StoreWriterError: LocalizedError {
    /// The classifier has nothing to choose from: the user deleted every
    /// category.
    case noTopicCategories

    var errorDescription: String? {
        switch self {
        case .noTopicCategories: "Add at least one category first."
        }
    }
}
