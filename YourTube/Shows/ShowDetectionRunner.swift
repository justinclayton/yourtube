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
///
/// The pass itself runs on `StoreWriter`, off the main context. It reads every
/// video in the store to judge a channel's shape, which on the main context
/// meant materialising thousands of objects behind the feed's own queries.
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

    private let writer: StoreWriter
    private let defaults: UserDefaults
    private var runningTask: Task<Void, Never>?

    init(
        modelContext: ModelContext,
        defaults: UserDefaults = .standard,
        writer: StoreWriter? = nil
    ) {
        self.writer = writer ?? StoreWriter(modelContainer: modelContext.container)
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
        let outcome = try await writer.detectShows(fingerprints: storedFingerprints())
        defaults.set(outcome.fingerprints, forKey: Self.fingerprintsKey)
        lastExamined = outcome.examined
        lastChanged = outcome.changed
        lastRunAt = .now
        return outcome.changed
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
