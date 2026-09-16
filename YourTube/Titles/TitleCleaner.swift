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
/// Staleness is the Shorts classifier's mechanism exactly: each video records
/// the cleaner version that produced its cached title, and a run picks up
/// anything below the current one. `version` is the two tiers' versions added
/// together, so bumping either one re-runs both — tier one's output is tier
/// two's input, and a rewrite judged against a stale stripping isn't worth
/// keeping.
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

    private let writer: StoreWriter
    private let rewriter: (any TitleRewriter)?
    private let defaults: UserDefaults
    private var runningTask: Task<Void, Never>?

    init(
        modelContext: ModelContext,
        rewriter: (any TitleRewriter)? = nil,
        defaults: UserDefaults = .standard,
        writer: StoreWriter? = nil
    ) {
        self.writer = writer ?? StoreWriter(modelContainer: modelContext.container)
        self.rewriter = rewriter
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
    /// Returns whether it had anything to do.
    @discardableResult
    func reconcileRewrites() async -> Bool {
        guard canRewrite, isRewriteEnabled else {
            let reverted = (try? await writer.revertRewrites()) ?? false
            rewriteStatus = .idle
            return reverted
        }
        return await rewritePending()
    }

    private func rewritePending() async -> Bool {
        guard let rewriter else { return false }
        rewriteStatus = .running(completed: 0, total: 0)
        lastRewriteFailures = 0
        do {
            let outcome = try await writer.rewritePendingTitles(
                version: Self.version,
                using: rewriter,
                onProgress: progress { [weak self] in self?.reportRewrite($0, $1) }
            )
            lastRewriteFailures = outcome.failures
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
