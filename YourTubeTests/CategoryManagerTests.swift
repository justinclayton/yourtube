import XCTest
import SwiftData
@testable import YourTube

/// Answers from a lookup table so the manager's bookkeeping can be tested
/// without the on-device model.
private struct StubCategorizer: ChannelCategorizer {
    struct Refused: Error {}

    var answers: [String: CategoryGuess]
    var fallback = CategoryGuess(categories: ["Other"])
    /// Titles the stub throws on, standing in for a guardrail refusal.
    var refuses: Set<String> = []

    func categorize(_ channel: ChannelDescriptor, among categories: [String]) async throws -> CategoryGuess {
        if refuses.contains(channel.title) { throw Refused() }
        return answers[channel.title] ?? fallback
    }
}

private func guess(_ names: String...) -> CategoryGuess { CategoryGuess(categories: names) }

@MainActor
final class CategoryManagerTests: XCTestCase {
    private var container: ModelContainer!
    private var context: ModelContext { container.mainContext }

    override func setUp() async throws {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        container = try ModelContainer(
            for: Video.self, Subscription.self, VideoCollection.self, ChannelRule.self,
            configurations: config
        )
    }

    private func makeManager(_ categorizer: (any ChannelCategorizer)?) -> CategoryManager {
        let manager = CategoryManager(modelContext: context, categorizer: categorizer)
        manager.seedDefaultCategoriesIfNeeded()
        return manager
    }

    private func subscribe(_ title: String, id: String? = nil) -> Subscription {
        let sub = Subscription(channelId: id ?? "UC-\(title)", title: title)
        context.insert(sub)
        return sub
    }

    // MARK: - Seeding

    func testSeedsDefaultsOnceOnly() throws {
        let manager = makeManager(nil)
        manager.seedDefaultCategoriesIfNeeded()
        let names = try manager.categories().map(\.name)
        XCTAssertEqual(names, [CategoryManager.priorityName] + CategoryManager.defaultCategoryNames)
        XCTAssertEqual(try manager.topicCategories().map(\.name), CategoryManager.defaultCategoryNames)
    }

    // MARK: - Priority

    func testPriorityIsSeededFirstAndNotUserCreated() throws {
        let manager = makeManager(nil)
        let priority = try XCTUnwrap(manager.priorityCategory())
        XCTAssertEqual(try manager.categories().first?.name, CategoryManager.priorityName)
        XCTAssertFalse(priority.isUserCreated)
        XCTAssertEqual(try manager.categories().filter(\.isPriority).count, 1)
    }

    /// A store from before the Priority tag existed has its defaults but no
    /// Priority; the next launch adds it without re-seeding the rest.
    func testPriorityIsAddedToExistingStore() throws {
        context.insert(VideoCollection(name: "Cars", isUserCreated: false, sortOrder: 0))
        context.insert(VideoCollection(name: "Mine", isUserCreated: true, sortOrder: 1))
        try context.save()
        let manager = makeManager(nil)
        XCTAssertEqual(try manager.categories().map(\.name), [CategoryManager.priorityName, "Cars", "Mine"])
    }

    func testUserMadePriorityCategoryIsPromotedNotDuplicated() throws {
        context.insert(VideoCollection(name: "priority", isUserCreated: true, sortOrder: 5))
        try context.save()
        let manager = makeManager(nil)
        let priorities = try manager.categories().filter(\.isPriority)
        XCTAssertEqual(priorities.count, 1)
        XCTAssertEqual(priorities.first?.name, "priority")
        XCTAssertEqual(try manager.categories().first?.isPriority, true)
    }

    func testPriorityCannotBeRenamedOrDeleted() throws {
        let manager = makeManager(nil)
        let priority = try XCTUnwrap(manager.priorityCategory())
        XCTAssertThrowsError(try manager.rename(priority, to: "Favourites"))
        XCTAssertThrowsError(try manager.delete(priority))
        XCTAssertEqual(priority.name, CategoryManager.priorityName)
        XCTAssertNotNil(try manager.priorityCategory())
    }

    func testClassifierNeverSeesPriority() async throws {
        final class Recorder: ChannelCategorizer, @unchecked Sendable {
            var seen: [String] = []
            func categorize(_ channel: ChannelDescriptor, among categories: [String]) async throws -> CategoryGuess {
                seen = categories
                return CategoryGuess(categories: [CategoryManager.priorityName, "Cars"])
            }
        }
        let recorder = Recorder()
        let manager = makeManager(recorder)
        let sub = subscribe("Sneaky")

        await manager.classify(scope: .unassigned)

        XCTAssertFalse(recorder.seen.contains(CategoryManager.priorityName))
        XCTAssertEqual(try manager.rule(forChannelId: sub.channelId)?.collections.map(\.name), ["Cars"],
                       "an off-list Priority answer is dropped, never assigned")
    }

    func testSetPriorityTogglesTagWithoutLockingTopics() async throws {
        let stub = StubCategorizer(answers: ["Fresh": guess("Cars")])
        let manager = makeManager(stub)
        let sub = subscribe("Fresh")

        try manager.setPriority(true, channelId: sub.channelId, channelTitle: sub.title)
        var rule = try XCTUnwrap(manager.rule(forChannelId: sub.channelId))
        XCTAssertTrue(rule.isPriority)
        XCTAssertFalse(rule.isUserSet, "priority alone doesn't count as manual filing")
        XCTAssertTrue(try manager.isPriority(channelId: sub.channelId))

        // The launch-time pass still files a priority-only channel.
        await manager.classify(scope: .unassigned)
        rule = try XCTUnwrap(manager.rule(forChannelId: sub.channelId))
        XCTAssertEqual(Set(rule.collections.map(\.name)), [CategoryManager.priorityName, "Cars"])

        try manager.setPriority(false, channelId: sub.channelId, channelTitle: sub.title)
        rule = try XCTUnwrap(manager.rule(forChannelId: sub.channelId))
        XCTAssertEqual(rule.collections.map(\.name), ["Cars"])
        XCTAssertFalse(try manager.isPriority(channelId: sub.channelId))
    }

    func testResortKeepsPriorityAndReplacesTopics() async throws {
        var stub = StubCategorizer(answers: ["Keep": guess("Cars")])
        let manager = makeManager(stub)
        let sub = subscribe("Keep")
        await manager.classify(scope: .unassigned)
        try manager.setPriority(true, channelId: sub.channelId, channelTitle: sub.title)

        stub.answers["Keep"] = guess("Food")
        let manager2 = CategoryManager(modelContext: context, categorizer: stub)
        await manager2.classify(scope: .allAutomatic)

        let rule = try XCTUnwrap(manager2.rule(forChannelId: sub.channelId))
        XCTAssertEqual(Set(rule.collections.map(\.name)), [CategoryManager.priorityName, "Food"])
    }

    func testManualFilingKeepsPriority() throws {
        let manager = makeManager(nil)
        let sub = subscribe("Manual")
        let comedy = try XCTUnwrap(manager.categories().first { $0.name == "Comedy" })
        try manager.setPriority(true, channelId: sub.channelId, channelTitle: sub.title)

        try manager.assign(channelId: sub.channelId, channelTitle: sub.title, to: [comedy])
        var rule = try XCTUnwrap(manager.rule(forChannelId: sub.channelId))
        XCTAssertEqual(Set(rule.collections.map(\.name)), [CategoryManager.priorityName, "Comedy"])
        XCTAssertTrue(rule.isUserSet)

        // Filing as Uncategorised clears topics, not Priority.
        try manager.assign(channelId: sub.channelId, channelTitle: sub.title, to: [])
        rule = try XCTUnwrap(manager.rule(forChannelId: sub.channelId))
        XCTAssertEqual(rule.collections.map(\.name), [CategoryManager.priorityName])
        XCTAssertTrue(rule.topicCollections.isEmpty)
    }

    /// Priority and Comedy at once: the channel is under both chips, and a
    /// priority-only channel still counts as Uncategorised for filing.
    func testPriorityChannelAppearsUnderBothChips() throws {
        let manager = makeManager(nil)
        let both = subscribe("Both")
        let onlyPriority = subscribe("OnlyPriority")
        let comedy = try XCTUnwrap(manager.categories().first { $0.name == "Comedy" })
        let priority = try XCTUnwrap(manager.priorityCategory())
        try manager.assign(channelId: both.channelId, channelTitle: both.title, to: [comedy])
        try manager.setPriority(true, channelId: both.channelId, channelTitle: both.title)
        try manager.setPriority(true, channelId: onlyPriority.channelId, channelTitle: onlyPriority.title)

        XCTAssertEqual(Set(try manager.channelIds(in: priority)), Set([both.channelId, onlyPriority.channelId]))
        XCTAssertEqual(try manager.channelIds(in: comedy), [both.channelId])
        XCTAssertEqual(try manager.channelIds(in: nil), [onlyPriority.channelId])
    }

    // MARK: - Classification

    func testConfidentGuessFilesChannel() async throws {
        let stub = StubCategorizer(answers: [
            "Auto Focus": guess("Cars"),
        ])
        let manager = makeManager(stub)
        let sub = subscribe("Auto Focus")

        await manager.classify(scope: .unassigned)

        let rule = try XCTUnwrap(manager.rule(forChannelId: sub.channelId))
        XCTAssertEqual(rule.collections.map(\.name), ["Cars"])
        XCTAssertFalse(rule.isUserSet)
        XCTAssertNotNil(rule.classifiedAt)
        XCTAssertEqual(manager.status, .idle)
    }

    func testUnsureGuessLeavesChannelUncategorisedButRecorded() async throws {
        let stub = StubCategorizer(answers: [
            "Mystery": .unsure,
        ])
        let manager = makeManager(stub)
        let sub = subscribe("Mystery")

        await manager.classify(scope: .unassigned)

        let rule = try XCTUnwrap(manager.rule(forChannelId: sub.channelId))
        XCTAssertTrue(rule.collections.isEmpty)
        XCTAssertNotNil(rule.classifiedAt, "should not be retried on the next unassigned pass")
    }

    func testMultipleAnswersFileChannelUnderEach() async throws {
        let stub = StubCategorizer(answers: [
            "Neal Brennan": guess("Podcasts & Interviews", "Comedy"),
        ])
        let manager = makeManager(stub)
        let sub = subscribe("Neal Brennan")

        await manager.classify(scope: .unassigned)

        let rule = try XCTUnwrap(manager.rule(forChannelId: sub.channelId))
        XCTAssertEqual(Set(rule.collections.map(\.name)), ["Podcasts & Interviews", "Comedy"])
    }

    /// Names the manager can't find in the list are skipped, not fatal.
    func testUnknownNamesInGuessAreDroppedIndividually() async throws {
        let stub = StubCategorizer(answers: [
            "Mixed": guess("Cars", "Sports"),
        ])
        let manager = makeManager(stub)
        let sub = subscribe("Mixed")

        await manager.classify(scope: .unassigned)

        XCTAssertEqual(try manager.rule(forChannelId: sub.channelId)?.collections.map(\.name), ["Cars"])
    }

    func testUnassignedScopeSkipsAlreadyClassified() async throws {
        var stub = StubCategorizer(answers: [
            "A": guess("Cars"),
        ])
        let manager = makeManager(stub)
        let sub = subscribe("A")
        await manager.classify(scope: .unassigned)

        // The model changes its mind; an unassigned pass must not re-ask.
        stub.answers["A"] = guess("Food")
        let manager2 = CategoryManager(modelContext: context, categorizer: stub)
        await manager2.classify(scope: .unassigned)
        XCTAssertEqual(try manager2.rule(forChannelId: sub.channelId)?.collections.map(\.name), ["Cars"])

        // But a full automatic re-run does.
        await manager2.classify(scope: .allAutomatic)
        XCTAssertEqual(try manager2.rule(forChannelId: sub.channelId)?.collections.map(\.name), ["Food"])
    }

    func testUserSetRuleSurvivesFullRerun() async throws {
        let stub = StubCategorizer(answers: [
            "Hand filed": guess("Games"),
        ])
        let manager = makeManager(stub)
        let sub = subscribe("Hand filed")
        let comedy = try XCTUnwrap(manager.categories().first { $0.name == "Comedy" })
        let food = try XCTUnwrap(manager.categories().first { $0.name == "Food" })
        try manager.assign(channelId: sub.channelId, channelTitle: sub.title, to: [comedy, food])

        await manager.classify(scope: .allAutomatic)

        let rule = try XCTUnwrap(manager.rule(forChannelId: sub.channelId))
        XCTAssertEqual(Set(rule.collections.map(\.name)), ["Comedy", "Food"])
        XCTAssertTrue(rule.isUserSet)
    }

    func testUnsureChannelsAreRetriedOnlyInWiderScope() async throws {
        var stub = StubCategorizer(answers: [
            "Later": .unsure,
        ])
        let manager = makeManager(stub)
        let sub = subscribe("Later")
        await manager.classify(scope: .unassigned)
        XCTAssertEqual(try manager.rule(forChannelId: sub.channelId)?.collections.isEmpty, true)

        stub.answers["Later"] = guess("Food")
        let manager2 = CategoryManager(modelContext: context, categorizer: stub)
        await manager2.classify(scope: .unassigned)
        XCTAssertEqual(try manager2.rule(forChannelId: sub.channelId)?.collections.isEmpty, true)

        await manager2.classify(scope: .unassignedAndUnsure)
        XCTAssertEqual(try manager2.rule(forChannelId: sub.channelId)?.collections.map(\.name), ["Food"])
    }

    /// A guardrail refusal on one channel must not abort the run.
    func testRefusedChannelIsRecordedUnsureAndRunContinues() async throws {
        let stub = StubCategorizer(
            answers: ["Fine": guess("Cars")],
            refuses: ["🛑 Blocked"]
        )
        let manager = makeManager(stub)
        let blocked = subscribe("🛑 Blocked")   // sorts first by title
        let fine = subscribe("Fine")

        await manager.classify(scope: .unassigned)

        XCTAssertEqual(manager.status, .idle)
        XCTAssertEqual(manager.lastRunFailures, 1)
        let blockedRule = try XCTUnwrap(manager.rule(forChannelId: blocked.channelId))
        XCTAssertTrue(blockedRule.collections.isEmpty)
        XCTAssertNotNil(blockedRule.classifiedAt)
        XCTAssertEqual(try manager.rule(forChannelId: fine.channelId)?.collections.map(\.name), ["Cars"])
    }

    func testNoCategorizerFailsCleanly() async throws {
        let manager = makeManager(nil)
        _ = subscribe("Anything")
        await manager.classify(scope: .unassigned)
        if case .failed = manager.status {} else {
            XCTFail("expected failed status, got \(manager.status)")
        }
        XCTAssertFalse(manager.canClassify)
    }

    // MARK: - Category editing

    func testDeletingCategoryRemovesItFromRulesButKeepsOtherCategories() async throws {
        let stub = StubCategorizer(answers: [
            "X": guess("Cars"),
            "Y": guess("Cars", "Comedy"),
        ])
        let manager = makeManager(stub)
        let x = subscribe("X")
        let y = subscribe("Y")
        await manager.classify(scope: .unassigned)
        let cars = try XCTUnwrap(manager.categories().first { $0.name == "Cars" })

        try manager.delete(cars)

        XCTAssertEqual(try manager.rule(forChannelId: x.channelId)?.collections.isEmpty, true)
        XCTAssertEqual(try manager.rule(forChannelId: y.channelId)?.collections.map(\.name), ["Comedy"])
        XCTAssertFalse(try manager.categories().contains { $0.name == "Cars" })
    }

    func testToggleAddsAndRemovesOneCategoryAndMarksUserSet() async throws {
        let stub = StubCategorizer(answers: ["T": guess("Cars")])
        let manager = makeManager(stub)
        let sub = subscribe("T")
        await manager.classify(scope: .unassigned)
        let comedy = try XCTUnwrap(manager.categories().first { $0.name == "Comedy" })
        let cars = try XCTUnwrap(manager.categories().first { $0.name == "Cars" })

        try manager.toggle(comedy, channelId: sub.channelId, channelTitle: sub.title)
        var rule = try XCTUnwrap(manager.rule(forChannelId: sub.channelId))
        XCTAssertEqual(Set(rule.collections.map(\.name)), ["Cars", "Comedy"])
        XCTAssertTrue(rule.isUserSet)

        try manager.toggle(cars, channelId: sub.channelId, channelTitle: sub.title)
        rule = try XCTUnwrap(manager.rule(forChannelId: sub.channelId))
        XCTAssertEqual(rule.collections.map(\.name), ["Comedy"])
    }

    func testAssignDedupesRepeatedCategories() throws {
        let manager = makeManager(nil)
        let sub = subscribe("D")
        let cars = try XCTUnwrap(manager.categories().first { $0.name == "Cars" })
        try manager.assign(channelId: sub.channelId, channelTitle: sub.title, to: [cars, cars])
        XCTAssertEqual(try manager.rule(forChannelId: sub.channelId)?.collections.count, 1)
    }

    // MARK: - Migration

    /// Rules written before multi-tagging stored one category in `collection`.
    func testLegacySingleCategoryRuleMigratesToOneTagSet() throws {
        let manager = makeManager(nil)
        let cars = try XCTUnwrap(manager.categories().first { $0.name == "Cars" })
        let auto = ChannelRule(channelId: "UC-auto", channelTitle: "Auto", collections: [], isUserSet: false, classifiedAt: .now)
        auto.collection = cars
        let hand = ChannelRule(channelId: "UC-hand", channelTitle: "Hand", collections: [], isUserSet: true)
        hand.collection = cars
        let unsure = ChannelRule(channelId: "UC-unsure", channelTitle: "Unsure", collections: [], classifiedAt: .now)
        context.insert(auto); context.insert(hand); context.insert(unsure)
        try context.save()

        XCTAssertEqual(try manager.migrateLegacyRules(), 2)

        for rule in [auto, hand] {
            XCTAssertEqual(rule.collections.map(\.name), ["Cars"])
            XCTAssertNil(rule.collection)
        }
        XCTAssertFalse(auto.isUserSet)
        XCTAssertTrue(hand.isUserSet, "user-set flag survives migration")
        XCTAssertNotNil(auto.classifiedAt)
        XCTAssertTrue(unsure.collections.isEmpty)

        XCTAssertEqual(try manager.migrateLegacyRules(), 0, "idempotent")
    }

    func testMigrationDoesNotOverwriteAlreadyMultiTaggedRule() throws {
        let manager = makeManager(nil)
        let cars = try XCTUnwrap(manager.categories().first { $0.name == "Cars" })
        let comedy = try XCTUnwrap(manager.categories().first { $0.name == "Comedy" })
        let rule = ChannelRule(channelId: "UC-both", channelTitle: "Both", collections: [comedy])
        rule.collection = cars
        context.insert(rule)
        try context.save()

        try manager.migrateLegacyRules()

        XCTAssertEqual(rule.collections.map(\.name), ["Comedy"])
        XCTAssertNil(rule.collection)
    }

    func testAddCategoryIsCaseInsensitiveDedup() throws {
        let manager = makeManager(nil)
        let before = try manager.categories().count
        let existing = try manager.addCategory(named: "  cars ")
        XCTAssertEqual(existing?.name, "Cars")
        XCTAssertEqual(try manager.categories().count, before)

        let added = try XCTUnwrap(manager.addCategory(named: "Sports"))
        XCTAssertTrue(added.isUserCreated)
        XCTAssertEqual(try manager.categories().last?.name, "Sports", "new categories sort last")
    }

    /// The feed predicate is "tag set contains X": a multi-tagged channel is
    /// in every category it carries, and Uncategorised means an empty set.
    func testChannelIdsInCategoryAndUncategorised() async throws {
        let stub = StubCategorizer(answers: [
            "Filed": guess("Cars"),
            "Both": guess("Cars", "Comedy"),
            "Unsure": .unsure,
        ])
        let manager = makeManager(stub)
        let filed = subscribe("Filed")
        let both = subscribe("Both")
        let unsure = subscribe("Unsure")
        await manager.classify(scope: .unassigned)
        let untouched = subscribe("Untouched")

        let cars = try XCTUnwrap(manager.categories().first { $0.name == "Cars" })
        let comedy = try XCTUnwrap(manager.categories().first { $0.name == "Comedy" })
        let food = try XCTUnwrap(manager.categories().first { $0.name == "Food" })
        XCTAssertEqual(Set(try manager.channelIds(in: cars)), Set([filed.channelId, both.channelId]))
        XCTAssertEqual(try manager.channelIds(in: comedy), [both.channelId])
        XCTAssertEqual(try manager.channelIds(in: food), [])
        XCTAssertEqual(
            Set(try manager.channelIds(in: nil)),
            Set([unsure.channelId, untouched.channelId])
        )
    }
}

// MARK: - Prompt

final class CategoryPromptTests: XCTestCase {
    func testPromptIncludesTitleAboutAndRecentTitles() {
        let descriptor = ChannelDescriptor(
            channelId: "UC1",
            title: "Auto Focus",
            about: "Cars, reviewed.",
            recentVideoTitles: ["Finally Driving the New 911 Turbo S", "This EV Doesn't Make Any Sense"]
        )
        let prompt = CategoryPrompt.prompt(for: descriptor)
        XCTAssertTrue(prompt.contains("Channel: Auto Focus"))
        XCTAssertTrue(prompt.contains("About: Cars, reviewed."))
        XCTAssertTrue(prompt.contains("- Finally Driving the New 911 Turbo S"))
    }

    func testPromptTruncatesLongAboutAndCapsTitles() {
        let descriptor = ChannelDescriptor(
            channelId: "UC1",
            title: "T",
            about: String(repeating: "x", count: 2000),
            recentVideoTitles: (0..<30).map { "Video \($0)" }
        )
        let prompt = CategoryPrompt.prompt(for: descriptor)
        XCTAssertLessThan(prompt.count, CategoryPrompt.maxAboutLength + 400)
        XCTAssertTrue(prompt.contains("- Video 9"))
        XCTAssertFalse(prompt.contains("- Video 10"))
    }

    func testEmptyAboutIsOmitted() {
        let prompt = CategoryPrompt.prompt(for: ChannelDescriptor(
            channelId: "UC1", title: "T", about: "   \n", recentVideoTitles: []
        ))
        XCTAssertFalse(prompt.contains("About:"))
        XCTAssertFalse(prompt.contains("Recent videos:"))
    }

    func testInstructionsListEveryCategoryAndAskForUpToThree() {
        let text = CategoryPrompt.instructions(categories: ["Cars", "Food"])
        XCTAssertTrue(text.contains("- Cars"))
        XCTAssertTrue(text.contains("- Food"))
        XCTAssertTrue(text.contains("one to 3 category names"))
    }

    /// Multi-answer resolution: each name resolved on its own, off-list ones
    /// dropped, duplicates collapsed, order kept, capped at three.
    func testResolveManyDropsOffListDedupesAndCaps() {
        let categories = CategoryManager.defaultCategoryNames
        XCTAssertEqual(
            CategoryPrompt.resolve(["Podcasts & Interviews", "Sports", "comedy"], among: categories),
            ["Podcasts & Interviews", "Comedy"]
        )
        XCTAssertEqual(
            CategoryPrompt.resolve(["Comedy", "COMEDY", "Comedy."], among: categories),
            ["Comedy"]
        )
        XCTAssertEqual(
            CategoryPrompt.resolve(["Cars", "Food", "Games", "Comedy"], among: categories),
            ["Cars", "Food", "Games"]
        )
        XCTAssertEqual(CategoryPrompt.resolve(["Sports", ""], among: categories), [])
        XCTAssertEqual(CategoryPrompt.resolve([], among: categories), [])
    }

    func testResolveToleratesCaseAndAmpersand() {
        let categories = ["Music & Audio Gear", "Tech & Engineering", "Other"]
        XCTAssertEqual(CategoryPrompt.resolve("music and audio gear", among: categories), "Music & Audio Gear")
        XCTAssertEqual(CategoryPrompt.resolve("Tech & Engineering.", among: categories), "Tech & Engineering")
        XCTAssertNil(CategoryPrompt.resolve("Sports", among: categories))
        XCTAssertNil(CategoryPrompt.resolve("", among: categories))
    }

    /// Real drift seen from the on-device model.
    func testResolveToleratesDroppedOrMangledTokens() {
        let categories = CategoryManager.defaultCategoryNames
        XCTAssertEqual(CategoryPrompt.resolve("Music’ Audio Gear", among: categories), "Music & Audio Gear")
        XCTAssertEqual(CategoryPrompt.resolve("Music’ & Audio Gear", among: categories), "Music & Audio Gear")
        XCTAssertEqual(CategoryPrompt.resolve("Science and Explainer", among: categories), nil,
                       "singular/plural isn't a token match; stays unsure rather than guessing")
        XCTAssertEqual(CategoryPrompt.resolve("Podcasts", among: categories), nil,
                       "one of two words isn't a majority")
        XCTAssertEqual(CategoryPrompt.resolve("News, Politics", among: categories), "News & Politics")
    }

    /// After a bump every non-user-set channel is re-classified once, so
    /// channels filed under one category can pick up extra tags.
    func testAutomaticScopeWidensOnceAfterVersionBump() {
        XCTAssertEqual(CategoryManager.automaticScope(storedVersion: 0), .allAutomatic)
        XCTAssertEqual(CategoryManager.automaticScope(storedVersion: CategoryManager.classifierVersion - 1), .allAutomatic)
        XCTAssertEqual(CategoryManager.automaticScope(storedVersion: CategoryManager.classifierVersion), .unassigned)
    }
}
