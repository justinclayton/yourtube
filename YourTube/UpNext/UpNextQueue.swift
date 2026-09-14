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
@MainActor
final class UpNextQueue {
    private let modelContext: ModelContext

    init(modelContext: ModelContext) {
        self.modelContext = modelContext
    }

    /// Earmarked videos in the user's order. Entries that predate Up Next
    /// and haven't been migrated yet fall to the end, oldest save first.
    func entries() throws -> [Video] {
        let descriptor = FetchDescriptor<Video>(
            predicate: #Predicate { $0.savedForLaterAt != nil }
        )
        return try modelContext.fetch(descriptor).sorted(by: Self.precedes)
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

    /// Reorder, with offsets in the order `entries()` returns.
    func move(fromOffsets source: IndexSet, toOffset destination: Int) throws {
        var ordered = try entries()
        ordered.move(fromOffsets: source, toOffset: destination)
        for (index, video) in ordered.enumerated() {
            video.upNextOrder = index + 1
        }
        try modelContext.save()
    }

    /// Watched is the one thing that empties Up Next without the user
    /// removing an entry by hand: a finished video has no business waiting.
    func markWatched(_ video: Video) throws {
        video.isWatched = true
        video.savedForLaterAt = nil
        video.upNextOrder = nil
        try modelContext.save()
    }

    nonisolated static func precedes(_ a: Video, _ b: Video) -> Bool {
        switch (a.upNextOrder, b.upNextOrder) {
        case let (x?, y?): return x < y
        case (_?, nil): return true
        case (nil, _?): return false
        case (nil, nil): return (a.savedForLaterAt ?? .distantPast) < (b.savedForLaterAt ?? .distantPast)
        }
    }
}
