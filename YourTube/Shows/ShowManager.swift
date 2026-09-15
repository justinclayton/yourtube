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
/// Membership is resolved live rather than stored: a channel-backed show's
/// episodes are every non-Short video from its channel. That keeps the
/// catalogue idempotent under feed refresh — a new upload is an episode the
/// moment it lands, with nothing to reconcile.
@MainActor
final class ShowManager {
    let modelContext: ModelContext

    init(modelContext: ModelContext) {
        self.modelContext = modelContext
    }

    // MARK: - Catalogue

    /// The catalogue, alphabetical. Tombstones for "not a show" are left out.
    func shows() throws -> [Show] {
        try allRecords()
            .filter(\.isActive)
            .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }

    /// Every row, tombstones included. Callers that care about the user's
    /// decisions (the detector, the Channels toggle) want this one.
    func allRecords() throws -> [Show] {
        try modelContext.fetch(FetchDescriptor<Show>())
    }

    func record(id: String) throws -> Show? {
        try modelContext.fetch(FetchDescriptor<Show>(
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
        if let existing = try record(id: source.showId) {
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

    // MARK: - Membership

    /// The show's episodes, in its play order, with segments and the
    /// retention window applied. A channel-backed show's episodes are every
    /// non-Short video from its channel that isn't a cut-down of one: Shorts
    /// are never episodes of anything, and neither are segments (see
    /// `ShowManager+Segments`).
    func episodes(of show: Show) throws -> [Video] {
        Self.order(try listing(of: show).episodes, by: show.playOrder)
    }

    /// Every video from the show's source, newest first, before anything is
    /// classified or hidden. The raw material for `listing(of:)`.
    func sourceVideos(of show: Show) throws -> [Video] {
        let channelId = show.channelId
        return try modelContext.fetch(FetchDescriptor<Video>(
            predicate: #Predicate { $0.channelId == channelId && !$0.isLikelyShort },
            sortBy: [SortDescriptor(\.publishedAt, order: .reverse)]
        ))
    }

    /// How many of a show's episodes are still unwatched. Segments and the
    /// episodes the retention window hides are not counted: a badge should
    /// only ever ask for what the show page is offering. Zero means the grid
    /// draws no badge at all.
    func unwatchedCount(for show: Show) throws -> Int {
        try episodes(of: show).filter { !$0.isWatched }.count
    }

    /// Unwatched counts for several shows at once, keyed by show ID, from
    /// videos the caller already has. The grid feeds it a live `@Query` so the
    /// badges follow the store without a fetch per poster.
    ///
    /// `videos` may hold anything; Shorts and other channels' videos are
    /// filtered out here, so the caller's query doesn't have to be exact.
    nonisolated static func unwatchedCounts(from videos: [Video], shows: [Show]) -> [String: Int] {
        let byChannel = Dictionary(grouping: videos.filter { !$0.isLikelyShort }, by: \.channelId)
        return shows.reduce(into: [String: Int]()) { counts, show in
            counts[show.id] = listing(from: byChannel[show.channelId] ?? [], of: show)
                .episodes.filter { !$0.isWatched }.count
        }
    }

    /// "Keep the last N": the newest N episodes, given a newest-first list.
    nonisolated static func retained(_ newestFirst: [Video], count: Int?) -> [Video] {
        guard let count, count >= 0 else { return newestFirst }
        return Array(newestFirst.prefix(count))
    }

    nonisolated static func order(_ newestFirst: [Video], by playOrder: PlayOrder) -> [Video] {
        playOrder == .newestFirst ? newestFirst : Array(newestFirst.reversed())
    }

    // MARK: - Automatic pass

    /// Applies a detector's verdicts to the catalogue.
    ///
    /// The user always wins: a channel with an override in either direction is
    /// skipped whole, and so is a show the user created by hand. A channel the
    /// detector flags gets a heuristic show; one it un-flags loses its
    /// heuristic show and nothing else. Returns how many rows changed.
    @discardableResult
    func applyAutomaticVerdicts(_ verdicts: [ShowVerdict]) throws -> Int {
        var changed = 0
        for verdict in verdicts {
            let existing = try record(forChannelId: verdict.channelId)
            if let existing, existing.override != .none || existing.flagOrigin == .user {
                continue
            }
            switch (verdict.isShow, existing) {
            case (true, let existing?):
                existing.title = verdict.channelTitle
                existing.detectorReasons = verdict.reasons
                changed += 1
            case (true, nil):
                try upsert(
                    source: .channel(id: verdict.channelId),
                    title: verdict.channelTitle,
                    flagOrigin: .heuristic,
                    override: .none,
                    reasons: verdict.reasons
                )
                changed += 1
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
