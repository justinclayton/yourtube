import Foundation
import SwiftData

/// Storing what a refresh found, on the writer's own context.
///
/// `VideoIntake` still owns the decision: it maps what the API returned. Only
/// the rows come through here. See `StoreWriter` for why.
extension StoreWriter {

    /// Every video ID already stored, so a refresh knows what it needn't
    /// hydrate. Read here rather than on the main context because it walks the
    /// whole store: on a 6,000-video library, doing it on the main context
    /// materialised every one of them where the views could keep them alive.
    /// `propertiesToFetch` keeps that materialisation to just the one string
    /// per row instead of a full `Video` for each.
    func knownVideoIds() throws -> Set<String> {
        var descriptor = FetchDescriptor<Video>()
        descriptor.propertiesToFetch = [\.videoId]
        return Set(try modelContext.fetch(descriptor).map(\.videoId))
    }

    /// Inserts hydrated videos, saving after each chunk.
    func insert(_ drafts: [VideoDraft]) throws {
        for chunk in drafts.chunked(into: Self.chunkSize) {
            for draft in chunk {
                modelContext.insert(draft.makeVideo())
            }
            try modelContext.save()
        }
    }
}
