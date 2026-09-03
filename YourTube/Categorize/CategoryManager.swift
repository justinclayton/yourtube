import Foundation
import SwiftData
import Observation

/// Owns categories (`VideoCollection`) and channel assignments (`ChannelRule`),
/// and drives the on-device classifier over subscribed channels. A channel can
/// carry up to three topic categories at once, plus the built-in Priority tag,
/// which only the user assigns and which survives every automatic pass.
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

    /// Display name for channels with no topic category. Not a real category.
    static let uncategorizedName = "Uncategorized"

    /// The built-in, hand-picked tag for the few channels the user never wants
    /// to miss. Pinned first in the chip row; the classifier never sees it.
    static let priorityName = "Priority"
    /// Sorts ahead of every editable category, whose orders start at 0.
    static let prioritySortOrder = -1

    struct BuiltInCategoryError: LocalizedError {
        var errorDescription: String? { "The Priority tag can't be renamed or deleted." }
    }

    /// Bump when the prompt or answer handling changes in a way that should
    /// give previously-classified channels another go. Stored in UserDefaults
    /// after a completed run; the next launch after a bump widens the
    /// automatic pass to every non-user-set channel once.
    ///
    /// 3: multi-tagging. Channels filed under one category get a chance to
    /// pick up a second or third.
    static let classifierVersion = 3
    static let classifierVersionKey = "categories.classifierVersion"

    /// Which scope the automatic launch-time pass should use.
    nonisolated static func automaticScope(storedVersion: Int) -> Scope {
        storedVersion < classifierVersion ? .allAutomatic : .unassigned
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

    /// Seeds the taxonomy on first launch, and makes sure the Priority tag
    /// exists on every launch: stores created before it was introduced already
    /// have their defaults but need Priority added.
    func seedDefaultCategoriesIfNeeded() {
        let existing = (try? modelContext.fetchCount(FetchDescriptor<VideoCollection>())) ?? 0
        if existing == 0 {
            for (index, name) in Self.defaultCategoryNames.enumerated() {
                modelContext.insert(VideoCollection(name: name, isUserCreated: false, sortOrder: index))
            }
        }
        seedPriorityIfNeeded()
        try? modelContext.save()
    }

    /// Adds the Priority tag if the store has none. A user-made category
    /// already called "Priority" is promoted rather than colliding with the
    /// unique name constraint.
    private func seedPriorityIfNeeded() {
        let all = (try? categories()) ?? []
        guard !all.contains(where: { $0.isPriority }) else { return }
        if let named = all.first(where: { $0.name.caseInsensitiveCompare(Self.priorityName) == .orderedSame }) {
            named.isPriority = true
            named.isUserCreated = false
            named.sortOrder = Self.prioritySortOrder
            return
        }
        modelContext.insert(VideoCollection(
            name: Self.priorityName,
            isUserCreated: false,
            sortOrder: Self.prioritySortOrder,
            isPriority: true
        ))
    }

    /// Every category, Priority first.
    func categories() throws -> [VideoCollection] {
        try modelContext.fetch(FetchDescriptor<VideoCollection>(
            sortBy: [SortDescriptor(\.sortOrder), SortDescriptor(\.name)]
        ))
    }

    /// The categories the classifier may choose from: everything but Priority.
    func topicCategories() throws -> [VideoCollection] {
        try categories().filter { !$0.isPriority }
    }

    func priorityCategory() throws -> VideoCollection? {
        try categories().first { $0.isPriority }
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
        guard !collection.isPriority else { throw BuiltInCategoryError() }
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name != collection.name else { return }
        collection.name = name
        try modelContext.save()
    }

    /// Deleting a category removes it from every rule, leaving the rules'
    /// other categories in place. Videos are untouched.
    func delete(_ collection: VideoCollection) throws {
        guard !collection.isPriority else { throw BuiltInCategoryError() }
        for rule in try rules() where rule.contains(collection) {
            rule.collections.removeAll { $0 === collection }
        }
        modelContext.delete(collection)
        try modelContext.save()
    }

    // MARK: - Assignments

    /// Folds pre-multi-tag rules into the new shape: a channel filed under X
    /// becomes filed under exactly {X}, keeping its user-set flag. Idempotent
    /// and cheap when there's nothing left to migrate; run once per launch.
    @discardableResult
    func migrateLegacyRules() throws -> Int {
        var migrated = 0
        for rule in try rules() {
            guard let legacy = rule.collection else { continue }
            if rule.collections.isEmpty {
                rule.collections = [legacy]
            }
            rule.collection = nil
            migrated += 1
        }
        if migrated > 0 { try modelContext.save() }
        return migrated
    }

    func rules() throws -> [ChannelRule] {
        try modelContext.fetch(FetchDescriptor<ChannelRule>())
    }

    func rule(forChannelId id: String) throws -> ChannelRule? {
        try modelContext.fetch(FetchDescriptor<ChannelRule>(
            predicate: #Predicate { $0.channelId == id }
        )).first
    }

    /// Files a channel by hand under any number of topic categories; an empty
    /// list makes it Uncategorised. Manual choices stick: the classifier never
    /// overwrites a user-set rule. The Priority tag is separate: it's kept as
    /// it was, and only `setPriority` changes it.
    func assign(channelId: String, channelTitle: String, to collections: [VideoCollection]) throws {
        let topics = collections.filter { !$0.isPriority }
        if let rule = try rule(forChannelId: channelId) {
            rule.collections = unique(rule.collections.filter(\.isPriority) + topics)
            rule.isUserSet = true
            rule.channelTitle = channelTitle
        } else {
            modelContext.insert(ChannelRule(
                channelId: channelId,
                channelTitle: channelTitle,
                collections: unique(topics),
                isUserSet: true
            ))
        }
        try modelContext.save()
    }

    /// Adds or removes the Priority tag on a channel. Deliberately does not
    /// mark the rule user-set: flagging a channel as important says nothing
    /// about its topic, so the classifier should still file (and re-file) it.
    func setPriority(_ isPriority: Bool, channelId: String, channelTitle: String) throws {
        guard let priority = try priorityCategory() else { throw BuiltInCategoryError() }
        if let rule = try rule(forChannelId: channelId) {
            var current = rule.collections.filter { !$0.isPriority }
            if isPriority { current.insert(priority, at: 0) }
            rule.collections = current
            rule.channelTitle = channelTitle
        } else if isPriority {
            modelContext.insert(ChannelRule(
                channelId: channelId,
                channelTitle: channelTitle,
                collections: [priority],
                isUserSet: false
            ))
        }
        try modelContext.save()
    }

    func isPriority(channelId: String) throws -> Bool {
        try rule(forChannelId: channelId)?.isPriority ?? false
    }

    private func unique(_ collections: [VideoCollection]) -> [VideoCollection] {
        collections.reduce(into: [VideoCollection]()) { acc, c in
            if !acc.contains(where: { $0 === c }) { acc.append(c) }
        }
    }

    /// Adds or removes one topic category on a channel's rule, keeping the
    /// others. Marks the rule user-set like `assign`. For Priority, use
    /// `setPriority`.
    func toggle(_ collection: VideoCollection, channelId: String, channelTitle: String) throws {
        guard !collection.isPriority else {
            try setPriority(!isPriority(channelId: channelId), channelId: channelId, channelTitle: channelTitle)
            return
        }
        var current = try rule(forChannelId: channelId)?.topicCollections ?? []
        if current.contains(where: { $0 === collection }) {
            current.removeAll { $0 === collection }
        } else {
            current.append(collection)
        }
        try assign(channelId: channelId, channelTitle: channelTitle, to: current)
    }

    /// Channel IDs whose tag set contains a category, or (for nil) has no
    /// topic category. Used to build feed predicates. Priority is a tag like
    /// any other here, so a channel that is Priority and Comedy is in both.
    func channelIds(in collection: VideoCollection?) throws -> [String] {
        let subscriptions = try modelContext.fetch(FetchDescriptor<Subscription>())
        let ruleByChannel = Dictionary(
            try rules().map { ($0.channelId, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        return subscriptions.map(\.channelId).filter { id in
            guard let rule = ruleByChannel[id] else { return collection == nil }
            if let collection { return rule.contains(collection) }
            return rule.topicCollections.isEmpty
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
            let names = try topicCategories().map(\.name)
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
                    guess = .unsure
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
            // A rule the classifier never wrote (e.g. Priority set by hand on
            // a fresh subscription) still counts as unassigned.
            case .unassigned: return rule.classifiedAt == nil
            case .unassignedAndUnsure: return rule.topicCollections.isEmpty
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

    /// Writes the classifier's topics onto the channel's rule. The Priority
    /// tag isn't the classifier's to give or take, so it's carried over.
    private func apply(_ guess: CategoryGuess, to subscription: Subscription) throws {
        let all = try topicCategories()
        let collections = guess.categories.compactMap { name in all.first { $0.name == name } }

        if let rule = try rule(forChannelId: subscription.channelId) {
            guard !rule.isUserSet else { return }
            rule.collections = rule.collections.filter(\.isPriority) + collections
            rule.channelTitle = subscription.title
            rule.classifiedAt = .now
        } else {
            modelContext.insert(ChannelRule(
                channelId: subscription.channelId,
                channelTitle: subscription.title,
                collections: collections,
                isUserSet: false,
                classifiedAt: .now
            ))
        }
    }
}
