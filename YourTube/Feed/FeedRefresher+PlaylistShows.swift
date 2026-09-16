import Foundation
import SwiftData

/// Refreshing a playlist-backed show: what the playlist holds now, and the
/// videos in it the store hasn't seen.
///
/// This is the one thing a playlist-backed show needs that a channel-backed
/// one doesn't. A channel's episodes arrive with the routine refresh, which
/// already walks every subscription's uploads; a playlist's membership is a
/// list only YouTube knows, so it has to be asked for. It is asked for on
/// demand — when the show is created and when its page is opened — never
/// during the routine refresh, so the daily quota the feed spends is exactly
/// what it was before playlist shows existed.
///
/// New videos come in through `upsert(videos:)`, the same door the feed uses,
/// so a playlist item gets its Shorts verdict before it is stored and appears
/// in the feed the moment it lands, like any other video.
extension FeedRefresher {

    /// What one refresh of a playlist-backed show cost and found.
    struct PlaylistShowRefresh: Equatable {
        /// Videos stored that the app had never seen.
        var newVideos: Int
        /// Quota units spent: one per playlist page, plus one per 50 videos
        /// hydrated.
        var quotaUnits: Int
    }

    /// Pulls every backing playlist's items, records them as the show's
    /// membership, and hydrates any video the store doesn't have yet.
    ///
    /// Costs 1 unit per playlist page (a page is 50 items) plus 1 per 50 new
    /// videos. A one-playlist show of 40 episodes therefore costs 1 unit on
    /// every refresh after the first.
    @discardableResult
    func refreshMembership(
        of show: Show,
        using shows: ShowManager
    ) async throws -> PlaylistShowRefresh {
        guard show.isPlaylistBacked else {
            return PlaylistShowRefresh(newVideos: 0, quotaUnits: 0)
        }

        var units = 0
        var seen: [String] = []
        for playlistId in show.backingPlaylistIds {
            let items = try await api.playlistItems(playlistId: playlistId)
            // One request per 50 items, and always at least one.
            units += max(1, Int(ceil(Double(items.count) / 50)))
            let videoIds = items.compactMap(\.videoId)
            try shows.setPlaylistItems(videoIds, playlistId: playlistId, of: show)
            seen.append(contentsOf: videoIds)
        }

        let known = try await knownVideoIds()
        // A playlist can list the same video twice, and two seasons of a show
        // can overlap; hydrating either twice would be a wasted unit.
        var unknown: [String] = []
        var added: Set<String> = []
        for id in seen where !known.contains(id) && added.insert(id).inserted {
            unknown.append(id)
        }
        guard !unknown.isEmpty else {
            return PlaylistShowRefresh(newVideos: 0, quotaUnits: units)
        }

        let hydrated = try await api.videos(ids: unknown)
        units += Int(ceil(Double(unknown.count) / 50))
        try await upsert(videos: hydrated)
        return PlaylistShowRefresh(newVideos: hydrated.count, quotaUnits: units)
    }
}
