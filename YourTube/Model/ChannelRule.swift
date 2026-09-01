import Foundation
import SwiftData

/// "Everything from this channel goes in this collection."
///
/// The cheapest and most reliable classification signal — most people rewatch
/// the same handful of channels, so a rule handles the majority of videos
/// without any embedding work.
@Model
final class ChannelRule {
    @Attribute(.unique) var channelId: String
    var channelTitle: String
    var collection: VideoCollection?
    var createdAt: Date

    init(channelId: String, channelTitle: String, collection: VideoCollection?) {
        self.channelId = channelId
        self.channelTitle = channelTitle
        self.collection = collection
        self.createdAt = .now
    }
}
