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
        let targets = try classificationTargets(scope: scope, recentTitlesPerChannel: recentTitlesPerChannel)
        guard !targets.isEmpty else { return ClassifyOutcome() }
        let names = try topicCategories().map(\.name)
        guard !names.isEmpty else { throw StoreWriterError.noTopicCategories }

        var outcome = ClassifyOutcome(total: targets.count)
        onProgress(0, targets.count)
        let interval = Self.progressInterval(total: targets.count)

        do {
            for subscription in targets {
                try Task.checkCancellation()
                let videos = try recentVideos(forChannelId: subscription.channelId, limit: recentTitlesPerChannel)
                let channelDescriptor = try descriptor(
                    for: subscription,
                    recentTitles: recentTitlesPerChannel,
                    taxonomy: names
                )
                let answer: CategoryGuess
                do {
                    answer = try await categorizer.categorize(channelDescriptor, among: names)
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    // Typically the model's safety guardrail objecting to a
                    // channel name or title. One bad channel must not abort
                    // the other six hundred; record it as unsure and carry on.
                    outcome.failures += 1
                    answer = .unsure
                }
                // The model gives one category; YouTube's own filing gives the
                // only possible second. See `CategoryDecision`.
                let guess = CategoryDecision.decide(
                    modelAnswer: answer, youtube: channelDescriptor.youtubeSignal, taxonomy: names
                )
                try apply(guess, recentVideoIds: videos.map(\.videoId), to: subscription)

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

    private func classificationTargets(
        scope: CategoryManager.Scope,
        recentTitlesPerChannel: Int
    ) throws -> [Subscription] {
        let subscriptions = try modelContext.fetch(FetchDescriptor<Subscription>(
            sortBy: [SortDescriptor(\.title)]
        ))
        let ruleByChannel = Dictionary(
            try rules().map { ($0.channelId, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        return try subscriptions.filter { subscription in
            guard let rule = ruleByChannel[subscription.channelId] else { return true }
            if rule.isUserSet { return false }
            switch scope {
            // A rule the classifier never wrote (e.g. Priority set by hand on
            // a fresh subscription) still counts as unassigned. One it did
            // write is unassigned again once its recent uploads have turned
            // over enough — see `CategoryManager.hasTurnedOver`.
            case .unassigned:
                guard rule.classifiedAt != nil else { return true }
                let currentIds = try recentVideos(
                    forChannelId: subscription.channelId, limit: recentTitlesPerChannel
                ).map(\.videoId)
                return CategoryManager.hasTurnedOver(
                    previousVideoIds: rule.classifierRecentVideoIds,
                    currentVideoIds: currentIds,
                    windowSize: recentTitlesPerChannel
                )
            case .unassignedAndUnsure: return rule.topicCollections.isEmpty
            case .allAutomatic: return true
            }
        }
    }

    /// A channel's most recent uploads, newest first — the same window the
    /// classifier prompt and the turnover check both read from.
    private func recentVideos(forChannelId channelId: String, limit: Int) throws -> [Video] {
        var fetch = FetchDescriptor<Video>(
            predicate: #Predicate { $0.channelId == channelId },
            sortBy: [SortDescriptor(\.publishedAt, order: .reverse)]
        )
        fetch.fetchLimit = limit
        return try modelContext.fetch(fetch)
    }

    /// Exactly what the classifier is shown for one channel: its title, about
    /// text, recent titles, and — when YouTube's own filing says something —
    /// that as a prior. `taxonomy` is what the signal has to land in to count;
    /// pass nil to build the descriptor without one (the export, which shows
    /// YouTube's category separately).
    private func descriptor(
        for subscription: Subscription,
        recentTitles: Int,
        taxonomy: [String]? = nil
    ) throws -> ChannelDescriptor {
        let videos = try recentVideos(forChannelId: subscription.channelId, limit: recentTitles)
        return ChannelDescriptor(
            channelId: subscription.channelId,
            title: subscription.title,
            about: subscription.channelDescription ?? "",
            recentVideoTitles: videos.map(\.title),
            youtubeSignal: try taxonomy.flatMap {
                try youtubeSuggestion(forChannelId: subscription.channelId, taxonomy: $0)
            }
        )
    }

    /// YouTube's own filing for a channel, as a taxonomy category: a majority
    /// vote over every stored video's `snippet.categoryId`, the same
    /// population `dominantCategoryId` reads. Nil when there's no clear
    /// majority or the majority is one of YouTube's catch-alls — see
    /// `YouTubeCategorySignal`.
    private func youtubeSuggestion(
        forChannelId channelId: String,
        taxonomy: [String]
    ) throws -> YouTubeCategorySuggestion? {
        let fetch = FetchDescriptor<Video>(predicate: #Predicate { $0.channelId == channelId })
        let signals = try modelContext.fetch(fetch).map {
            EpisodeSignals(
                durationSeconds: $0.durationSeconds,
                publishedAt: $0.publishedAt,
                title: $0.title,
                categoryId: $0.youtubeCategoryId
            )
        }
        return YouTubeCategorySignal.suggestion(for: signals, taxonomy: taxonomy)
    }

    /// Writes the classifier's topics onto the channel's rule. The Priority
    /// tag isn't the classifier's to give or take, so it's carried over.
    /// Also records the evidence behind the answer — the model's raw reply,
    /// the channel's dominant YouTube category, and the `videoId`s of the
    /// recent-titles window it was shown — so a wrong guess can be read, the
    /// answer exported later, and the routine pass can tell when this
    /// channel's uploads have turned over enough to ask again. See
    /// `ChannelRule.classifierRawAnswer` and `.classifierRecentVideoIds`.
    private func apply(_ guess: CategoryGuess, recentVideoIds: [String], to subscription: Subscription) throws {
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
            rule.classifierModelCategory = guess.modelCategory
            rule.classifierYouTubeCategory = guess.youtubeCategory
            rule.classifierYouTubeReason = guess.youtubeReason
            rule.classifierDominantCategoryId = dominantCategoryId
            rule.classifierRecentVideoIds = recentVideoIds
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
            rule.classifierModelCategory = guess.modelCategory
            rule.classifierYouTubeCategory = guess.youtubeCategory
            rule.classifierYouTubeReason = guess.youtubeReason
            rule.classifierDominantCategoryId = dominantCategoryId
            rule.classifierRecentVideoIds = recentVideoIds
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
        /// The classifier's resolved categories from that same pass — the
        /// model's first, YouTube's second when there is one. Nil alongside
        /// `rawAnswer`.
        var resolvedCategories: [String]?
        /// Which of `resolvedCategories` the model chose. Nil when the model
        /// gave nothing usable, or for a rule classified before v4.
        var modelCategory: String?
        /// The category YouTube's own filing added, present only when it
        /// differs from `modelCategory`. Together with it, this is what makes
        /// a wrong chip attributable to one source or the other.
        var youtubeCategory: String?
        /// Why `youtubeCategory` is there, in the signal's own words.
        var youtubeReason: String?
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
                modelCategory: rule?.classifierModelCategory,
                youtubeCategory: rule?.classifierYouTubeCategory,
                youtubeReason: rule?.classifierYouTubeReason,
                dominantYouTubeCategory: rule?.classifierDominantCategoryId.map(YouTubeCategory.name(forId:)),
                isUserSet: rule?.isUserSet ?? false,
                userCategories: (rule?.isUserSet ?? false) ? rule?.topicCollections.map(\.name) : nil
            )
        }
    }
}
