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
        guard let show = try show(containing: video) else { return nil }
        let oldestFirst = try episodes(of: show).sorted { $0.publishedAt < $1.publishedAt }
        guard let index = oldestFirst.firstIndex(where: { $0.videoId == video.videoId }) else {
            return nil
        }
        let nextIndex = index + 1
        return nextIndex < oldestFirst.count ? oldestFirst[nextIndex] : nil
    }

    /// The show a video is an episode of, or nil when it belongs to none.
    ///
    /// A channel-backed show wins over a playlist-backed one on the same
    /// channel: it's the whole of what the channel puts out, so following it
    /// forward is following the channel forward. A playlist-backed show is
    /// only consulted when the channel itself isn't a show, or when the video
    /// came from a channel with no show at all — a playlist may hold a guest
    /// channel's video, and that video is still an episode of this show.
    func show(containing video: Video) throws -> Show? {
        if let channelShow = try record(forChannelId: video.channelId), channelShow.isActive {
            return channelShow
        }
        return try allRecords().first {
            $0.isActive && $0.isPlaylistBacked && $0.memberVideoIds.contains(video.videoId)
        }
    }
}
