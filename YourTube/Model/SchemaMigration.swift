import Foundation
import SwiftData

/// The store's schema before issue #132: the feed still fetched every upload
/// and hid Shorts with a heuristic, so `Video` carried its verdict, the
/// version it was judged under, and the thumbnail dimensions the verdict read.
///
/// Every model here is its own copy, even the four that didn't change.
/// Reusing the live `Subscription`/`VideoCollection`/`ChannelRule`/`Show`
/// types in two different `VersionedSchema.models` lists makes SwiftData
/// treat this schema and `SchemaV2` as the same schema — the migration plan
/// then crashes opening the store with "the current model reference and the
/// next model reference cannot be equal" instead of running the migration.
enum SchemaV1: VersionedSchema {
    static var versionIdentifier = Schema.Version(1, 0, 0)

    static var models: [any PersistentModel.Type] {
        [Video.self, Subscription.self, VideoCollection.self, ChannelRule.self, Show.self]
    }

    @Model
    final class Video {
        @Attribute(.unique) var videoId: String
        var channelId: String
        var channelTitle: String
        var title: String
        var videoDescription: String
        var publishedAt: Date
        var durationSeconds: Int
        var thumbnailURL: String?
        var thumbnailWidth: Int?
        var thumbnailHeight: Int?
        var youtubeCategoryId: String?

        var isLikelyShort: Bool
        var isWatched: Bool
        var savedForLaterAt: Date?
        var upNextOrder: Int?
        var resumePositionSeconds: Double?
        var lastPlayedAt: Date?

        var collection: SchemaV1.VideoCollection?
        var classifierVersion: Int

        var cleanedTitle: String?
        var strippedTitle: String?
        var isTitleRewritten: Bool = false
        var seasonNumber: Int?
        var episodeNumber: Int?
        var titleCleanerVersion: Int = 0

        init(
            videoId: String,
            channelId: String,
            channelTitle: String,
            title: String,
            videoDescription: String,
            publishedAt: Date,
            durationSeconds: Int,
            thumbnailURL: String? = nil,
            thumbnailWidth: Int? = nil,
            thumbnailHeight: Int? = nil,
            youtubeCategoryId: String? = nil,
            isLikelyShort: Bool = false,
            isWatched: Bool = false,
            savedForLaterAt: Date? = nil,
            upNextOrder: Int? = nil,
            resumePositionSeconds: Double? = nil,
            lastPlayedAt: Date? = nil,
            classifierVersion: Int = 0,
            cleanedTitle: String? = nil,
            strippedTitle: String? = nil,
            isTitleRewritten: Bool = false,
            seasonNumber: Int? = nil,
            episodeNumber: Int? = nil,
            titleCleanerVersion: Int = 0
        ) {
            self.videoId = videoId
            self.channelId = channelId
            self.channelTitle = channelTitle
            self.title = title
            self.videoDescription = videoDescription
            self.publishedAt = publishedAt
            self.durationSeconds = durationSeconds
            self.thumbnailURL = thumbnailURL
            self.thumbnailWidth = thumbnailWidth
            self.thumbnailHeight = thumbnailHeight
            self.youtubeCategoryId = youtubeCategoryId
            self.isLikelyShort = isLikelyShort
            self.isWatched = isWatched
            self.savedForLaterAt = savedForLaterAt
            self.upNextOrder = upNextOrder
            self.resumePositionSeconds = resumePositionSeconds
            self.lastPlayedAt = lastPlayedAt
            self.classifierVersion = classifierVersion
            self.cleanedTitle = cleanedTitle
            self.strippedTitle = strippedTitle
            self.isTitleRewritten = isTitleRewritten
            self.seasonNumber = seasonNumber
            self.episodeNumber = episodeNumber
            self.titleCleanerVersion = titleCleanerVersion
        }
    }

    /// Unchanged since before this issue; duplicated here only because
    /// `VersionedSchema` requires every schema version to own every model.
    @Model
    final class Subscription {
        @Attribute(.unique) var channelId: String
        var title: String
        var thumbnailURL: String?
        var channelDescription: String?
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
    }

    /// Unchanged since before this issue; duplicated here only because
    /// `VersionedSchema` requires every schema version to own every model.
    @Model
    final class VideoCollection {
        @Attribute(.unique) var name: String
        var isUserCreated: Bool
        var createdAt: Date
        var sortOrder: Int
        var isPriority: Bool = false
        var centroid: [Double]?
        var centroidSampleCount: Int

        @Relationship(deleteRule: .nullify, inverse: \SchemaV1.Video.collection)
        var videos: [SchemaV1.Video] = []

        @Relationship(deleteRule: .nullify, inverse: \SchemaV1.ChannelRule.collections)
        var rules: [SchemaV1.ChannelRule] = []

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
    }

    /// Unchanged since before this issue; duplicated here only because
    /// `VersionedSchema` requires every schema version to own every model.
    @Model
    final class ChannelRule {
        @Attribute(.unique) var channelId: String
        var channelTitle: String
        var collections: [SchemaV1.VideoCollection] = []
        var collection: SchemaV1.VideoCollection?
        var createdAt: Date
        var isUserSet: Bool = false
        var classifiedAt: Date?
        var classifierRawAnswer: [String]?
        var classifierResolvedCategories: [String]?
        var classifierModelCategory: String?
        var classifierYouTubeCategory: String?
        var classifierYouTubeReason: String?
        var classifierDominantCategoryId: String?
        var classifierRecentVideoIds: [String]?
        var classifiedVersion: Int = 0

        init(
            channelId: String,
            channelTitle: String,
            collections: [SchemaV1.VideoCollection],
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
    }

    /// Unchanged since before this issue; duplicated here only because
    /// `VersionedSchema` requires every schema version to own every model.
    @Model
    final class Show {
        @Attribute(.unique) var id: String
        var sourceKind: String
        var sourceId: String
        var channelId: String
        var title: String
        var flagOriginRaw: String
        var overrideRaw: String
        var playOrderRaw: String
        var retentionCount: Int?
        var segmentThreshold: Double = 0.5
        var hideSegments: Bool = true
        var artPreferenceRaw: String
        var detectorReasons: [String] = []
        var pendingDormancyReview: Bool = false
        var seasonNames: [String] = []
        var seasonPlaylistIds: [String] = []
        var playlistItemIds: [String: [String]] = [:]
        var membershipRefreshedAt: Date?
        var createdAt: Date

        init(
            id: String,
            sourceKind: String,
            sourceId: String,
            channelId: String,
            title: String,
            flagOriginRaw: String,
            overrideRaw: String,
            playOrderRaw: String,
            artPreferenceRaw: String
        ) {
            self.id = id
            self.sourceKind = sourceKind
            self.sourceId = sourceId
            self.channelId = channelId
            self.title = title
            self.flagOriginRaw = flagOriginRaw
            self.overrideRaw = overrideRaw
            self.playOrderRaw = playOrderRaw
            self.artPreferenceRaw = artPreferenceRaw
            self.createdAt = .now
        }
    }
}

/// The current schema: `Video` without the Shorts heuristic's fields, since
/// the feed now fetches the `UULF` (long-form-only) playlist and never stores
/// a Short to begin with (issue #132). The other four models are unchanged,
/// so this schema just points at the app's live types.
enum SchemaV2: VersionedSchema {
    static var versionIdentifier = Schema.Version(2, 0, 0)

    static var models: [any PersistentModel.Type] {
        [Video.self, Subscription.self, VideoCollection.self, ChannelRule.self, Show.self]
    }
}

/// Moves a pre-#132 store onto the current schema, deleting whatever the old
/// heuristic had already flagged as a Short before the column that flagged it
/// disappears. A few false positives get re-admitted on the next refresh (the
/// heuristic over-hid some long-form videos) and a few unflagged Shorts linger
/// until they age out — both acceptable, since a real fix requires `UULF` to
/// have run at least once, which happens right after this migration.
enum VideoMigrationPlan: SchemaMigrationPlan {
    static var schemas: [any VersionedSchema.Type] { [SchemaV1.self, SchemaV2.self] }

    static var stages: [MigrationStage] { [migrateV1toV2] }

    static let migrateV1toV2 = MigrationStage.custom(
        fromVersion: SchemaV1.self,
        toVersion: SchemaV2.self,
        willMigrate: { context in
            let flagged = try context.fetch(FetchDescriptor<SchemaV1.Video>(
                predicate: #Predicate { $0.isLikelyShort }
            ))
            for video in flagged { context.delete(video) }
            try context.save()
        },
        didMigrate: nil
    )
}
