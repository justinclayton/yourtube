import Foundation
import SwiftData

/// The door videos enter the store by.
///
/// Everything between "the API handed back some JSON" and "there is a `Video`
/// row" happens here and nowhere else: the DTO is mapped to a draft, the
/// Shorts verdict is reached, and only then is the row inserted. Three
/// callers use it — the feed refresh, a playlist-backed show's membership
/// refresh, and `DebugFixtures` — and none of them may build a `Video` of
/// its own.
///
/// **Classify before inserting.** The feed's `@Query` watches the store, and
/// the verdict can suspend on a thumbnail download, so a video inserted first
/// would appear in the feed with the default `isLikelyShort = false` and then
/// vanish once its verdict landed. Holding the insert until the verdict is
/// known means a Short is hidden from its first appearance. That the rows are
/// written on another context doesn't change it: what's deferred is the
/// insert, not the save.
///
/// **Why the thumbnail verdict is accepted rather than owned.** It is the one
/// part of the decision that leaves the process, and it is the only reason
/// this used to need a network. Handed in, the app passes
/// `DownloadedThumbnailVerdict` and everything else passes
/// `CannedThumbnailVerdict` — so a test can watch a video be held until the
/// verdict is known without a semaphore-gated `URLProtocol`, and the fixtures
/// get their Shorts from the real heuristic rather than a hand-stamped field.
///
/// A value type with no state of its own: it is two dependencies and the
/// order they're used in. `StoreWriter` owns the context the rows land on;
/// see `StoreWriter` for why that isn't the main one.
struct VideoIntake: Sendable {
    private let writer: StoreWriter
    private let thumbnails: ThumbnailVerdict

    init(writer: StoreWriter, thumbnails: ThumbnailVerdict) {
        self.writer = writer
        self.thumbnails = thumbnails
    }

    /// Every video ID already through the door, so a caller knows what it
    /// needn't hydrate.
    func knownVideoIds() async throws -> Set<String> {
        try await writer.knownVideoIds()
    }

    /// Maps, judges and stores hydrated videos. Returns how many rows were
    /// written, which is fewer than `items` when some of them can't be stored
    /// at all — a live stream or premiere has no duration, so `VideoDraft`
    /// declines it.
    @discardableResult
    func admit(_ items: [YT.VideoItem]) async throws -> Int {
        var drafts = items.compactMap(VideoDraft.init(item:))
        guard !drafts.isEmpty else { return 0 }

        let verdicts = await shortsVerdicts(for: drafts.map { ($0.videoId, $0.signals) })
        for index in drafts.indices {
            drafts[index].isLikelyShort = verdicts[drafts[index].videoId] ?? false
        }
        try await writer.insert(drafts, classifierVersion: ShortsHeuristic.version)
        return drafts.count
    }

    /// Re-runs the heuristic over videos judged by an older version of it, and
    /// writes the new verdicts back. Cheap when there's nothing to do, which
    /// is every time but the first launch after an app update that changed the
    /// heuristic.
    ///
    /// Lives here rather than on `FeedRefresher` because it asks the same
    /// question of the same dependency as `admit` does — the only difference
    /// is that the signals come off a stored row instead of off a DTO, and
    /// `VideoSignals` knows both derivations.
    func reclassifyStale() async throws {
        let current = ShortsHeuristic.version
        let stale = try await writer.staleShortsSignals(version: current)
        guard !stale.isEmpty else { return }

        let verdicts = await shortsVerdicts(for: stale.map { ($0.key, $0.value) })
        try await writer.applyShortsVerdicts(verdicts, version: current)
    }

    /// Applies the Shorts heuristic to signals, asking for a thumbnail verdict
    /// only where it could change the answer: inside the duration gate and not
    /// already caught by a cheaper signal.
    ///
    /// Works on plain signals rather than on rows because the rows belong to
    /// the writer's context.
    private func shortsVerdicts(
        for pending: [(videoId: String, signals: VideoSignals)]
    ) async -> [String: Bool] {
        var undecided: [String] = []
        for (videoId, signals) in pending
        where ShortsHeuristic.isWithinDurationGate(signals)
            && !ShortsHeuristic.isLikelyShort(signals) {
            undecided.append(videoId)
        }

        let pillarboxed = await thumbnails.pillarboxed(videoIds: undecided)

        var verdicts: [String: Bool] = [:]
        for (videoId, signals) in pending {
            var signals = signals
            signals.hasPillarboxedThumbnail = pillarboxed[videoId] ?? nil
            verdicts[videoId] = ShortsHeuristic.isLikelyShort(signals)
        }
        return verdicts
    }
}
