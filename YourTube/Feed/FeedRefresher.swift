import Foundation
import SwiftData
import Observation

/// Pulls new uploads from every subscribed channel and reconciles them into
/// the local store.
///
/// Why the fan-out: `activities.list` (the obvious "give me my subscription
/// feed" endpoint) has been functionally broken since around 2020 and Google
/// never fixed it, and `search.list` costs 100 quota units per call. Walking
/// each channel's uploads playlist costs 1 unit per channel, which is what
/// makes a full refresh affordable — roughly 102 units for 100 channels.
@Observable
@MainActor
final class FeedRefresher {
    enum Status: Equatable {
        case idle
        case refreshing(Phase)
        case failed(String)

        /// Where in a refresh we are, for `RefreshButton` to show. A refresh
        /// used to look done the moment the channel fan-out finished, while
        /// hydration, Shorts classification and the save still ran behind an
        /// unmoving ring; each phase now gets its own label, and, where a
        /// total is knowable, its own count.
        enum Phase: Equatable {
            case checkingChannels(completed: Int, total: Int)
            case fetchingVideos(completed: Int, total: Int)
            case sortingShorts

            var label: String {
                switch self {
                case .checkingChannels(_, let total):
                    "Checking \(total) channel\(total == 1 ? "" : "s")"
                case .fetchingVideos(_, let total):
                    "Fetching \(total) new video\(total == 1 ? "" : "s")"
                case .sortingShorts:
                    "Sorting Shorts"
                }
            }

            /// `nil` when there's no meaningful total to draw a determinate
            /// ring for.
            var progress: (completed: Int, total: Int)? {
                switch self {
                case .checkingChannels(let completed, let total): (completed, total)
                case .fetchingVideos(let completed, let total): (completed, total)
                case .sortingShorts: nil
                }
            }
        }
    }

    private(set) var status: Status = .idle
    private(set) var lastRefreshedAt: Date?

    /// How many channels we hit at once. Enough to keep a refresh brisk without
    /// opening 100 simultaneous connections to Google.
    private let maxConcurrentChannelFetches = 6
    /// Recent uploads to pull per channel per refresh.
    private let uploadsPerChannel = 10

    private let modelContext: ModelContext
    /// Rows go in through here rather than the main context, so a refresh
    /// storing a few hundred videos doesn't make every live query in the app
    /// re-fetch a few hundred times. See `StoreWriter`.
    private let writer: StoreWriter
    /// Internal so `FeedRefresher+PlaylistShows` can reach the same client.
    let api: YouTubeAPI
    private let thumbnailSession: URLSession

    init(
        modelContext: ModelContext,
        api: YouTubeAPI,
        thumbnailSession: URLSession = .shared,
        writer: StoreWriter? = nil
    ) {
        self.modelContext = modelContext
        self.writer = writer ?? StoreWriter(modelContainer: modelContext.container)
        self.api = api
        self.thumbnailSession = thumbnailSession
    }

    var isRefreshing: Bool {
        if case .refreshing = status { return true }
        return false
    }

    // MARK: - Refresh

    func refresh() async {
        guard !isRefreshing else { return }
        status = .refreshing(.checkingChannels(completed: 0, total: 0))

        do {
            try await reclassifyStaleVideos()

            let subscriptions = try await syncSubscriptions()
            guard !subscriptions.isEmpty else {
                status = .idle
                lastRefreshedAt = .now
                return
            }

            let known = try await knownVideoIds()
            try await fetchAndStoreNewVideos(from: subscriptions, known: known)

            lastRefreshedAt = .now
            status = .idle
        } catch {
            status = .failed(error.localizedDescription)
        }
    }

    /// Pulls a deeper slice of one channel's uploads playlist than a normal
    /// refresh does, for browsing a channel's back catalogue. Returns how many
    /// videos were newly stored; zero means we've already got everything the
    /// playlist offers within the page limit.
    ///
    /// Costs 1 unit for the playlist page plus 1 per 50 videos hydrated.
    func loadOlderUploads(channelId: String, pageSize: Int = 50) async throws -> Int {
        let playlistId = Subscription.uploadsPlaylistId(forChannelId: channelId)
        let known = try await knownVideoIds()
        let items = try await api.recentUploads(playlistId: playlistId, limit: pageSize)
        let newIds = items.compactMap(\.videoId).filter { !known.contains($0) }
        guard !newIds.isEmpty else { return 0 }

        let hydrated = try await api.videos(ids: newIds)
        try await upsert(videos: hydrated)
        return hydrated.count
    }

    // MARK: - Steps

    /// Mirrors the remote subscription list into the local store, adding new
    /// channels and dropping ones the user has since unsubscribed from.
    private func syncSubscriptions() async throws -> [ChannelFeedTarget] {
        let remote = try await api.subscriptions()

        var seen: Set<String> = []
        var result: [ChannelFeedTarget] = []

        let existing = try modelContext.fetch(FetchDescriptor<Subscription>())
        var byId = Dictionary(
            existing.map { ($0.channelId, $0) },
            uniquingKeysWith: { first, _ in first }
        )

        for item in remote {
            guard let channelId = item.snippet.resourceId.channelId else { continue }
            seen.insert(channelId)

            if let record = byId[channelId] {
                // Assign only when the value actually changed: SwiftData
                // dirties (and therefore saves and re-notifies every live
                // query for) a row on assignment alone, even when the new
                // value equals the old one. An unchanged subscription list
                // would otherwise touch all 629 rows every refresh.
                let title = item.snippet.title
                if record.title != title { record.title = title }
                let thumbnailURL = item.snippet.thumbnails?.best?.url
                if record.thumbnailURL != thumbnailURL { record.thumbnailURL = thumbnailURL }
                let channelDescription = item.snippet.description
                if record.channelDescription != channelDescription {
                    record.channelDescription = channelDescription
                }
            } else {
                let record = Subscription(
                    channelId: channelId,
                    title: item.snippet.title,
                    thumbnailURL: item.snippet.thumbnails?.best?.url,
                    channelDescription: item.snippet.description
                )
                modelContext.insert(record)
                byId[channelId] = record
            }
            result.append(ChannelFeedTarget(
                channelId: channelId,
                playlistId: Subscription.uploadsPlaylistId(forChannelId: channelId)
            ))
        }

        // Unsubscribed channels: drop the subscription but keep their videos,
        // since they may already be filed into collections or watch-later.
        for (channelId, record) in byId where !seen.contains(channelId) {
            modelContext.delete(record)
        }

        try modelContext.save()
        return result
    }

    /// Fetches recent uploads across all channels and stores whatever's new as
    /// each channel's results land, rather than waiting for the whole
    /// fan-out to finish.
    ///
    /// A task group refilled one channel at a time as each fetch completes,
    /// rather than fixed-size lockstep batches: the slowest channel in a
    /// batch of six used to hold up the other five's slots doing nothing, and
    /// 629 channels made 105 such waits. This keeps six requests in flight
    /// throughout with no idle gaps, and the same six-request ceiling on
    /// simultaneous connections to Google.
    ///
    /// Storing per channel rather than once for the whole refresh — still
    /// classify-before-insert (see `upsert`), just at channel granularity
    /// instead of whole-refresh granularity — is what lets new videos reach
    /// the feed while later channels are still being checked, instead of a
    /// first fill of hundreds of videos showing nothing for minutes.
    private func fetchAndStoreNewVideos(
        from subscriptions: [ChannelFeedTarget], known: Set<String>
    ) async throws {
        var known = known
        var checked = 0
        let total = subscriptions.count
        let limit = uploadsPerChannel
        let client = api

        status = .refreshing(.checkingChannels(completed: checked, total: total))

        try await withThrowingTaskGroup(of: [String].self) { group in
            var remaining = subscriptions.makeIterator()

            func fillSlot() {
                guard let target = remaining.next() else { return }
                group.addTask {
                    do {
                        let items = try await client.recentUploads(
                            playlistId: target.playlistId, limit: limit
                        )
                        return items.compactMap(\.videoId)
                    } catch YouTubeAPI.APIError.http(let status, _) where status == 404 {
                        // No uploads playlist, or it's private. Not worth
                        // failing the whole refresh over.
                        return []
                    }
                }
            }

            for _ in 0..<maxConcurrentChannelFetches { fillSlot() }

            while let ids = try await group.next() {
                checked += 1
                status = .refreshing(.checkingChannels(completed: checked, total: total))

                let newIds = Set(ids).subtracting(known)
                if !newIds.isEmpty {
                    status = .refreshing(.fetchingVideos(completed: 0, total: newIds.count))
                    let hydrated = try await api.videos(ids: Array(newIds))

                    status = .refreshing(.sortingShorts)
                    try await upsert(videos: hydrated)

                    known.formUnion(newIds)
                    status = .refreshing(.checkingChannels(completed: checked, total: total))
                }

                fillSlot()
            }
        }
    }

    /// Every video ID already stored. Internal so a playlist-backed show's
    /// refresh can ask the same question before hydrating anything.
    func knownVideoIds() async throws -> Set<String> {
        try await writer.knownVideoIds()
    }

    /// Stores hydrated videos, Shorts verdict first. Internal because it is
    /// the one way videos enter the store: `FeedRefresher+PlaylistShows`
    /// brings a playlist's items in through it rather than inserting its own.
    ///
    /// Classify before inserting. The feed's `@Query` watches the store, and
    /// classification suspends on thumbnail downloads, so a video inserted
    /// first would show up in the feed with the default `isLikelyShort =
    /// false` and then vanish once its verdict landed. Holding the insert
    /// until the verdict is known means a Short is hidden from its first
    /// appearance. That the rows are written on another context doesn't change
    /// it: what's deferred is the insert, not the save.
    func upsert(videos: [YT.VideoItem]) async throws {
        var drafts = videos.compactMap(VideoDraft.init(item:))
        guard !drafts.isEmpty else { return }

        let verdicts = await shortsVerdicts(for: drafts.map { ($0.videoId, $0.signals) })
        for index in drafts.indices {
            drafts[index].isLikelyShort = verdicts[drafts[index].videoId] ?? false
        }
        try await writer.insert(drafts, classifierVersion: ShortsHeuristic.version)
    }

    // MARK: - Shorts classification

    /// Re-runs the heuristic over videos classified by an older version of it.
    /// Cheap when there's nothing to do, which is every time but the first
    /// launch after an app update that changed the heuristic. Runs at the start
    /// of every refresh and when the feed appears, so an update takes effect
    /// without waiting for new uploads.
    func reclassifyStaleVideos() async throws {
        let current = ShortsHeuristic.version
        let stale = try await writer.staleShortsSignals(version: current)
        guard !stale.isEmpty else { return }

        let verdicts = await shortsVerdicts(for: stale.map { ($0.key, $0.value) })
        try await writer.applyShortsVerdicts(verdicts, version: current)
    }

    /// Applies the Shorts heuristic to signals, fetching and analysing the
    /// thumbnail for videos where it could change the answer: inside the
    /// duration gate and not already caught by a cheaper signal.
    ///
    /// Works on plain signals rather than on rows because the rows belong to
    /// the writer's context, and the thumbnail session belongs here.
    private func shortsVerdicts(
        for pending: [(videoId: String, signals: VideoSignals)]
    ) async -> [String: Bool] {
        var needsThumbnail: [String] = []
        for (videoId, signals) in pending
        where ShortsHeuristic.isWithinDurationGate(signals)
            && !ShortsHeuristic.isLikelyShort(signals) {
            needsThumbnail.append(videoId)
        }

        let pillarboxed = await analyzeThumbnails(videoIds: needsThumbnail)

        var verdicts: [String: Bool] = [:]
        for (videoId, signals) in pending {
            var signals = signals
            signals.hasPillarboxedThumbnail = pillarboxed[videoId] ?? nil
            verdicts[videoId] = ShortsHeuristic.isLikelyShort(signals)
        }
        return verdicts
    }

    /// Downloads `hqdefault.jpg` for each ID and runs `ThumbnailAnalyzer`.
    /// Failures (offline, 404, undecodable) map to nil: no evidence, and the
    /// video is left un-flagged rather than the refresh failing.
    private func analyzeThumbnails(videoIds: [String]) async -> [String: Bool?] {
        var results: [String: Bool?] = [:]
        let session = thumbnailSession

        for batch in videoIds.chunked(into: maxConcurrentChannelFetches) {
            await withTaskGroup(of: (String, Bool?).self) { group in
                for id in batch {
                    group.addTask {
                        let url = ThumbnailAnalyzer.thumbnailURL(forVideoId: id)
                        guard let (data, response) = try? await session.data(from: url),
                              (response as? HTTPURLResponse)?.statusCode == 200
                        else { return (id, nil) }
                        // The video's own thumbnail is often this same
                        // hqdefault URL (the API's "high" quality); seeding
                        // it here means the feed row shows it without a
                        // second download. See `ImageCache`.
                        ImageCache.shared.seed(data: data, for: url)
                        return (id, ThumbnailAnalyzer.looksPillarboxed(imageData: data))
                    }
                }
                for await (id, verdict) in group { results[id] = verdict }
            }
        }
        return results
    }
}

/// One channel to poll during a refresh.
private struct ChannelFeedTarget: Sendable {
    let channelId: String
    let playlistId: String
}
