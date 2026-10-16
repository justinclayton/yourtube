import XCTest
import SwiftData
@testable import YourTube

/// The pass that joins `ShowDetector` to the suggestions: which channels it
/// looks at, which it is never allowed to touch, and that it never adds a
/// show itself.
///
/// The channels below are the same synthetic shapes as `ShowDetectorTests`,
/// cut down to what the store needs to reproduce a verdict.
@MainActor
final class ShowDetectionRunnerTests: XCTestCase {
    private var container: ModelContainer!
    private var context: ModelContext { container.mainContext }
    private var shows: ShowManager!
    private var suggestions: ShowSuggestions!
    private var runner: ShowDetectionRunner!
    private var defaults: UserDefaults!

    override func setUp() async throws {
        container = try ModelContainer(
            for: Video.self, Subscription.self, VideoCollection.self, ChannelRule.self, Show.self, ShowSuggestion.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        shows = ShowManager(modelContext: context, watchState: WatchState(modelContext: context))
        suggestions = ShowSuggestions(modelContext: context)
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

    func testAPassSuggestsAShowShapedChannelWithItsReasonsAndAddsNoShow() async throws {
        seedShowShapedChannel(id: "UC-bellwether", title: "The Bellwether")
        seedClipsChannel(id: "UC-clips", title: "Clips Archive")

        let changed = try await runner.detect()

        XCTAssertEqual(changed, 1)
        let pending = try suggestions.pending()
        XCTAssertEqual(pending.map(\.channelId), ["UC-bellwether"])
        XCTAssertFalse(pending[0].reasons.isEmpty, "a suggestion has to say why")
        XCTAssertTrue(try shows.allRecords().isEmpty, "the detector never adds a show")
    }

    func testAChannelTheUserCalledNotAShowIsNeverSuggested() async throws {
        seedShowShapedChannel(id: "UC-offtherecord", title: "Off the Record")
        try shows.markAsNotAShow(channelId: "UC-offtherecord", channelTitle: "Off the Record")

        try await runner.detect()

        XCTAssertTrue(try suggestions.pending().isEmpty)
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

        XCTAssertEqual(try suggestions.pending().map(\.channelId), ["UC-bellwether"], "the detector reached the channel")
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
        XCTAssertEqual(try fresh.fetch(FetchDescriptor<ShowSuggestion>()).map(\.channelId), ["UC-bellwether"])
    }

    // MARK: - Examining a channel once

    /// A rejected channel's fingerprint really does skip it. A pending
    /// suggestion is the deliberate exception — see the dormancy test below —
    /// so it's the one re-examined here even though nothing about it moved.
    func testASecondPassOverAnUnchangedStoreExaminesOnlyTheSuggestedChannel() async throws {
        seedShowShapedChannel(id: "UC-bellwether", title: "The Bellwether")
        seedClipsChannel(id: "UC-clips", title: "Clips Archive")

        try await runner.detect()
        XCTAssertEqual(runner.lastExamined, 2)

        try await runner.detect()
        XCTAssertEqual(runner.lastExamined, 1, "the suggestion is re-checked; the rejected channel is skipped")
        XCTAssertEqual(runner.lastChanged, 0, "its verdict didn't move, so nothing counts as changed")
        XCTAssertEqual(try suggestions.pendingCount(), 1, "and the suggestion is left as it was")
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
    /// unconditional re-check of pending suggestions is for.
    func testASuggestionGoingDormantIsWithdrawnOnTheNextPass() async throws {
        seedShowShapedChannel(id: "UC-bellwether", title: "The Bellwether")
        try await runner.detect()
        XCTAssertEqual(try suggestions.pendingCount(), 1)

        let videos = try context.fetch(FetchDescriptor<Video>())
        let daysSinceOldestStillFresh = Double(ShowDetector.maximumDormantDays + 30)
        for (offset, video) in videos.enumerated() {
            video.publishedAt = Date(timeIntervalSinceNow: -(daysSinceOldestStillFresh + Double(offset)) * 86_400)
        }
        try context.save()

        try await runner.detect()

        XCTAssertTrue(try suggestions.pending().isEmpty, "withdrawn without asking")
        XCTAssertTrue(try shows.allRecords().isEmpty)
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

    // MARK: - The upgrade

    /// The first pass under the new rules hands the old grid back: the
    /// detector's own shows become suggestions, and every channel is looked
    /// at again.
    func testTheFirstPassConvertsTheDetectorsShowsAndForgetsTheFingerprints() async throws {
        seedShowShapedChannel(id: "UC-bellwether", title: "The Bellwether")
        seedClipsChannel(id: "UC-clips", title: "Clips Archive")
        // What the old detector left behind for the Bellwether.
        let guess = Show(source: .channel(id: "UC-bellwether"), title: "The Bellwether", flagOrigin: .heuristic)
        guess.detectorReasons = ["Numbered episodes"]
        context.insert(guess)
        try shows.markAsShow(channelId: "UC-mine", channelTitle: "Mine")
        // A store the old detector had already been over.
        defaults.set(["UC-bellwether": "stale", "UC-clips": "stale"], forKey: ShowDetectionRunner.fingerprintsKey)
        defaults.set(ShowDetector.version, forKey: ShowDetectionRunner.versionKey)

        try await runner.detect()

        XCTAssertEqual(runner.lastExamined, 2, "every channel is re-examined once")
        XCTAssertEqual(try suggestions.pending().map(\.channelId), ["UC-bellwether"])
        XCTAssertNil(try shows.record(forChannelId: "UC-bellwether"), "the guessed show is now only a suggestion")
        XCTAssertEqual(try shows.shows().map(\.channelId), ["UC-mine"])
    }

    func testASuggestionForAChannelYouUnsubscribedFromIsWithdrawn() async throws {
        let subscription = seedShowShapedChannel(id: "UC-bellwether", title: "The Bellwether")
        try await runner.detect()
        XCTAssertEqual(try suggestions.pendingCount(), 1)

        context.delete(subscription)
        try context.save()
        try await runner.detect()

        XCTAssertEqual(try suggestions.pendingCount(), 0)
    }

    /// Once per store: a later pass converts nothing.
    func testTheConversionRunsOnce() async throws {
        try await runner.detect()
        context.insert(Show(source: .channel(id: "UC-old"), title: "Old Guess", flagOrigin: .heuristic))
        try context.save()

        try await runner.detect()

        XCTAssertNotNil(try shows.record(forChannelId: "UC-old"))
        XCTAssertEqual(
            defaults.integer(forKey: ShowDetectionRunner.suggestionsMigrationKey),
            ShowDetectionRunner.suggestionsMigrationVersion
        )
    }
}
