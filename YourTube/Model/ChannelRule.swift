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
/// The built-in Priority tag rides alongside the topic categories in
/// `collections`: it's set only by hand, and the classifier preserves it
/// while rewriting the topics. "Uncategorised" means no *topic* category, so
/// a priority-only channel still shows up there for filing.
///
/// A rule with no topic categories and a `classifiedAt` date means the
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

    /// The model's answer, verbatim, before `CategoryPrompt.resolve` matched
    /// it against the taxonomy — what the classifier was told to say. Nil
    /// means no automatic pass has recorded evidence for this rule yet:
    /// either it's never been classified under this version, or it's a rule
    /// filed by hand from the start. Never set for a user-set rule. Optional
    /// with no default so existing stores open without a migration.
    var classifierRawAnswer: [String]?
    /// The classifier's resolved category names at the time it last ran, as
    /// a snapshot independent of `collections` — which the user may have
    /// edited since. Nil alongside `classifierRawAnswer`.
    var classifierResolvedCategories: [String]?
    /// Which of `classifierResolvedCategories` the model itself chose — the
    /// one category it was allowed to give. Nil when the model gave nothing
    /// usable, and for rules classified before v4, which recorded the answer
    /// without saying where each half came from. Optional with no default so
    /// existing stores open without a migration.
    var classifierModelCategory: String?
    /// The category YouTube's own per-video filing contributed, present only
    /// when it differed from `classifierModelCategory`. Keeping the two apart
    /// is what lets a wrong chip be blamed on the model or on YouTube rather
    /// than on "the classifier". See `CategoryDecision`.
    var classifierYouTubeCategory: String?
    /// Why `classifierYouTubeCategory` is there, in `YouTubeCategorySignal`'s
    /// own words ("YouTube files most of its videos under Gaming").
    var classifierYouTubeReason: String?
    /// The channel's dominant YouTube video category (`Video.youtubeCategoryId`)
    /// as of the last automatic pass, e.g. `"24"` for Entertainment. Look up
    /// the display name with `YouTubeCategory.name(forId:)`. Nil alongside
    /// `classifierRawAnswer`.
    var classifierDominantCategoryId: String?
    /// The `videoId`s of the recent uploads the classifier read from at the
    /// last automatic pass — the same window `recentVideoTitles` draws from.
    /// The routine pass compares this against the channel's current window
    /// to decide whether uploads have turned over enough to be worth asking
    /// about again; see `CategoryManager.hasTurnedOver`. Nil means no
    /// automatic pass has recorded a fingerprint yet, which the routine pass
    /// treats as due for one. Never set for a user-set rule. Optional with no
    /// default so existing stores open without a migration.
    var classifierRecentVideoIds: [String]?
    /// The classifier version that produced this rule's current answer.
    /// Compared against `CategoryManager.classifierVersion` the way
    /// `Video.titleCleanerVersion` tracks title cleaning: a rule below the
    /// current version is due for the version-bump pass (`Scope.staleVersion`),
    /// paged across launches rather than re-run all at once. Defaults to 0, so
    /// every rule written before this field existed is due once, the same
    /// one-time cost the old whole-store bump paid. Never set for a user-set
    /// rule.
    var classifiedVersion: Int = 0

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

    /// Whether the channel carries the built-in Priority tag.
    var isPriority: Bool {
        collections.contains { $0.isPriority }
    }

    /// The categories the classifier is responsible for: everything except
    /// Priority. Empty means Uncategorised.
    var topicCollections: [VideoCollection] {
        collections.filter { !$0.isPriority }
    }

    /// Category names, in the list's display order.
    var sortedCollections: [VideoCollection] {
        collections.sorted {
            ($0.sortOrder, $0.name) < ($1.sortOrder, $1.name)
        }
    }
}
