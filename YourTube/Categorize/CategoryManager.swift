import Foundation
import SwiftData
import Observation

/// Owns categories (`VideoCollection`) and channel assignments (`ChannelRule`),
/// and drives the on-device classifier over subscribed channels.
///
/// Classification is one call per channel, run sequentially in the background;
/// a few hundred channels take a few minutes on first launch and are then
/// cached forever as rules. Only channels with no rule are classified
/// automatically. Re-running over everything is an explicit Settings action
/// and still never touches rules the user set by hand.
@Observable
@MainActor
final class CategoryManager {
    enum Status: Equatable {
        case idle
        case running(completed: Int, total: Int)
        case failed(String)
    }

    enum Scope: Equatable {
        /// Channels with no rule at all.
        case unassigned
        /// Unassigned plus channels the classifier previously left uncategorised.
        case unassignedAndUnsure
        /// Every channel except user-set rules.
        case allAutomatic
    }

    /// The taxonomy seeded on first launch. Editable afterwards in Settings.
    static let defaultCategoryNames = [
        "Comedy",
        "Music & Audio Gear",
        "Tech & Engineering",
        "News & Politics",
        "Cars",
        "Film & TV",
        "Games",
        "Science & Explainers",
        "Food",
        "Makers & DIY",
        "Podcasts & Interviews",
        "Other",
    ]

    /// Display name for channels with no collection. Not a real category.
    static let uncategorizedName = "Uncategorized"

    /// Bump when the prompt or answer handling changes in a way that should
    /// give previously-unsure channels another go. Stored in UserDefaults
    /// after a completed run; the next launch after a bump widens the
    /// automatic pass to include unsure channels once.
    static let classifierVersion = 2
    static let classifierVersionKey = "categories.classifierVersion"

    /// Which scope the automatic launch-time pass should use.
    nonisolated static func automaticScope(storedVersion: Int) -> Scope {
        storedVersion < classifierVersion ? .unassignedAndUnsure : .unassigned
    }

    private(set) var status: Status = .idle
    private(set) var lastRunAt: Date?
    /// Channels the model refused or errored on during the last run. They're
    /// left Uncategorised (and marked classified so they aren't retried on
    /// every launch). Surfaced in Settings so a pile-up is visible.
    private(set) var lastRunFailures = 0

    private let modelContext: ModelContext
    private let categorizer: (any ChannelCategorizer)?
    private let defaults: UserDefaults
    private var runningTask: Task<Void, Never>?

    /// Save every N channels so a kill mid-run doesn't lose everything.
    private let saveInterval = 10
    private let recentTitlesPerChannel = 10

    init(
        modelContext: ModelContext,
        categorizer: (any ChannelCategorizer)?,
        defaults: UserDefaults = .standard
    ) {
        self.modelContext = modelContext
        self.categorizer = categorizer
        self.defaults = defaults
    }

    var canClassify: Bool { categorizer != nil }

    var isRunning: Bool {
        if case .running = status { return true }
        return false
    }

    // MARK: - Categories

    func seedDefaultCategoriesIfNeeded() {
        let existing = (try? modelContext.fetchCount(FetchDescriptor<VideoCollection>())) ?? 0
        guard existing == 0 else { return }
        for (index, name) in Self.defaultCategoryNames.enumerated() {
            modelContext.insert(VideoCollection(name: name, isUserCreated: false, sortOrder: index))
        }
        try? modelContext.save()
    }

    func categories() throws -> [VideoCollection] {
        try modelContext.fetch(FetchDescriptor<VideoCollection>(
            sortBy: [SortDescriptor(\.sortOrder), SortDescriptor(\.name)]
        ))
    }

    @discardableResult
    func addCategory(named rawName: String) throws -> VideoCollection? {
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return nil }
        let all = try categories()
        if let existing = all.first(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) {
            return existing
        }
        let nextOrder = (all.map(\.sortOrder).max() ?? -1) + 1
        let collection = VideoCollection(name: name, isUserCreated: true, sortOrder: nextOrder)
        modelContext.insert(collection)
        try modelContext.save()
        return collection
    }

    func rename(_ collection: VideoCollection, to rawName: String) throws {
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name != collection.name else { return }
        collection.name = name
        try modelContext.save()
    }

    /// Deleting a category un-files its channels rather than deleting anything
    /// else. Videos are untouched.
    func delete(_ collection: VideoCollection) throws {
        for rule in try rules() where rule.collection === collection {
            rule.collection = nil
        }
        modelContext.delete(collection)
        try modelContext.save()
    }

    // MARK: - Assignments

    func rules() throws -> [ChannelRule] {
        try modelContext.fetch(FetchDescriptor<ChannelRule>())
    }

    func rule(forChannelId id: String) throws -> ChannelRule? {
        try modelContext.fetch(FetchDescriptor<ChannelRule>(
            predicate: #Predicate { $0.channelId == id }
        )).first
    }

    /// Files a channel by hand. Pass nil to make it Uncategorised. Manual
    /// choices stick: the classifier never overwrites a user-set rule.
    func assign(channelId: String, channelTitle: String, to collection: VideoCollection?) throws {
        if let rule = try rule(forChannelId: channelId) {
            rule.collection = collection
            rule.isUserSet = true
            rule.channelTitle = channelTitle
        } else {
            modelContext.insert(ChannelRule(
                channelId: channelId,
                channelTitle: channelTitle,
                collection: collection,
                isUserSet: true
            ))
        }
        try modelContext.save()
    }

    /// Channel IDs currently filed under a category, or (for nil) under none.
    /// Used to build feed predicates.
    func channelIds(in collection: VideoCollection?) throws -> [String] {
        let subscriptions = try modelContext.fetch(FetchDescriptor<Subscription>())
        let ruleByChannel = Dictionary(
            try rules().map { ($0.channelId, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        return subscriptions.map(\.channelId).filter { id in
            let filed = ruleByChannel[id]?.collection
            if let collection { return filed === collection }
            return filed == nil
        }
    }

    // MARK: - Classification

    /// Fire-and-forget entry point used at launch and after each refresh.
    /// No-op if the model isn't available, a run is already going, or there's
    /// nothing unassigned.
    func classifyUnassignedInBackground() {
        guard canClassify, !isRunning else { return }
        let stored = defaults.integer(forKey: Self.classifierVersionKey)
        let scope = Self.automaticScope(storedVersion: stored)
        runningTask = Task {
            await classify(scope: scope)
            if case .idle = status {
                defaults.set(Self.classifierVersion, forKey: Self.classifierVersionKey)
            }
        }
    }

    func start(scope: Scope) {
        guard !isRunning else { return }
        runningTask = Task { await classify(scope: scope) }
    }

    func cancel() {
        runningTask?.cancel()
    }

    func classify(scope: Scope) async {
        guard let categorizer else {
            status = .failed("Automatic categories aren't available on this device.")
            return
        }
        guard !isRunning else { return }

        do {
            let targets = try targets(for: scope)
            guard !targets.isEmpty else {
                status = .idle
                return
            }
            let names = try categories().map(\.name)
            guard !names.isEmpty else {
                status = .failed("Add at least one category first.")
                return
            }

            status = .running(completed: 0, total: targets.count)
            var completed = 0
            lastRunFailures = 0

            for subscription in targets {
                try Task.checkCancellation()
                let descriptor = try descriptor(for: subscription)
                let guess: CategoryGuess
                do {
                    guess = try await categorizer.categorize(descriptor, among: names)
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    // Typically the model's safety guardrail objecting to a
                    // channel name or title. One bad channel must not abort
                    // the other six hundred; record it as unsure and carry on.
                    lastRunFailures += 1
                    guess = CategoryGuess(category: nil, isConfident: false)
                }
                try apply(guess, to: subscription)

                completed += 1
                status = .running(completed: completed, total: targets.count)
                if completed % saveInterval == 0 { try modelContext.save() }
            }

            try modelContext.save()
            lastRunAt = .now
            status = .idle
        } catch is CancellationError {
            try? modelContext.save()
            status = .idle
        } catch {
            try? modelContext.save()
            status = .failed(error.localizedDescription)
        }
    }

    private func targets(for scope: Scope) throws -> [Subscription] {
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
            case .unassigned: return false
            case .unassignedAndUnsure: return rule.collection == nil
            case .allAutomatic: return true
            }
        }
    }

    private func descriptor(for subscription: Subscription) throws -> ChannelDescriptor {
        let channelId = subscription.channelId
        var fetch = FetchDescriptor<Video>(
            predicate: #Predicate { $0.channelId == channelId },
            sortBy: [SortDescriptor(\.publishedAt, order: .reverse)]
        )
        fetch.fetchLimit = recentTitlesPerChannel
        let titles = try modelContext.fetch(fetch).map(\.title)
        return ChannelDescriptor(
            channelId: channelId,
            title: subscription.title,
            about: subscription.channelDescription ?? "",
            recentVideoTitles: titles
        )
    }

    private func apply(_ guess: CategoryGuess, to subscription: Subscription) throws {
        let collection: VideoCollection? = {
            guard guess.isConfident, let name = guess.category else { return nil }
            return try? categories().first { $0.name == name }
        }()

        if let rule = try rule(forChannelId: subscription.channelId) {
            guard !rule.isUserSet else { return }
            rule.collection = collection
            rule.channelTitle = subscription.title
            rule.classifiedAt = .now
        } else {
            modelContext.insert(ChannelRule(
                channelId: subscription.channelId,
                channelTitle: subscription.title,
                collection: collection,
                isUserSet: false,
                classifiedAt: .now
            ))
        }
    }
}
