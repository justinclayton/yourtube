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
/// Membership isn't stored: a channel-backed show's episodes are every
/// non-Short video from its channel, resolved live by `ShowManager`, which
/// keeps the catalogue idempotent under refresh the way `ChannelRule` does
/// for categories.
@Model
final class Show {
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
    var segmentThreshold: Double = 0.5
    var artPreferenceRaw: String
    /// Season names in running order, for playlist-backed shows. Empty until
    /// playlist sources land.
    var seasonNames: [String] = []
    var createdAt: Date

    init(
        source: ShowSource,
        title: String,
        flagOrigin: ShowFlagOrigin,
        override: ShowOverride = .none,
        playOrder: PlayOrder = .newestFirst,
        retentionCount: Int? = nil,
        segmentThreshold: Double = 0.5,
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

    /// One line of provenance for the show page: where the episodes come
    /// from, given the name of the channel behind them.
    func sourceDescription(channelTitle: String) -> String {
        switch source {
        case .channel: "Channel"
        case .playlist: "Playlist on \(channelTitle)"
        }
    }
}
