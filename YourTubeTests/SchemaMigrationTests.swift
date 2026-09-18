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
            for: Video.self, Subscription.self, VideoCollection.self, ChannelRule.self, Show.self,
            migrationPlan: VideoMigrationPlan.self,
            configurations: ModelConfiguration(url: storeURL)
        )

        let videos = try migrated.mainContext.fetch(FetchDescriptor<Video>())
        XCTAssertEqual(videos.map(\.videoId), ["real-video"], "the flagged row is gone, the real one survived")
    }

    /// A brand-new store (no file on disk yet) has nothing to migrate from,
    /// so it just opens on the current schema.
    func testAFreshStoreOpensWithoutMigrating() throws {
        let container = try ModelContainer(
            for: Video.self, Subscription.self, VideoCollection.self, ChannelRule.self, Show.self,
            migrationPlan: VideoMigrationPlan.self,
            configurations: ModelConfiguration(url: storeURL)
        )

        XCTAssertEqual(try container.mainContext.fetchCount(FetchDescriptor<Video>()), 0)
    }
}
