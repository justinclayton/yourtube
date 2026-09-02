import Foundation
import SwiftData

/// "Everything from this channel goes in this collection."
///
/// One rule per subscribed channel is how the app categorises: videos inherit
/// their channel's collection. Rules are written either by the on-device
/// classifier (`isUserSet == false`) or by the user filing a channel by hand
/// (`isUserSet == true`, never overwritten automatically).
///
/// A rule with a nil `collection` and a `classifiedAt` date means the
/// classifier ran but wasn't confident, so the channel stays Uncategorised
/// rather than being filed somewhere wrong.
@Model
final class ChannelRule {
    @Attribute(.unique) var channelId: String
    var channelTitle: String
    var collection: VideoCollection?
    var createdAt: Date
    var isUserSet: Bool = false
    /// When the classifier last produced this rule. Nil for user-set rules.
    var classifiedAt: Date?

    init(
        channelId: String,
        channelTitle: String,
        collection: VideoCollection?,
        isUserSet: Bool = false,
        classifiedAt: Date? = nil
    ) {
        self.channelId = channelId
        self.channelTitle = channelTitle
        self.collection = collection
        self.createdAt = .now
        self.isUserSet = isUserSet
        self.classifiedAt = classifiedAt
    }
}
