import Foundation
import SwiftData

/// The viewer's relationship to a video: watched, earmarked to Up Next, or
/// partway through. Five fields on `Video` — `isWatched`, `savedForLaterAt`,
/// `upNextOrder`, `resumePositionSeconds`, `lastPlayedAt` — and `WatchState`
/// is their only writer, so "what does watched clear" and "what order is Up
/// Next in" each have exactly one answer instead of one per caller.
///
/// `upNextOrder` is nil only in the pre-migration window: `earmark` assigns
/// one immediately and `migrateLegacySaves()` backfills the rest at launch,
/// so by the time any view queries it there are no nils left for
/// `upNextPredicate`/`upNextSortDescriptors` to disagree about.
///
/// Split by concern into `WatchState+UpNext` (earmarking and order) and
/// `WatchState+Playback` (position and the 90% rule); this file holds what's
/// shared between them and the watched/unwatched transition itself, since
/// that's the one write both concerns care about.
@MainActor
final class WatchState {
    let modelContext: ModelContext

    init(modelContext: ModelContext) {
        self.modelContext = modelContext
    }

    /// The one definition of Up Next's order, shared by `entries()` and every
    /// `@Query` that lists it, so a view's own sort can never drift from
    /// what `move` assumes.
    static let upNextPredicate = #Predicate<Video> { $0.savedForLaterAt != nil }
    static let upNextSortDescriptors: [SortDescriptor<Video>] = [
        SortDescriptor(\Video.upNextOrder), SortDescriptor(\Video.savedForLaterAt)
    ]

    /// The one definition of Continue Watching, shared the same way.
    static let inProgressPredicate = #Predicate<Video> { $0.resumePositionSeconds != nil && !$0.isWatched }
    static let inProgressSortDescriptors: [SortDescriptor<Video>] = [
        SortDescriptor(\Video.lastPlayedAt, order: .reverse)
    ]

    /// Watched is the one thing that empties Up Next and clears any stored
    /// position without the user removing an entry by hand: a finished video
    /// has no business waiting, and replaying it starts over rather than
    /// picking up at the 90% mark. Every entry point — swipe, mark-all, the
    /// 90% auto-rule, the manual button — goes through this, so they leave
    /// identical state.
    func markWatched(_ video: Video) throws {
        applyWatched(to: video)
        try modelContext.save()
    }

    /// Same effect as `markWatched`, batched into one save: clearing a
    /// show's backlog through `ShowManager.markAllWatched` shouldn't rerun
    /// every live query in the app once per episode.
    @discardableResult
    func markWatched(_ videos: some Sequence<Video>) throws -> Int {
        var count = 0
        for video in videos {
            applyWatched(to: video)
            count += 1
        }
        if count > 0 { try modelContext.save() }
        return count
    }

    private func applyWatched(to video: Video) {
        video.isWatched = true
        video.savedForLaterAt = nil
        video.upNextOrder = nil
        video.resumePositionSeconds = nil
    }

    /// Unwatching doesn't put a video back in Up Next or restore a position:
    /// `markWatched` already cleared both, so there's nothing to restore.
    func unwatch(_ video: Video) throws {
        video.isWatched = false
        try modelContext.save()
    }
}
