import Foundation
import SwiftData

/// One pending suggestion as the Pick grid draws it: the detector's case for
/// the channel, its art, and what the user has already watched from it.
struct PendingSuggestion: Identifiable, Sendable, Equatable {
    var channelId: String
    var title: String
    var reasons: [String]
    var avatarURL: String?
    var engagement: SuggestionEngagement

    var id: String { channelId }
}

/// Owns the channels the detector thinks are shows and the user hasn't
/// decided on.
///
/// Every show is added by the user. The detector's verdicts come in through
/// `apply` and only ever create, refresh or remove suggestions; the user's
/// answers go out through `accept` and `setAside`, which write the same
/// `Show` rows the Channels tab writes (`ShowManager.markAsShow` and
/// `markAsNotAShow`) and delete the suggestion. Set aside is the "Not a show"
/// tombstone, so a set-aside channel is never suggested again.
///
/// A decision made anywhere else clears the suggestion too: `ShowManager`
/// calls `dismissSuggestion(forChannel:in:)` from both of its channel-level
/// writes.
@MainActor
final class ShowSuggestions {
    let modelContext: ModelContext

    init(modelContext: ModelContext) {
        self.modelContext = modelContext
    }

    // MARK: - Reading

    /// Every pending suggestion, in `SuggestionRanking` order.
    func pending() throws -> [PendingSuggestion] {
        let suggestions = try modelContext.fetch(FetchDescriptor<ShowSuggestion>())
        guard !suggestions.isEmpty else { return [] }
        let ids = suggestions.map(\.channelId)
        let videos = try modelContext.fetch(FetchDescriptor<Video>(
            predicate: #Predicate { ids.contains($0.channelId) }
        ))
        let byChannel = Dictionary(grouping: videos, by: \.channelId)
        let subscriptions = try modelContext.fetch(FetchDescriptor<Subscription>(
            predicate: #Predicate { ids.contains($0.channelId) }
        ))
        let avatars = Dictionary(
            subscriptions.compactMap { sub in sub.thumbnailURL.map { (sub.channelId, $0) } },
            uniquingKeysWith: { first, _ in first }
        )
        return suggestions
            .map { suggestion in
                PendingSuggestion(
                    channelId: suggestion.channelId,
                    title: suggestion.title,
                    reasons: suggestion.reasons,
                    avatarURL: avatars[suggestion.channelId],
                    engagement: Self.engagement(of: byChannel[suggestion.channelId] ?? [])
                )
            }
            .sorted {
                SuggestionRanking.key(title: $0.title, reasons: $0.reasons, engagement: $0.engagement)
                    < SuggestionRanking.key(title: $1.title, reasons: $1.reasons, engagement: $1.engagement)
            }
    }

    /// How many are pending, without reading anything else: what the Your
    /// Shows footer and the onboarding check need.
    func pendingCount() throws -> Int {
        try modelContext.fetchCount(FetchDescriptor<ShowSuggestion>())
    }

    func suggestion(forChannel channelId: String) throws -> ShowSuggestion? {
        try Self.suggestion(forChannel: channelId, in: modelContext)
    }

    nonisolated static func engagement(of videos: [Video]) -> SuggestionEngagement {
        var engagement = SuggestionEngagement(total: videos.count)
        for video in videos {
            if video.isWatched {
                engagement.watched += 1
            } else if video.resumePositionSeconds != nil {
                engagement.started += 1
            }
            if video.isInUpNext { engagement.earmarked += 1 }
        }
        return engagement
    }

    // MARK: - The detector's side

    /// Applies a detector pass. Returns how many suggestions changed.
    @discardableResult
    func apply(_ verdicts: [ShowVerdict]) throws -> Int {
        try Self.apply(verdicts, in: modelContext)
    }

    /// The same rules on any context, so the detector can apply its verdicts
    /// on the background one it read the evidence from.
    ///
    /// A channel the user has decided about — a `Show` row with an override,
    /// or one they made — is skipped whole. Otherwise a show verdict creates
    /// or refreshes the suggestion, and any other verdict, dormancy included,
    /// removes a pending one silently: nobody was promised it.
    @discardableResult
    nonisolated static func apply(_ verdicts: [ShowVerdict], in modelContext: ModelContext) throws -> Int {
        var changed = 0
        for verdict in verdicts {
            if let show = try ShowManager.record(
                id: ShowSource.channel(id: verdict.channelId).showId, in: modelContext
            ), show.override != .none || show.flagOrigin == .user {
                continue
            }
            let existing = try suggestion(forChannel: verdict.channelId, in: modelContext)
            switch (verdict.isShow, existing) {
            case (true, nil):
                modelContext.insert(ShowSuggestion(
                    channelId: verdict.channelId,
                    title: verdict.channelTitle,
                    reasons: verdict.reasons
                ))
                changed += 1
            case (true, let existing?):
                // A pending suggestion is re-verdicted every pass (see
                // `ShowDetectionRunner`), so most passes reconfirm it
                // unchanged. Only count and save when it moved.
                if existing.title != verdict.channelTitle || existing.reasons != verdict.reasons {
                    existing.title = verdict.channelTitle
                    existing.reasons = verdict.reasons
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

    // MARK: - The user's side

    /// Adds each channel as a show.
    func accept(_ channelIds: [String]) throws {
        try resolve(accepting: channelIds, settingAside: [])
    }

    /// Records "not a show" for each channel, which is what keeps it from
    /// being suggested again.
    func setAside(_ channelIds: [String]) throws {
        try resolve(accepting: [], settingAside: channelIds)
    }

    /// The Pick grid's one button: accepts some and sets aside others in a
    /// single save. A channel no longer pending (a pass removed it, or the
    /// user decided elsewhere while the sheet was open) is left alone.
    func resolve(accepting accepted: [String], settingAside setAside: [String]) throws {
        for (channelIds, isShow) in [(accepted, true), (setAside, false)] {
            for channelId in channelIds {
                guard let suggestion = try suggestion(forChannel: channelId) else { continue }
                try ShowManager.recordDecision(
                    isShow: isShow,
                    channelId: channelId,
                    channelTitle: suggestion.title,
                    in: modelContext
                )
                modelContext.delete(suggestion)
            }
        }
        try modelContext.save()
    }

    /// Drops a channel's pending suggestion because the user decided about
    /// the channel some other way.
    func dismissSuggestion(forChannel channelId: String) throws {
        try Self.dismissSuggestion(forChannel: channelId, in: modelContext)
        try modelContext.save()
    }

    /// The same without saving, for a caller that saves its own write.
    nonisolated static func dismissSuggestion(forChannel channelId: String, in modelContext: ModelContext) throws {
        if let suggestion = try suggestion(forChannel: channelId, in: modelContext) {
            modelContext.delete(suggestion)
        }
    }

    nonisolated static func suggestion(forChannel channelId: String, in modelContext: ModelContext) throws -> ShowSuggestion? {
        try modelContext.fetch(FetchDescriptor<ShowSuggestion>(
            predicate: #Predicate { $0.channelId == channelId }
        )).first
    }

    // MARK: - Upgrade

    /// Turns every show the detector filed by itself before issue #145 into
    /// a suggestion carrying the same reasons, and deletes the show: the
    /// upgrade hands the old grid back as a Pick. Hand-made shows, overrides
    /// in either direction, and playlist-backed shows are left exactly as
    /// they are. Per-show settings on a converted show are not kept.
    ///
    /// Idempotent: once it has run there is no heuristic show left to
    /// convert. `ShowDetectionRunner` runs it once per store, before its
    /// first pass under the new rules. Returns how many shows it converted.
    @discardableResult
    nonisolated static func convertHeuristicShows(in modelContext: ModelContext) throws -> Int {
        let guesses = try modelContext.fetch(FetchDescriptor<Show>()).filter {
            !$0.isPlaylistBacked && $0.flagOrigin == .heuristic && $0.override == .none
        }
        for show in guesses {
            if try suggestion(forChannel: show.channelId, in: modelContext) == nil {
                modelContext.insert(ShowSuggestion(
                    channelId: show.channelId,
                    title: show.title,
                    reasons: show.detectorReasons
                ))
            }
            modelContext.delete(show)
        }
        if !guesses.isEmpty { try modelContext.save() }
        return guesses.count
    }
}
