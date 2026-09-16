import Foundation
import SwiftData
import Observation

/// Owns categories (`VideoCollection`) and channel assignments (`ChannelRule`),
/// and drives the on-device classifier over subscribed channels. A channel
/// carries at most two automatic topic categories — one from the model, one
/// from YouTube's own filing (see `CategoryDecision`) — plus the built-in
/// Priority tag, which only the user assigns and which survives every
/// automatic pass.
///
/// Classification is one call per channel, run sequentially in the background;
/// a few hundred channels take a few minutes on first launch and are then
/// cached forever as rules. Only channels with no rule are classified
/// automatically. Re-running over everything is an explicit Settings action
/// and still never touches rules the user set by hand.
///
/// The run itself is on `StoreWriter`, off the main context, so several
/// minutes of classification cost a scrolling feed nothing. What the user
/// edits by hand — the taxonomy, a channel's filing, the Priority tag — stays
/// here on the main context, where a tap should reach the screen at once.
@Observable
@MainActor
final class CategoryManager {
    enum Status: Equatable {
        case idle
        case running(completed: Int, total: Int)
        case failed(String)
    }

    enum Scope: Equatable, Sendable {
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
    /// 4: one grounded answer. The model is constrained to a single on-list
    /// category and sampled greedily, and a second category can only come
    /// from YouTube's own filing — so every channel padded out to two or
    /// three guesses needs re-sorting once.
    static let classifierVersion = 4
    static let classifierVersionKey = "categories.classifierVersion"

    /// Which scope the automatic launch-time pass should use.
    nonisolated static func automaticScope(storedVersion: Int) -> Scope {
        storedVersion < classifierVersion ? .allAutomatic : .unassigned
    }

    /// Whether an automatically-filed channel's recent uploads have turned
    /// over enough to be worth asking the classifier about again. Compares
    /// the `videoId`s in the current recent-titles window against the ones
    /// recorded at the last automatic pass (`ChannelRule.classifierRecentVideoIds`),
    /// the way `ShowDetectionRunner.fingerprint` tracks a channel's shape for
    /// the show detector.
    ///
    /// A single new upload isn't enough — a weekly show would get re-filed
    /// every week — so the bar is a majority of the window being new, with a
    /// floor of two regardless of how small the window is. A rule with no
    /// recorded fingerprint (classified before this existed, or classified
    /// with the window empty) is treated as due, so it picks up a baseline on
    /// the next pass rather than never being looked at again.
    nonisolated static func hasTurnedOver(
        previousVideoIds: [String]?,
        currentVideoIds: [String],
        windowSize: Int
    ) -> Bool {
        guard let previousVideoIds else { return true }
        let threshold = max(2, windowSize / 2)
        let newCount = Set(currentVideoIds).subtracting(previousVideoIds).count
        return newCount >= threshold
    }

    private(set) var status: Status = .idle
    private(set) var lastRunAt: Date?
    /// Channels the model refused or errored on during the last run. They're
    /// left Uncategorised (and marked classified so they aren't retried on
    /// every launch). Surfaced in Settings so a pile-up is visible.
    private(set) var lastRunFailures = 0

    private let modelContext: ModelContext
    private let writer: StoreWriter
    private let categorizer: (any ChannelCategorizer)?
    private let defaults: UserDefaults
    private var runningTask: Task<Void, Never>?

    private let recentTitlesPerChannel = 10

    init(
        modelContext: ModelContext,
        categorizer: (any ChannelCategorizer)?,
        defaults: UserDefaults = .standard,
        writer: StoreWriter? = nil
    ) {
        self.modelContext = modelContext
        self.writer = writer ?? StoreWriter(modelContainer: modelContext.container)
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

    /// The chip row's names, in display order: every category (Priority
    /// first, by sort order) plus Uncategorized. The one place the Feed,
    /// Your Shows and Channels all read the chip list from, so adding,
    /// renaming or deleting a category can't drift out of sync between them.
    func chipNames() throws -> [String] {
        try categories().map(\.name) + [Self.uncategorizedName]
    }

    /// Channel IDs a chip leaves, in the chip's own vocabulary: nil or empty
    /// is "All" (every subscribed channel), `uncategorizedName` is channels
    /// with no topic category, and any other name is channels whose rule
    /// carries a category of that name. A channel appears under every chip
    /// it carries, Priority included, so a channel that is Priority and
    /// Comedy is under both. The one derivation the Feed, Your Shows and
    /// Channels all filter through.
    func channelIds(in categoryName: String?) throws -> [String] {
        let subscriptions = try modelContext.fetch(FetchDescriptor<Subscription>())
        guard let categoryName, !categoryName.isEmpty else {
            return subscriptions.map(\.channelId)
        }
        let ruleByChannel = Dictionary(
            try rules().map { ($0.channelId, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        return subscriptions.map(\.channelId).filter { id in
            guard let rule = ruleByChannel[id] else {
                return categoryName == Self.uncategorizedName
            }
            if categoryName == Self.uncategorizedName {
                return rule.topicCollections.isEmpty
            }
            return rule.collections.contains { $0.name == categoryName }
        }
    }

    /// Channel ids carrying the Priority tag. Used to pin Priority channels
    /// first within a chip's filtered list — Your Shows and Channels both
    /// do this; the Feed doesn't, since it's ordered by publish date instead.
    func priorityChannelIds() throws -> Set<String> {
        Set(try rules().filter(\.isPriority).map(\.channelId))
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

        status = .running(completed: 0, total: 0)
        lastRunFailures = 0
        do {
            let outcome = try await writer.classifyChannels(
                scope: scope,
                using: categorizer,
                recentTitlesPerChannel: recentTitlesPerChannel,
                onProgress: { [weak self] completed, total in
                    Task { @MainActor in self?.reportProgress(completed, total) }
                }
            )
            lastRunFailures = outcome.failures
            if outcome.total > 0 { lastRunAt = .now }
            status = .idle
        } catch is CancellationError {
            status = .idle
        } catch {
            status = .failed(error.localizedDescription)
        }
    }

    /// Progress is a hop to the main actor, so it can land after the run it
    /// belongs to has already finished. A finished run's status stands.
    private func reportProgress(_ completed: Int, _ total: Int) {
        guard case .running = status else { return }
        status = .running(completed: completed, total: total)
    }

    // MARK: - Export

    /// One JSON document, one record per subscribed channel: what the
    /// classifier saw and answered, and any correction the user has since
    /// made by hand. See `StoreWriter.ChannelClassifierRecord`.
    func exportClassifierEvidence() async throws -> Data {
        let records = try await writer.exportClassifierEvidence(recentTitlesPerChannel: recentTitlesPerChannel)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(records)
    }
}
