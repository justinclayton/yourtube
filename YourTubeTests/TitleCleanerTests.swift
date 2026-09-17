import XCTest
import SwiftData
@testable import YourTube

/// Answers from a lookup table so the cleaner's tier-two bookkeeping can be
/// tested without the on-device model, the way `CategoryManagerTests` stubs
/// the categorizer.
private struct StubRewriter: TitleRewriter {
    struct Refused: Error {}

    /// Stripped title -> what the model "answers". Anything not listed comes
    /// back sentence-cased, which is what the real rewrite mostly does.
    var answers: [String: String] = [:]
    /// Stripped titles the stub throws on, standing in for a guardrail refusal.
    var refuses: Set<String> = []
    /// Every request the stub was given, so a test can assert on who was asked.
    final class Log: @unchecked Sendable {
        var requests: [TitleRewriteRequest] = []
    }
    var log = Log()

    func rewrite(_ request: TitleRewriteRequest) async throws -> String {
        log.requests.append(request)
        if refuses.contains(request.strippedTitle) { throw Refused() }
        if let answer = answers[request.strippedTitle] { return answer }
        return request.strippedTitle.lowercased()
    }
}

/// Stops a rewrite batch in the middle of itself, so the store can be
/// inspected while a run is in flight.
private final class GatedRewriter: TitleRewriter, @unchecked Sendable {
    /// Fulfilled when the call named by `stopAt` arrives.
    let reached: XCTestExpectation
    private let stopAt: Int
    private let gate = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var calls = 0

    init(stopAt: Int, reached: XCTestExpectation) {
        self.stopAt = stopAt
        self.reached = reached
    }

    func rewrite(_ request: TitleRewriteRequest) async throws -> String {
        lock.lock()
        calls += 1
        let call = calls
        lock.unlock()
        if call == stopAt {
            reached.fulfill()
            // Runs on the writer's own thread, so blocking here holds only the
            // batch; the main actor stays free for the test to look around.
            gate.wait()
        }
        return request.strippedTitle.lowercased()
    }

    func resume() { gate.signal() }
}

/// The cleaner's own job is the bookkeeping around `TitleStripper`: which
/// videos are stale, which titles it judges them against, and that a version
/// bump re-does the lot. Driven against an in-memory container, the way
/// `CategoryManagerTests` drives the category manager.
@MainActor
final class TitleCleanerTests: XCTestCase {
    private var container: ModelContainer!
    private var context: ModelContext { container.mainContext }

    override func setUp() async throws {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        container = try ModelContainer(
            for: Video.self, Subscription.self, VideoCollection.self, ChannelRule.self, Show.self,
            configurations: config
        )
    }

    /// REAL: QI, whose every upload ends "| QI".
    private let qi = [
        "How To Ruin University Challenge | QI",
        "Sandi's Favourite Malicious Compliance | QI",
        "How Do Bonobos Have Fun? | QI",
        "The Mysterious Flowers With Synchronised Lifespans | QI",
        "What's The Most Recognised Song In Britain? | QI",
    ]

    @discardableResult
    private func seed(
        _ titles: [String],
        channelId: String = "UC-qi",
        cleanerVersion: Int = 0
    ) -> [Video] {
        let videos = titles.enumerated().map { index, title in
            Video(
                videoId: "\(channelId)-\(index)",
                channelId: channelId,
                channelTitle: channelId,
                title: title,
                videoDescription: "",
                publishedAt: Date(timeIntervalSinceNow: -Double(index) * 3600),
                durationSeconds: 1800,
                titleCleanerVersion: cleanerVersion
            )
        }
        videos.forEach(context.insert)
        try? context.save()
        return videos
    }

    private func stored(channelId: String = "UC-qi") throws -> [Video] {
        try context.fetch(FetchDescriptor<Video>(
            predicate: #Predicate { $0.channelId == channelId },
            sortBy: [SortDescriptor(\.publishedAt, order: .reverse)]
        ))
    }

    // MARK: - A first run

    func testCleansStoredVideosAndStampsTheVersion() async throws {
        seed(qi)
        let cleaner = TitleCleaner(modelContext: context)
        await cleaner.cleanStale()

        let videos = try stored()
        XCTAssertEqual(videos.map(\.displayTitle).first, "How To Ruin University Challenge")
        XCTAssertTrue(videos.allSatisfy { $0.titleCleanerVersion == TitleCleaner.version })
        XCTAssertTrue(videos.allSatisfy { $0.hasCleanedTitle })
        XCTAssertEqual(cleaner.status, .idle)
    }

    /// A video that hasn't been cleaned yet shows its raw title, which is
    /// what lets cleaning run behind the feed instead of in front of it.
    func testUncleanedVideoDisplaysItsRawTitle() throws {
        let videos = seed(qi)
        XCTAssertEqual(videos[0].displayTitle, "How To Ruin University Challenge | QI")
        XCTAssertFalse(videos[0].hasCleanedTitle)
        XCTAssertNil(videos[0].episodeLabel)
    }

    /// Each channel is judged against its own titles only; one channel's
    /// suffix must never be taken off another's.
    func testChannelsAreCleanedAgainstTheirOwnTitlesOnly() async throws {
        seed(qi)
        seed(
            ["Bench planes | QI", "Sharpening jigs | Woodwork", "Dovetails | Weekly", "Oak finishes"],
            channelId: "UC-wood"
        )
        await TitleCleaner(modelContext: context).cleanStale()

        XCTAssertEqual(try stored()[0].displayTitle, "How To Ruin University Challenge")
        // Nothing repeats on the woodwork channel, so nothing is stripped —
        // including the "QI" that is boilerplate somewhere else.
        XCTAssertEqual(
            Set(try stored(channelId: "UC-wood").map(\.displayTitle)),
            ["Bench planes | QI", "Sharpening jigs | Woodwork", "Dovetails | Weekly", "Oak finishes"]
        )
    }

    /// REAL: four titles from the store that YouTube left a trailing space
    /// on. Dropping it is not a change the viewer needs the original for, so
    /// the player must not set a duplicate line underneath.
    func testTrailingWhitespaceAloneIsNotACleanedTitle() async throws {
        seed(
            ["I bought a house ", "How to larp ", "I'm Done ", "Building a community "],
            channelId: "UC-space"
        )
        await TitleCleaner(modelContext: context).cleanStale()

        let videos = try stored(channelId: "UC-space")
        XCTAssertEqual(Set(videos.map(\.displayTitle)),
                       ["I bought a house", "How to larp", "I'm Done", "Building a community"])
        XCTAssertTrue(videos.allSatisfy { !$0.hasCleanedTitle })
    }

    // MARK: - Versioning

    /// Videos already at the current version are left alone, which is what
    /// makes the every-launch run cheap.
    func testVideosAtTheCurrentVersionAreNotRecleaned() async throws {
        seed(qi, cleanerVersion: TitleCleaner.version)
        for video in try stored() { video.cleanedTitle = "left alone" }
        try context.save()

        await TitleCleaner(modelContext: context).cleanStale()
        XCTAssertEqual(Set(try stored().map(\.displayTitle)), ["left alone"])
    }

    /// The version bump: dropping one video below the current version marks
    /// its channel stale, and the next run re-cleans the channel — which is
    /// what happens to every stored video when `TitleStripper.version` goes
    /// up and the app next launches.
    func testAVersionBumpReclearsAlreadyStoredVideos() async throws {
        seed(qi, cleanerVersion: TitleCleaner.version)
        let seeded = try stored()
        for video in seeded { video.cleanedTitle = "stale result" }
        seeded[0].titleCleanerVersion = TitleCleaner.version - 1
        try context.save()

        await TitleCleaner(modelContext: context).cleanStale()

        let videos = try stored()
        XCTAssertEqual(videos[0].displayTitle, "How To Ruin University Challenge")
        // The whole channel, not only the video that was stale: the affix is
        // a channel-wide judgement and must not be applied half-way.
        XCTAssertEqual(videos[1].displayTitle, "Sandi's Favourite Malicious Compliance")
        XCTAssertTrue(videos.allSatisfy { $0.titleCleanerVersion == TitleCleaner.version })
    }

    // MARK: - Episode numbers

    /// REAL: Trolden, whose numbering is the only thing that varies.
    func testEpisodeNumbersAreCachedSeparatelyFromTheTitle() async throws {
        seed((671...675).reversed().map { "Funny And Lucky Moments - Hearthstone - Ep. \($0)" },
             channelId: "UC-trolden")
        await TitleCleaner(modelContext: context).cleanStale()

        let videos = try stored(channelId: "UC-trolden")
        XCTAssertEqual(videos[0].episodeNumber, 675)
        XCTAssertEqual(videos[0].episodeLabel, "Ep. 675")
        XCTAssertNil(videos[0].seasonNumber)
        XCTAssertFalse(videos[0].displayTitle.contains("675"))
    }

    // MARK: - Nothing to do

    func testEmptyStoreIsANoOp() async throws {
        let cleaner = TitleCleaner(modelContext: context)
        await cleaner.cleanStale()
        XCTAssertEqual(cleaner.status, .idle)
        XCTAssertNil(cleaner.lastRunAt)
    }

    // MARK: - Tier two

    private func makeShow(channelId: String, title: String) {
        context.insert(Show(
            source: .channel(id: channelId),
            title: title,
            flagOrigin: .user,
            override: .forceShow
        ))
        try? context.save()
    }

    private func makeCleaner(
        _ rewriter: (any TitleRewriter)?,
        rewriteEnabled: Bool = true
    ) -> TitleCleaner {
        let defaults = UserDefaults(suiteName: "TitleCleanerTests-\(UUID().uuidString)")!
        defaults.set(rewriteEnabled, forKey: TitleCleaner.rewriteEnabledKey)
        return TitleCleaner(modelContext: context, rewriter: rewriter, defaults: defaults)
    }

    /// The whole point of tier two: the stripped title goes to the model and
    /// the model's answer is what the viewer sees, with the raw title still
    /// recoverable underneath it in the player.
    func testShowEpisodesAreRewrittenOnTopOfTheStripping() async throws {
        makeShow(channelId: "UC-qi", title: "QI")
        seed(qi)
        let rewriter = StubRewriter(answers: [
            "How To Ruin University Challenge": "How to ruin University Challenge",
        ])
        await makeCleaner(rewriter).cleanStale()

        let video = try stored()[0]
        XCTAssertEqual(video.displayTitle, "How to ruin university challenge")
        XCTAssertEqual(video.strippedTitle, "How To Ruin University Challenge")
        XCTAssertTrue(video.isTitleRewritten)
        XCTAssertTrue(video.hasCleanedTitle)
        // The model is asked about the stripped title, never YouTube's, and is
        // told the show so it doesn't put the name back.
        XCTAssertEqual(rewriter.log.requests.first?.strippedTitle, "How To Ruin University Challenge")
        XCTAssertEqual(rewriter.log.requests.first?.showTitle, "QI")
    }

    /// A channel that isn't a show gets tier one only. The rewrite is a model
    /// call per title; spending it on every video in the store isn't worth it,
    /// and the shows are where clickbait is most in the way.
    func testVideosOutsideAShowGetTierOneOnly() async throws {
        makeShow(channelId: "UC-qi", title: "QI")
        seed(qi)
        seed(["A | Maker Weekly", "B | Maker Weekly", "C | Maker Weekly", "D | Maker Weekly"],
             channelId: "UC-maker")
        let rewriter = StubRewriter()
        await makeCleaner(rewriter).cleanStale()

        let maker = try stored(channelId: "UC-maker")
        XCTAssertEqual(Set(maker.map(\.displayTitle)), ["A", "B", "C", "D"])
        XCTAssertTrue(maker.allSatisfy { !$0.isTitleRewritten })
        XCTAssertTrue(rewriter.log.requests.allSatisfy { $0.showTitle == "QI" })
    }

    /// A playlist-backed show, made the way `ShowManager` makes one so its
    /// membership lands where the cleaner reads it.
    @discardableResult
    private func makePlaylistShow(
        _ title: String,
        channelId: String,
        playlistId: String,
        videoIds: [String]
    ) throws -> Show {
        let manager = ShowManager(modelContext: context, watchState: WatchState(modelContext: context))
        let show = try manager.addPlaylistShow(
            [PlaylistChoice(playlistId: playlistId, title: title)],
            channelId: channelId,
            title: title
        )
        try manager.setPlaylistItems(videoIds, playlistId: playlistId, of: show)
        return show
    }

    /// REAL: Team Coco hosts "Conan O'Brien Needs a Friend" as a playlist and
    /// posts a great deal else besides. Only the playlist's own members are
    /// episodes, so only they are rewritten — and the host channel's other
    /// uploads must not be handed the podcast's name.
    func testOnlyAPlaylistShowsMembersAreRewritten() async throws {
        seed(
            [
                "Ted Danson Needs A Friend",
                "Conan Reacts To His Own Monologue",
                "Michelle Obama Returns",
                "Clueless Gamer Plays Death Stranding",
                "Timothee Chalamet Drops In",
                "Conan Visits A Haunted House",
            ],
            channelId: "UC-coco"
        )
        try makePlaylistShow(
            "Conan O'Brien Needs a Friend",
            channelId: "UC-coco",
            playlistId: "PL-friend",
            videoIds: ["UC-coco-0", "UC-coco-2", "UC-coco-4"]
        )

        let rewriter = StubRewriter()
        await makeCleaner(rewriter).cleanStale()

        let byId = Dictionary(uniqueKeysWithValues: try stored(channelId: "UC-coco").map { ($0.videoId, $0) })
        XCTAssertEqual(byId["UC-coco-0"]?.displayTitle, "Ted Danson needs a friend")
        XCTAssertEqual(byId["UC-coco-2"]?.displayTitle, "Michelle Obama returns")
        XCTAssertEqual(byId["UC-coco-4"]?.displayTitle, "Timothee Chalamet drops in")
        // The channel's other uploads are nobody's episodes: tier one's title
        // stands, untouched by the model.
        XCTAssertEqual(byId["UC-coco-1"]?.displayTitle, "Conan Reacts To His Own Monologue")
        XCTAssertEqual(byId["UC-coco-3"]?.displayTitle, "Clueless Gamer Plays Death Stranding")
        XCTAssertEqual(byId["UC-coco-5"]?.displayTitle, "Conan Visits A Haunted House")
        XCTAssertEqual(
            ["UC-coco-1", "UC-coco-3", "UC-coco-5"].compactMap { byId[$0]?.isTitleRewritten },
            [false, false, false]
        )
        XCTAssertEqual(
            Set(rewriter.log.requests.map(\.strippedTitle)),
            ["Ted Danson Needs A Friend", "Michelle Obama Returns", "Timothee Chalamet Drops In"]
        )
        XCTAssertTrue(rewriter.log.requests.allSatisfy { $0.showTitle == "Conan O'Brien Needs a Friend" })
    }

    /// A playlist may hold a guest channel's video, and that video is still an
    /// episode of the podcast — named under it, not under the channel it was
    /// uploaded to.
    func testAPlaylistMemberFromAnotherChannelIsNamedUnderTheShow() async throws {
        seed(["Ted Danson Needs A Friend"], channelId: "UC-coco")
        seed(["The Crossover Episode"], channelId: "UC-guest")
        try makePlaylistShow(
            "Conan O'Brien Needs a Friend",
            channelId: "UC-coco",
            playlistId: "PL-friend",
            videoIds: ["UC-coco-0", "UC-guest-0"]
        )

        let rewriter = StubRewriter()
        await makeCleaner(rewriter).cleanStale()

        XCTAssertEqual(try stored(channelId: "UC-guest")[0].displayTitle, "The crossover episode")
        XCTAssertTrue(rewriter.log.requests.allSatisfy { $0.showTitle == "Conan O'Brien Needs a Friend" })
        XCTAssertEqual(rewriter.log.requests.count, 2)
    }

    /// Shorts are never episodes of anything, so they're never rewritten.
    func testShortsAreNotRewritten() async throws {
        makeShow(channelId: "UC-qi", title: "QI")
        let videos = seed(qi)
        videos[0].isLikelyShort = true
        try context.save()

        let rewriter = StubRewriter()
        await makeCleaner(rewriter).cleanStale()

        XCTAssertFalse(try stored()[0].isTitleRewritten)
        XCTAssertEqual(rewriter.log.requests.count, qi.count - 1)
    }

    /// An answer the app can't use costs the viewer the rewrite, never the
    /// title: the stripped version stands, with its shouting taken off.
    func testAnUnusableAnswerLeavesTheCalmedStrippedTitle() async throws {
        makeShow(channelId: "UC-qi", title: "QI")
        seed(qi)
        await makeCleaner(StubRewriter(answers: [
            "How To Ruin University Challenge": "   ",
            "Sandi's Favourite Malicious Compliance": String(repeating: "wordy ", count: 40),
        ])).cleanStale()

        let videos = try stored()
        XCTAssertEqual(videos[0].displayTitle, "How to ruin university challenge")
        XCTAssertEqual(videos[1].displayTitle, "Sandi's favourite malicious compliance")
    }

    /// A guardrail refusal on one news headline must not abort the rest.
    func testARefusedTitleIsCountedAndTheRunCarriesOn() async throws {
        makeShow(channelId: "UC-qi", title: "QI")
        seed(qi)
        let cleaner = makeCleaner(StubRewriter(refuses: ["How To Ruin University Challenge"]))
        await cleaner.cleanStale()

        // The refused title isn't left as tier one had it: it gets the
        // calming that needs no model, so a refusal costs the wording of
        // the rewrite and not its calm.
        let videos = try stored()
        XCTAssertEqual(videos[0].displayTitle, "How to ruin university challenge")
        XCTAssertEqual(videos[1].displayTitle, "Sandi's favourite malicious compliance")
        XCTAssertEqual(cleaner.lastRewriteFailures, 1)
        XCTAssertEqual(cleaner.rewriteStatus, .idle)
    }

    /// The device without Apple Intelligence: stripping still happens, and
    /// nothing is left half-cleaned waiting for a model that never arrives.
    func testWithoutAModelStrippingStillApplies() async throws {
        makeShow(channelId: "UC-qi", title: "QI")
        seed(qi)
        let cleaner = makeCleaner(nil)
        XCTAssertFalse(cleaner.canRewrite)
        await cleaner.cleanStale()

        let videos = try stored()
        XCTAssertEqual(videos[0].displayTitle, "How To Ruin University Challenge")
        XCTAssertTrue(videos.allSatisfy { !$0.isTitleRewritten })
        XCTAssertTrue(videos.allSatisfy { $0.titleCleanerVersion == TitleCleaner.version })
    }

    // MARK: - The setting

    /// Off means stripping only, from the start.
    func testWithTheSettingOffOnlyTheStrippingRuns() async throws {
        makeShow(channelId: "UC-qi", title: "QI")
        seed(qi)
        let rewriter = StubRewriter()
        await makeCleaner(rewriter, rewriteEnabled: false).cleanStale()

        XCTAssertEqual(try stored()[0].displayTitle, "How To Ruin University Challenge")
        XCTAssertTrue(rewriter.log.requests.isEmpty)
    }

    /// Turning it off puts the stripped titles back without re-running the
    /// stripper, which is why tier one's output is kept alongside the rewrite.
    func testTurningTheSettingOffRestoresTheStrippedTitles() async throws {
        makeShow(channelId: "UC-qi", title: "QI")
        seed(qi)
        let defaults = UserDefaults(suiteName: "TitleCleanerTests-\(UUID().uuidString)")!
        let cleaner = TitleCleaner(modelContext: context, rewriter: StubRewriter(), defaults: defaults)
        await cleaner.cleanStale()
        XCTAssertEqual(try stored()[0].displayTitle, "How to ruin university challenge")

        cleaner.isRewriteEnabled = false
        await cleaner.reconcileRewrites()

        let videos = try stored()
        XCTAssertEqual(videos[0].displayTitle, "How To Ruin University Challenge")
        XCTAssertTrue(videos.allSatisfy { !$0.isTitleRewritten })
        // Tier one's work is untouched: the version stamp doesn't move, so the
        // next launch doesn't re-strip the store.
        XCTAssertTrue(videos.allSatisfy { $0.titleCleanerVersion == TitleCleaner.version })
    }

    /// And turning it back on rewrites them again, without a second stripping
    /// pass.
    func testTurningTheSettingBackOnReRunsTheRewrite() async throws {
        makeShow(channelId: "UC-qi", title: "QI")
        seed(qi)
        let defaults = UserDefaults(suiteName: "TitleCleanerTests-\(UUID().uuidString)")!
        defaults.set(false, forKey: TitleCleaner.rewriteEnabledKey)
        let cleaner = TitleCleaner(modelContext: context, rewriter: StubRewriter(), defaults: defaults)
        await cleaner.cleanStale()
        XCTAssertEqual(try stored()[0].displayTitle, "How To Ruin University Challenge")

        cleaner.isRewriteEnabled = true
        await cleaner.reconcileRewrites()

        XCTAssertEqual(try stored()[0].displayTitle, "How to ruin university challenge")
        XCTAssertTrue(try stored().allSatisfy { $0.isTitleRewritten })
    }

    /// A channel flagged as a show after cleaning has already run picks up the
    /// rewrite on the next pass, with nothing to re-strip.
    func testAChannelFlaggedAsAShowLaterIsRewrittenOnTheNextPass() async throws {
        seed(qi)
        let cleaner = makeCleaner(StubRewriter())
        await cleaner.cleanStale()
        XCTAssertEqual(try stored()[0].displayTitle, "How To Ruin University Challenge")

        makeShow(channelId: "UC-qi", title: "QI")
        await cleaner.cleanStale()

        XCTAssertEqual(try stored()[0].displayTitle, "How to ruin university challenge")
    }

    // MARK: - Where the writes go

    /// What the cleaner was moved off the main context for: `@Query` observes
    /// that context live, unsaved edits included, so a pass that wrote a title
    /// at a time through it made every live query in the app re-fetch a title
    /// at a time. Freeze the rewrite once it has written one title and check
    /// the main context has nothing pending.
    func testARunInFlightLeavesNoUnsavedEditsOnTheMainContext() async throws {
        makeShow(channelId: "UC-qi", title: "QI")
        seed(qi)
        let reached = expectation(description: "the rewrite is under way")
        let rewriter = GatedRewriter(stopAt: 2, reached: reached)
        let cleaner = makeCleaner(rewriter)

        let run = Task { await cleaner.cleanStale() }
        await fulfillment(of: [reached], timeout: 5)

        XCTAssertFalse(
            context.hasChanges,
            "a batch pass writes on its own context, never the main one"
        )

        rewriter.resume()
        await run.value
        // And the work is in the store, not merely pending somewhere: a
        // context that has never seen any of it can read it back.
        let fresh = ModelContext(container)
        let videos = try fresh.fetch(FetchDescriptor<Video>(
            sortBy: [SortDescriptor(\.publishedAt, order: .reverse)]
        ))
        XCTAssertEqual(videos.first?.displayTitle, "How to ruin university challenge")
        XCTAssertTrue(videos.allSatisfy { $0.titleCleanerVersion == TitleCleaner.version })
    }

    /// The version bump with tier two in play: both tiers run again, so a
    /// rewrite is never left standing on a stripping that has changed.
    func testAVersionBumpReRunsBothTiers() async throws {
        makeShow(channelId: "UC-qi", title: "QI")
        seed(qi, cleanerVersion: TitleCleaner.version)
        let seeded = try stored()
        for video in seeded {
            video.cleanedTitle = "stale rewrite"
            video.strippedTitle = "stale stripping"
            video.isTitleRewritten = true
        }
        seeded[0].titleCleanerVersion = TitleCleaner.version - 1
        try context.save()

        await makeCleaner(StubRewriter()).cleanStale()

        let videos = try stored()
        XCTAssertEqual(videos[0].strippedTitle, "How To Ruin University Challenge")
        XCTAssertEqual(videos[0].displayTitle, "How to ruin university challenge")
        XCTAssertEqual(videos[1].strippedTitle, "Sandi's Favourite Malicious Compliance")
        XCTAssertTrue(videos.allSatisfy { $0.isTitleRewritten })
        XCTAssertTrue(videos.allSatisfy { $0.titleCleanerVersion == TitleCleaner.version })
    }

    // MARK: - Lazy, bounded rewriting (#65)

    private func freshDefaults() -> UserDefaults {
        UserDefaults(suiteName: "TitleCleanerTests-\(UUID().uuidString)")!
    }

    /// A cold launch with far more pending rewrites than any reasonable
    /// per-launch budget must stop at the budget and go idle, leaving the
    /// rest pending — not run the model once per title until the store is
    /// exhausted, which is what #65 measured (261 calls, 4.5 minutes).
    func testAutomaticPassStopsAtItsPerLaunchBudget() async throws {
        makeShow(channelId: "UC-qi", title: "QI")
        let titles = (0..<20).map { "Episode \($0) | QI" }
        seed(titles)
        let rewriter = StubRewriter()
        let cleaner = TitleCleaner(
            modelContext: context, rewriter: rewriter, defaults: freshDefaults(),
            rewriteBudgetPerLaunch: 3
        )

        await cleaner.cleanStale()

        XCTAssertEqual(rewriter.log.requests.count, 3)
        XCTAssertEqual(try stored().filter(\.isTitleRewritten).count, 3)
        // What's left is still stale, not stuck: nothing marks the unreached
        // episodes as seen, so a later pass (or opening the show) picks them
        // up rather than skipping them forever.
        XCTAssertEqual(try stored().filter { !$0.isTitleRewritten }.count, 17)
    }

    /// Titles are only read on the show page and the Shows tab, so the
    /// automatic pass only needs a show's retention window settled at
    /// launch — the rest is lazy, picked up when the show is opened.
    func testAutomaticPassOnlyRewritesTheShowsRetentionWindowByDefault() async throws {
        makeShow(channelId: "UC-qi", title: "QI")
        let titles = (0..<15).map { "Episode \($0) | QI" }
        seed(titles)
        let rewriter = StubRewriter()
        let cleaner = TitleCleaner(
            modelContext: context, rewriter: rewriter, defaults: freshDefaults(),
            rewriteBudgetPerLaunch: 1000
        )

        await cleaner.cleanStale()

        let videos = try stored()
        XCTAssertEqual(rewriter.log.requests.count, TitleCleaner.defaultRewriteWindow)
        XCTAssertTrue(videos.prefix(TitleCleaner.defaultRewriteWindow).allSatisfy(\.isTitleRewritten))
        XCTAssertTrue(videos.suffix(from: TitleCleaner.defaultRewriteWindow).allSatisfy { !$0.isTitleRewritten })
    }

    /// Opening a show page asks for that show's episodes in full, ahead of
    /// whatever the lazy window left behind — the ordering rule Done-when
    /// names explicitly.
    func testOpeningAShowRewritesItsRemainingEpisodesFirst() async throws {
        makeShow(channelId: "UC-qi", title: "QI")
        let titles = (0..<15).map { "Episode \($0) | QI" }
        seed(titles)
        let rewriter = StubRewriter()
        let cleaner = TitleCleaner(
            modelContext: context, rewriter: rewriter, defaults: freshDefaults(),
            rewriteBudgetPerLaunch: 1000
        )
        await cleaner.cleanStale()
        XCTAssertEqual(rewriter.log.requests.count, TitleCleaner.defaultRewriteWindow)

        await cleaner.rewriteEpisodes(ofShowId: ShowSource.channel(id: "UC-qi").showId)

        let videos = try stored()
        XCTAssertTrue(videos.allSatisfy(\.isTitleRewritten))
        XCTAssertEqual(rewriter.log.requests.count, 15)
    }

    /// A show open costs from the same per-launch budget as the automatic
    /// pass, so opening show after show can't turn into an unbounded run.
    func testOpeningAShowStillRespectsTheRemainingBudget() async throws {
        makeShow(channelId: "UC-qi", title: "QI")
        let titles = (0..<15).map { "Episode \($0) | QI" }
        seed(titles)
        let rewriter = StubRewriter()
        let cleaner = TitleCleaner(
            modelContext: context, rewriter: rewriter, defaults: freshDefaults(),
            rewriteBudgetPerLaunch: TitleCleaner.defaultRewriteWindow + 2
        )
        await cleaner.cleanStale()
        XCTAssertEqual(rewriter.log.requests.count, TitleCleaner.defaultRewriteWindow)

        await cleaner.rewriteEpisodes(ofShowId: ShowSource.channel(id: "UC-qi").showId)

        XCTAssertEqual(rewriter.log.requests.count, TitleCleaner.defaultRewriteWindow + 2)
        XCTAssertEqual(try stored().filter(\.isTitleRewritten).count, TitleCleaner.defaultRewriteWindow + 2)
    }

    /// The one moment the pass must never compete for the main thread: a
    /// refresh in flight. It's skipped rather than queued, so it costs
    /// nothing extra once the refresh finishes — the next trigger tries again.
    func testTheRewritePassIsSkippedWhileARefreshIsRunning() async throws {
        makeShow(channelId: "UC-qi", title: "QI")
        seed(qi)
        let rewriter = StubRewriter()
        let cleaner = TitleCleaner(
            modelContext: context, rewriter: rewriter, defaults: freshDefaults(),
            isRefreshingProvider: { true }
        )

        let didWork = await cleaner.reconcileRewrites()

        XCTAssertFalse(didWork)
        XCTAssertTrue(rewriter.log.requests.isEmpty)
        XCTAssertTrue(try stored().allSatisfy { !$0.isTitleRewritten })
    }

    /// The automatic entry point waits out its start delay before its first
    /// model call, so launch's first frame and the user's first tap never
    /// compete with it. Direct calls to `cleanStale()` (every other test in
    /// this file) skip the wait entirely.
    func testTheAutomaticPassWaitsBeforeItsFirstModelCall() async throws {
        makeShow(channelId: "UC-qi", title: "QI")
        seed(qi)
        let rewriter = StubRewriter()
        let cleaner = TitleCleaner(
            modelContext: context, rewriter: rewriter, defaults: freshDefaults(),
            startDelay: .milliseconds(150)
        )

        cleaner.cleanStaleInBackground()
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertTrue(rewriter.log.requests.isEmpty, "must not call the model before the start delay elapses")

        try await Task.sleep(for: .milliseconds(400))
        XCTAssertFalse(rewriter.log.requests.isEmpty, "should have run once the delay elapsed")
    }
}
