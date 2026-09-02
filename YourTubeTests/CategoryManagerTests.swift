import XCTest
import SwiftData
@testable import YourTube

/// Answers from a lookup table so the manager's bookkeeping can be tested
/// without the on-device model.
private struct StubCategorizer: ChannelCategorizer {
    struct Refused: Error {}

    var answers: [String: CategoryGuess]
    var fallback = CategoryGuess(category: "Other", isConfident: true)
    /// Titles the stub throws on, standing in for a guardrail refusal.
    var refuses: Set<String> = []

    func categorize(_ channel: ChannelDescriptor, among categories: [String]) async throws -> CategoryGuess {
        if refuses.contains(channel.title) { throw Refused() }
        return answers[channel.title] ?? fallback
    }
}

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
        XCTAssertEqual(names, CategoryManager.defaultCategoryNames)
    }

    // MARK: - Classification

    func testConfidentGuessFilesChannel() async throws {
        let stub = StubCategorizer(answers: [
            "Auto Focus": CategoryGuess(category: "Cars", isConfident: true),
        ])
        let manager = makeManager(stub)
        let sub = subscribe("Auto Focus")

        await manager.classify(scope: .unassigned)

        let rule = try XCTUnwrap(manager.rule(forChannelId: sub.channelId))
        XCTAssertEqual(rule.collection?.name, "Cars")
        XCTAssertFalse(rule.isUserSet)
        XCTAssertNotNil(rule.classifiedAt)
        XCTAssertEqual(manager.status, .idle)
    }

    func testUnsureGuessLeavesChannelUncategorisedButRecorded() async throws {
        let stub = StubCategorizer(answers: [
            "Mystery": CategoryGuess(category: "Comedy", isConfident: false),
        ])
        let manager = makeManager(stub)
        let sub = subscribe("Mystery")

        await manager.classify(scope: .unassigned)

        let rule = try XCTUnwrap(manager.rule(forChannelId: sub.channelId))
        XCTAssertNil(rule.collection)
        XCTAssertNotNil(rule.classifiedAt, "should not be retried on the next unassigned pass")
    }

    func testOffListAnswerIsTreatedAsUnsure() async throws {
        let stub = StubCategorizer(answers: [
            "Weird": CategoryGuess(category: nil, isConfident: true),
        ])
        let manager = makeManager(stub)
        let sub = subscribe("Weird")

        await manager.classify(scope: .unassigned)

        XCTAssertNil(try manager.rule(forChannelId: sub.channelId)?.collection)
    }

    func testUnassignedScopeSkipsAlreadyClassified() async throws {
        var stub = StubCategorizer(answers: [
            "A": CategoryGuess(category: "Cars", isConfident: true),
        ])
        let manager = makeManager(stub)
        let sub = subscribe("A")
        await manager.classify(scope: .unassigned)

        // The model changes its mind; an unassigned pass must not re-ask.
        stub.answers["A"] = CategoryGuess(category: "Food", isConfident: true)
        let manager2 = CategoryManager(modelContext: context, categorizer: stub)
        await manager2.classify(scope: .unassigned)
        XCTAssertEqual(try manager2.rule(forChannelId: sub.channelId)?.collection?.name, "Cars")

        // But a full automatic re-run does.
        await manager2.classify(scope: .allAutomatic)
        XCTAssertEqual(try manager2.rule(forChannelId: sub.channelId)?.collection?.name, "Food")
    }

    func testUserSetRuleSurvivesFullRerun() async throws {
        let stub = StubCategorizer(answers: [
            "Hand filed": CategoryGuess(category: "Games", isConfident: true),
        ])
        let manager = makeManager(stub)
        let sub = subscribe("Hand filed")
        let comedy = try XCTUnwrap(manager.categories().first { $0.name == "Comedy" })
        try manager.assign(channelId: sub.channelId, channelTitle: sub.title, to: comedy)

        await manager.classify(scope: .allAutomatic)

        let rule = try XCTUnwrap(manager.rule(forChannelId: sub.channelId))
        XCTAssertEqual(rule.collection?.name, "Comedy")
        XCTAssertTrue(rule.isUserSet)
    }

    func testUnsureChannelsAreRetriedOnlyInWiderScope() async throws {
        var stub = StubCategorizer(answers: [
            "Later": CategoryGuess(category: "Food", isConfident: false),
        ])
        let manager = makeManager(stub)
        let sub = subscribe("Later")
        await manager.classify(scope: .unassigned)
        XCTAssertNil(try manager.rule(forChannelId: sub.channelId)?.collection)

        stub.answers["Later"] = CategoryGuess(category: "Food", isConfident: true)
        let manager2 = CategoryManager(modelContext: context, categorizer: stub)
        await manager2.classify(scope: .unassigned)
        XCTAssertNil(try manager2.rule(forChannelId: sub.channelId)?.collection)

        await manager2.classify(scope: .unassignedAndUnsure)
        XCTAssertEqual(try manager2.rule(forChannelId: sub.channelId)?.collection?.name, "Food")
    }

    /// A guardrail refusal on one channel must not abort the run.
    func testRefusedChannelIsRecordedUnsureAndRunContinues() async throws {
        let stub = StubCategorizer(
            answers: ["Fine": CategoryGuess(category: "Cars", isConfident: true)],
            refuses: ["🛑 Blocked"]
        )
        let manager = makeManager(stub)
        let blocked = subscribe("🛑 Blocked")   // sorts first by title
        let fine = subscribe("Fine")

        await manager.classify(scope: .unassigned)

        XCTAssertEqual(manager.status, .idle)
        XCTAssertEqual(manager.lastRunFailures, 1)
        let blockedRule = try XCTUnwrap(manager.rule(forChannelId: blocked.channelId))
        XCTAssertNil(blockedRule.collection)
        XCTAssertNotNil(blockedRule.classifiedAt)
        XCTAssertEqual(try manager.rule(forChannelId: fine.channelId)?.collection?.name, "Cars")
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

    func testDeletingCategoryUnfilesChannels() async throws {
        let stub = StubCategorizer(answers: [
            "X": CategoryGuess(category: "Cars", isConfident: true),
        ])
        let manager = makeManager(stub)
        let sub = subscribe("X")
        await manager.classify(scope: .unassigned)
        let cars = try XCTUnwrap(manager.categories().first { $0.name == "Cars" })

        try manager.delete(cars)

        XCTAssertNil(try manager.rule(forChannelId: sub.channelId)?.collection)
        XCTAssertFalse(try manager.categories().contains { $0.name == "Cars" })
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

    func testChannelIdsInCategoryAndUncategorised() async throws {
        let stub = StubCategorizer(answers: [
            "Filed": CategoryGuess(category: "Cars", isConfident: true),
            "Unsure": CategoryGuess(category: "Cars", isConfident: false),
        ])
        let manager = makeManager(stub)
        let filed = subscribe("Filed")
        let unsure = subscribe("Unsure")
        let never = subscribe("Never")
        // Remove "Never" from targets by giving it a user-set nil rule? No —
        // simply exclude it from the stub run by classifying before inserting.
        context.delete(never)
        await manager.classify(scope: .unassigned)
        let untouched = subscribe("Untouched")

        let cars = try XCTUnwrap(manager.categories().first { $0.name == "Cars" })
        XCTAssertEqual(try manager.channelIds(in: cars), [filed.channelId])
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

    func testInstructionsListEveryCategory() {
        let text = CategoryPrompt.instructions(categories: ["Cars", "Food"])
        XCTAssertTrue(text.contains("- Cars"))
        XCTAssertTrue(text.contains("- Food"))
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

    func testAutomaticScopeWidensOnceAfterVersionBump() {
        XCTAssertEqual(CategoryManager.automaticScope(storedVersion: 0), .unassignedAndUnsure)
        XCTAssertEqual(CategoryManager.automaticScope(storedVersion: CategoryManager.classifierVersion - 1), .unassignedAndUnsure)
        XCTAssertEqual(CategoryManager.automaticScope(storedVersion: CategoryManager.classifierVersion), .unassigned)
    }
}
