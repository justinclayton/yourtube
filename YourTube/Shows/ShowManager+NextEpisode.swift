import Foundation

/// Resolves the player's "Next episode" action: the episode published
/// immediately after the one currently playing, within the same show.
///
/// This is deliberately not "next in play order" — a podcast backlog with
/// `oldestFirst` play order still advances chronologically here, because the
/// player is following the show forward from where the viewer is, not
/// handing them the catalogue's idea of what's up next (that's `#23`'s
/// concern). It never reaches into another show: a video that isn't part of
/// any show, or that's already the newest episode of its show, resolves to
/// nil, and the player hides the button rather than falling back to autoplay.
extension ShowManager {
    /// The episode published immediately after `video` within its own show.
    /// Nil when `video` doesn't belong to a show, when it isn't itself an
    /// episode (a Short, say), or when it's already the newest one.
    func nextEpisode(after video: Video) throws -> Video? {
        guard let show = try record(forChannelId: video.channelId), show.isActive else {
            return nil
        }
        let oldestFirst = try episodes(of: show).sorted { $0.publishedAt < $1.publishedAt }
        guard let index = oldestFirst.firstIndex(where: { $0.videoId == video.videoId }) else {
            return nil
        }
        let nextIndex = index + 1
        return nextIndex < oldestFirst.count ? oldestFirst[nextIndex] : nil
    }
}
