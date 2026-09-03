import Foundation
import SwiftData

/// "Everything from this channel goes in these collections."
///
/// One rule per subscribed channel is how the app categorises: videos inherit
/// their channel's categories. A channel can carry several at once — a
/// comedian's podcast is both Comedy and Podcasts & Interviews — and shows up
/// under every feed chip it carries. Rules are written either by the on-device
/// classifier (`isUserSet == false`) or by the user filing a channel by hand
/// (`isUserSet == true`, never overwritten automatically).
///
/// A rule with empty `collections` and a `classifiedAt` date means the
/// classifier ran but produced nothing usable, so the channel stays
/// Uncategorised rather than being filed somewhere wrong.
@Model
final class ChannelRule {
    @Attribute(.unique) var channelId: String
    var channelTitle: String
    /// The categories this channel is filed under. Unordered; the inverse
    /// lives on `VideoCollection.rules`.
    var collections: [VideoCollection] = []
    /// Pre-multi-tag storage: the single category a channel was filed under.
    /// Kept only so existing stores open without a schema migration;
    /// `CategoryManager.migrateLegacyRules()` folds it into `collections`
    /// on launch and clears it. New code never writes it.
    var collection: VideoCollection?
    var createdAt: Date
    var isUserSet: Bool = false
    /// When the classifier last produced this rule. Nil for user-set rules.
    var classifiedAt: Date?

    init(
        channelId: String,
        channelTitle: String,
        collections: [VideoCollection],
        isUserSet: Bool = false,
        classifiedAt: Date? = nil
    ) {
        self.channelId = channelId
        self.channelTitle = channelTitle
        self.collections = collections
        self.createdAt = .now
        self.isUserSet = isUserSet
        self.classifiedAt = classifiedAt
    }

    /// Whether the channel is filed under `collection`.
    func contains(_ collection: VideoCollection) -> Bool {
        collections.contains { $0 === collection }
    }

    /// Category names, in the list's display order.
    var sortedCollections: [VideoCollection] {
        collections.sorted {
            ($0.sortOrder, $0.name) < ($1.sortOrder, $1.name)
        }
    }
}
