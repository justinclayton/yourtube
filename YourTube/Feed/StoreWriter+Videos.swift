import Foundation
import SwiftData

/// Storing what a refresh found, on the writer's own context.
///
/// `FeedRefresher` still owns the network: it decodes what the API returned
/// and runs the Shorts heuristic, which needs to download thumbnails. Only the
/// rows come through here. See `StoreWriter` for why.
extension StoreWriter {

    /// Every video ID already stored, so a refresh knows what it needn't
    /// hydrate. Read here rather than on the main context because it walks the
    /// whole store: on a 6,000-video library, doing it on the main context
    /// materialised every one of them where the views could keep them alive.
    func knownVideoIds() throws -> Set<String> {
        Set(try modelContext.fetch(FetchDescriptor<Video>()).map(\.videoId))
    }

    /// Inserts hydrated videos that already carry their Shorts verdict,
    /// saving after each chunk.
    func insert(_ drafts: [VideoDraft], classifierVersion: Int) throws {
        for chunk in drafts.chunked(into: Self.chunkSize) {
            for draft in chunk {
                modelContext.insert(draft.makeVideo(classifierVersion: classifierVersion))
            }
            try modelContext.save()
        }
    }

    /// Signals for every video judged by an older version of the heuristic,
    /// keyed by video ID, for `FeedRefresher` to re-judge.
    func staleShortsSignals(version: Int) throws -> [String: VideoSignals] {
        let stale = try modelContext.fetch(FetchDescriptor<Video>(
            predicate: #Predicate { $0.classifierVersion < version }
        ))
        return Dictionary(uniqueKeysWithValues: stale.map { video in
            (video.videoId, VideoSignals(
                durationSeconds: video.durationSeconds,
                title: video.title,
                description: video.videoDescription,
                thumbnailWidth: video.thumbnailWidth,
                thumbnailHeight: video.thumbnailHeight
            ))
        })
    }

    /// Writes re-judged verdicts back, saving after each chunk. A video with
    /// no verdict in hand keeps its old version stamp and is offered again on
    /// the next pass.
    func applyShortsVerdicts(_ verdicts: [String: Bool], version: Int) throws {
        let stale = try modelContext.fetch(FetchDescriptor<Video>(
            predicate: #Predicate { $0.classifierVersion < version }
        ))
        for chunk in stale.chunked(into: Self.chunkSize) {
            for video in chunk {
                guard let verdict = verdicts[video.videoId] else { continue }
                video.isLikelyShort = verdict
                video.classifierVersion = version
            }
            try modelContext.save()
        }
    }
}
