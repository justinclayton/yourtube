import Foundation
import SwiftData

/// The user's earmark list, and the only queue in the app.
///
/// Up Next replaces Watch Later. Nothing lands here automatically and the
/// order means nothing to the app: it's the user's own grouping, kept only
/// so a reordering sticks. Entries live on `Video`: `savedForLaterAt` is the
/// earmark date (kept under its Watch Later name so existing stores open
/// without a migration) and `upNextOrder` is the position. Marking a video
/// watched removes it, so the list stays honest.
extension WatchState {
    /// Earmarked videos in the user's order.
    func entries() throws -> [Video] {
        let descriptor = FetchDescriptor<Video>(predicate: Self.upNextPredicate, sortBy: Self.upNextSortDescriptors)
        return try modelContext.fetch(descriptor)
    }

    /// Watch Later saves from before Up Next existed carry a date but no
    /// position. Give them one, oldest save first, so a list built over time
    /// comes across in the order it was built. Idempotent; returns how many
    /// entries were given a position.
    @discardableResult
    func migrateLegacySaves() throws -> Int {
        let entries = try entries()
        let unplaced = entries.filter { $0.upNextOrder == nil }
        guard !unplaced.isEmpty else { return 0 }
        var next = (entries.compactMap(\.upNextOrder).max() ?? 0) + 1
        for video in unplaced.sorted(by: { ($0.savedForLaterAt ?? .distantPast) < ($1.savedForLaterAt ?? .distantPast) }) {
            video.upNextOrder = next
            next += 1
        }
        try modelContext.save()
        return unplaced.count
    }

    /// Append to the end of the list. A no-op if already earmarked.
    func earmark(_ video: Video) throws {
        guard !video.isInUpNext else { return }
        let last = try entries().compactMap(\.upNextOrder).max() ?? 0
        video.savedForLaterAt = .now
        video.upNextOrder = last + 1
        try modelContext.save()
    }

    func remove(_ video: Video) throws {
        guard video.isInUpNext else { return }
        video.savedForLaterAt = nil
        video.upNextOrder = nil
        try modelContext.save()
    }

    func toggle(_ video: Video) throws {
        if video.isInUpNext {
            try remove(video)
        } else {
            try earmark(video)
        }
    }

    /// Reorder. `ordered` is the list exactly as the caller displayed it —
    /// its own `@Query` over `upNextPredicate`/`upNextSortDescriptors` — so
    /// the offsets SwiftUI's `onMove` hands in always index the same array
    /// this reassigns, rather than whatever a fresh `entries()` fetch would
    /// return.
    func move(_ ordered: [Video], fromOffsets source: IndexSet, toOffset destination: Int) throws {
        var ordered = ordered
        ordered.move(fromOffsets: source, toOffset: destination)
        for (index, video) in ordered.enumerated() {
            video.upNextOrder = index + 1
        }
        try modelContext.save()
    }
}
