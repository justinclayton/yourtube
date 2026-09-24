import XCTest
import SwiftData
@testable import YourTube

/// The pass that joins `ShowDetector` to the catalogue: which channels it
/// looks at, and which it is never allowed to touch.
///
/// The channels below are the same synthetic shapes as `ShowDetectorTests`,
/// cut down to what the store needs to reproduce a verdict.
@MainActor
final class ShowDetectionRunnerTests: XCTestCase {
    private var container: ModelContainer!
    private var context: ModelContext { container.mainContext }
    private var shows: ShowManager!
    private var runner: ShowDetectionRunner!
    private var defaults: UserDefaults!

    override func setUp() async throws {
        container = try ModelContainer(
            for: Video.self, Subscription.self, VideoCollection.self, ChannelRule.self, Show.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        shows = ShowManager(modelContext: context, watchState: WatchState(modelContext: context))
        defaults = UserDefaults(suiteName: "ShowDetectionRunnerTests-\(UUID().uuidString)")
        runner = ShowDetectionRunner(modelContext: context, defaults: defaults)
    }

    /// A twice-weekly hour-long news show: the shape the detector is meant to
    /// find without help.
    @discardableResult
    private func seedShowShapedChannel(
        id: String,
        title: String,
        episodes: Int = 8,
        seconds: Int = 3_900
    ) -> Subscription {
        let subscription = Subscription(channelId: id, title: title)
        context.insert(subscription)
        for index in 0..<episodes {
            // Tuesdays and Fridays: alternating three- and four-day gaps.
            let daysAgo = Double(index / 2) * 7 + (index.isMultiple(of: 2) ? 0 : 3)
            context.insert(Video(
                videoId: "\(id)-\(index)",
                channelId: id,
                channelTitle: title,
                title: "\(title): the week in one hour",
                videoDescription: "An episode of \(title).",
                publishedAt: Date(timeIntervalSinceNow: -daysAgo * 86_400),
                durationSeconds: seconds,
                youtubeCategoryId: "25"
            ))
        }
        // The pass reads its own context, so seeding has to be saved before it
        // runs — as a real refresh's does.
        try? context.save()
        return subscription
    }

    /// A clips channel: short, constant, no episodes.
    private func seedClipsChannel(id: String, title: String) {
        context.insert(Subscription(channelId: id, title: title))
        for index in 0..<20 {
            context.insert(Video(
                videoId: "\(id)-\(index)",
                channelId: id,
                channelTitle: title,
                title: "Best bits \(index)",
                videoDescription: "Clips.",
                publishedAt: Date(timeIntervalSinceNow: -Double(index) * 20_000),
                durationSeconds: 300,
                youtubeCategoryId: "24"
            ))
        }
        try? context.save()
    }

    func testAPassFlagsAShowShapedChannelWithItsReasonsAndLeavesTheRestAlone() async throws {
        seedShowShapedChannel(id: "UC-bellwether", title: "The Bellwether")
        seedClipsChannel(id: "UC-clips", title: "Clips Archive")

        let changed = try await runner.detect()

        XCTAssertEqual(changed, 1)
        XCTAssertEqual(try shows.shows().map(\.channelId), ["UC-bellwether"])
        let record = try XCTUnwrap(shows.record(forChannelId: "UC-bellwether"))
        XCTAssertEqual(record.flagOrigin, .heuristic)
        XCTAssertFalse(record.detectorReasons.isEmpty, "a guess has to say why")
        XCTAssertNil(try shows.record(forChannelId: "UC-clips"))
    }

    func testAChannelTheUserCalledNotAShowIsNeverFlagged() async throws {
        seedShowShapedChannel(id: "UC-offtherecord", title: "Off the Record")
        try shows.markAsNotAShow(channelId: "UC-offtherecord", channelTitle: "Off the Record")

        try await runner.detect()

        XCTAssertFalse(try shows.isShow(channelId: "UC-offtherecord"))
        XCTAssertTrue(try shows.shows().isEmpty)
        XCTAssertEqual(try shows.record(forChannelId: "UC-offtherecord")?.override, .forceNotShow)
    }

    /// The other direction: a channel the detector would reject outright,
    /// flagged by hand, stays flagged.
    func testAUserFlaggedShowIsNeverUnflagged() async throws {
        seedClipsChannel(id: "UC-clips", title: "Clips Archive")
        try shows.markAsShow(channelId: "UC-clips", channelTitle: "Clips Archive")

        try await runner.detect()

        XCTAssertTrue(try shows.isShow(channelId: "UC-clips"))
        XCTAssertEqual(try shows.record(forChannelId: "UC-clips")?.flagOrigin, .user)
    }

    /// A playlist-backed show's `forceShow` is the user's opinion about that
    /// playlist, not about the channel that hosts it — the channel itself
    /// still needs a verdict.
    func testAChannelWithOnlyAPlaylistShowStillGetsAVerdict() async throws {
        seedShowShapedChannel(id: "UC-bellwether", title: "The Bellwether")
        try shows.addPlaylistShow(
            [PlaylistChoice(playlistId: "PL-bellwether", title: "Season 1")],
            channelId: "UC-bellwether"
        )

        try await runner.detect()

        let channelRecord = try XCTUnwrap(shows.record(forChannelId: "UC-bellwether"))
        XCTAssertEqual(channelRecord.flagOrigin, .heuristic, "the detector reached the channel")
        XCTAssertTrue(try shows.isShow(channelId: "UC-bellwether"))
        // The playlist show is untouched.
        XCTAssertEqual(try shows.playlistShows(forChannelId: "UC-bellwether").count, 1)
    }

    /// The pass runs on its own context: its rows reach the store, and the
    /// main context — the one every live `@Query` watches — is left untouched.
    func testVerdictsAreSavedToTheStoreAndNotPendingOnTheMainContext() async throws {
        seedShowShapedChannel(id: "UC-bellwether", title: "The Bellwether")

        try await runner.detect()

        XCTAssertFalse(context.hasChanges)
        let fresh = ModelContext(container)
        XCTAssertEqual(try fresh.fetch(FetchDescriptor<Show>()).map(\.channelId), ["UC-bellwether"])
    }

    // MARK: - Examining a channel once

    /// A rejected channel's fingerprint really does skip it. A flagged show is
    /// the deliberate exception — see the dormancy test below — so it's the
    /// one re-examined here even though nothing about it moved.
    func testASecondPassOverAnUnchangedStoreExaminesOnlyTheFlaggedShow() async throws {
        seedShowShapedChannel(id: "UC-bellwether", title: "The Bellwether")
        seedClipsChannel(id: "UC-clips", title: "Clips Archive")

        try await runner.detect()
        XCTAssertEqual(runner.lastExamined, 2)

        try await runner.detect()
        XCTAssertEqual(runner.lastExamined, 1, "the flagged show is re-checked; the rejected channel is skipped")
        XCTAssertEqual(runner.lastChanged, 0, "its verdict didn't move, so nothing counts as changed")
        XCTAssertEqual(try shows.shows().count, 1, "and the catalogue is left as it was")
    }

    func testANewUploadPutsItsChannelBackInFrontOfTheDetector() async throws {
        seedClipsChannel(id: "UC-clips", title: "Clips Archive")
        seedClipsChannel(id: "UC-clips2", title: "Clips Archive Two")
        try await runner.detect()

        context.insert(Video(
            videoId: "UC-clips-new",
            channelId: "UC-clips",
            channelTitle: "Clips Archive",
            title: "Clips Archive: Ep. 1 — the full sit-down",
            videoDescription: "An episode.",
            publishedAt: .now,
            durationSeconds: 3_600,
            youtubeCategoryId: "24"
        ))
        try context.save()

        try await runner.detect()
        XCTAssertEqual(runner.lastExamined, 1, "only the channel whose uploads moved")
    }

    /// The fingerprint can't see a channel going quiet — its video count and
    /// newest date don't change just because time passes. That's what the
    /// unconditional re-check of flagged shows is for.
    func testAFlaggedShowGoingDormantIsHeldForReviewOnTheNextPass() async throws {
        seedShowShapedChannel(id: "UC-bellwether", title: "The Bellwether")
        try await runner.detect()
        XCTAssertTrue(try shows.isShow(channelId: "UC-bellwether"))

        let videos = try context.fetch(FetchDescriptor<Video>())
        let daysSinceOldestStillFresh = Double(ShowDetector.maximumDormantDays + 30)
        for (offset, video) in videos.enumerated() {
            video.publishedAt = Date(timeIntervalSinceNow: -(daysSinceOldestStillFresh + Double(offset)) * 86_400)
        }
        try context.save()

        try await runner.detect()

        // Still in the catalogue — going quiet is the user's call, not the
        // detector's, so it's held for review rather than dropped.
        XCTAssertTrue(try shows.isShow(channelId: "UC-bellwether"))
        let record = try XCTUnwrap(shows.record(forChannelId: "UC-bellwether"))
        XCTAssertTrue(record.pendingDormancyReview)
        XCTAssertTrue(record.detectorReasons.contains { $0.hasPrefix("Hasn't posted in") }, "\(record.detectorReasons)")
    }

    /// Changing the heuristic has to reach channels already examined under the
    /// old one.
    func testBumpingTheDetectorVersionReExaminesEverything() async throws {
        seedShowShapedChannel(id: "UC-bellwether", title: "The Bellwether")
        try await runner.detect()
        XCTAssertEqual(runner.lastExamined, 1)

        defaults.set(ShowDetector.version - 1, forKey: ShowDetectionRunner.versionKey)
        try await runner.detect()
        XCTAssertEqual(runner.lastExamined, 1)
    }
}
