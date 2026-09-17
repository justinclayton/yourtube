import XCTest
import SwiftData
@testable import YourTube

/// `WatchState` driven through an in-memory container, the way
/// `ShowManagerTests` drives the show catalogue. Covers the four cases the
/// issue that created this module called out as previously untested:
/// un-watching doesn't resurrect Continue Watching, swipe-watched and
/// mark-all-watched leave identical state, the 90% rule and the manual
/// button converge, and Up Next orders unplaced legacy entries consistently.
@MainActor
final class WatchStateTests: XCTestCase {
    private var container: ModelContainer!
    private var context: ModelContext { container.mainContext }
    private var watchState: WatchState!

    override func setUp() async throws {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        container = try ModelContainer(for: Video.self, configurations: config)
        watchState = WatchState(modelContext: context)
    }

    @discardableResult
    private func video(
        _ id: String,
        durationSeconds: Int = 600,
        isWatched: Bool = false,
        savedForLaterAt: Date? = nil,
        upNextOrder: Int? = nil,
        resumePositionSeconds: Double? = nil,
        lastPlayedAt: Date? = nil
    ) -> Video {
        let video = Video(
            videoId: id,
            channelId: "UC-channel",
            channelTitle: "Channel",
            title: id,
            videoDescription: "",
            publishedAt: .now,
            durationSeconds: durationSeconds,
            isWatched: isWatched,
            savedForLaterAt: savedForLaterAt,
            upNextOrder: upNextOrder,
            resumePositionSeconds: resumePositionSeconds,
            lastPlayedAt: lastPlayedAt
        )
        context.insert(video)
        return video
    }

    // MARK: - Watched clears everything, everywhere

    /// The bug this module exists to fix: swipe-watched used to keep
    /// `resumePositionSeconds`, so unwatching afterwards resurrected the
    /// video in Continue Watching at the old position.
    func testUnwatchingAFinishedVideoDoesNotResurrectContinueWatching() throws {
        let video = video("v1", resumePositionSeconds: 300, lastPlayedAt: .now)
        try watchState.markWatched(video)
        try watchState.unwatch(video)

        XCTAssertFalse(video.isWatched)
        XCTAssertNil(video.resumePositionSeconds, "watched already cleared it; unwatch has nothing to restore")
        XCTAssertTrue(try watchState.inProgress().isEmpty)
    }

    /// Swipe (single-video `markWatched`) and "Mark all watched" (the batched
    /// overload `ShowManager.markAllWatched` uses) write the same fields.
    func testSwipeWatchedAndMarkAllWatchedLeaveIdenticalState() throws {
        let swiped = video("swiped", savedForLaterAt: .now, upNextOrder: 1, resumePositionSeconds: 200)
        let batched = video("batched", savedForLaterAt: .now, upNextOrder: 2, resumePositionSeconds: 200)

        try watchState.markWatched(swiped)
        try watchState.markWatched([batched])

        for video in [swiped, batched] {
            XCTAssertTrue(video.isWatched)
            XCTAssertNil(video.savedForLaterAt)
            XCTAssertNil(video.upNextOrder)
            XCTAssertNil(video.resumePositionSeconds)
        }
    }

    /// The 90% auto-rule (`record`) and the manual button (`markWatched`)
    /// converge on the same transition rather than each clearing a different
    /// subset of fields.
    func testThe90PercentRuleAndTheManualButtonConverge() throws {
        let autoFinished = video("auto", durationSeconds: 100, savedForLaterAt: .now, upNextOrder: 1)
        let manuallyFinished = video("manual", durationSeconds: 100, savedForLaterAt: .now, upNextOrder: 2)

        watchState.record(autoFinished, position: 95) // past the 90% mark
        try watchState.markWatched(manuallyFinished)

        for video in [autoFinished, manuallyFinished] {
            XCTAssertTrue(video.isWatched)
            XCTAssertNil(video.savedForLaterAt)
            XCTAssertNil(video.upNextOrder)
            XCTAssertNil(video.resumePositionSeconds)
        }
    }

    // MARK: - Up Next ordering

    /// Entries saved before Up Next existed carry a date but no position;
    /// `migrateLegacySaves` places them after everything already ordered,
    /// oldest save first, and `entries()` reflects exactly that order —
    /// the one thing both `move`'s offsets and any `@Query` need to agree on.
    func testUpNextOrdersUnplacedLegacyEntries() throws {
        let placedFirst = video("placed-first", savedForLaterAt: .now, upNextOrder: 1)
        let olderLegacy = video("older-legacy", savedForLaterAt: Date(timeIntervalSinceNow: -200))
        let newerLegacy = video("newer-legacy", savedForLaterAt: Date(timeIntervalSinceNow: -100))

        let migrated = try watchState.migrateLegacySaves()
        XCTAssertEqual(migrated, 2)

        let order = try watchState.entries().map(\.videoId)
        XCTAssertEqual(order, [placedFirst, olderLegacy, newerLegacy].map(\.videoId),
                       "already-placed entries keep their position; legacy ones follow, oldest save first")
        XCTAssertEqual(try watchState.migrateLegacySaves(), 0, "idempotent once nothing is left unplaced")
    }

    /// `move` reorders exactly the array the caller displayed — the fix for
    /// the offset-space mismatch, where a view's own `@Query` order could
    /// diverge from a re-fetched `entries()` and scramble the wrong videos.
    func testMoveReordersTheCallersDisplayedArray() throws {
        let a = video("a", savedForLaterAt: .now, upNextOrder: 1)
        let b = video("b", savedForLaterAt: .now, upNextOrder: 2)
        let c = video("c", savedForLaterAt: .now, upNextOrder: 3)
        let displayed = [a, b, c]

        try watchState.move(displayed, fromOffsets: IndexSet(integer: 2), toOffset: 0)

        XCTAssertEqual(try watchState.entries().map(\.videoId), ["c", "a", "b"])
    }

    // MARK: - Earmarking

    func testEarmarkAppendsToTheEndAndToggleRemoves() throws {
        let first = video("first")
        let second = video("second")

        try watchState.earmark(first)
        try watchState.earmark(second)
        XCTAssertEqual(try watchState.entries().map(\.videoId), ["first", "second"])

        try watchState.toggle(first)
        XCTAssertFalse(first.isInUpNext)
        XCTAssertEqual(try watchState.entries().map(\.videoId), ["second"])
    }

    // MARK: - Resume

    func testResumePositionIgnoresAGlanceAndAWatchedVideo() {
        let glanced = video("glanced", resumePositionSeconds: 10)
        let inProgress = video("in-progress", resumePositionSeconds: 200)
        let watched = video("watched", isWatched: true, resumePositionSeconds: 200)

        XCTAssertNil(WatchState.resumePosition(for: glanced), "under the started threshold doesn't count")
        XCTAssertEqual(WatchState.resumePosition(for: inProgress), 200)
        XCTAssertNil(WatchState.resumePosition(for: watched), "a finished video always starts over")
    }
}
