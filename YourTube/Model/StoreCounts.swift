import Foundation
import SwiftData

/// The totals the UI puts in badges and in Settings, read straight from the
/// store rather than by counting the rows of a live query.
///
/// Every one of these used to be a `@Query` returning thousands of `Video`
/// objects to produce one number, re-run on every store change whether or not
/// its tab was on screen (issue #66). They are one-shot reads instead, driven
/// by `View.recomputingFromStore(id:_:)`.
enum StoreCounts {
    /// What the Settings "Library" section reports. Three counts, no rows.
    static func library(in context: ModelContext) throws -> LibraryCounts {
        LibraryCounts(
            subscriptions: try context.fetchCount(FetchDescriptor<Subscription>()),
            videos: try context.fetchCount(FetchDescriptor<Video>()),
            shorts: try context.fetchCount(FetchDescriptor<Video>(
                predicate: #Predicate { $0.isLikelyShort }
            ))
        )
    }

    /// How many unwatched videos each channel has, keyed by channel ID, for
    /// the Channels rows and their group headers.
    ///
    /// One fetch rather than a `fetchCount` per row: with several hundred
    /// subscriptions a count each is hundreds of round trips, and the answer
    /// is wanted for all of them at once. Only `channelId` is read back, so
    /// the rows come across narrow.
    static func unwatchedByChannel(
        in context: ModelContext,
        includingShorts: Bool
    ) throws -> [String: Int] {
        var descriptor = FetchDescriptor<Video>(
            predicate: includingShorts
                ? #Predicate<Video> { !$0.isWatched }
                : #Predicate<Video> { !$0.isWatched && !$0.isLikelyShort }
        )
        descriptor.propertiesToFetch = [\.channelId]
        return try context.fetch(descriptor).reduce(into: [String: Int]()) {
            $0[$1.channelId, default: 0] += 1
        }
    }
}

/// The three numbers the Settings library section shows. Zero everywhere
/// until the first read lands, which is one frame after the view appears.
struct LibraryCounts: Equatable {
    var subscriptions = 0
    var videos = 0
    var shorts = 0
}
