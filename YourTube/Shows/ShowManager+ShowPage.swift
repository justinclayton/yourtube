import Foundation
import SwiftData

/// What the show page asks the catalogue for: which episode "Play next"
/// means, clearing a backlog in one go, and the two computed facts in the
/// header — the weekdays a show posts on and how long its episodes usually
/// run.
///
/// Cadence and typical duration are computed on every read and never stored,
/// so a show that changes its habits stops lying about them as soon as the
/// new episodes land. Both read the same `episodes(of:)` the page lists,
/// which is what makes the retention window and segment hiding apply to them
/// for free — the typical length of a news hour is the length of the hour,
/// not of the clips cut from it.
extension ShowManager {

    // MARK: - Play next

    /// The episode "Play next" opens, or nil when the show is caught up.
    ///
    /// An episode you're partway through always wins: whatever the play order
    /// says, the thing you actually want is the one you walked away from.
    /// Otherwise the play order decides, which `episodes(of:)` has already
    /// applied — newest first for a daily news show, oldest first for a
    /// backlog watched forwards.
    func nextUp(of show: Show) throws -> Video? {
        Self.nextUp(in: try episodes(of: show))
    }

    /// `nextUp(of:)` over episodes the caller already has, in play order.
    nonisolated static func nextUp(in episodesInPlayOrder: [Video]) -> Video? {
        let pending = episodesInPlayOrder.filter { !$0.isWatched }
        let resumable = pending.filter { PlaybackProgress.resumePosition(for: $0) != nil }
        if !resumable.isEmpty {
            // More than one half-watched episode is rare; when it happens the
            // one you touched last is the one you meant, the same rule that
            // orders Continue Watching.
            return resumable.max { ($0.lastPlayedAt ?? .distantPast) < ($1.lastPlayedAt ?? .distantPast) }
        }
        return pending.first
    }

    /// Whether "Play next" should read "Resume": this episode has a stored
    /// position to pick up from.
    nonisolated static func isResumable(_ video: Video) -> Bool {
        PlaybackProgress.resumePosition(for: video) != nil
    }

    // MARK: - Clearing a backlog

    /// Marks every listed episode watched, which is what "Mark all watched"
    /// means: the show's badge goes, its episodes leave Continue Watching and
    /// Up Next, and the ones hidden as segments or aged out by the retention
    /// window are left alone — clearing a backlog shouldn't reach behind the
    /// page you're looking at.
    ///
    /// The per-video effect is `UpNextQueue.markWatched`'s: a finished episode
    /// has no business waiting in a list of things to watch. Returns how many
    /// episodes changed.
    @discardableResult
    func markAllWatched(of show: Show) throws -> Int {
        let pending = try episodes(of: show).filter { !$0.isWatched }
        for video in pending {
            video.isWatched = true
            video.resumePositionSeconds = nil
            video.savedForLaterAt = nil
            video.upNextOrder = nil
        }
        if !pending.isEmpty { try modelContext.save() }
        return pending.count
    }

    // MARK: - Cadence and typical duration

    /// The weekdays a show has posted on at least twice (`Calendar`
    /// numbering, 1 = Sunday), in week order.
    ///
    /// Twice is the bar because one Sunday upload is an accident and two is a
    /// habit; it's also what keeps a show that moved night from claiming both
    /// forever once the old episodes age out of the retention window.
    func cadenceWeekdays(of show: Show, calendar: Calendar = .current) throws -> [Int] {
        Self.cadenceWeekdays(of: try episodes(of: show), calendar: calendar)
    }

    nonisolated static func cadenceWeekdays(of episodes: [Video], calendar: Calendar = .current) -> [Int] {
        let counts = episodes.reduce(into: [Int: Int]()) { counts, video in
            counts[calendar.component(.weekday, from: video.publishedAt), default: 0] += 1
        }
        return counts.filter { $0.value >= 2 }.keys
            .sorted { weekOffset($0, calendar: calendar) < weekOffset($1, calendar: calendar) }
    }

    /// How long an episode usually runs, in seconds, or nil when the show has
    /// no episodes yet.
    ///
    /// The median rather than the mean: one three-hour special shouldn't move
    /// the number the show is described by.
    func typicalDuration(of show: Show) throws -> TimeInterval? {
        Self.typicalDuration(of: try episodes(of: show))
    }

    nonisolated static func typicalDuration(of episodes: [Video]) -> TimeInterval? {
        let durations = episodes.map(\.durationSeconds).filter { $0 > 0 }.sorted()
        guard !durations.isEmpty else { return nil }
        return TimeInterval(durations[durations.count / 2])
    }

    /// The header's one line of habit: "Posts Tue, Fri · about 1 hr 15 min".
    /// Nil when the show has told us nothing yet, so a brand new show gets no
    /// line rather than an empty one.
    func cadenceDescription(of show: Show, calendar: Calendar = .current) throws -> String? {
        Self.cadenceDescription(of: try episodes(of: show), calendar: calendar)
    }

    nonisolated static func cadenceDescription(of episodes: [Video], calendar: Calendar = .current) -> String? {
        cadenceDescription(
            weekdays: cadenceWeekdays(of: episodes, calendar: calendar),
            typicalDuration: typicalDuration(of: episodes),
            calendar: calendar
        )
    }

    nonisolated static func cadenceDescription(
        weekdays: [Int],
        typicalDuration: TimeInterval?,
        calendar: Calendar = .current
    ) -> String? {
        var parts: [String] = []
        if !weekdays.isEmpty {
            let symbols = calendar.shortWeekdaySymbols
            parts.append("Posts " + weekdays.map { symbols[$0 - 1] }.joined(separator: ", "))
        }
        if let typicalDuration, let length = approximateLength(typicalDuration) {
            // Without a weekday the sentence needs a subject of its own.
            parts.append(weekdays.isEmpty ? "Episodes about \(length)" : "about \(length)")
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// "1 hr", "1 hr 15 min", "45 min": rounded to five minutes, because a
    /// typical length is a shape, not a measurement.
    nonisolated static func approximateLength(_ seconds: TimeInterval) -> String? {
        guard seconds > 0 else { return nil }
        let minutes = max(Int((seconds / 300).rounded()) * 5, 5)
        guard minutes >= 60 else { return "\(minutes) min" }
        let (hours, remainder) = (minutes / 60, minutes % 60)
        return remainder == 0 ? "\(hours) hr" : "\(hours) hr \(remainder) min"
    }

    private nonisolated static func weekOffset(_ weekday: Int, calendar: Calendar) -> Int {
        (weekday - calendar.firstWeekday + 7) % 7
    }

    // MARK: - Episodes from a live query

    /// `episodes(of:)` over videos the caller already has, so a view can drive
    /// the show page from a live `@Query` and follow the store without
    /// re-fetching on every change. Mirrors `episodes(of:)` exactly, the way
    /// `unwatchedCounts(from:shows:)` mirrors `unwatchedCount(for:)`.
    nonisolated static func episodes(from videos: [Video], of show: Show) -> [Video] {
        order(episodesNewestFirst(from: videos, of: show), by: show.playOrder)
    }

    /// The same episodes in air order, whatever the play order.
    ///
    /// The show page lists them this way even for a show watched oldest
    /// first: an episode list is read newest first — that's where the new
    /// ones are — and it's "Play next" that walks the backlog forwards.
    nonisolated static func episodesNewestFirst(from videos: [Video], of show: Show) -> [Video] {
        listing(from: members(from: videos, of: show), of: show).episodes
    }
}
