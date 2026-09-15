import Foundation
import SwiftData

/// Where playback stopped, and when a video counts as watched.
///
/// The player reports its current time here every few seconds and again when
/// the view is left; everything else about resume follows from the two fields
/// this writes on `Video` (`resumePositionSeconds` and `lastPlayedAt`).
///
/// Two rules give those fields their meaning:
///
/// - Under `startedThreshold` seconds is *not started*. Opening a video,
///   watching the first few seconds and backing out shouldn't fill Continue
///   Watching with things you never began, so a position that low clears the
///   stored one rather than replacing it.
/// - Past `watchedFraction` of the duration is *watched*. This replaces the
///   old "opening the player marks watched" rule, which conflicted with
///   resuming: peeking at an earmarked video used to drop it out of Up Next.
///   Watched still leaves Up Next (`UpNextQueue.markWatched`), and it leaves
///   Continue Watching because that section only lists unwatched videos.
///
/// The manual "Mark watched" button is untouched: this is the automatic path,
/// not the only one.
@MainActor
final class PlaybackProgress {
    /// Below this many seconds in, a video counts as not started.
    static let startedThreshold: Double = 30

    /// Watched once playback passes this fraction of the duration.
    static let watchedFraction: Double = 0.9

    /// How far the reported position must move since the last write before
    /// another one is worth its cost. `record` is a store change, and every
    /// store change reruns every live query in the app for as long as
    /// playback lasts (#71), so the 2 s poll in `PlayerView` only calls
    /// `record` when `shouldWrite` says so, or unconditionally on pause and
    /// on leaving the player.
    static let minimumWriteDelta: Double = 15

    /// Whether a newly polled position is worth writing to the store.
    ///
    /// Pure and `nonisolated` so the throttle can be proven correct — see
    /// `PlaybackProgressThrottleTests` — without a player, a view, or a
    /// `ModelContext`.
    ///
    /// - Parameters:
    ///   - lastWritten: The position most recently written for this video,
    ///     or nil if nothing has been written yet (always writes).
    ///   - position: The position just polled.
    ///   - forced: Pause and view-disappear write regardless of movement,
    ///     so the resume point reflects the moment playback stopped.
    nonisolated static func shouldWrite(lastWritten: Double?, position: Double, forced: Bool = false) -> Bool {
        guard !forced else { return true }
        guard let lastWritten else { return true }
        return abs(position - lastWritten) >= minimumWriteDelta
    }

    private let modelContext: ModelContext
    private let upNext: UpNextQueue

    init(modelContext: ModelContext, upNext: UpNextQueue) {
        self.modelContext = modelContext
        self.upNext = upNext
    }

    /// Where the player should start, or nil to start from the beginning.
    /// A watched video starts over: finishing it means the position is spent.
    nonisolated static func resumePosition(for video: Video) -> Double? {
        guard !video.isWatched, let position = video.resumePositionSeconds else { return nil }
        return position >= Self.startedThreshold ? position : nil
    }

    /// Record where playback has reached. Safe to call often and out of
    /// order; the last report wins.
    func record(_ video: Video, position: Double) {
        guard position.isFinite, position >= 0 else { return }
        let duration = Double(video.durationSeconds)

        if duration > 0, position >= duration * Self.watchedFraction {
            // Finished in all but name. Clear the position so a replay
            // starts at the top rather than at the 90% mark.
            video.resumePositionSeconds = nil
            video.lastPlayedAt = .now
            if !video.isWatched {
                try? upNext.markWatched(video)
            }
            try? modelContext.save()
            return
        }

        video.resumePositionSeconds = position >= Self.startedThreshold ? position : nil
        video.lastPlayedAt = .now
        try? modelContext.save()
    }

    /// Videos to offer in Continue Watching: started, not finished, most
    /// recently played first.
    func inProgress() throws -> [Video] {
        var descriptor = FetchDescriptor<Video>(
            predicate: #Predicate { $0.resumePositionSeconds != nil && !$0.isWatched },
            sortBy: [SortDescriptor(\.lastPlayedAt, order: .reverse)]
        )
        descriptor.fetchLimit = 50
        return try modelContext.fetch(descriptor)
    }
}

extension Video {
    /// How far through, 0...1, for the progress bar over the card's art.
    var playbackFraction: Double {
        guard durationSeconds > 0, let position = resumePositionSeconds else { return 0 }
        return min(max(position / Double(durationSeconds), 0), 1)
    }

    /// "42m left", the Continue Watching card's replacement for the duration.
    var formattedTimeLeft: String {
        let remaining = max(Double(durationSeconds) - (resumePositionSeconds ?? 0), 0)
        let minutes = Int(remaining.rounded(.up)) / 60
        if minutes >= 60 {
            return String(format: "%dh %02dm left", minutes / 60, minutes % 60)
        }
        return "\(max(minutes, 1))m left"
    }
}
