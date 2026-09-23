import Foundation
import SwiftData

/// One playlist the user has chosen to make a show of.
struct PlaylistChoice: Hashable, Sendable {
    var playlistId: String
    var title: String

    init(playlistId: String, title: String) {
        self.playlistId = playlistId
        self.title = title
    }

    init(_ playlist: YT.Playlist) {
        self.init(playlistId: playlist.id, title: playlist.title)
    }
}

/// Playlist-backed shows: a podcast hosted on a network channel is its own
/// show, and a series-based show browses by season.
///
/// The difference from a channel-backed show is membership and nothing else.
/// A channel's episodes are a rule ("every video from this channel") that
/// `ShowManager` resolves against the store on every read; a
/// playlist's are a list only YouTube knows, so it's stored on the record and
/// refreshed from the API when the show is opened (`FeedRefresher`
/// `refreshPlaylistShow`). Everything downstream — the grid, the page, Play
/// next, cadence, retention — reads a `ShowListing` and never learns which
/// kind it's looking at.
///
/// Categories and Priority are not stored here either: a `Show` carries the
/// channel behind it whatever its source, and the chips read the channel's
/// `ChannelRule`. A playlist-backed show is therefore filed the moment its
/// channel is, and filing it twice is impossible.
extension ShowManager {

    /// Creates a show from one or more of a channel's playlists, or updates
    /// the one already made from the same first playlist.
    ///
    /// Several playlists make one show with seasons, in the order given:
    /// that's how a series-based show (a playlist per series) becomes one
    /// thing in Your Shows with a picker on its page. A single playlist has
    /// nothing to pick between, so it gets no seasons at all.
    ///
    /// The show is flagged the way a hand-flagged channel is — the user asked
    /// for it, so no automatic pass may take it away.
    @discardableResult
    func addPlaylistShow(
        _ playlists: [PlaylistChoice],
        channelId: String,
        title: String? = nil
    ) throws -> Show {
        guard let first = playlists.first else {
            throw PlaylistShowError.noPlaylistChosen
        }
        let source = ShowSource.playlist(id: first.playlistId, channelId: channelId)
        let show = try upsertPlaylistShow(
            source: source,
            title: (title?.trimmingCharacters(in: .whitespaces)).flatMap { $0.isEmpty ? nil : $0 }
                ?? first.title
        )
        show.seasonPlaylistIds = playlists.map(\.playlistId)
        show.seasonNames = playlists.count > 1 ? playlists.map(\.title) : []
        // Anything the previous membership held for a playlist that's no
        // longer part of the show is dead weight; drop it so `memberVideoIds`
        // can't outlive a season the user removed.
        let kept = Set(show.seasonPlaylistIds)
        show.playlistItemIds = show.playlistItemIds.filter { kept.contains($0.key) }
        try modelContext.save()
        return show
    }

    /// The playlist-backed shows already made from a channel, so the picker
    /// can show which of its playlists are spoken for.
    func playlistShows(forChannelId channelId: String) throws -> [Show] {
        try allRecords().filter { $0.isPlaylistBacked && $0.channelId == channelId && $0.isActive }
    }

    /// Records what one backing playlist holds, in playlist order. Called by
    /// the refresher once per playlist; the show's membership is the
    /// concatenation, in season order.
    func setPlaylistItems(_ videoIds: [String], playlistId: String, of show: Show) throws {
        show.playlistItemIds[playlistId] = videoIds
        show.membershipRefreshedAt = .now
        try modelContext.save()
    }

    /// Removes a playlist-backed show outright. Unlike a channel, a playlist
    /// has no standing "not a show" decision to record — the user simply
    /// never has to see it again — so there's no tombstone.
    func removePlaylistShow(_ show: Show) throws {
        guard show.isPlaylistBacked else { return }
        modelContext.delete(show)
        try modelContext.save()
    }

    // MARK: - Seasons

    /// Narrowing a list to one season is `ShowListing`'s: the season is
    /// applied before classification, so a season's listing is about that
    /// season alone.
    ///
    /// Which season an episode belongs to, by index, or nil when the show has
    /// no seasons or the episode is in none of them.
    nonisolated static func seasonIndex(of video: Video, in show: Show) -> Int? {
        guard show.hasSeasons else { return nil }
        return show.backingPlaylistIds.indices.first {
            show.videoIds(inSeason: $0).contains(video.videoId)
        }
    }

    // MARK: - Errors

    enum PlaylistShowError: LocalizedError {
        case noPlaylistChosen

        var errorDescription: String? {
            switch self {
            case .noPlaylistChosen: "Pick at least one playlist to make a show of."
            }
        }
    }

    private func upsertPlaylistShow(source: ShowSource, title: String) throws -> Show {
        if let existing = try record(id: source.showId) {
            existing.title = title
            existing.flagOrigin = .user
            existing.override = .forceShow
            return existing
        }
        let show = Show(
            source: source,
            title: title,
            flagOrigin: .user,
            override: .forceShow
        )
        modelContext.insert(show)
        return show
    }
}
