import Foundation
import SwiftData

/// The classifier pass, as a pass over the writer's own context.
/// `CategoryManager` owns the taxonomy, the rules the user edits by hand and
/// the status the views bind to; this is the run over several hundred channels
/// behind them. See `StoreWriter` for why it isn't on the main context.
extension StoreWriter {

    /// What one classifier run did.
    struct ClassifyOutcome: Sendable {
        /// Channels the run had to ask about. Zero means there was nothing to
        /// do, which is every launch after the first.
        var total = 0
        var completed = 0
        /// Channels the model refused or errored on. They're left
        /// Uncategorised and marked classified, so they aren't retried every
        /// launch.
        var failures = 0
    }

    /// One call per channel in scope, sequentially, saving after each chunk.
    func classifyChannels(
        scope: CategoryManager.Scope,
        using categorizer: any ChannelCategorizer,
        recentTitlesPerChannel: Int,
        onProgress: @escaping StoreWriterProgress
    ) async throws -> ClassifyOutcome {
        let targets = try classificationTargets(scope: scope)
        guard !targets.isEmpty else { return ClassifyOutcome() }
        let names = try topicCategories().map(\.name)
        guard !names.isEmpty else { throw StoreWriterError.noTopicCategories }

        var outcome = ClassifyOutcome(total: targets.count)
        onProgress(0, targets.count)
        let interval = Self.progressInterval(total: targets.count)

        do {
            for subscription in targets {
                try Task.checkCancellation()
                let descriptor = try descriptor(
                    for: subscription, recentTitles: recentTitlesPerChannel
                )
                let guess: CategoryGuess
                do {
                    guess = try await categorizer.categorize(descriptor, among: names)
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    // Typically the model's safety guardrail objecting to a
                    // channel name or title. One bad channel must not abort
                    // the other six hundred; record it as unsure and carry on.
                    outcome.failures += 1
                    guess = .unsure
                }
                try apply(guess, to: subscription)

                outcome.completed += 1
                if outcome.completed.isMultiple(of: Self.chunkSize) { try modelContext.save() }
                if outcome.completed.isMultiple(of: interval) {
                    onProgress(outcome.completed, targets.count)
                }
            }
        } catch {
            try? modelContext.save()
            throw error
        }
        try modelContext.save()
        return outcome
    }

    private func classificationTargets(scope: CategoryManager.Scope) throws -> [Subscription] {
        let subscriptions = try modelContext.fetch(FetchDescriptor<Subscription>(
            sortBy: [SortDescriptor(\.title)]
        ))
        let ruleByChannel = Dictionary(
            try rules().map { ($0.channelId, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        return subscriptions.filter { subscription in
            guard let rule = ruleByChannel[subscription.channelId] else { return true }
            if rule.isUserSet { return false }
            switch scope {
            // A rule the classifier never wrote (e.g. Priority set by hand on
            // a fresh subscription) still counts as unassigned.
            case .unassigned: return rule.classifiedAt == nil
            case .unassignedAndUnsure: return rule.topicCollections.isEmpty
            case .allAutomatic: return true
            }
        }
    }

    private func descriptor(
        for subscription: Subscription,
        recentTitles: Int
    ) throws -> ChannelDescriptor {
        let channelId = subscription.channelId
        var fetch = FetchDescriptor<Video>(
            predicate: #Predicate { $0.channelId == channelId },
            sortBy: [SortDescriptor(\.publishedAt, order: .reverse)]
        )
        fetch.fetchLimit = recentTitles
        let titles = try modelContext.fetch(fetch).map(\.title)
        return ChannelDescriptor(
            channelId: channelId,
            title: subscription.title,
            about: subscription.channelDescription ?? "",
            recentVideoTitles: titles
        )
    }

    /// Writes the classifier's topics onto the channel's rule. The Priority
    /// tag isn't the classifier's to give or take, so it's carried over.
    /// Also records the evidence behind the answer — the model's raw reply
    /// and the channel's dominant YouTube category — so a wrong guess can be
    /// read and the answer exported later. See `ChannelRule.classifierRawAnswer`.
    private func apply(_ guess: CategoryGuess, to subscription: Subscription) throws {
        let all = try topicCategories()
        let collections = guess.categories.compactMap { name in all.first { $0.name == name } }
        let dominantCategoryId = try dominantCategoryId(forChannelId: subscription.channelId)

        if let rule = try rule(forChannelId: subscription.channelId) {
            guard !rule.isUserSet else { return }
            rule.collections = rule.collections.filter(\.isPriority) + collections
            rule.channelTitle = subscription.title
            rule.classifiedAt = .now
            rule.classifierRawAnswer = guess.rawCategories
            rule.classifierResolvedCategories = guess.categories
            rule.classifierDominantCategoryId = dominantCategoryId
        } else {
            let rule = ChannelRule(
                channelId: subscription.channelId,
                channelTitle: subscription.title,
                collections: collections,
                isUserSet: false,
                classifiedAt: .now
            )
            rule.classifierRawAnswer = guess.rawCategories
            rule.classifierResolvedCategories = guess.categories
            rule.classifierDominantCategoryId = dominantCategoryId
            modelContext.insert(rule)
        }
    }

    /// The most common `youtubeCategoryId` among everything we've stored for
    /// a channel. Every stored video votes, not just the recent titles the
    /// prompt shows the model — this is read off YouTube's own metadata, not
    /// the classifier's input.
    private func dominantCategoryId(forChannelId channelId: String) throws -> String? {
        let fetch = FetchDescriptor<Video>(predicate: #Predicate { $0.channelId == channelId })
        let categoryIds = try modelContext.fetch(fetch).map(\.youtubeCategoryId)
        return YouTubeCategory.dominant(among: categoryIds)
    }

    // MARK: - The catalogue, on this context

    /// Priority first, the way `CategoryManager.categories()` orders them.
    private func categories() throws -> [VideoCollection] {
        try modelContext.fetch(FetchDescriptor<VideoCollection>(
            sortBy: [SortDescriptor(\.sortOrder), SortDescriptor(\.name)]
        ))
    }

    /// What the classifier may choose from: everything but Priority.
    private func topicCategories() throws -> [VideoCollection] {
        try categories().filter { !$0.isPriority }
    }

    private func rules() throws -> [ChannelRule] {
        try modelContext.fetch(FetchDescriptor<ChannelRule>())
    }

    private func rule(forChannelId id: String) throws -> ChannelRule? {
        try modelContext.fetch(FetchDescriptor<ChannelRule>(
            predicate: #Predicate { $0.channelId == id }
        )).first
    }

    // MARK: - Export

    /// One subscription's classifier evidence, the shape written out by
    /// `exportClassifierEvidence`.
    struct ChannelClassifierRecord: Codable, Sendable, Equatable {
        var channelId: String
        var channelTitle: String
        /// What the classifier would see today, recomputed live rather than
        /// stored per-channel — the export is the measuring stick for later
        /// classifier changes, so this half of the record should reflect the
        /// current about text and uploads, not a stale snapshot.
        var about: String
        var recentVideoTitles: [String]
        /// The model's verbatim answer from the last automatic pass. Nil
        /// means no automatic pass has recorded evidence: never classified
        /// under this version, or filed by hand from the start.
        var rawAnswer: [String]?
        /// The classifier's resolved categories from that same pass. Nil
        /// alongside `rawAnswer`.
        var resolvedCategories: [String]?
        /// `YouTubeCategory.name(forId:)` of the channel's dominant video
        /// category as of that pass. Nil alongside `rawAnswer`.
        var dominantYouTubeCategory: String?
        var isUserSet: Bool
        /// The categories the user filed the channel under by hand. Present
        /// only when `isUserSet`, so a record with both this and `rawAnswer`
        /// is exactly the case of a corrected automatic answer — the export's
        /// labeled data.
        var userCategories: [String]?
    }

    /// One record per subscribed channel: the measuring stick for later
    /// classifier changes, and the user's hand corrections are its labeled
    /// data. See `ChannelClassifierRecord`.
    func exportClassifierEvidence(recentTitlesPerChannel: Int) throws -> [ChannelClassifierRecord] {
        let subscriptions = try modelContext.fetch(FetchDescriptor<Subscription>(
            sortBy: [SortDescriptor(\.title)]
        ))
        let ruleByChannel = Dictionary(
            try rules().map { ($0.channelId, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        return try subscriptions.map { subscription in
            let rule = ruleByChannel[subscription.channelId]
            let evidence = try descriptor(for: subscription, recentTitles: recentTitlesPerChannel)
            return ChannelClassifierRecord(
                channelId: subscription.channelId,
                channelTitle: subscription.title,
                about: evidence.about,
                recentVideoTitles: evidence.recentVideoTitles,
                rawAnswer: rule?.classifierRawAnswer,
                resolvedCategories: rule?.classifierResolvedCategories,
                dominantYouTubeCategory: rule?.classifierDominantCategoryId.map(YouTubeCategory.name(forId:)),
                isUserSet: rule?.isUserSet ?? false,
                userCategories: (rule?.isUserSet ?? false) ? rule?.topicCollections.map(\.name) : nil
            )
        }
    }
}
