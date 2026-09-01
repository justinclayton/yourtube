import Foundation
import SwiftData

/// A YouTube channel the user is subscribed to.
@Model
final class Subscription {
    @Attribute(.unique) var channelId: String
    var title: String
    var thumbnailURL: String?
    /// Last time we successfully pulled this channel's uploads.
    var lastFetchedAt: Date?

    init(channelId: String, title: String, thumbnailURL: String? = nil) {
        self.channelId = channelId
        self.title = title
        self.thumbnailURL = thumbnailURL
    }

    /// YouTube's uploads playlist for a channel is the channel ID with the
    /// second character rewritten from `C` to `U`. This is stable and saves us
    /// a `channels.list` round trip per channel.
    var uploadsPlaylistId: String {
        Self.uploadsPlaylistId(forChannelId: channelId)
    }

    static func uploadsPlaylistId(forChannelId id: String) -> String {
        guard id.count > 2, id.hasPrefix("UC") else { return id }
        return "UU" + id.dropFirst(2)
    }
}
