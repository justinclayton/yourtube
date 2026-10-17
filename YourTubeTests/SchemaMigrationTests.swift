import XCTest
import SwiftData
@testable import YourTube

/// A pre-#132 store still has `isLikelyShort` rows on disk. `VideoMigrationPlan`
/// has to delete those before the column disappears, and it has to do so on a
/// real (file-backed) store — an in-memory container never touches migration
/// at all, which is why none of the other suites exercise this path.
@MainActor
final class SchemaMigrationTests: XCTestCase {
    private var storeURL: URL!

    override func setUp() {
        storeURL = FileManager.default.temporaryDirectory
            .appending(path: "SchemaMigrationTests-\(UUID().uuidString).sqlite")
    }

    override func tearDown() {
        for suffix in ["", "-wal", "-shm"] {
            try? FileManager.default.removeItem(
                at: URL(fileURLWithPath: storeURL.path + suffix)
            )
        }
    }

    /// Builds a pre-#132 store at `storeURL` directly from `SchemaV1`, the way
    /// a store that predates this issue's migration plan looks on disk.
    private func makeV1Store() throws {
        let container = try ModelContainer(
            for: SchemaV1.Video.self, SchemaV1.Subscription.self,
            SchemaV1.VideoCollection.self, SchemaV1.ChannelRule.self, SchemaV1.Show.self,
            configurations: ModelConfiguration(schema: Schema(versionedSchema: SchemaV1.self), url: storeURL)
        )
        let context = container.mainContext
        context.insert(SchemaV1.Video(
            videoId: "flagged-short", channelId: "UCaaa", channelTitle: "Some Channel",
            title: "A Short", videoDescription: "", publishedAt: .now,
            durationSeconds: 40, isLikelyShort: true
        ))
        context.insert(SchemaV1.Video(
            videoId: "real-video", channelId: "UCaaa", channelTitle: "Some Channel",
            title: "A real upload", videoDescription: "", publishedAt: .now,
            durationSeconds: 1_200, isLikelyShort: false
        ))
        try context.save()
    }

    func testMigrationDeletesRowsFlaggedAsShortsAndKeepsTheRest() throws {
        try makeV1Store()

        let migrated = try ModelContainer(
            for: Video.self, Subscription.self, VideoCollection.self, ChannelRule.self, Show.self, ShowSuggestion.self,
            migrationPlan: VideoMigrationPlan.self,
            configurations: ModelConfiguration(url: storeURL)
        )

        let videos = try migrated.mainContext.fetch(FetchDescriptor<Video>())
        XCTAssertEqual(videos.map(\.videoId), ["real-video"], "the flagged row is gone, the real one survived")
    }

    /// A store from between #132 and #145: `Show` still has its dormancy
    /// flag and there is no `ShowSuggestion` table. Both changes are
    /// lightweight; the shows themselves have to come through untouched,
    /// since turning the detector's into suggestions is the detector's job.
    func testAV2StoreKeepsItsShowsAndGainsSuggestions() throws {
        let old = try ModelContainer(
            for: SchemaV2.Video.self, SchemaV2.Subscription.self,
            SchemaV2.VideoCollection.self, SchemaV2.ChannelRule.self, SchemaV2.Show.self,
            configurations: ModelConfiguration(schema: Schema(versionedSchema: SchemaV2.self), url: storeURL)
        )
        let show = SchemaV2.Show(
            id: "channel:UCaaa", sourceKind: "channel", sourceId: "UCaaa", channelId: "UCaaa",
            title: "A Show", flagOriginRaw: "heuristic", overrideRaw: "none",
            playOrderRaw: "newestFirst", artPreferenceRaw: "channelArt"
        )
        show.detectorReasons = ["Numbered episodes"]
        show.pendingDormancyReview = true
        old.mainContext.insert(show)
        try old.mainContext.save()

        let migrated = try ModelContainer(
            for: Video.self, Subscription.self, VideoCollection.self, ChannelRule.self, Show.self, ShowSuggestion.self,
            migrationPlan: VideoMigrationPlan.self,
            configurations: ModelConfiguration(url: storeURL)
        )

        let shows = try migrated.mainContext.fetch(FetchDescriptor<Show>())
        XCTAssertEqual(shows.map(\.id), ["channel:UCaaa"])
        XCTAssertEqual(shows.first?.flagOrigin, .heuristic)
        XCTAssertEqual(shows.first?.detectorReasons, ["Numbered episodes"])
        migrated.mainContext.insert(ShowSuggestion(channelId: "UCbbb", title: "B", reasons: []))
        try migrated.mainContext.save()
        XCTAssertEqual(try migrated.mainContext.fetchCount(FetchDescriptor<ShowSuggestion>()), 1)
    }

    /// A brand-new store (no file on disk yet) has nothing to migrate from,
    /// so it just opens on the current schema.
    func testAFreshStoreOpensWithoutMigrating() throws {
        let container = try ModelContainer(
            for: Video.self, Subscription.self, VideoCollection.self, ChannelRule.self, Show.self, ShowSuggestion.self,
            migrationPlan: VideoMigrationPlan.self,
            configurations: ModelConfiguration(url: storeURL)
        )

        XCTAssertEqual(try container.mainContext.fetchCount(FetchDescriptor<Video>()), 0)
    }
}
