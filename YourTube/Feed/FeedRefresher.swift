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
///
/// What it keeps is the finding: the subscription list, the fan-out across
/// channels, the phase the refresh is in, and the quota that costs. What
/// happens to a video once it has been found — mapping, the Shorts verdict,
/// the insert — belongs to `VideoIntake`, which is also what the fixtures and
/// a playlist-backed show's membership refresh go through.
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
    /// The one door videos enter the store by. This class finds out *which*
    /// videos there are to store; what happens to them after that is not its
    /// business. Internal so `FeedRefresher+PlaylistShows` uses the same door.
    let intake: VideoIntake
    /// Internal so `FeedRefresher+PlaylistShows` can reach the same client.
    let api: YouTubeAPI

    init(
        modelContext: ModelContext,
        api: YouTubeAPI,
        writer: StoreWriter? = nil,
        intake: VideoIntake? = nil
    ) {
        self.modelContext = modelContext
        self.api = api
        // Rows go in through the writer's context rather than the main one,
        // so a refresh storing a few hundred videos doesn't make every live
        // query in the app re-fetch a few hundred times. See `StoreWriter`.
        self.intake = intake ?? VideoIntake(
            writer: writer ?? StoreWriter(modelContainer: modelContext.container),
            thumbnails: DownloadedThumbnailVerdict()
        )
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
            try await intake.reclassifyStale()

            let subscriptions = try await syncSubscriptions()
            guard !subscriptions.isEmpty else {
                status = .idle
                lastRefreshedAt = .now
                return
            }

            let known = try await intake.knownVideoIds()
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
        let known = try await intake.knownVideoIds()
        let items = try await api.recentUploads(playlistId: playlistId, limit: pageSize)
        let newIds = items.compactMap(\.videoId).filter { !known.contains($0) }
        guard !newIds.isEmpty else { return 0 }

        let hydrated = try await api.videos(ids: newIds)
        return try await intake.admit(hydrated)
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
    /// classify-before-insert (see `VideoIntake`), just at channel granularity
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
                    try await intake.admit(hydrated)

                    known.formUnion(newIds)
                    status = .refreshing(.checkingChannels(completed: checked, total: total))
                }

                fillSlot()
            }
        }
    }
}

/// One channel to poll during a refresh.
private struct ChannelFeedTarget: Sendable {
    let channelId: String
    let playlistId: String
}
