import Foundation
import SwiftData

/// One channel's verdict from the automatic show detector: is this a show, and
/// why. `ShowDetector` produces them; the manager applies them, and knows what
/// it must never touch. The reasons are kept on the `Show` row so the show page
/// can say why a channel was flagged.
struct ShowVerdict: Sendable, Equatable {
    var channelId: String
    var channelTitle: String
    var isShow: Bool
    var reasons: [String] = []
    /// True when `isShow` is false specifically because the channel's gone
    /// quiet, rather than never having looked like a show. `applyAutomaticVerdicts`
    /// treats this case differently for a channel already flagged: it holds
    /// the row for the user to decide about instead of dropping it.
    var dormant: Bool = false
}

/// Owns the show catalogue: which channels are shows, which videos are their
/// episodes, and how many of those are still unwatched.
///
/// Shows are flagged by hand in this release. A detector arrives later, so
/// every write records who made the call (`flagOrigin`) and whether the user
/// has a standing opinion (`override`). `applyAutomaticVerdicts` is the door
/// the detector comes through, and it is barred for any channel the user has
/// decided about in either direction — including "not a show", which leaves a
/// `Show` row behind purely as a tombstone. `shows()` never returns those.
///
/// A channel-backed show's membership is resolved live rather than stored:
/// its episodes are every non-Short video from its channel. That keeps the
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

    /// Heuristic shows whose latest pass found the channel gone quiet —
    /// still in the catalogue, but waiting on the user to say whether to
    /// keep them. What a dormancy prompt should list.
    func showsPendingDormancyReview() throws -> [Show] {
        try shows().filter(\.pendingDormancyReview)
    }

    /// Flags a channel as a show by hand. A hand-made flag is permanent until
    /// the user changes it: origin and override both say "user", so no
    /// automatic pass can take it back.
    @discardableResult
    func markAsShow(channelId: String, channelTitle: String) throws -> Show {
        let show = try upsert(
            source: .channel(id: channelId),
            title: channelTitle,
            flagOrigin: .user,
            override: .forceShow
        )
        try modelContext.save()
        return show
    }

    /// Records "this is not a show". The row stays as a tombstone so a later
    /// detector run can't flag the channel again.
    func markAsNotAShow(channelId: String, channelTitle: String) throws {
        try upsert(
            source: .channel(id: channelId),
            title: channelTitle,
            flagOrigin: .user,
            override: .forceNotShow
        )
        try modelContext.save()
    }

    func setIsShow(_ isShow: Bool, channelId: String, channelTitle: String) throws {
        if isShow {
            try markAsShow(channelId: channelId, channelTitle: channelTitle)
        } else {
            try markAsNotAShow(channelId: channelId, channelTitle: channelTitle)
        }
    }

    /// Forgets a channel entirely, override included, so the detector is free
    /// to have an opinion about it again.
    func forget(channelId: String) throws {
        guard let record = try record(forChannelId: channelId) else { return }
        modelContext.delete(record)
        try modelContext.save()
    }

    @discardableResult
    private func upsert(
        source: ShowSource,
        title: String,
        flagOrigin: ShowFlagOrigin,
        override: ShowOverride,
        reasons: [String] = []
    ) throws -> Show {
        try Self.upsert(
            source: source,
            title: title,
            flagOrigin: flagOrigin,
            override: override,
            reasons: reasons,
            in: modelContext
        )
    }

    @discardableResult
    nonisolated static func upsert(
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
            existing.pendingDormancyReview = false
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
                predicate: #Predicate { $0.channelId == channelId && !$0.isLikelyShort },
                sortBy: byDate
            ))
        case .playlist:
            let ids = show.memberVideoIds
            guard !ids.isEmpty else { return [] }
            return try modelContext.fetch(FetchDescriptor<Video>(
                predicate: #Predicate { ids.contains($0.videoId) && !$0.isLikelyShort },
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

    // MARK: - Automatic pass

    /// Applies a detector's verdicts to the catalogue.
    ///
    /// The user always wins: a channel with an override in either direction is
    /// skipped whole, and so is a show the user created by hand. A channel the
    /// detector flags gets a heuristic show; one it un-flags loses its
    /// heuristic show — unless the un-flagging is dormancy, which is a
    /// question for the user rather than a verdict the detector gets to act
    /// on by itself: the row stays, `pendingDormancyReview` goes up, and
    /// `markAsShow`/`markAsNotAShow` are how the user answers it. Returns how
    /// many rows changed.
    @discardableResult
    func applyAutomaticVerdicts(_ verdicts: [ShowVerdict]) throws -> Int {
        try Self.applyAutomaticVerdicts(verdicts, in: modelContext)
    }

    /// The same rules on any context, so the detector can apply its verdicts
    /// on the background one it read the evidence from.
    @discardableResult
    nonisolated static func applyAutomaticVerdicts(
        _ verdicts: [ShowVerdict],
        in modelContext: ModelContext
    ) throws -> Int {
        var changed = 0
        for verdict in verdicts {
            let existing = try record(id: ShowSource.channel(id: verdict.channelId).showId, in: modelContext)
            if let existing, existing.override != .none || existing.flagOrigin == .user {
                continue
            }
            switch (verdict.isShow, existing) {
            case (true, let existing?):
                // A heuristic show is re-verdicted every pass (its dormancy
                // gate depends on wall-clock time, not just its stored
                // videos), so most passes reconfirm a verdict that hasn't
                // actually moved. Only count and save when it has. Coming
                // back from dormancy on its own — the channel posted again
                // before the user answered — resolves the question too.
                if existing.title != verdict.channelTitle
                    || existing.detectorReasons != verdict.reasons
                    || existing.pendingDormancyReview {
                    existing.title = verdict.channelTitle
                    existing.detectorReasons = verdict.reasons
                    existing.pendingDormancyReview = false
                    changed += 1
                }
            case (true, nil):
                try upsert(
                    source: .channel(id: verdict.channelId),
                    title: verdict.channelTitle,
                    flagOrigin: .heuristic,
                    override: .none,
                    reasons: verdict.reasons,
                    in: modelContext
                )
                changed += 1
            case (false, let existing?) where verdict.dormant:
                // Gone quiet is the user's call: hold the row and ask, rather
                // than drop a show they may still want.
                if !existing.pendingDormancyReview || existing.detectorReasons != verdict.reasons {
                    existing.detectorReasons = verdict.reasons
                    existing.pendingDormancyReview = true
                    changed += 1
                }
            case (false, let existing?):
                modelContext.delete(existing)
                changed += 1
            case (false, nil):
                continue
            }
        }
        if changed > 0 { try modelContext.save() }
        return changed
    }
}
