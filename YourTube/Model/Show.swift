import Foundation
import SwiftData

/// Where a show's episodes come from.
///
/// A show is a channel, or a playlist within a channel. Only the channel case
/// can be created today; the playlist case is modelled now so the show
/// catalogue doesn't have to change shape when playlist-backed shows arrive.
enum ShowSource: Hashable, Sendable {
    case channel(id: String)
    case playlist(id: String, channelId: String)

    /// The channel behind the show either way. A playlist-backed show still
    /// inherits its channel's categories, Priority tag, and avatar, so the
    /// channel ID is never absent.
    var channelId: String {
        switch self {
        case .channel(let id): id
        case .playlist(_, let channelId): channelId
        }
    }

    /// The show's stable identity, and what makes a channel-backed and a
    /// playlist-backed show on the same channel two different shows.
    var showId: String {
        switch self {
        case .channel(let id): "channel:\(id)"
        case .playlist(let id, _): "playlist:\(id)"
        }
    }
}

/// Which unwatched episode "Play next" means: a daily news show wants the
/// newest, a podcast backlog the oldest.
enum PlayOrder: String, Codable, CaseIterable, Sendable {
    case newestFirst
    case oldestFirst
}

/// Who decided this is a show.
enum ShowFlagOrigin: String, Codable, Sendable {
    case user
    case heuristic
}

/// The user's standing decision about a channel, which no automatic pass may
/// contradict. `forceNotShow` is why a `Show` row can exist for something
/// that isn't a show: the row is the tombstone that keeps the detector from
/// flagging it again.
enum ShowOverride: String, Codable, Sendable {
    case none
    case forceShow
    case forceNotShow
}

/// Whether a show's cards use the channel's avatar or the videos' thumbnails.
enum ShowArtPreference: String, Codable, Sendable {
    case channelArt
    case thumbnails
}

/// A series of episodes, presented as one thing in Your Shows.
///
/// Identity is `id` (`"channel:UC…"`, later `"playlist:PL…"`), which survives
/// a title change and is what the grid and the show page address. The source
/// is stored as a discriminator plus IDs rather than an encoded enum so the
/// playlist case can be added without a store migration; read it through
/// `source`.
///
/// A channel-backed show's membership isn't stored: its episodes are every
/// non-Short video from its channel, resolved live by `ShowManager`, which
/// keeps the catalogue idempotent under refresh the way `ChannelRule` does
/// for categories. A playlist-backed show has no such rule to resolve — only
/// YouTube knows what's in a playlist — so its membership is stored, in
/// `playlistItemIds`, and refreshed when the show is opened.
@Model
final class Show {
    /// A video shorter than half a typical episode is a cut-down of one. Half
    /// is low enough that a short episode is still an episode, and high enough
    /// to catch a twenty-minute extract from an hour.
    static let defaultSegmentThreshold = 0.5

    /// What the show's settings offer for `segmentThreshold`: a tenth of an
    /// episode is as permissive as the rule gets before every clip is an
    /// episode, nine tenths as strict as it gets before every episode is a
    /// clip.
    static let segmentThresholdRange = 0.1...0.9

    /// The retention windows the show's settings offer, shortest first.
    /// Presets rather than a free number: "keep the last N" is a shape of
    /// backlog, not a measurement.
    static let retentionOptions = [5, 10, 25, 50]

    @Attribute(.unique) var id: String
    /// `"channel"` or `"playlist"`; see `source`.
    var sourceKind: String
    /// The channel ID or the playlist ID, per `sourceKind`.
    var sourceId: String
    /// The channel behind the show, set for both source kinds.
    var channelId: String
    var title: String
    var flagOriginRaw: String
    var overrideRaw: String
    var playOrderRaw: String
    /// "Keep the last N episodes": older ones are hidden from the show page
    /// and the unwatched count. Nil keeps everything. Nothing is deleted,
    /// the same policy as Shorts hiding.
    var retentionCount: Int?
    /// How short a video has to be, as a fraction of this show's typical
    /// episode, before it counts as a segment cut from one. A half by
    /// default; see `ShowManager+Segments`.
    var segmentThreshold: Double = Show.defaultSegmentThreshold
    var artPreferenceRaw: String
    /// Why the detector flagged this channel, in its own words, so a guess can
    /// be read and trusted or corrected. Empty for a hand-made flag.
    var detectorReasons: [String] = []
    /// Set when a heuristic show's latest pass found the channel's gone quiet.
    /// A show going dormant is the user's call, not the detector's: the row is
    /// held rather than dropped, and this is what asks. `markAsShow` and
    /// `markAsNotAShow` both clear it, whichever way the user answers; so does
    /// the detector itself, if the channel starts posting again first.
    var pendingDormancyReview: Bool = false
    /// Season names in running order, for a show built from several
    /// playlists. Empty for a show backed by one playlist, which has nothing
    /// to pick between, and for every channel-backed show.
    var seasonNames: [String] = []
    /// The playlists behind a playlist-backed show, in running order, and in
    /// the same order as `seasonNames` when the show has seasons. Read it
    /// through `backingPlaylistIds`, which falls back to the source playlist.
    var seasonPlaylistIds: [String] = []
    /// Each backing playlist's item video IDs, in playlist order, keyed by
    /// playlist ID. This is a playlist-backed show's membership: what the
    /// last refresh saw in the playlist.
    var playlistItemIds: [String: [String]] = [:]
    /// When the membership above was last pulled from the API. Nil for a
    /// show that hasn't been opened since it was created.
    var membershipRefreshedAt: Date?
    var createdAt: Date

    init(
        source: ShowSource,
        title: String,
        flagOrigin: ShowFlagOrigin,
        override: ShowOverride = .none,
        playOrder: PlayOrder = .newestFirst,
        retentionCount: Int? = nil,
        segmentThreshold: Double = Show.defaultSegmentThreshold,
        artPreference: ShowArtPreference = .channelArt
    ) {
        self.id = source.showId
        switch source {
        case .channel(let id):
            self.sourceKind = "channel"
            self.sourceId = id
        case .playlist(let id, _):
            self.sourceKind = "playlist"
            self.sourceId = id
        }
        self.channelId = source.channelId
        self.title = title
        self.flagOriginRaw = flagOrigin.rawValue
        self.overrideRaw = override.rawValue
        self.playOrderRaw = playOrder.rawValue
        self.retentionCount = retentionCount
        self.segmentThreshold = segmentThreshold
        self.artPreferenceRaw = artPreference.rawValue
        self.createdAt = .now
    }

    var source: ShowSource {
        sourceKind == "playlist"
            ? .playlist(id: sourceId, channelId: channelId)
            : .channel(id: sourceId)
    }

    var flagOrigin: ShowFlagOrigin {
        get { ShowFlagOrigin(rawValue: flagOriginRaw) ?? .heuristic }
        set { flagOriginRaw = newValue.rawValue }
    }

    var override: ShowOverride {
        get { ShowOverride(rawValue: overrideRaw) ?? .none }
        set { overrideRaw = newValue.rawValue }
    }

    var playOrder: PlayOrder {
        get { PlayOrder(rawValue: playOrderRaw) ?? .newestFirst }
        set { playOrderRaw = newValue.rawValue }
    }

    var artPreference: ShowArtPreference {
        get { ShowArtPreference(rawValue: artPreferenceRaw) ?? .channelArt }
        set { artPreferenceRaw = newValue.rawValue }
    }

    /// Whether this row is a show in the catalogue, as opposed to the
    /// tombstone left by "Not a show".
    var isActive: Bool { override != .forceNotShow }

    // MARK: - Playlist backing

    var isPlaylistBacked: Bool { sourceKind == "playlist" }

    /// Every playlist behind the show, in running order. Empty for a
    /// channel-backed show; for a playlist-backed one it is `seasonPlaylistIds`
    /// when the show has seasons and the source playlist alone otherwise, so
    /// a show created before seasons existed still answers correctly.
    var backingPlaylistIds: [String] {
        guard isPlaylistBacked else { return [] }
        return seasonPlaylistIds.isEmpty ? [sourceId] : seasonPlaylistIds
    }

    /// The show's membership: the video IDs of every backing playlist, in
    /// running order. Order here is the playlist's, not the air date's —
    /// the page still lists episodes newest first.
    var memberVideoIds: [String] {
        backingPlaylistIds.flatMap { playlistItemIds[$0] ?? [] }
    }

    /// Whether the page offers a season picker: more than one named season to
    /// pick between.
    var hasSeasons: Bool { seasonNames.count > 1 }

    /// The video IDs of one season, addressed by its index in `seasonNames`.
    /// Empty for an index the show doesn't have.
    func videoIds(inSeason index: Int) -> [String] {
        let playlists = backingPlaylistIds
        guard playlists.indices.contains(index) else { return [] }
        return playlistItemIds[playlists[index]] ?? []
    }

    /// One line of provenance for the show page: where the episodes come
    /// from, given the name of the channel behind them.
    func sourceDescription(channelTitle: String) -> String {
        switch source {
        case .channel: "Channel"
        case .playlist: "Playlist on \(channelTitle)"
        }
    }
}
