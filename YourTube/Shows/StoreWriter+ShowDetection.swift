import Foundation
import SwiftData

/// The show detector's pass over the stored channels, on the writer's own
/// context. `ShowDetectionRunner` keeps the fingerprints and decides when a
/// pass runs; this is the pass. See `StoreWriter` for why it isn't on the main
/// context — this one also read every video in the store, which on the main
/// context meant materialising thousands of objects the views then held on to.
extension StoreWriter {

    /// What one detection pass did, plus the fingerprints it leaves behind for
    /// the next one.
    struct DetectionOutcome: Sendable {
        /// Channels actually examined; the rest were unchanged or the user's
        /// business.
        var examined = 0
        /// Show rows added, updated, or removed.
        var changed = 0
        var fingerprints: [String: String] = [:]
    }

    func detectShows(fingerprints stored: [String: String]) throws -> DetectionOutcome {
        var fingerprints = stored
        let subscriptions = try modelContext.fetch(FetchDescriptor<Subscription>())
        // Shorts are never episodes, so they're no evidence either.
        let byChannel = Dictionary(
            grouping: try modelContext.fetch(FetchDescriptor<Video>()).filter { !$0.isLikelyShort },
            by: \.channelId
        )
        // Only a channel-backed record speaks for the channel's own override:
        // a playlist-backed show's forced override is the user's opinion
        // about that playlist, not about whether the channel itself is a
        // show, so it must not remove the channel from consideration.
        let decided = Set(try modelContext.fetch(FetchDescriptor<Show>())
            .filter { !$0.isPlaylistBacked && ($0.override != .none || $0.flagOrigin == .user) }
            .map(\.channelId))

        var verdicts: [ShowVerdict] = []
        var examined = 0

        for subscription in subscriptions {
            let channelId = subscription.channelId
            guard !decided.contains(channelId) else { continue }

            let videos = byChannel[channelId] ?? []
            let fingerprint = ShowDetectionRunner.fingerprint(of: videos)
            guard fingerprints[channelId] != fingerprint else { continue }

            examined += 1
            fingerprints[channelId] = fingerprint
            verdicts.append(ShowDetector.verdict(for: ChannelEvidence(
                channelId: channelId,
                channelTitle: subscription.title,
                videos: videos.map(ShowDetectionRunner.signals(for:))
            )))
        }

        // Applied in chunks like every other pass, though a pass usually
        // changes only a handful of rows: it's the first pass over a fresh
        // store, which can flag dozens at once, that the chunking is for.
        var changed = 0
        for chunk in verdicts.chunked(into: Self.chunkSize) {
            changed += try ShowManager.applyAutomaticVerdicts(chunk, in: modelContext)
        }
        return DetectionOutcome(examined: examined, changed: changed, fingerprints: fingerprints)
    }
}
