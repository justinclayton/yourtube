import Foundation
import SwiftData

/// The door videos enter the store by.
///
/// Everything between "the API handed back some JSON" and "there is a `Video`
/// row" happens here and nowhere else: the DTO is mapped to a draft, and only
/// then is the row inserted. Three callers use it — the feed refresh, a
/// playlist-backed show's membership refresh, and `DebugFixtures` — and none
/// of them may build a `Video` of its own.
///
/// A value type with no state of its own: `StoreWriter` owns the context the
/// rows land on; see `StoreWriter` for why that isn't the main one.
struct VideoIntake: Sendable {
    private let writer: StoreWriter

    init(writer: StoreWriter) {
        self.writer = writer
    }

    /// Every video ID already through the door, so a caller knows what it
    /// needn't hydrate.
    func knownVideoIds() async throws -> Set<String> {
        try await writer.knownVideoIds()
    }

    /// Maps and stores hydrated videos. Returns how many rows were written,
    /// which is fewer than `items` when some of them can't be stored at all —
    /// a live stream or premiere has no duration, so `VideoDraft` declines it.
    @discardableResult
    func admit(_ items: [YT.VideoItem]) async throws -> Int {
        let drafts = items.compactMap(VideoDraft.init(item:))
        guard !drafts.isEmpty else { return 0 }

        try await writer.insert(drafts)
        return drafts.count
    }
}
