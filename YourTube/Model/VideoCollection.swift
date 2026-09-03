import Foundation
import SwiftData

/// A user-facing bucket for videos ("Learn", "Cooking", ...).
///
/// `centroid` is the running mean of the embeddings of videos filed here.
/// It starts nil and is filled in once the first video lands, so collections
/// get more accurate as you use them rather than needing to be trained up front.
@Model
final class VideoCollection {
    @Attribute(.unique) var name: String
    var isUserCreated: Bool
    var createdAt: Date
    var sortOrder: Int
    /// The one built-in, hand-assigned tag ("Priority"). Exactly one collection
    /// carries this. It sits first in every list, the classifier never sees
    /// it, and it can't be renamed or deleted. Stored with a default so
    /// existing stores open without a migration.
    var isPriority: Bool = false

    /// Mean embedding vector of member videos. Nil until the first assignment.
    var centroid: [Double]?
    /// How many videos contributed to `centroid`, for incremental averaging.
    var centroidSampleCount: Int

    @Relationship(deleteRule: .nullify, inverse: \Video.collection)
    var videos: [Video] = []

    /// Channels filed here. Declared so the relationship is many-to-many:
    /// without an explicit inverse SwiftData treats `ChannelRule.collections`
    /// as one-to-many and a category can only belong to a single rule.
    @Relationship(deleteRule: .nullify, inverse: \ChannelRule.collections)
    var rules: [ChannelRule] = []

    init(
        name: String,
        isUserCreated: Bool = true,
        sortOrder: Int = 0,
        isPriority: Bool = false,
        centroid: [Double]? = nil,
        centroidSampleCount: Int = 0
    ) {
        self.name = name
        self.isUserCreated = isUserCreated
        self.createdAt = .now
        self.sortOrder = sortOrder
        self.isPriority = isPriority
        self.centroid = centroid
        self.centroidSampleCount = centroidSampleCount
    }

    /// Fold a new embedding into the running mean.
    func absorb(embedding: [Double]) {
        guard !embedding.isEmpty else { return }
        guard var current = centroid, current.count == embedding.count else {
            centroid = embedding
            centroidSampleCount = 1
            return
        }
        let n = Double(centroidSampleCount)
        for i in current.indices {
            current[i] = (current[i] * n + embedding[i]) / (n + 1)
        }
        centroid = current
        centroidSampleCount += 1
    }
}
