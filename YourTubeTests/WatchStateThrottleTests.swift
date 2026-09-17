import XCTest
@testable import YourTube

/// Proves the store-write throttle described in #71: the player polls every
/// two seconds, but `WatchState.shouldWrite` should only let a fraction
/// of those polls actually reach `record` (a store change that reruns every
/// live query in the app for as long as playback lasts).
final class WatchStateThrottleTests: XCTestCase {
    /// Simulates `PlayerView.reportProgress`'s bookkeeping: feed it every
    /// polled position in order and count how many would have been written.
    private func simulateWrites(positions: [Double]) -> Int {
        var lastWritten: Double?
        var writes = 0
        for position in positions {
            if WatchState.shouldWrite(lastWritten: lastWritten, position: position) {
                lastWritten = position
                writes += 1
            }
        }
        return writes
    }

    /// The issue's "done when": an uninterrupted minute of playback, polled
    /// every 2 s (30 polls), produces no more than four saves.
    func testUninterruptedMinuteProducesAtMostFourSaves() {
        let positions = stride(from: 2.0, through: 60.0, by: 2.0).map { $0 }
        XCTAssertLessThanOrEqual(simulateWrites(positions: positions), 4)
    }

    func testFirstReportAlwaysWrites() {
        XCTAssertTrue(WatchState.shouldWrite(lastWritten: nil, position: 0.5))
    }

    func testSmallMovementIsSkipped() {
        XCTAssertFalse(WatchState.shouldWrite(lastWritten: 100, position: 114))
    }

    func testMovementAtTheThresholdWrites() {
        XCTAssertTrue(WatchState.shouldWrite(lastWritten: 100, position: 115))
    }

    func testMovementBackwardsPastTheThresholdAlsoWrites() {
        // A seek backwards should still bank the new position once it moves
        // far enough, not just forward progress.
        XCTAssertTrue(WatchState.shouldWrite(lastWritten: 100, position: 84))
    }

    func testForcedAlwaysWritesRegardlessOfMovement() {
        XCTAssertTrue(WatchState.shouldWrite(lastWritten: 100, position: 100.1, forced: true))
    }

    /// The 90%-watched rule must still fire even though most polls are
    /// throttled: once the throttle does let a write through past the
    /// watched fraction, `record` still clears the resume position and marks
    /// the video watched (covered separately for `record` itself; here we
    /// only need the throttle to not wedge that write shut permanently).
    func testThrottleEventuallyAdmitsAWriteNearTheEndOfPlayback() {
        // A 20s video polled every 2s: 90% is 18s. The throttle's first
        // write is immediate, so the next admitted write lands at or after
        // 15s of movement -- well before playback runs out.
        let positions = stride(from: 2.0, through: 20.0, by: 2.0).map { $0 }
        var lastWritten: Double?
        var wroteAtOrPastWatched = false
        for position in positions {
            if WatchState.shouldWrite(lastWritten: lastWritten, position: position) {
                lastWritten = position
                if position >= 18 { wroteAtOrPastWatched = true }
            }
        }
        XCTAssertTrue(wroteAtOrPastWatched)
    }
}
