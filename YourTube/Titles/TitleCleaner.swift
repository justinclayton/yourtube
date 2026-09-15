import Foundation
import SwiftData
import Observation

/// Drives `TitleStripper` over the stored videos and caches what it finds on
/// `Video`.
///
/// Cleaning is a background job for the same reason category classification
/// is: it's per-channel work over the whole store, and the feed must render
/// before it finishes. A video with no cached result shows its raw title, so
/// the worst a slow run costs is a title that tidies itself a moment later.
///
/// Staleness is the Shorts classifier's mechanism exactly: each video records
/// the cleaner version that produced its cached title, and a run picks up
/// anything below the current one. Bumping `TitleStripper.version` therefore
/// re-cleans the whole store on the next launch, with no migration to write.
///
/// Work is grouped by channel because the stripper needs a channel's titles
/// together to find the repeated affix. When any video of a channel is stale
/// the whole channel is re-cleaned, so a channel's titles are never a mix of
/// verdicts from different evidence — new uploads can change what counts as
/// boilerplate.
@Observable
@MainActor
final class TitleCleaner {
    enum Status: Equatable {
        case idle
        case running(completed: Int, total: Int)
        case failed(String)
    }

    /// The version stamped on cleaned videos. Tier two (#27) bumps this when
    /// the rewrite lands, which re-cleans everything.
    static var version: Int { TitleStripper.version }

    private(set) var status: Status = .idle
    private(set) var lastRunAt: Date?

    private let modelContext: ModelContext
    private var runningTask: Task<Void, Never>?

    /// Save every N channels so a kill mid-run doesn't lose the work.
    private let saveInterval = 20

    init(modelContext: ModelContext) {
        self.modelContext = modelContext
    }

    var isRunning: Bool {
        if case .running = status { return true }
        return false
    }

    /// Fire-and-forget entry point, used at launch and after each refresh.
    /// Cheap when there's nothing stale, which is every launch but the first
    /// after an update that changed the stripper.
    func cleanStaleInBackground() {
        guard !isRunning else { return }
        runningTask = Task { await cleanStale() }
    }

    func cancel() {
        runningTask?.cancel()
    }

    func cleanStale() async {
        guard !isRunning else { return }
        do {
            let channelIds = try staleChannelIds()
            guard !channelIds.isEmpty else {
                status = .idle
                return
            }

            status = .running(completed: 0, total: channelIds.count)
            var completed = 0
            for channelId in channelIds {
                try Task.checkCancellation()
                clean(channelId: channelId)
                completed += 1
                status = .running(completed: completed, total: channelIds.count)
                if completed % saveInterval == 0 { try modelContext.save() }
                // Hand the main actor back between channels so the feed keeps
                // scrolling while a first run works through the store.
                await Task.yield()
            }

            try modelContext.save()
            lastRunAt = .now
            status = .idle
        } catch is CancellationError {
            try? modelContext.save()
            status = .idle
        } catch {
            try? modelContext.save()
            status = .failed(error.localizedDescription)
        }
    }

    /// Channels holding at least one video cleaned by an older version (or
    /// never cleaned), sorted so a run is reproducible.
    private func staleChannelIds() throws -> [String] {
        let current = Self.version
        let stale = try modelContext.fetch(FetchDescriptor<Video>(
            predicate: #Predicate { $0.titleCleanerVersion < current }
        ))
        return Set(stale.map(\.channelId)).sorted()
    }

    /// Re-cleans every video of one channel from its full title list.
    private func clean(channelId: String) {
        let videos = (try? modelContext.fetch(FetchDescriptor<Video>(
            predicate: #Predicate { $0.channelId == channelId },
            sortBy: [SortDescriptor(\.publishedAt, order: .reverse)]
        ))) ?? []
        guard !videos.isEmpty else { return }

        for (video, cleaned) in zip(videos, TitleStripper.clean(titles: videos.map(\.title))) {
            video.cleanedTitle = cleaned.title
            video.seasonNumber = cleaned.seasonNumber
            video.episodeNumber = cleaned.episodeNumber
            video.titleCleanerVersion = Self.version
        }
    }
}
