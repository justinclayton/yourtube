import Foundation

/// One row of the subscription feed after the per-channel daily cap is applied.
enum FeedRow<V>: Identifiable where V: Identifiable {
    case video(V)
    /// A channel exceeded the cap. `hidden` holds the videos folded away, in
    /// feed order; `key` identifies the fold so the UI can track expansion.
    case more(key: String, channelTitle: String, hidden: [V])

    var id: String {
        switch self {
        case .video(let video): return "video-\(video.id)"
        case .more(let key, _, _): return "more-\(key)"
        }
    }
}

/// Collapses high-volume channels within a single calendar day.
///
/// A dedup by source, not a ranking: the first `cap` videos from each channel
/// stay where they are, everything after folds into a single "+N more" row at
/// the position the first hidden video would have taken. Order is never
/// changed. The caller has already filtered Shorts and bucketed by day, so
/// this only ever sees one day's worth of videos.
enum ChannelDailyCap {
    /// Feed keys with a stable form so the UI can persist expansion per fold.
    static func key(channelId: String, day: Date) -> String {
        "\(channelId)|\(Int(day.timeIntervalSinceReferenceDate))"
    }

    /// - Parameters:
    ///   - videos: one day's videos, newest first.
    ///   - cap: max videos shown per channel; 0 disables collapsing.
    ///   - expanded: keys (from `key(channelId:day:)`) whose fold is open.
    ///     Expanded folds keep their "+N more" row and emit the hidden videos
    ///     inline after it, so a second tap can close them again.
    static func apply<V: Identifiable>(
        _ videos: [V],
        cap: Int,
        day: Date,
        expanded: Set<String>,
        channelId: (V) -> String,
        channelTitle: (V) -> String
    ) -> [FeedRow<V>] {
        guard cap > 0 else { return videos.map(FeedRow.video) }

        var shown: [String: Int] = [:]
        var foldIndex: [String: Int] = [:]
        var rows: [FeedRow<V>] = []

        for video in videos {
            let channel = channelId(video)
            let count = shown[channel, default: 0]
            if count < cap {
                shown[channel] = count + 1
                rows.append(.video(video))
                continue
            }
            let foldKey = key(channelId: channel, day: day)
            if let index = foldIndex[channel],
               case .more(let k, let title, var hidden) = rows[index] {
                hidden.append(video)
                rows[index] = .more(key: k, channelTitle: title, hidden: hidden)
            } else {
                foldIndex[channel] = rows.count
                rows.append(.more(key: foldKey, channelTitle: channelTitle(video), hidden: [video]))
            }
        }

        guard !expanded.isEmpty else { return rows }
        return rows.flatMap { row -> [FeedRow<V>] in
            if case .more(let k, _, let hidden) = row, expanded.contains(k) {
                return [row] + hidden.map(FeedRow.video)
            }
            return [row]
        }
    }
}
