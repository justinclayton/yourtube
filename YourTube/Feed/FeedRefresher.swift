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

    init(modelContext: ModelContext, api: YouTubeAPI) {
        self.modelContext = modelContext
        self.api = api
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
                try upsert(videos: hydrated)
            }

            lastRefreshedAt = .now
            status = .idle
        } catch {
            status = .failed(error.localizedDescription)
        }
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
            } else {
                let record = Subscription(
                    channelId: channelId,
                    title: item.snippet.title,
                    thumbnailURL: item.snippet.thumbnails?.best?.url
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

    private func upsert(videos: [YT.VideoItem]) throws {
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
                thumbnailHeight: thumbnail?.height,
                isLikelyShort: ShortsHeuristic.isLikelyShort(signals)
            )
            modelContext.insert(video)
        }
        try modelContext.save()
    }
}

/// One channel to poll during a refresh.
private struct ChannelFeedTarget: Sendable {
    let channelId: String
    let playlistId: String
}
