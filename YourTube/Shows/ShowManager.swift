import Foundation
import SwiftData

/// One channel's verdict from the show detector: does this look like a show,
/// and why. `ShowDetector` produces them; `ShowSuggestions.apply` turns them
/// into suggestions, and knows what it must never touch. The reasons travel
/// with the suggestion, and onto the show if the user adds it.
struct ShowVerdict: Sendable, Equatable {
    var channelId: String
    var channelTitle: String
    var isShow: Bool
    var reasons: [String] = []
    /// True when `isShow` is false specifically because the channel's gone
    /// quiet, rather than never having looked like a show. Either way a
    /// pending suggestion goes; the flag is there so the reasons can say why.
    var dormant: Bool = false
}

/// Owns the show catalogue: which channels are shows, which videos are their
/// episodes, and how many of those are still unwatched.
///
/// Every show is added by the user: flagged in the Channels tab, or accepted
/// from a detector suggestion (see `ShowSuggestions`). Both paths come through
/// `markAsShow` and `markAsNotAShow`, which record a standing decision
/// (`override`) and clear any pending suggestion for the channel. "Not a
/// show" leaves a `Show` row behind purely as a tombstone, which is what keeps
/// the detector from suggesting the channel again; `shows()` never returns
/// those.
///
/// A channel-backed show's membership is resolved live rather than stored:
/// its episodes are every video from its channel. That keeps the
/// catalogue idempotent under feed refresh — a new upload is an episode the
/// moment it lands, with nothing to reconcile. A playlist-backed show has no
/// such rule to resolve, so its membership is stored on the record and
/// refreshed from the API when the show is opened; see `ShowManager+Playlists`
/// and `FeedRefresher+PlaylistShows`.
///
/// What a show *lists* — episodes, segments, the retention window, the
/// counts, "Play next", cadence — is not here: that is `ShowListing`, one
/// value type over a show's settings and a pile of videos. This class fetches
/// the videos (`listing(of:)`) and owns the catalogue writes.
@MainActor
final class ShowManager {
    let modelContext: ModelContext
    let watchState: WatchState

    init(modelContext: ModelContext, watchState: WatchState) {
        self.modelContext = modelContext
        self.watchState = watchState
    }

    // MARK: - Catalogue

    /// The catalogue, alphabetical. Tombstones for "not a show" are left out.
    func shows() throws -> [Show] {
        Self.active(try allRecords())
    }

    /// The same catalogue from records the caller already holds. A static so a
    /// background pass over its own context answers exactly what `shows()`
    /// does, rather than keeping a second idea of what counts as a show.
    nonisolated static func active(_ records: [Show]) -> [Show] {
        records
            .filter(\.isActive)
            .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }

    /// Every row, tombstones included. Callers that care about the user's
    /// decisions (the detector, the Channels toggle) want this one.
    func allRecords() throws -> [Show] {
        try modelContext.fetch(FetchDescriptor<Show>())
    }

    func record(id: String) throws -> Show? {
        try Self.record(id: id, in: modelContext)
    }

    nonisolated static func record(id: String, in context: ModelContext) throws -> Show? {
        try context.fetch(FetchDescriptor<Show>(
            predicate: #Predicate { $0.id == id }
        )).first
    }

    /// The channel-backed row for a channel, whether or not it's a show.
    func record(forChannelId id: String) throws -> Show? {
        try record(id: ShowSource.channel(id: id).showId)
    }

    /// Whether the channel is in the catalogue right now.
    func isShow(channelId: String) throws -> Bool {
        try record(forChannelId: channelId)?.isActive ?? false
    }

    /// Adds a channel as a show. Permanent until the user changes it: origin
    /// and override both say "user", so the detector never reconsiders it.
    ///
    /// - Parameter reasons: the detector's reasons, when the show is accepted
    ///   from a suggestion; empty for a flag made in the Channels tab.
    @discardableResult
    func markAsShow(channelId: String, channelTitle: String, reasons: [String] = []) throws -> Show {
        let show = try Self.recordDecision(
            isShow: true, channelId: channelId, channelTitle: channelTitle, reasons: reasons, in: modelContext
        )
        try modelContext.save()
        return show
    }

    /// Records "this is not a show". The row stays as a tombstone so the
    /// detector never suggests the channel again.
    func markAsNotAShow(channelId: String, channelTitle: String) throws {
        try Self.recordDecision(isShow: false, channelId: channelId, channelTitle: channelTitle, in: modelContext)
        try modelContext.save()
    }

    /// The write behind both of the above, unsaved, so `ShowSuggestions` can
    /// record a whole Pick in one save. A decision ends any suggestion
    /// pending for the channel, wherever it was made.
    @discardableResult
    nonisolated static func recordDecision(
        isShow: Bool,
        channelId: String,
        channelTitle: String,
        reasons: [String] = [],
        in modelContext: ModelContext
    ) throws -> Show {
        try ShowSuggestions.dismissSuggestion(forChannel: channelId, in: modelContext)
        return try upsert(
            source: .channel(id: channelId),
            title: channelTitle,
            flagOrigin: .user,
            override: isShow ? .forceShow : .forceNotShow,
            reasons: reasons,
            in: modelContext
        )
    }

    func setIsShow(_ isShow: Bool, channelId: String, channelTitle: String) throws {
        if isShow {
            try markAsShow(channelId: channelId, channelTitle: channelTitle)
        } else {
            try markAsNotAShow(channelId: channelId, channelTitle: channelTitle)
        }
    }

    /// Forgets a channel entirely, override included, so the detector is free
    /// to suggest it again.
    func forget(channelId: String) throws {
        guard let record = try record(forChannelId: channelId) else { return }
        modelContext.delete(record)
        try modelContext.save()
    }

    @discardableResult
    private nonisolated static func upsert(
        source: ShowSource,
        title: String,
        flagOrigin: ShowFlagOrigin,
        override: ShowOverride,
        reasons: [String] = [],
        in modelContext: ModelContext
    ) throws -> Show {
        if let existing = try record(id: source.showId, in: modelContext) {
            existing.title = title
            existing.flagOrigin = flagOrigin
            existing.override = override
            existing.detectorReasons = reasons
            return existing
        }
        let show = Show(source: source, title: title, flagOrigin: flagOrigin, override: override)
        show.detectorReasons = reasons
        modelContext.insert(show)
        return show
    }

    // MARK: - Listing

    /// The show's listing, fetched rather than handed in: the one place a
    /// show's videos are read out of the store.
    ///
    /// Everything about what a show lists, counts, hides and plays next is
    /// `ShowListing`'s (see that type); this is the thin layer that gets it
    /// the videos. A view that already holds a live `@Query` builds its own
    /// listing from that instead, and gets the same answers.
    func listing(of show: Show, season: Int? = nil) throws -> ShowListing {
        ShowListing(of: show, season: season, from: try sourceVideos(of: show))
    }

    /// Every video from the show's source, newest first, before anything is
    /// classified or hidden — the one place membership is resolved against
    /// the store. `ShowListing` applies the same rule to videos handed in, so
    /// the narrowing here is only about fetching less.
    private func sourceVideos(of show: Show) throws -> [Video] {
        let byDate = [SortDescriptor(\Video.publishedAt, order: .reverse)]
        switch show.source {
        case .channel(let channelId):
            return try modelContext.fetch(FetchDescriptor<Video>(
                predicate: #Predicate { $0.channelId == channelId },
                sortBy: byDate
            ))
        case .playlist:
            let ids = show.memberVideoIds
            guard !ids.isEmpty else { return [] }
            return try modelContext.fetch(FetchDescriptor<Video>(
                predicate: #Predicate { ids.contains($0.videoId) },
                sortBy: byDate
            ))
        }
    }

    /// The show a video is an episode of, over a catalogue the caller already
    /// has, or nil when it belongs to none.
    ///
    /// A channel-backed show wins over a playlist-backed one on the same
    /// channel: it's the whole of what the channel puts out, so following it
    /// forward is following the channel forward. A playlist-backed show is
    /// only consulted when the channel itself isn't a show, or when the video
    /// came from a channel with no show at all — a playlist may hold a guest
    /// channel's video, and that video is still an episode of this show.
    ///
    /// A view that already holds a live `@Query` of `[Show]` (the catalogue
    /// is a handful of rows) uses this to resolve a card's show once, instead
    /// of paying for a fetch on every body evaluation.
    nonisolated static func show(containing video: Video, in shows: [Show]) -> Show? {
        if let channelShow = shows.first(where: {
            !$0.isPlaylistBacked && $0.channelId == video.channelId && $0.isActive
        }) {
            return channelShow
        }
        return shows.first {
            $0.isActive && $0.isPlaylistBacked && $0.memberVideoIds.contains(video.videoId)
        }
    }

    /// Marks every listed episode watched, which is what "Mark all watched"
    /// means: the show's badge goes, its episodes leave Continue Watching and
    /// Up Next, and the ones hidden as segments or aged out by the retention
    /// window are left alone — clearing a backlog shouldn't reach behind the
    /// page you're looking at.
    ///
    /// The per-video effect is `WatchState.markWatched`'s: a finished episode
    /// has no business waiting in a list of things to watch. Returns how many
    /// episodes changed.
    @discardableResult
    func markAllWatched(of show: Show) throws -> Int {
        try watchState.markWatched(listing(of: show).episodes.filter { !$0.isWatched })
    }
}
