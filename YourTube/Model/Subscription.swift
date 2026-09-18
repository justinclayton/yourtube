import Foundation
import SwiftData

/// A YouTube channel the user is subscribed to.
@Model
final class Subscription {
    @Attribute(.unique) var channelId: String
    var title: String
    var thumbnailURL: String?
    /// The channel's "about" text, fed to the category classifier.
    var channelDescription: String?
    /// Last time we successfully pulled this channel's uploads.
    var lastFetchedAt: Date?

    init(
        channelId: String,
        title: String,
        thumbnailURL: String? = nil,
        channelDescription: String? = nil
    ) {
        self.channelId = channelId
        self.title = title
        self.thumbnailURL = thumbnailURL
        self.channelDescription = channelDescription
    }

    /// YouTube's long-form-uploads playlist for a channel: the channel ID
    /// with its `UC` prefix rewritten to `UULF`. This is the channel's Videos
    /// tab — no Shorts, no live streams — undocumented but stable, and it
    /// saves us a `channels.list` round trip per channel.
    var uploadsPlaylistId: String {
        Self.uploadsPlaylistId(forChannelId: channelId)
    }

    static func uploadsPlaylistId(forChannelId id: String) -> String {
        guard id.count > 2, id.hasPrefix("UC") else { return id }
        return "UULF" + id.dropFirst(2)
    }
}
