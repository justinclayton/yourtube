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
/// The passes themselves run on `StoreWriter`, off the main context, so a run
/// is invisible to a feed being scrolled; what's left here is when to run,
/// what the setting says, and what the viewer is told.
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
/// Staleness is tracked the same way `CategoryManager`'s classifier tracks
/// it: each video records the cleaner version that produced its cached
/// title, and a run picks up anything below the current one. `version` is
/// the two tiers' versions added together, so bumping either one re-runs
/// both — tier one's output is tier two's input, and a rewrite judged
/// against a stale stripping isn't worth keeping.
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

    /// How many pending episodes a show's automatic pass rewrites when it has
    /// no retention setting of its own. The rest are rewritten lazily, only
    /// once the show's page is opened — issue #65: titles are read on the
    /// show page and the Shows tab, so a show nobody has opened yet doesn't
    /// need every backlogged episode calmed before launch goes idle.
    static let defaultRewriteWindow = 10

    /// Which pending episodes one rewrite pass may draw from.
    enum RewriteScope: Sendable, Equatable {
        /// Every show's pending episodes, newest first, but only the newest
        /// `perShow` of each (a show's own `retentionCount`, or `perShow`
        /// when it hasn't set one). What the automatic pass uses.
        case retentionWindow(perShow: Int)
        /// Every pending episode of one show, regardless of window — what
        /// opening that show's page asks for.
        case show(id: String)
    }

    private(set) var status: Status = .idle
    private(set) var rewriteStatus: Status = .idle
    private(set) var lastRunAt: Date?
    /// Titles the model refused or errored on during the last rewrite pass.
    /// They keep their stripped title and aren't retried until a version bump,
    /// the way `CategoryManager` treats a channel the guardrail objects to.
    private(set) var lastRewriteFailures = 0

    private let writer: StoreWriter
    private let rewriter: (any TitleRewriter)?
    private let defaults: UserDefaults
    private var runningTask: Task<Void, Never>?

    /// How many model calls one launch may spend on rewrites in total, across
    /// the automatic pass and every show page opened along the way. Bounds
    /// the cold-launch cost the performance audit measured (261 calls, 4.5
    /// minutes) to something that goes idle quickly; the rest is picked up
    /// lazily as shows are opened, or on the next launch.
    private let rewriteBudgetPerLaunch: Int
    /// How long the automatic pass waits before its first model call, so
    /// launch's first frame and the user's first tap never compete with it.
    /// Only the very first automatic pass of a launch waits; later ones (a
    /// refresh finishing) are already given their own idle delay by
    /// `RootView`.
    private let startDelay: Duration
    /// True once a refresh is under way. Read at the start of the automatic
    /// pass so it never competes with the feed the user is about to read;
    /// see `RootView` and `FeedRefresher.isRefreshing`.
    private let isRefreshingProvider: @MainActor () -> Bool

    private var rewritesSpentThisLaunch = 0
    private var hasWaitedForStartDelay = false

    /// What's left of this launch's rewrite budget.
    private var remainingBudget: Int { max(0, rewriteBudgetPerLaunch - rewritesSpentThisLaunch) }

    init(
        modelContext: ModelContext,
        rewriter: (any TitleRewriter)? = nil,
        defaults: UserDefaults = .standard,
        writer: StoreWriter? = nil,
        rewriteBudgetPerLaunch: Int = 40,
        startDelay: Duration = .seconds(3),
        isRefreshingProvider: @escaping @MainActor () -> Bool = { false }
    ) {
        self.writer = writer ?? StoreWriter(modelContainer: modelContext.container)
        self.rewriter = rewriter
        self.defaults = defaults
        self.rewriteBudgetPerLaunch = rewriteBudgetPerLaunch
        self.startDelay = startDelay
        self.isRefreshingProvider = isRefreshingProvider
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
    /// after an update that changed either tier. The very first call of a
    /// launch waits `startDelay` before its first model call; RootView gives
    /// later, refresh-triggered calls their own idle delay, so this one is a
    /// no-op by the time they land.
    func cleanStaleInBackground() {
        guard !isRunning else { return }
        runningTask = Task {
            await waitForStartDelayIfNeeded()
            guard !Task.isCancelled else { return }
            await cleanStale()
        }
    }

    /// Called when the Settings toggle moves: turning it off puts the stripped
    /// titles back, turning it on rewrites the show episodes that were left
    /// stripped. Neither costs a pass over the whole store. A user action, so
    /// it never waits on `startDelay`.
    func applyRewriteSettingInBackground() {
        guard !isRunning else { return }
        runningTask = Task { await reconcileRewrites() }
    }

    /// Rewrites one show's pending episodes, in full, ahead of the automatic
    /// pass's own retention window — what opening a show page asks for.
    /// Preempts whatever automatic pass may be running, since the page on
    /// screen matters more than a background pass over shows nobody is
    /// looking at; the preempted pass leaves its own remaining work pending
    /// for next time. Still spends from the same per-launch budget, so
    /// opening show after show can't turn into an unbounded run either.
    func rewriteEpisodes(ofShowId showId: String) async {
        guard canRewrite, isRewriteEnabled else { return }
        runningTask?.cancel()
        let task: Task<Void, Never> = Task { [weak self] in
            _ = await self?.rewritePending(scope: .show(id: showId))
        }
        runningTask = task
        await task.value
    }

    func cancel() {
        runningTask?.cancel()
    }

    /// Waits out `startDelay` once per launch. Direct calls to `cleanStale()`
    /// and `reconcileRewrites()` (tests, the settings toggle, a show page)
    /// skip it entirely; only the fire-and-forget automatic entry point does.
    private func waitForStartDelayIfNeeded() async {
        guard !hasWaitedForStartDelay else { return }
        hasWaitedForStartDelay = true
        try? await Task.sleep(for: startDelay)
    }

    func cleanStale() async {
        guard !isRunning else { return }
        var didWork = false
        do {
            didWork = try await strip()
        } catch is CancellationError {
            status = .idle
            return
        } catch {
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
        status = .running(completed: 0, total: 0)
        do {
            let didWork = try await writer.stripStaleTitles(
                version: Self.version,
                onProgress: progress { [weak self] in self?.reportStrip($0, $1) }
            )
            status = .idle
            return didWork
        } catch {
            status = .idle
            throw error
        }
    }

    // MARK: - Tier two

    /// Brings the store in line with what the rewrite setting asks for.
    /// Returns whether it had anything to do. Skips the pass while a refresh
    /// is running — that's exactly when the user is reading the fresh feed,
    /// the one moment the model must not compete for the main thread — and
    /// leaves everything pending for the next trigger.
    @discardableResult
    func reconcileRewrites() async -> Bool {
        guard canRewrite, isRewriteEnabled else {
            let reverted = (try? await writer.revertRewrites()) ?? false
            rewriteStatus = .idle
            return reverted
        }
        guard !isRefreshingProvider() else { return false }
        return await rewritePending(scope: .retentionWindow(perShow: Self.defaultRewriteWindow))
    }

    private func rewritePending(scope: RewriteScope) async -> Bool {
        guard let rewriter else { return false }
        let limit = remainingBudget
        guard limit > 0 else { return false }
        rewriteStatus = .running(completed: 0, total: 0)
        lastRewriteFailures = 0
        do {
            let outcome = try await writer.rewritePendingTitles(
                version: Self.version,
                using: rewriter,
                scope: scope,
                limit: limit,
                onProgress: progress { [weak self] in self?.reportRewrite($0, $1) }
            )
            lastRewriteFailures = outcome.failures
            rewritesSpentThisLaunch += outcome.processed
            rewriteStatus = .idle
            return outcome.didWork
        } catch {
            rewriteStatus = .failed(error.localizedDescription)
            return false
        }
    }

    // MARK: - Progress

    /// Wraps a main-actor handler as something the writer can call from its
    /// own context.
    private nonisolated func progress(
        _ handler: @escaping @Sendable @MainActor (Int, Int) -> Void
    ) -> StoreWriterProgress {
        { completed, total in Task { @MainActor in handler(completed, total) } }
    }

    /// Progress is a hop to the main actor, so it can land after the run it
    /// belongs to has already finished. A finished run's status stands.
    private func reportStrip(_ completed: Int, _ total: Int) {
        guard case .running = status else { return }
        status = .running(completed: completed, total: total)
    }

    private func reportRewrite(_ completed: Int, _ total: Int) {
        guard case .running = rewriteStatus else { return }
        rewriteStatus = .running(completed: completed, total: total)
    }
}
