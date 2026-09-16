import Foundation
import SwiftData
import Observation

/// Runs `ShowDetector` over the stored channels and files its verdicts through
/// `ShowManager`, the way `CategoryManager` runs the classifier: fire and
/// forget, at launch and after every refresh, never on the path to drawing
/// anything.
///
/// Two things keep the pass cheap and quiet. It skips any channel the user has
/// an opinion about, so a hand-made flag is never even reconsidered. And it
/// remembers a fingerprint per channel — how many videos we hold and the
/// newest publish date — so a channel is examined once and then only again
/// when its uploads actually move. The fingerprints are keyed by detector
/// version, so changing the heuristic re-examines everything exactly once.
///
/// Fingerprints live in `UserDefaults` rather than the store because most
/// channels are examined and rejected, and a rejection has no `Show` row to
/// hang anything off.
@Observable
@MainActor
final class ShowDetectionRunner {
    static let fingerprintsKey = "shows.detector.fingerprints"
    static let versionKey = "shows.detector.version"

    private(set) var lastRunAt: Date?
    /// Channels actually examined by the last pass; the rest were unchanged
    /// or the user's business.
    private(set) var lastExamined = 0
    /// Show rows the last pass added, updated, or removed.
    private(set) var lastChanged = 0
    private(set) var isRunning = false

    private let modelContext: ModelContext
    private let shows: ShowManager
    private let defaults: UserDefaults
    private var runningTask: Task<Void, Never>?

    /// Channels per slice before yielding, so a first pass over several
    /// hundred subscriptions can't hold the main thread through a frame.
    private let yieldInterval = 25

    init(modelContext: ModelContext, shows: ShowManager, defaults: UserDefaults = .standard) {
        self.modelContext = modelContext
        self.shows = shows
        self.defaults = defaults
    }

    /// Entry point for launch and for the end of a refresh. No-op while a
    /// pass is already going.
    func detectInBackground() {
        guard !isRunning else { return }
        runningTask = Task { [weak self] in
            _ = try? await self?.detect()
        }
    }

    /// One pass. Returns how many `Show` rows changed.
    @discardableResult
    func detect() async throws -> Int {
        guard !isRunning else { return 0 }
        isRunning = true
        defer { isRunning = false }

        forgetFingerprintsIfDetectorChanged()
        var fingerprints = storedFingerprints()

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
        let decided = Set(try shows.allRecords()
            .filter { !$0.isPlaylistBacked && ($0.override != .none || $0.flagOrigin == .user) }
            .map(\.channelId))

        var verdicts: [ShowVerdict] = []
        var examined = 0

        for (index, subscription) in subscriptions.enumerated() {
            if index > 0 && index.isMultiple(of: yieldInterval) { await Task.yield() }
            let channelId = subscription.channelId
            guard !decided.contains(channelId) else { continue }

            let videos = byChannel[channelId] ?? []
            let fingerprint = Self.fingerprint(of: videos)
            guard fingerprints[channelId] != fingerprint else { continue }

            examined += 1
            fingerprints[channelId] = fingerprint
            verdicts.append(ShowDetector.verdict(for: ChannelEvidence(
                channelId: channelId,
                channelTitle: subscription.title,
                videos: videos.map(Self.signals(for:))
            )))
        }

        let changed = try shows.applyAutomaticVerdicts(verdicts)
        defaults.set(fingerprints, forKey: Self.fingerprintsKey)
        lastExamined = examined
        lastChanged = changed
        lastRunAt = .now
        return changed
    }

    /// What "materially changed" means: a different number of videos, or a
    /// newer one. Both of those can move a verdict; nothing else we store can.
    nonisolated static func fingerprint(of videos: [Video]) -> String {
        let newest = videos.map(\.publishedAt).max()?.timeIntervalSince1970 ?? 0
        return "\(videos.count)|\(Int(newest))"
    }

    nonisolated static func signals(for video: Video) -> EpisodeSignals {
        EpisodeSignals(
            durationSeconds: video.durationSeconds,
            publishedAt: video.publishedAt,
            title: video.title,
            description: video.videoDescription,
            categoryId: video.youtubeCategoryId
        )
    }

    private func storedFingerprints() -> [String: String] {
        defaults.dictionary(forKey: Self.fingerprintsKey) as? [String: String] ?? [:]
    }

    private func forgetFingerprintsIfDetectorChanged() {
        guard defaults.integer(forKey: Self.versionKey) != ShowDetector.version else { return }
        defaults.removeObject(forKey: Self.fingerprintsKey)
        defaults.set(ShowDetector.version, forKey: Self.versionKey)
    }
}
