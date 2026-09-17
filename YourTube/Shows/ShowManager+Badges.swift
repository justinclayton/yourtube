import Foundation
import SwiftData

extension ShowManager {
    /// The unwatched count behind every poster in Your Shows, keyed by show
    /// ID, in one fetch scoped to the videos those shows could hold.
    ///
    /// The grid used to feed `ShowListing.unwatchedCounts(from:shows:)` a live `@Query`
    /// over every non-Short video in the store — thousands of rows, re-fetched
    /// on every store change even while another tab was showing (issue #66).
    /// The answer is the same one: the pure pass still applies segments and
    /// the retention window, so a badge never promises more than the show page
    /// lists. Only the raw material is narrower — the shows' own channels'
    /// videos, plus the members of any playlist-backed show, which is all
    /// `ShowListing.sourceVideos(from:of:inSeason:)` was ever going to keep.
    func unwatchedCounts(for shows: [Show]) throws -> [String: Int] {
        let channelIds = shows.filter { !$0.isPlaylistBacked }.map(\.channelId)
        let memberIds = shows.flatMap(\.memberVideoIds)
        guard !channelIds.isEmpty || !memberIds.isEmpty else {
            return shows.reduce(into: [String: Int]()) { $0[$1.id] = 0 }
        }
        let videos = try modelContext.fetch(FetchDescriptor<Video>(
            predicate: #Predicate {
                !$0.isLikelyShort
                    && (channelIds.contains($0.channelId) || memberIds.contains($0.videoId))
            }
        ))
        return ShowListing.unwatchedCounts(from: videos, shows: shows)
    }
}
