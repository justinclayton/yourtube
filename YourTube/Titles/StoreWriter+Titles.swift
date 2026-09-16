import Foundation
import SwiftData

/// Both tiers of title cleaning, as passes over the writer's own context.
/// `TitleCleaner` decides when these run and what the viewer is told about
/// them; this is the run itself. See `StoreWriter` for why it isn't on the
/// main context.
extension StoreWriter {

    /// What one tier-two pass did, handed back as a value rather than left on
    /// shared state, so the manager owns everything a view can see.
    struct RewriteOutcome: Sendable {
        var didWork = false
        var failures = 0
    }

    // MARK: - Tier one

    /// Re-strips every channel holding a video cleaned by an older version,
    /// saving after each chunk of channels. Returns whether anything was
    /// stale.
    ///
    /// Work is grouped by channel because the stripper needs a channel's
    /// titles together to find the repeated affix. When any video of a channel
    /// is stale the whole channel is re-cleaned, so a channel's titles are
    /// never a mix of verdicts from different evidence.
    func stripStaleTitles(
        version: Int,
        onProgress: @escaping StoreWriterProgress
    ) throws -> Bool {
        let channelIds = try staleTitleChannelIds(version: version)
        guard !channelIds.isEmpty else { return false }
        onProgress(0, channelIds.count)

        let interval = Self.progressInterval(total: channelIds.count)
        var completed = 0
        do {
            for channelId in channelIds {
                try Task.checkCancellation()
                stripTitles(ofChannel: channelId, version: version)
                completed += 1
                if completed.isMultiple(of: Self.chunkSize) { try modelContext.save() }
                if completed.isMultiple(of: interval) { onProgress(completed, channelIds.count) }
            }
        } catch {
            // Keep what the run got through. What's left is still stale, so
            // the next run picks it up.
            try? modelContext.save()
            throw error
        }
        try modelContext.save()
        return true
    }

    /// Channels holding at least one video cleaned by an older version (or
    /// never cleaned), sorted so a run is reproducible.
    private func staleTitleChannelIds(version: Int) throws -> [String] {
        let stale = try modelContext.fetch(FetchDescriptor<Video>(
            predicate: #Predicate { $0.titleCleanerVersion < version }
        ))
        return Set(stale.map(\.channelId)).sorted()
    }

    /// Re-cleans every video of one channel from its full title list. Any
    /// rewrite the channel's videos carried is dropped: it was judged against
    /// a stripping that no longer holds, and tier two runs again behind this.
    private func stripTitles(ofChannel channelId: String, version: Int) {
        let videos = (try? modelContext.fetch(FetchDescriptor<Video>(
            predicate: #Predicate { $0.channelId == channelId },
            sortBy: [SortDescriptor(\.publishedAt, order: .reverse)]
        ))) ?? []
        guard !videos.isEmpty else { return }

        for (video, cleaned) in zip(videos, TitleStripper.clean(titles: videos.map(\.title))) {
            video.strippedTitle = cleaned.title
            video.cleanedTitle = cleaned.title
            video.isTitleRewritten = false
            video.seasonNumber = cleaned.seasonNumber
            video.episodeNumber = cleaned.episodeNumber
            video.titleCleanerVersion = version
        }
    }

    // MARK: - Tier two

    /// Puts every rewritten title back to tier one's output. Cheap because the
    /// stripped title was kept alongside the rewrite rather than recomputed.
    func revertRewrites() throws -> Bool {
        let rewritten = (try? modelContext.fetch(FetchDescriptor<Video>(
            predicate: #Predicate { $0.isTitleRewritten }
        ))) ?? []
        guard !rewritten.isEmpty else { return false }
        for chunk in rewritten.chunked(into: Self.chunkSize) {
            for video in chunk {
                if let stripped = video.strippedTitle { video.cleanedTitle = stripped }
                video.isTitleRewritten = false
            }
            try? modelContext.save()
        }
        return true
    }

    /// One model call per show episode that tier two hasn't seen, newest
    /// first so the titles the viewer is about to scroll past settle first.
    func rewritePendingTitles(
        version: Int,
        using rewriter: any TitleRewriter,
        onProgress: @escaping StoreWriterProgress
    ) async throws -> RewriteOutcome {
        let pending = try pendingRewrites(version: version)
        guard !pending.isEmpty else { return RewriteOutcome() }
        onProgress(0, pending.count)

        let interval = Self.progressInterval(total: pending.count)
        var outcome = RewriteOutcome(didWork: true)
        var completed = 0

        for (video, showTitle) in pending {
            if Task.isCancelled { break }
            guard let stripped = video.strippedTitle else { continue }
            let request = TitleRewriteRequest(strippedTitle: stripped, showTitle: showTitle)
            do {
                let answer = try await rewriter.rewrite(request)
                video.cleanedTitle = TitleRewritePrompt.resolve(answer, strippedTitle: stripped)
            } catch is CancellationError {
                break
            } catch {
                // Typically the model's safety guardrail objecting to a news
                // headline — a third of a political show's titles, on the
                // Mac's model. One title must not abort the rest; it gets the
                // deterministic calming instead and isn't retried until a
                // version bump.
                outcome.failures += 1
                video.cleanedTitle = TitleRewritePrompt.fallback(for: stripped)
            }
            video.isTitleRewritten = true

            completed += 1
            if completed.isMultiple(of: Self.chunkSize) { try? modelContext.save() }
            if completed.isMultiple(of: interval) { onProgress(completed, pending.count) }
        }

        try? modelContext.save()
        return outcome
    }

    /// Show episodes that tier one has cleaned and tier two hasn't seen, each
    /// paired with the title of the show to name it under.
    ///
    /// Membership is the one `ShowManager` resolves, inverted into lookups
    /// because this is a pass over the store rather than over one show: a
    /// channel-backed show's episodes are every non-Short video from its
    /// channel, a playlist-backed show's are only the videos the playlist
    /// holds. The host channel of a playlist-backed show is *not* a show, so
    /// its other uploads keep their tier-one title.
    ///
    /// Precedence follows `show(containing:)`: a channel-backed show wins over
    /// a playlist-backed one on the same channel, and a playlist's member that
    /// came from a guest channel is still named under the playlist's show.
    private func pendingRewrites(version: Int) throws -> [(video: Video, showTitle: String)] {
        let shows = ShowManager.active(try modelContext.fetch(FetchDescriptor<Show>()))
        guard !shows.isEmpty else { return [] }
        var titleByChannel: [String: String] = [:]
        var titleByMemberVideo: [String: String] = [:]
        // The catalogue is alphabetical, so first-wins is a stable choice when
        // two playlists claim the same video.
        for show in shows {
            switch show.source {
            case .channel(let channelId):
                if titleByChannel[channelId] == nil { titleByChannel[channelId] = show.title }
            case .playlist:
                for videoId in show.memberVideoIds where titleByMemberVideo[videoId] == nil {
                    titleByMemberVideo[videoId] = show.title
                }
            }
        }
        guard !titleByChannel.isEmpty || !titleByMemberVideo.isEmpty else { return [] }

        let candidates = try modelContext.fetch(FetchDescriptor<Video>(
            predicate: #Predicate {
                !$0.isTitleRewritten && !$0.isLikelyShort && $0.titleCleanerVersion == version
            },
            sortBy: [SortDescriptor(\.publishedAt, order: .reverse)]
        ))
        return candidates.compactMap { video in
            guard let title = titleByChannel[video.channelId] ?? titleByMemberVideo[video.videoId]
            else { return nil }
            return (video, title)
        }
    }
}
