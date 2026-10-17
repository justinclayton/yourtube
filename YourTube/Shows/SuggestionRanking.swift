import Foundation

/// What the user has already done with a suggested channel's stored videos:
/// the evidence that they watch it as a show whether or not it's one yet.
struct SuggestionEngagement: Sendable, Equatable {
    var watched = 0
    /// Started and not finished. See `WatchState.inProgressPredicate`.
    var started = 0
    /// In Up Next.
    var earmarked = 0
    /// Every video stored from the channel.
    var total = 0

    var score: Int { watched + started + earmarked }

    /// The poster's line, or nil when there's nothing to say: "You've watched
    /// 14 of 62", "2 in Up Next", "You've watched 3 of 20, 1 started".
    var line: String? {
        var parts: [String] = []
        if watched > 0 { parts.append("You've watched \(watched) of \(total)") }
        if started > 0 { parts.append("\(started) started") }
        if earmarked > 0 { parts.append("\(earmarked) in Up Next") }
        return parts.isEmpty ? nil : parts.joined(separator: ", ")
    }
}

/// The order the Pick grid lists suggestions in: the channels you already
/// watch first, since those are the ones you'd have added anyway; then the
/// ones the detector is surest of; then by name.
///
/// Engagement-first is a bet the simulator store can't check, having almost
/// no watch history. If it doesn't separate anything on a real store, swap
/// the first two fields of `Key`'s comparison.
enum SuggestionRanking {
    struct Key: Comparable, Sendable {
        var engagement: Int
        var reasonCount: Int
        var title: String

        static func < (a: Key, b: Key) -> Bool {
            if a.engagement != b.engagement { return a.engagement > b.engagement }
            if a.reasonCount != b.reasonCount { return a.reasonCount > b.reasonCount }
            return a.title.localizedStandardCompare(b.title) == .orderedAscending
        }

        static func == (a: Key, b: Key) -> Bool {
            !(a < b) && !(b < a)
        }
    }

    static func key(title: String, reasons: [String], engagement: SuggestionEngagement) -> Key {
        Key(engagement: engagement.score, reasonCount: reasons.count, title: title)
    }
}
