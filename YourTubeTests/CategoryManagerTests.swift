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

private func guess(_ names: String..., raw: [String]? = nil) -> CategoryGuess {
    CategoryGuess(categories: names, rawCategories: raw ?? names)
}

/// Records which channels it was asked about, and in what order — what the
/// version-bump pass's budget and ordering tests need instead of the
/// on-device model.
private final class CountingCategorizer: ChannelCategorizer, @unchecked Sendable {
    private(set) var calledChannelTitles: [String] = []
    var answer = CategoryGuess(categories: ["Other"])

    func categorize(_ channel: ChannelDescriptor, among categories: [String]) async throws -> CategoryGuess {
        calledChannelTitles.append(channel.title)
        return answer
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
        // The classifier runs on its own context, so a subscription has to be
        // saved before it can be seen — as `FeedRefresher` saves the real ones
        // before classification is started.
        try? context.save()
        return sub
    }

    /// Inserts a video for a channel with a given YouTube category, so the
    /// classifier has something to read a dominant category off of.
    @discardableResult
    private func addVideo(
        channelId: String,
        categoryId: String?,
        title: String = "V",
        publishedAt: Date = .now
    ) -> Video {
        let video = Video(
            videoId: "\(channelId)-\(UUID().uuidString)",
            channelId: channelId,
            channelTitle: channelId,
            title: title,
            videoDescription: "",
            publishedAt: publishedAt,
            durationSeconds: 600,
            youtubeCategoryId: categoryId
        )
        context.insert(video)
        try? context.save()
        return video
    }

    /// `count` uploads a second apart starting at `base`, standing in for a
    /// channel's recent-titles window.
    private func addVideos(channelId: String, count: Int, startingAt base: Date, titlePrefix: String = "V") {
        for i in 0..<count {
            addVideo(channelId: channelId, categoryId: nil, title: "\(titlePrefix)\(i)", publishedAt: base.addingTimeInterval(TimeInterval(i)))
        }
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
        try manager.assign(channelId: both.channelId, channelTitle: both.title, to: [comedy])
        try manager.setPriority(true, channelId: both.channelId, channelTitle: both.title)
        try manager.setPriority(true, channelId: onlyPriority.channelId, channelTitle: onlyPriority.title)

        XCTAssertEqual(
            Set(try manager.channelIds(in: CategoryManager.priorityName)),
            Set([both.channelId, onlyPriority.channelId])
        )
        XCTAssertEqual(try manager.channelIds(in: comedy.name), [both.channelId])
        XCTAssertEqual(try manager.channelIds(in: CategoryManager.uncategorizedName), [onlyPriority.channelId])
    }

    /// "All" (nil, and the empty string the chip row treats the same way) is
    /// every subscribed channel, filed or not.
    func testChannelIdsForAllReturnsEverySubscription() throws {
        let manager = makeManager(nil)
        let a = subscribe("A")
        let b = subscribe("B")
        XCTAssertEqual(Set(try manager.channelIds(in: nil)), Set([a.channelId, b.channelId]))
        XCTAssertEqual(Set(try manager.channelIds(in: "")), Set([a.channelId, b.channelId]))
    }

    /// A channel with two topic categories appears under each of its chips.
    func testMultiTopicChannelAppearsUnderEachOfItsCategories() throws {
        let manager = makeManager(nil)
        let sub = subscribe("Multi")
        let comedy = try XCTUnwrap(manager.categories().first { $0.name == "Comedy" })
        let food = try XCTUnwrap(manager.categories().first { $0.name == "Food" })
        try manager.assign(channelId: sub.channelId, channelTitle: sub.title, to: [comedy, food])

        XCTAssertEqual(try manager.channelIds(in: "Comedy"), [sub.channelId])
        XCTAssertEqual(try manager.channelIds(in: "Food"), [sub.channelId])
    }

    /// A Priority-only channel — no topic category at all — still shows up
    /// under Uncategorized, since Priority says nothing about topic.
    func testPriorityOnlyChannelAppearsUnderUncategorized() throws {
        let manager = makeManager(nil)
        let sub = subscribe("OnlyPriority")
        try manager.setPriority(true, channelId: sub.channelId, channelTitle: sub.title)

        XCTAssertEqual(try manager.channelIds(in: CategoryManager.uncategorizedName), [sub.channelId])
    }

    /// Deleting a category drops it from the chip list, which is what lets
    /// each chip row's Binding fall back to "All" instead of pointing at a
    /// name that no longer exists.
    func testChipNamesDropsADeletedCategory() throws {
        let manager = makeManager(nil)
        let comedy = try XCTUnwrap(manager.categories().first { $0.name == "Comedy" })

        try manager.delete(comedy)

        XCTAssertFalse(try manager.chipNames().contains("Comedy"))
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

    /// v4: only the model's first answer counts, and a second category can
    /// only come from YouTube's own filing. A comedian's interview show is
    /// Podcasts & Interviews because the model said so, and Comedy because
    /// YouTube files its uploads there.
    func testSecondCategoryComesFromYouTubeNotFromTheModel() async throws {
        let stub = StubCategorizer(answers: [
            "Neal Brennan": guess("Podcasts & Interviews", "Games", "Food"),
        ])
        let manager = makeManager(stub)
        let sub = subscribe("Neal Brennan")
        for _ in 0..<3 { addVideo(channelId: sub.channelId, categoryId: "23") }

        await manager.classify(scope: .unassigned)

        let rule = try XCTUnwrap(manager.rule(forChannelId: sub.channelId))
        // `collections` is an unordered relationship; the recorded answer is
        // what keeps the model's category first.
        XCTAssertEqual(Set(rule.collections.map(\.name)), ["Podcasts & Interviews", "Comedy"])
        XCTAssertEqual(rule.classifierResolvedCategories, ["Podcasts & Interviews", "Comedy"],
                       "the model's answer first, YouTube's second")
        XCTAssertEqual(rule.classifierModelCategory, "Podcasts & Interviews")
        XCTAssertEqual(rule.classifierYouTubeCategory, "Comedy")
    }

    /// The hard ceiling the whole change is for: however many names come back,
    /// a pass leaves at most two topic chips on a channel.
    func testNoChannelCarriesMoreThanTwoAutomaticCategories() async throws {
        let stub = StubCategorizer(answers: [
            "Everything": guess("Cars", "Comedy", "Food", "Games"),
        ])
        let manager = makeManager(stub)
        let sub = subscribe("Everything")
        for _ in 0..<3 { addVideo(channelId: sub.channelId, categoryId: "20") }

        await manager.classify(scope: .unassigned)

        let rule = try XCTUnwrap(manager.rule(forChannelId: sub.channelId))
        XCTAssertEqual(rule.topicCollections.count, CategoryPrompt.maxCategoriesPerChannel)
        XCTAssertEqual(Set(rule.collections.map(\.name)), ["Cars", "Games"])
    }

    /// When YouTube agrees with the model there's nothing to add: one chip,
    /// not the same one twice.
    func testAgreeingYouTubeSignalAddsNoSecondCategory() async throws {
        let stub = StubCategorizer(answers: ["Auto Focus": guess("Cars")])
        let manager = makeManager(stub)
        let sub = subscribe("Auto Focus")
        for _ in 0..<3 { addVideo(channelId: sub.channelId, categoryId: "2") }

        await manager.classify(scope: .unassigned)

        let rule = try XCTUnwrap(manager.rule(forChannelId: sub.channelId))
        XCTAssertEqual(rule.collections.map(\.name), ["Cars"])
        XCTAssertEqual(rule.classifierModelCategory, "Cars")
        XCTAssertNil(rule.classifierYouTubeCategory)
    }

    /// A channel the model wouldn't commit on stays Uncategorised even when
    /// YouTube files it somewhere: the second category is a second, never a
    /// first. Precision over recall — a missing chip is invisible.
    func testYouTubeSignalAloneDoesNotFileAChannel() async throws {
        let stub = StubCategorizer(answers: ["Mystery": .unsure])
        let manager = makeManager(stub)
        let sub = subscribe("Mystery")
        for _ in 0..<3 { addVideo(channelId: sub.channelId, categoryId: "20") }

        await manager.classify(scope: .unassigned)

        let rule = try XCTUnwrap(manager.rule(forChannelId: sub.channelId))
        XCTAssertTrue(rule.topicCollections.isEmpty)
        XCTAssertNil(rule.classifierYouTubeCategory)
    }

    /// The prompt states YouTube's filing as a prior, so the model can use it
    /// as evidence about the subject rather than being overruled by it.
    func testPromptStatesTheYouTubeSignalAsAPrior() async throws {
        final class Recorder: ChannelCategorizer, @unchecked Sendable {
            var prompts: [String] = []
            func categorize(_ channel: ChannelDescriptor, among categories: [String]) async throws -> CategoryGuess {
                prompts.append(CategoryPrompt.prompt(for: channel))
                return CategoryGuess(categories: ["Cars"])
            }
        }
        let recorder = Recorder()
        let manager = makeManager(recorder)
        let sub = subscribe("Prior")
        for _ in 0..<3 { addVideo(channelId: sub.channelId, categoryId: "20") }

        await manager.classify(scope: .unassigned)

        let prompt = try XCTUnwrap(recorder.prompts.first)
        XCTAssertTrue(prompt.contains("YouTube files most of its videos under Gaming"), prompt)
        XCTAssertTrue(prompt.contains("Games"), prompt)
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

    /// The classifier runs on its own context, so what it files is in the
    /// store rather than pending on the main context, where every live
    /// `@Query` would have seen each rule land.
    func testClassificationIsSavedToTheStoreAndNotPendingOnTheMainContext() async throws {
        let manager = makeManager(StubCategorizer(answers: ["Auto Focus": guess("Cars")]))
        let sub = subscribe("Auto Focus")

        await manager.classify(scope: .unassigned)

        XCTAssertFalse(context.hasChanges)
        let fresh = ModelContext(container)
        let rules = try fresh.fetch(FetchDescriptor<ChannelRule>())
        XCTAssertEqual(rules.map(\.channelId), [sub.channelId])
        XCTAssertEqual(rules.first?.collections.map(\.name), ["Cars"])
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

    // MARK: - Classifier evidence

    func testClassifyRecordsRawAnswerAndDominantCategory() async throws {
        let stub = StubCategorizer(answers: [
            "Auto Focus": guess("Cars", raw: ["Cars", "cars & trucks"]),
        ])
        let manager = makeManager(stub)
        let sub = subscribe("Auto Focus")
        addVideo(channelId: sub.channelId, categoryId: "2")
        addVideo(channelId: sub.channelId, categoryId: "2")
        addVideo(channelId: sub.channelId, categoryId: "10")

        await manager.classify(scope: .unassigned)

        let rule = try XCTUnwrap(manager.rule(forChannelId: sub.channelId))
        XCTAssertEqual(rule.classifierRawAnswer, ["Cars", "cars & trucks"])
        XCTAssertEqual(rule.classifierResolvedCategories, ["Cars"])
        XCTAssertEqual(rule.classifierDominantCategoryId, "2")
        XCTAssertEqual(YouTubeCategory.name(forId: rule.classifierDominantCategoryId!), "Autos & Vehicles")
    }

    /// The recorded reasons have to say which chip came from where, or a
    /// wrong one can't be blamed on the model or on YouTube.
    func testRecordedReasonsNameTheModelsCategoryAndYouTubes() async throws {
        let stub = StubCategorizer(answers: ["Split": guess("Podcasts & Interviews")])
        let manager = makeManager(stub)
        let sub = subscribe("Split")
        for _ in 0..<3 { addVideo(channelId: sub.channelId, categoryId: "23") }

        await manager.classify(scope: .unassigned)

        let rule = try XCTUnwrap(manager.rule(forChannelId: sub.channelId))
        XCTAssertEqual(rule.classifierResolvedCategories, ["Podcasts & Interviews", "Comedy"])
        XCTAssertEqual(rule.classifierModelCategory, "Podcasts & Interviews")
        XCTAssertEqual(rule.classifierYouTubeCategory, "Comedy")
        XCTAssertEqual(rule.classifierYouTubeReason, "YouTube files most of its videos under Comedy")
    }

    /// An unsure guess is still a recorded answer — an empty one — distinct
    /// from a rule that's never been classified at all.
    func testUnsureGuessRecordsEmptyEvidenceNotNil() async throws {
        let stub = StubCategorizer(answers: ["Mystery": .unsure])
        let manager = makeManager(stub)
        let sub = subscribe("Mystery")

        await manager.classify(scope: .unassigned)

        let rule = try XCTUnwrap(manager.rule(forChannelId: sub.channelId))
        XCTAssertEqual(rule.classifierRawAnswer, [])
        XCTAssertEqual(rule.classifierResolvedCategories, [])
    }

    /// A channel filed by hand from the start has no automatic pass behind
    /// it, so there's nothing to show or export.
    func testHandFiledChannelHasNoClassifierEvidence() throws {
        let manager = makeManager(nil)
        let sub = subscribe("Manual")
        let comedy = try XCTUnwrap(manager.categories().first { $0.name == "Comedy" })
        try manager.assign(channelId: sub.channelId, channelTitle: sub.title, to: [comedy])

        let rule = try XCTUnwrap(manager.rule(forChannelId: sub.channelId))
        XCTAssertNil(rule.classifierRawAnswer)
        XCTAssertNil(rule.classifierResolvedCategories)
        XCTAssertNil(rule.classifierDominantCategoryId)
        XCTAssertTrue(rule.isUserSet)
    }

    /// A correction after an automatic pass keeps the automatic evidence on
    /// the rule — the export's whole point is comparing the two.
    func testCorrectingAnAutomaticRuleKeepsItsEvidence() async throws {
        let stub = StubCategorizer(answers: ["Keep": guess("Cars")])
        let manager = makeManager(stub)
        let sub = subscribe("Keep")
        await manager.classify(scope: .unassigned)
        let food = try XCTUnwrap(manager.categories().first { $0.name == "Food" })

        try manager.assign(channelId: sub.channelId, channelTitle: sub.title, to: [food])

        let rule = try XCTUnwrap(manager.rule(forChannelId: sub.channelId))
        XCTAssertTrue(rule.isUserSet)
        XCTAssertEqual(rule.collections.map(\.name), ["Food"], "the user's filing wins")
        XCTAssertEqual(rule.classifierRawAnswer, ["Cars"], "but the automatic answer is still on record")
        XCTAssertEqual(rule.classifierResolvedCategories, ["Cars"])
    }

    // MARK: - Export

    func testExportIncludesOneRecordPerSubscriptionWithFullShape() async throws {
        let stub = StubCategorizer(answers: [
            "Auto Focus": guess("Cars", raw: ["Cars"]),
        ])
        let manager = makeManager(stub)
        let sub = subscribe("Auto Focus")
        addVideo(channelId: sub.channelId, categoryId: "2", title: "First video")
        await manager.classify(scope: .unassigned)

        let data = try await manager.exportClassifierEvidence()
        let records = try JSONDecoder().decode([StoreWriter.ChannelClassifierRecord].self, from: data)

        XCTAssertEqual(records.count, 1)
        let record = try XCTUnwrap(records.first)
        XCTAssertEqual(record.channelId, sub.channelId)
        XCTAssertEqual(record.channelTitle, "Auto Focus")
        XCTAssertEqual(record.about, "")
        XCTAssertEqual(record.recentVideoTitles, ["First video"])
        XCTAssertEqual(record.rawAnswer, ["Cars"])
        XCTAssertEqual(record.resolvedCategories, ["Cars"])
        XCTAssertEqual(record.dominantYouTubeCategory, "Autos & Vehicles")
        XCTAssertEqual(record.modelCategory, "Cars")
        XCTAssertNil(record.youtubeCategory, "YouTube agreed, so it added nothing")
        XCTAssertFalse(record.isUserSet)
        XCTAssertNil(record.userCategories)
    }

    /// The vote tally is the raw evidence behind YouTube's filing, recomputed
    /// live rather than read off the rule — so it is there for a channel the
    /// classifier has never touched, which `dominantYouTubeCategory` is not.
    func testExportTalliesYouTubeCategoryVotesLiveForEveryChannel() async throws {
        let manager = makeManager(nil)
        let voted = subscribe("Voted")
        for _ in 0..<3 { addVideo(channelId: voted.channelId, categoryId: "23") }
        addVideo(channelId: voted.channelId, categoryId: "24")
        addVideo(channelId: voted.channelId, categoryId: nil)
        let silent = subscribe("Silent")
        addVideo(channelId: silent.channelId, categoryId: nil)

        let data = try await manager.exportClassifierEvidence()
        let records = try JSONDecoder().decode([StoreWriter.ChannelClassifierRecord].self, from: data)

        let votedRecord = try XCTUnwrap(records.first { $0.channelId == voted.channelId })
        XCTAssertEqual(votedRecord.youtubeCategoryVotes, ["23": 3, "24": 1], "uncategorised videos don't vote")
        XCTAssertNil(votedRecord.dominantYouTubeCategory, "no classifier pass has run, so the rule records nothing")

        let silentRecord = try XCTUnwrap(records.first { $0.channelId == silent.channelId })
        XCTAssertEqual(silentRecord.youtubeCategoryVotes, [:])
    }

    /// The measuring stick for later classifier changes: a corrected channel
    /// carries both the automatic answer and what the user chose instead.
    func testExportRecordsBothAutomaticAnswerAndUserCorrection() async throws {
        let stub = StubCategorizer(answers: ["Keep": guess("Cars")])
        let manager = makeManager(stub)
        let sub = subscribe("Keep")
        await manager.classify(scope: .unassigned)
        let food = try XCTUnwrap(manager.categories().first { $0.name == "Food" })
        try manager.assign(channelId: sub.channelId, channelTitle: sub.title, to: [food])

        let data = try await manager.exportClassifierEvidence()
        let records = try JSONDecoder().decode([StoreWriter.ChannelClassifierRecord].self, from: data)
        let record = try XCTUnwrap(records.first { $0.channelId == sub.channelId })

        XCTAssertTrue(record.isUserSet)
        XCTAssertEqual(record.userCategories, ["Food"])
        XCTAssertEqual(record.rawAnswer, ["Cars"])
        XCTAssertEqual(record.resolvedCategories, ["Cars"])
    }

    /// The export has to carry the same split as the sheet, since it's what
    /// the answers get compared against by hand.
    func testExportSeparatesTheModelsCategoryFromYouTubes() async throws {
        let stub = StubCategorizer(answers: ["Split": guess("Podcasts & Interviews")])
        let manager = makeManager(stub)
        let sub = subscribe("Split")
        for _ in 0..<3 { addVideo(channelId: sub.channelId, categoryId: "23") }
        await manager.classify(scope: .unassigned)

        let data = try await manager.exportClassifierEvidence()
        let records = try JSONDecoder().decode([StoreWriter.ChannelClassifierRecord].self, from: data)
        let record = try XCTUnwrap(records.first { $0.channelId == sub.channelId })

        XCTAssertEqual(record.resolvedCategories, ["Podcasts & Interviews", "Comedy"])
        XCTAssertEqual(record.modelCategory, "Podcasts & Interviews")
        XCTAssertEqual(record.youtubeCategory, "Comedy")
        XCTAssertEqual(record.youtubeReason, "YouTube files most of its videos under Comedy")
    }

    /// A rule classified before this change carries no evidence; the export
    /// must say so rather than crash or invent an answer.
    func testExportShowsNotRecordedForPreExistingRule() async throws {
        let manager = makeManager(nil)
        let sub = subscribe("Old")
        let legacyRule = ChannelRule(
            channelId: sub.channelId,
            channelTitle: sub.title,
            collections: [],
            isUserSet: false,
            classifiedAt: .now
        )
        context.insert(legacyRule)
        try context.save()

        let data = try await manager.exportClassifierEvidence()
        let records = try JSONDecoder().decode([StoreWriter.ChannelClassifierRecord].self, from: data)
        let record = try XCTUnwrap(records.first { $0.channelId == sub.channelId })

        XCTAssertNil(record.rawAnswer)
        XCTAssertNil(record.resolvedCategories)
        XCTAssertNil(record.modelCategory)
        XCTAssertNil(record.youtubeCategory)
        XCTAssertNil(record.dominantYouTubeCategory)
        XCTAssertFalse(record.isUserSet)
        XCTAssertNil(record.userCategories)
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
        for _ in 0..<3 { addVideo(channelId: y.channelId, categoryId: "23") }
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
        for _ in 0..<3 { addVideo(channelId: both.channelId, categoryId: "23") }
        let unsure = subscribe("Unsure")
        await manager.classify(scope: .unassigned)
        let untouched = subscribe("Untouched")

        XCTAssertEqual(Set(try manager.channelIds(in: "Cars")), Set([filed.channelId, both.channelId]))
        XCTAssertEqual(try manager.channelIds(in: "Comedy"), [both.channelId])
        XCTAssertEqual(try manager.channelIds(in: "Food"), [])
        XCTAssertEqual(
            Set(try manager.channelIds(in: CategoryManager.uncategorizedName)),
            Set([unsure.channelId, untouched.channelId])
        )
    }

    // MARK: - Re-filing on upload turnover (#95)

    /// One new upload out of a ten-title window isn't enough to re-ask —
    /// otherwise a weekly show would be re-filed every week.
    func testOneNewUploadDoesNotReclassifyInUnassignedScope() async throws {
        var stub = StubCategorizer(answers: ["Turnover": guess("Cars")])
        let manager = makeManager(stub)
        let sub = subscribe("Turnover")
        let base = Date(timeIntervalSince1970: 1_000_000)
        addVideos(channelId: sub.channelId, count: 10, startingAt: base)
        await manager.classify(scope: .unassigned)
        XCTAssertEqual(try manager.rule(forChannelId: sub.channelId)?.collections.map(\.name), ["Cars"])

        addVideo(channelId: sub.channelId, categoryId: nil, title: "New", publishedAt: base.addingTimeInterval(10_000))
        stub.answers["Turnover"] = guess("Food")
        let manager2 = CategoryManager(modelContext: context, categorizer: stub)
        await manager2.classify(scope: .unassigned)
        XCTAssertEqual(try manager2.rule(forChannelId: sub.channelId)?.collections.map(\.name), ["Cars"])
    }

    /// More than half the classifier's ten-title window replaced counts as
    /// substantial turnover, so the routine pass asks again.
    func testSubstantialTurnoverReclassifiesInUnassignedScope() async throws {
        var stub = StubCategorizer(answers: ["Turnover": guess("Cars")])
        let manager = makeManager(stub)
        let sub = subscribe("Turnover")
        let base = Date(timeIntervalSince1970: 1_000_000)
        addVideos(channelId: sub.channelId, count: 10, startingAt: base)
        await manager.classify(scope: .unassigned)
        XCTAssertEqual(try manager.rule(forChannelId: sub.channelId)?.collections.map(\.name), ["Cars"])

        addVideos(channelId: sub.channelId, count: 6, startingAt: base.addingTimeInterval(10_000), titlePrefix: "New")
        stub.answers["Turnover"] = guess("Food")
        let manager2 = CategoryManager(modelContext: context, categorizer: stub)
        await manager2.classify(scope: .unassigned)
        XCTAssertEqual(try manager2.rule(forChannelId: sub.channelId)?.collections.map(\.name), ["Food"])
    }

    /// A channel whose uploads haven't moved at all is skipped, so the
    /// routine pass after a refresh stays near-free.
    func testUnchangedUploadsAreNotReclassified() async throws {
        var stub = StubCategorizer(answers: ["Stable": guess("Cars")])
        let manager = makeManager(stub)
        let sub = subscribe("Stable")
        addVideos(channelId: sub.channelId, count: 10, startingAt: Date(timeIntervalSince1970: 1_000_000))
        await manager.classify(scope: .unassigned)

        stub.answers["Stable"] = guess("Food")
        let manager2 = CategoryManager(modelContext: context, categorizer: stub)
        await manager2.classify(scope: .unassigned)
        XCTAssertEqual(try manager2.rule(forChannelId: sub.channelId)?.collections.map(\.name), ["Cars"])
    }

    /// User-set rules are never touched, no matter how much a channel's
    /// uploads have turned over.
    func testUserSetRuleIsNeverReclassifiedDespiteTurnover() async throws {
        let stub = StubCategorizer(answers: ["Hand": guess("Games")])
        let manager = makeManager(stub)
        let sub = subscribe("Hand")
        let comedy = try XCTUnwrap(manager.categories().first { $0.name == "Comedy" })
        try manager.assign(channelId: sub.channelId, channelTitle: sub.title, to: [comedy])
        addVideos(channelId: sub.channelId, count: 20, startingAt: Date(timeIntervalSince1970: 1_000_000))

        await manager.classify(scope: .unassigned)
        XCTAssertEqual(try manager.rule(forChannelId: sub.channelId)?.collections.map(\.name), ["Comedy"])
        XCTAssertTrue(try XCTUnwrap(manager.rule(forChannelId: sub.channelId)).isUserSet)
    }

    /// Classifying records the window's `videoId`s as the fingerprint for
    /// the next turnover check.
    func testClassificationRecordsRecentVideoIdsFingerprint() async throws {
        let stub = StubCategorizer(answers: ["Fingerprint": guess("Cars")])
        let manager = makeManager(stub)
        let sub = subscribe("Fingerprint")
        addVideos(channelId: sub.channelId, count: 3, startingAt: Date(timeIntervalSince1970: 1_000_000))
        await manager.classify(scope: .unassigned)

        let rule = try XCTUnwrap(manager.rule(forChannelId: sub.channelId))
        XCTAssertEqual(rule.classifierRecentVideoIds?.count, 3)
    }

    func testHasTurnedOverRequiresMajorityNewWithFloorOfTwo() {
        // 1 of 3 new: below the floor-adjusted threshold.
        XCTAssertFalse(CategoryManager.hasTurnedOver(
            previousVideoIds: ["a", "b", "c"], currentVideoIds: ["a", "b", "d"], windowSize: 3
        ))
        // Small window: floor of two still applies even though half of two is one.
        XCTAssertTrue(CategoryManager.hasTurnedOver(
            previousVideoIds: ["a", "b"], currentVideoIds: ["c", "d"], windowSize: 2
        ))
        // No recorded fingerprint: due, so a baseline gets captured.
        XCTAssertTrue(CategoryManager.hasTurnedOver(
            previousVideoIds: nil, currentVideoIds: ["a"], windowSize: 10
        ))
        // Identical window: never due.
        XCTAssertFalse(CategoryManager.hasTurnedOver(
            previousVideoIds: ["a", "b", "c"], currentVideoIds: ["a", "b", "c"], windowSize: 3
        ))
    }

    // MARK: - Classifier version bump, paged across launches (#119)

    /// Inserts a channel already classified under `version` — standing in for
    /// a channel that was fine under the classifier's previous version and is
    /// now due for `.staleVersion`, without going through a real classify
    /// pass first.
    @discardableResult
    private func makeStaleRule(
        title: String,
        version: Int,
        classifiedAt: Date = .now
    ) throws -> (subscription: Subscription, rule: ChannelRule) {
        let sub = subscribe(title)
        let cars = try XCTUnwrap(context.fetch(FetchDescriptor<VideoCollection>())
            .first { $0.name == "Cars" })
        let rule = ChannelRule(
            channelId: sub.channelId, channelTitle: title, collections: [cars],
            isUserSet: false, classifiedAt: classifiedAt
        )
        rule.classifiedVersion = version
        context.insert(rule)
        try context.save()
        return (sub, rule)
    }

    /// A version-bump pass spends only its budget's worth of calls, leaving
    /// the rest of the backlog for a later launch.
    func testStaleVersionPassRespectsPerLaunchBudget() async throws {
        let counter = CountingCategorizer()
        let manager = makeManager(counter)
        for i in 0..<5 { try makeStaleRule(title: "Stale \(i)", version: 0) }

        await manager.classify(scope: .staleVersion, limit: 2)

        XCTAssertEqual(counter.calledChannelTitles.count, 2)
        let rules = try manager.rules()
        XCTAssertEqual(rules.filter { $0.classifiedVersion == CategoryManager.classifierVersion }.count, 2)
        XCTAssertEqual(rules.filter { $0.classifiedVersion == 0 }.count, 3)
    }

    /// Within one launch's budget, a channel with an upload since its last
    /// classification goes first — the Done-when's explicit ordering.
    func testStaleVersionOrdersUploadTurnoverFirst() async throws {
        let counter = CountingCategorizer()
        let manager = makeManager(counter)
        let base = Date(timeIntervalSince1970: 1_000_000)
        let (stableSub, _) = try makeStaleRule(title: "Stable", version: 0, classifiedAt: base)
        addVideo(channelId: stableSub.channelId, categoryId: nil, publishedAt: base.addingTimeInterval(-10))
        let (turnedOverSub, _) = try makeStaleRule(title: "TurnedOver", version: 0, classifiedAt: base)
        addVideo(channelId: turnedOverSub.channelId, categoryId: nil, publishedAt: base.addingTimeInterval(10))

        await manager.classify(scope: .staleVersion, limit: 1)

        XCTAssertEqual(counter.calledChannelTitles, ["TurnedOver"])
        XCTAssertEqual(try manager.rule(forChannelId: turnedOverSub.channelId)?.classifiedVersion, CategoryManager.classifierVersion)
        XCTAssertEqual(try manager.rule(forChannelId: stableSub.channelId)?.classifiedVersion, 0)
    }

    /// However small the budget, every channel reaches the current version
    /// within a bounded number of launches — no channel is skipped forever.
    func testStaleVersionReachesEveryChannelWithinBoundedLaunches() async throws {
        let channelCount = 5
        let budget = 2
        let counter = CountingCategorizer()
        let manager = makeManager(counter)
        for i in 0..<channelCount { try makeStaleRule(title: "Channel \(i)", version: 0) }

        let expectedLaunches = Int((Double(channelCount) / Double(budget)).rounded(.up))
        for _ in 0..<expectedLaunches {
            await manager.classify(scope: .staleVersion, limit: budget)
        }

        let rules = try manager.rules()
        XCTAssertEqual(rules.filter { $0.classifiedVersion == CategoryManager.classifierVersion }.count, channelCount,
                       "every channel reached the current version within \(expectedLaunches) launches")
        // One more launch beyond the bound must be a no-op: nothing left to page.
        await manager.classify(scope: .staleVersion, limit: budget)
        XCTAssertEqual(counter.calledChannelTitles.count, channelCount)
    }

    /// `.unassigned` — a fresh subscription — is classified on the launch
    /// that first sees it, even while a version-bump backlog is also pending.
    func testUnassignedIsClassifiedImmediatelyAlongsideAVersionBump() async throws {
        let stub = StubCategorizer(answers: ["Fresh": guess("Cars")])
        let manager = makeManager(stub)
        try makeStaleRule(title: "Backlogged", version: 0)
        let fresh = subscribe("Fresh")

        manager.classifyUnassignedInBackground()
        for _ in 0..<200 {
            if try manager.rule(forChannelId: fresh.channelId)?.collections.isEmpty == false { break }
            try await Task.sleep(for: .milliseconds(10))
        }

        XCTAssertEqual(try manager.rule(forChannelId: fresh.channelId)?.collections.map(\.name), ["Cars"])
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

    func testInstructionsListEveryCategoryAndAskForExactlyOne() {
        let text = CategoryPrompt.instructions(categories: ["Cars", "Food"])
        XCTAssertTrue(text.contains("- Cars"))
        XCTAssertTrue(text.contains("- Food"))
        XCTAssertTrue(text.contains("exactly one category name"))
    }

    func testPriorLineNamesYouTubesCategoryAndItsTaxonomyHome() {
        let prompt = CategoryPrompt.prompt(for: ChannelDescriptor(
            channelId: "UC1",
            title: "T",
            about: "",
            recentVideoTitles: [],
            youtubeSignal: YouTubeCategorySuggestion(
                categoryName: "Games",
                reason: "YouTube files most of its videos under Gaming"
            )
        ))
        XCTAssertTrue(prompt.contains("YouTube files most of its videos under Gaming, which is usually Games."), prompt)
    }

    func testNoPriorLineWithoutASignal() {
        let prompt = CategoryPrompt.prompt(for: ChannelDescriptor(
            channelId: "UC1", title: "T", about: "", recentVideoTitles: []
        ))
        XCTAssertFalse(prompt.contains("YouTube"))
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

}

// MARK: - The decision

/// The policy itself, without a store: one category from the model, a second
/// only from YouTube's own filing.
final class CategoryDecisionTests: XCTestCase {
    private let taxonomy = CategoryManager.defaultCategoryNames

    private func youtube(_ name: String) -> YouTubeCategorySuggestion {
        YouTubeCategorySuggestion(categoryName: name, reason: "YouTube files most of its videos under Gaming")
    }

    func testModelAnswerIsPrimaryAndYouTubeIsSecond() {
        let decided = CategoryDecision.decide(
            modelAnswer: CategoryGuess(categories: ["Comedy"], rawCategories: ["Comedy"]),
            youtube: youtube("Games"),
            taxonomy: taxonomy
        )
        XCTAssertEqual(decided.categories, ["Comedy", "Games"])
        XCTAssertEqual(decided.modelCategory, "Comedy")
        XCTAssertEqual(decided.youtubeCategory, "Games")
        XCTAssertEqual(decided.youtubeReason, "YouTube files most of its videos under Gaming")
        XCTAssertEqual(decided.rawCategories, ["Comedy"])
    }

    func testExtraModelAnswersAreDropped() {
        let decided = CategoryDecision.decide(
            modelAnswer: CategoryGuess(categories: ["Comedy", "Food", "Cars"]),
            youtube: nil,
            taxonomy: taxonomy
        )
        XCTAssertEqual(decided.categories, ["Comedy"])
        XCTAssertNil(decided.youtubeCategory)
    }

    func testOffListModelAnswersAreSkipped() {
        let decided = CategoryDecision.decide(
            modelAnswer: CategoryGuess(categories: ["Sports", "Cars"]),
            youtube: nil,
            taxonomy: taxonomy
        )
        XCTAssertEqual(decided.categories, ["Cars"], "the first on-list name is the primary")

        let none = CategoryDecision.decide(
            modelAnswer: CategoryGuess(categories: ["Sports"], rawCategories: ["Sports"]),
            youtube: youtube("Games"),
            taxonomy: taxonomy
        )
        XCTAssertEqual(none.categories, [])
        XCTAssertNil(none.modelCategory)
        XCTAssertEqual(none.rawCategories, ["Sports"], "the raw answer is kept for the evidence export")
    }

    func testAgreementProducesOneCategory() {
        let decided = CategoryDecision.decide(
            modelAnswer: CategoryGuess(categories: ["Games"]),
            youtube: youtube("Games"),
            taxonomy: taxonomy
        )
        XCTAssertEqual(decided.categories, ["Games"])
        XCTAssertNil(decided.youtubeCategory)
    }

    func testYouTubeCategoryMissingFromTheTaxonomyIsIgnored() {
        let decided = CategoryDecision.decide(
            modelAnswer: CategoryGuess(categories: ["Comedy"]),
            youtube: youtube("Sports"),
            taxonomy: taxonomy
        )
        XCTAssertEqual(decided.categories, ["Comedy"])
    }

    func testNeverMoreThanTwo() {
        for answer in [["Comedy", "Food", "Cars", "Games"], ["Comedy"], []] {
            let decided = CategoryDecision.decide(
                modelAnswer: CategoryGuess(categories: answer),
                youtube: youtube("Games"),
                taxonomy: taxonomy
            )
            XCTAssertLessThanOrEqual(decided.categories.count, CategoryPrompt.maxCategoriesPerChannel)
        }
    }
}
