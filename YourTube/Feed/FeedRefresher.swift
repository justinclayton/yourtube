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
        case refreshing(completed: Int, total: Int)
        case failed(String)
    }

    private(set) var status: Status = .idle
    private(set) var lastRefreshedAt: Date?

    /// How many channels we hit at once. Enough to keep a refresh brisk without
    /// opening 100 simultaneous connections to Google.
    private let maxConcurrentChannelFetches = 6
    /// Recent uploads to pull per channel per refresh.
    private let uploadsPerChannel = 10

    private let modelContext: ModelContext
    private let api: YouTubeAPI
    private let thumbnailSession: URLSession

    init(
        modelContext: ModelContext,
        api: YouTubeAPI,
        thumbnailSession: URLSession = .shared
    ) {
        self.modelContext = modelContext
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
        status = .refreshing(completed: 0, total: 0)

        do {
            try await reclassifyStaleVideos()

            let subscriptions = try await syncSubscriptions()
            guard !subscriptions.isEmpty else {
                status = .idle
                lastRefreshedAt = .now
                return
            }

            status = .refreshing(completed: 0, total: subscriptions.count)
            let newVideoIds = try await collectNewVideoIds(from: subscriptions)

            if !newVideoIds.isEmpty {
                let hydrated = try await api.videos(ids: Array(newVideoIds))
                try await upsert(videos: hydrated)
            }

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
        let known = try knownVideoIds()
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
                record.title = item.snippet.title
                record.thumbnailURL = item.snippet.thumbnails?.best?.url
                record.channelDescription = item.snippet.description
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

    /// Fetches recent uploads across all channels and returns the video IDs we
    /// haven't already stored.
    ///
    /// Processed in fixed-size batches rather than one big task group so the
    /// number of simultaneous connections to Google stays bounded.
    private func collectNewVideoIds(
        from subscriptions: [ChannelFeedTarget]
    ) async throws -> Set<String> {
        let known = try knownVideoIds()
        var candidates: Set<String> = []
        var completed = 0

        for batch in subscriptions.chunked(into: maxConcurrentChannelFetches) {
            let playlistIds = batch.map(\.playlistId)
            let limit = uploadsPerChannel
            let client = api

            let results: [[String]] = try await withThrowingTaskGroup(
                of: [String].self
            ) { group in
                for playlistId in playlistIds {
                    group.addTask {
                        do {
                            let items = try await client.recentUploads(
                                playlistId: playlistId, limit: limit
                            )
                            return items.compactMap(\.videoId)
                        } catch YouTubeAPI.APIError.http(let status, _) where status == 404 {
                            // No uploads playlist, or it's private. Not worth
                            // failing the whole refresh over.
                            return []
                        }
                    }
                }
                var collected: [[String]] = []
                for try await ids in group { collected.append(ids) }
                return collected
            }

            for ids in results { candidates.formUnion(ids) }
            completed += batch.count
            status = .refreshing(completed: completed, total: subscriptions.count)
        }

        return candidates.subtracting(known)
    }

    private func knownVideoIds() throws -> Set<String> {
        Set(try modelContext.fetch(FetchDescriptor<Video>()).map(\.videoId))
    }

    private func upsert(videos: [YT.VideoItem]) async throws {
        var pending: [(video: Video, signals: VideoSignals)] = []

        for item in videos {
            guard let snippet = item.snippet else { continue }

            // Live streams and premieres have no duration yet. Skip rather than
            // storing a 0-second video that the Shorts heuristic can't judge.
            guard let durationString = item.contentDetails?.duration,
                  let duration = ISO8601Duration.seconds(from: durationString),
                  duration > 0 else { continue }

            let thumbnail = snippet.thumbnails?.best
            let signals = VideoSignals(
                durationSeconds: duration,
                title: snippet.title ?? "",
                description: snippet.description ?? "",
                thumbnailWidth: thumbnail?.width,
                thumbnailHeight: thumbnail?.height
            )

            let video = Video(
                videoId: item.id,
                channelId: snippet.channelId ?? "",
                channelTitle: snippet.channelTitle ?? "",
                title: snippet.title ?? "Untitled",
                videoDescription: snippet.description ?? "",
                publishedAt: snippet.publishedAt ?? .now,
                durationSeconds: duration,
                thumbnailURL: thumbnail?.url,
                thumbnailWidth: thumbnail?.width,
                thumbnailHeight: thumbnail?.height
            )
            modelContext.insert(video)
            pending.append((video, signals))
        }

        await classify(pending)
        try modelContext.save()
    }

    // MARK: - Shorts classification

    /// Re-runs the heuristic over videos classified by an older version of it.
    /// Cheap when there's nothing to do, which is every time but the first
    /// launch after an app update that changed the heuristic. Runs at the start
    /// of every refresh and when the feed appears, so an update takes effect
    /// without waiting for new uploads.
    func reclassifyStaleVideos() async throws {
        let current = ShortsHeuristic.version
        let stale = try modelContext.fetch(FetchDescriptor<Video>(
            predicate: #Predicate { $0.classifierVersion < current }
        ))
        guard !stale.isEmpty else { return }

        let pending = stale.map { video in
            (video, VideoSignals(
                durationSeconds: video.durationSeconds,
                title: video.title,
                description: video.videoDescription,
                thumbnailWidth: video.thumbnailWidth,
                thumbnailHeight: video.thumbnailHeight
            ))
        }
        await classify(pending)
        try modelContext.save()
    }

    /// Applies the Shorts heuristic, fetching and analysing the thumbnail for
    /// videos where it could change the answer: inside the duration gate and
    /// not already caught by a cheaper signal.
    private func classify(_ pending: [(video: Video, signals: VideoSignals)]) async {
        var needsThumbnail: [String] = []
        for (video, signals) in pending
        where ShortsHeuristic.isWithinDurationGate(signals)
            && !ShortsHeuristic.isLikelyShort(signals) {
            needsThumbnail.append(video.videoId)
        }

        let pillarboxed = await analyzeThumbnails(videoIds: needsThumbnail)

        for (video, signals) in pending {
            var signals = signals
            signals.hasPillarboxedThumbnail = pillarboxed[video.videoId] ?? nil
            video.isLikelyShort = ShortsHeuristic.isLikelyShort(signals)
            video.classifierVersion = ShortsHeuristic.version
        }
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
