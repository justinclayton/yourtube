import Foundation
import SwiftData
import Observation

/// Drives both tiers of title cleaning over the stored videos and caches what
/// they produce on `Video`.
///
/// Cleaning is a background job for the same reason category classification
/// is: it's per-channel work over the whole store, and the feed must render
/// before it finishes. A video with no cached result shows its raw title, so
/// the worst a slow run costs is a title that tidies itself a moment later.
///
/// **Tier one**, `TitleStripper`, is deterministic, runs for every channel and
/// writes both `strippedTitle` and `cleanedTitle`.
///
/// **Tier two**, `TitleRewriter`, asks the on-device model to calm what tier
/// one left. It runs only for episodes of shows — the surface where a
/// clickbait title is most in the way, and a small enough set that one model
/// call per title is affordable — and it overwrites `cleanedTitle` only.
/// `strippedTitle` stays put, which is what makes turning the rewrite off in
/// Settings a field copy rather than a second pass over the whole store.
///
/// Staleness is the Shorts classifier's mechanism exactly: each video records
/// the cleaner version that produced its cached title, and a run picks up
/// anything below the current one. `version` is the two tiers' versions added
/// together, so bumping either one re-runs both — tier one's output is tier
/// two's input, and a rewrite judged against a stale stripping isn't worth
/// keeping.
///
/// Work in tier one is grouped by channel because the stripper needs a
/// channel's titles together to find the repeated affix. When any video of a
/// channel is stale the whole channel is re-cleaned, so a channel's titles are
/// never a mix of verdicts from different evidence — new uploads can change
/// what counts as boilerplate.
@Observable
@MainActor
final class TitleCleaner {
    enum Status: Equatable {
        case idle
        case running(completed: Int, total: Int)
        case failed(String)
    }

    /// The version stamped on cleaned videos: both tiers added, so a bump in
    /// either re-cleans the whole store on the next launch with no migration
    /// to write.
    static var version: Int { TitleStripper.version + TitleRewritePrompt.version }

    /// Whether the model rewrite is wanted. Stripping is not optional and has
    /// no setting; this covers tier two alone.
    static let rewriteEnabledKey = "settings.rewriteTitles"

    private(set) var status: Status = .idle
    private(set) var rewriteStatus: Status = .idle
    private(set) var lastRunAt: Date?
    /// Titles the model refused or errored on during the last rewrite pass.
    /// They keep their stripped title and aren't retried until a version bump,
    /// the way `CategoryManager` treats a channel the guardrail objects to.
    private(set) var lastRewriteFailures = 0

    private let modelContext: ModelContext
    private let rewriter: (any TitleRewriter)?
    private let shows: ShowManager
    private let defaults: UserDefaults
    private var runningTask: Task<Void, Never>?

    /// Save every N channels (or titles) so a kill mid-run doesn't lose the work.
    private let saveInterval = 20

    init(
        modelContext: ModelContext,
        rewriter: (any TitleRewriter)? = nil,
        shows: ShowManager? = nil,
        defaults: UserDefaults = .standard
    ) {
        self.modelContext = modelContext
        self.rewriter = rewriter
        self.shows = shows ?? ShowManager(modelContext: modelContext)
        self.defaults = defaults
    }

    /// Whether this device can rewrite at all. False leaves tier-one stripping
    /// running on its own, which is the degradation the feature is built
    /// around; Settings disables the toggle and says why.
    var canRewrite: Bool { rewriter != nil }

    /// The user's setting, on unless they turned it off.
    var isRewriteEnabled: Bool {
        get { defaults.object(forKey: Self.rewriteEnabledKey) as? Bool ?? true }
        set { defaults.set(newValue, forKey: Self.rewriteEnabledKey) }
    }

    var isRunning: Bool {
        if case .running = status { return true }
        if case .running = rewriteStatus { return true }
        return false
    }

    /// Fire-and-forget entry point, used at launch and after each refresh.
    /// Cheap when there's nothing stale, which is every launch but the first
    /// after an update that changed either tier.
    func cleanStaleInBackground() {
        guard !isRunning else { return }
        runningTask = Task { await cleanStale() }
    }

    /// Called when the Settings toggle moves: turning it off puts the stripped
    /// titles back, turning it on rewrites the show episodes that were left
    /// stripped. Neither costs a pass over the whole store.
    func applyRewriteSettingInBackground() {
        guard !isRunning else { return }
        runningTask = Task { await reconcileRewrites() }
    }

    func cancel() {
        runningTask?.cancel()
    }

    func cleanStale() async {
        guard !isRunning else { return }
        var didWork = false
        do {
            didWork = try await strip()
        } catch is CancellationError {
            try? modelContext.save()
            status = .idle
            return
        } catch {
            try? modelContext.save()
            status = .failed(error.localizedDescription)
            return
        }
        // `||` in this order so the rewrite pass always runs.
        didWork = await reconcileRewrites() || didWork
        if didWork { lastRunAt = .now }
    }

    // MARK: - Tier one

    /// Returns whether there was anything stale to re-strip.
    @discardableResult
    private func strip() async throws -> Bool {
        let channelIds = try staleChannelIds()
        guard !channelIds.isEmpty else {
            status = .idle
            return false
        }

        status = .running(completed: 0, total: channelIds.count)
        var completed = 0
        for channelId in channelIds {
            try Task.checkCancellation()
            clean(channelId: channelId)
            completed += 1
            status = .running(completed: completed, total: channelIds.count)
            if completed % saveInterval == 0 { try modelContext.save() }
            // Hand the main actor back between channels so the feed keeps
            // scrolling while a first run works through the store.
            await Task.yield()
        }

        try modelContext.save()
        status = .idle
        return true
    }

    /// Channels holding at least one video cleaned by an older version (or
    /// never cleaned), sorted so a run is reproducible.
    private func staleChannelIds() throws -> [String] {
        let current = Self.version
        let stale = try modelContext.fetch(FetchDescriptor<Video>(
            predicate: #Predicate { $0.titleCleanerVersion < current }
        ))
        return Set(stale.map(\.channelId)).sorted()
    }

    /// Re-cleans every video of one channel from its full title list. Any
    /// rewrite the channel's videos carried is dropped: it was judged against
    /// a stripping that no longer holds, and tier two will run again behind
    /// this.
    private func clean(channelId: String) {
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
            video.titleCleanerVersion = Self.version
        }
    }

    // MARK: - Tier two

    /// Brings the store in line with what the rewrite setting asks for.
    /// Returns whether it had anything to do.
    @discardableResult
    func reconcileRewrites() async -> Bool {
        guard canRewrite, isRewriteEnabled else {
            let reverted = revertRewrites()
            rewriteStatus = .idle
            return reverted
        }
        return await rewritePending()
    }

    /// Puts every rewritten title back to tier one's output. Cheap because the
    /// stripped title was kept alongside the rewrite rather than recomputed.
    @discardableResult
    private func revertRewrites() -> Bool {
        let rewritten = (try? modelContext.fetch(FetchDescriptor<Video>(
            predicate: #Predicate { $0.isTitleRewritten }
        ))) ?? []
        guard !rewritten.isEmpty else { return false }
        for video in rewritten {
            if let stripped = video.strippedTitle { video.cleanedTitle = stripped }
            video.isTitleRewritten = false
        }
        try? modelContext.save()
        return true
    }

    /// One model call per show episode that tier two hasn't seen, newest
    /// first so the titles the viewer is about to scroll past settle first.
    @discardableResult
    private func rewritePending() async -> Bool {
        guard let rewriter else { return false }
        let pending: [Video]
        let titles: [String: String]
        do {
            (pending, titles) = try pendingRewrites()
        } catch {
            rewriteStatus = .failed(error.localizedDescription)
            return false
        }
        guard !pending.isEmpty else {
            rewriteStatus = .idle
            return false
        }

        rewriteStatus = .running(completed: 0, total: pending.count)
        lastRewriteFailures = 0
        var completed = 0

        for video in pending {
            if Task.isCancelled { break }
            guard let stripped = video.strippedTitle else { continue }
            let request = TitleRewriteRequest(
                strippedTitle: stripped,
                showTitle: titles[video.channelId] ?? video.channelTitle
            )
            do {
                let answer = try await rewriter.rewrite(request)
                video.cleanedTitle = TitleRewritePrompt.resolve(answer, strippedTitle: stripped)
            } catch is CancellationError {
                break
            } catch {
                // Typically the model's safety guardrail objecting to a news
                // headline. One title must not abort the rest; it keeps the
                // stripped version and isn't retried until a version bump.
                lastRewriteFailures += 1
                video.cleanedTitle = stripped
            }
            video.isTitleRewritten = true

            completed += 1
            rewriteStatus = .running(completed: completed, total: pending.count)
            if completed % saveInterval == 0 { try? modelContext.save() }
            // Hand the main actor back between titles so the feed keeps
            // scrolling while a first run works through a backlog.
            await Task.yield()
        }

        try? modelContext.save()
        rewriteStatus = .idle
        return true
    }

    /// Show episodes that tier one has cleaned and tier two hasn't seen, plus
    /// the show title to name each one under.
    ///
    /// A video belongs to a show when its channel is in the catalogue and it
    /// isn't a Short — the same membership `ShowManager` resolves, read here
    /// as a channel-ID set because this is a pass over the store rather than
    /// over one show.
    private func pendingRewrites() throws -> ([Video], [String: String]) {
        let shows = try shows.shows()
        guard !shows.isEmpty else { return ([], [:]) }
        let titleByChannel = Dictionary(
            shows.map { ($0.channelId, $0.title) },
            uniquingKeysWith: { first, _ in first }
        )
        let channelIds = Set(titleByChannel.keys)
        let current = Self.version
        let candidates = try modelContext.fetch(FetchDescriptor<Video>(
            predicate: #Predicate {
                !$0.isTitleRewritten && !$0.isLikelyShort && $0.titleCleanerVersion == current
            },
            sortBy: [SortDescriptor(\.publishedAt, order: .reverse)]
        ))
        return (candidates.filter { channelIds.contains($0.channelId) }, titleByChannel)
    }
}
