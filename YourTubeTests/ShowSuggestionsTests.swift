import XCTest
import SwiftData
@testable import YourTube

/// The detector suggests, the user decides. Driven through `ShowSuggestions`
/// and `ShowManager` against an in-memory store, with the detector's verdicts
/// handed in directly (computing them is `ShowDetectorTests`): what's under
/// test is what the Pick grid and Your Shows would read back.
@MainActor
final class ShowSuggestionsTests: XCTestCase {
    private var container: ModelContainer!
    private var context: ModelContext { container.mainContext }
    private var shows: ShowManager!
    private var suggestions: ShowSuggestions!

    override func setUp() async throws {
        container = try ModelContainer(
            for: Video.self, Subscription.self, VideoCollection.self, ChannelRule.self, Show.self, ShowSuggestion.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        shows = ShowManager(modelContext: context, watchState: WatchState(modelContext: context))
        suggestions = ShowSuggestions(modelContext: context)
    }

    private func verdict(
        _ channelId: String,
        isShow: Bool = true,
        reasons: [String] = ["Posts on a regular schedule (Tue, Fri)"],
        dormant: Bool = false
    ) -> ShowVerdict {
        ShowVerdict(channelId: channelId, channelTitle: channelId, isShow: isShow, reasons: reasons, dormant: dormant)
    }

    private func pendingIds() throws -> [String] {
        try suggestions.pending().map(\.channelId)
    }

    // MARK: - Applying a pass

    func testAShowVerdictMakesASuggestionAndNeverAShow() throws {
        let changed = try suggestions.apply([verdict("UC-news"), verdict("UC-vlog", isShow: false)])

        XCTAssertEqual(changed, 1)
        XCTAssertEqual(try pendingIds(), ["UC-news"])
        XCTAssertTrue(try shows.shows().isEmpty, "the detector never adds a show")
        XCTAssertNil(try shows.record(forChannelId: "UC-news"))
    }

    func testASecondPassRefreshesTheReasonsAndCountsOnlyARealChange() throws {
        try suggestions.apply([verdict("UC-news", reasons: ["Old reason"])])
        XCTAssertEqual(try suggestions.apply([verdict("UC-news", reasons: ["Old reason"])]), 0)

        XCTAssertEqual(try suggestions.apply([verdict("UC-news", reasons: ["New reason"])]), 1)
        XCTAssertEqual(try suggestions.pending().map(\.reasons), [["New reason"]])
    }

    func testANotAShowVerdictWithdrawsAPendingSuggestionSilently() throws {
        try suggestions.apply([verdict("UC-news")])

        try suggestions.apply([verdict("UC-news", isShow: false)])

        XCTAssertTrue(try pendingIds().isEmpty)
        XCTAssertNil(try shows.record(forChannelId: "UC-news"), "and leaves no tombstone: nobody decided")
    }

    /// Going quiet is no longer a question for the user: a suggestion that
    /// goes dormant is simply withdrawn.
    func testADormantVerdictRemovesASuggestionRatherThanAsking() throws {
        try suggestions.apply([verdict("UC-news")])

        try suggestions.apply([verdict("UC-news", isShow: false, reasons: ["Hasn't posted in 130 days"], dormant: true)])

        XCTAssertTrue(try pendingIds().isEmpty)
        XCTAssertTrue(try shows.shows().isEmpty)
    }

    func testAChannelTheUserCalledNotAShowIsNeverSuggested() throws {
        try shows.markAsNotAShow(channelId: "UC-vlog", channelTitle: "Berlin Vlogs")

        try suggestions.apply([verdict("UC-vlog")])

        XCTAssertTrue(try pendingIds().isEmpty)
        XCTAssertEqual(try shows.record(forChannelId: "UC-vlog")?.override, .forceNotShow)
    }

    /// The other direction: a show the user added is never touched by a pass,
    /// dormant or not.
    func testAShowTheUserAddedIsNeverSuggestedOrRemoved() throws {
        try shows.markAsShow(channelId: "UC-news", channelTitle: "Newsline")

        try suggestions.apply([verdict("UC-news")])
        try suggestions.apply([verdict("UC-news", isShow: false, dormant: true)])

        XCTAssertTrue(try pendingIds().isEmpty)
        let record = try XCTUnwrap(shows.record(forChannelId: "UC-news"))
        XCTAssertTrue(record.isActive)
        XCTAssertEqual(record.title, "Newsline", "the pass doesn't get to rename it either")
    }

    /// A playlist show is the user's opinion about one playlist, not about
    /// the channel, so the channel can still be suggested.
    func testAPlaylistShowDoesNotCountAsADecisionAboutItsChannel() throws {
        try shows.addPlaylistShow(
            [PlaylistChoice(playlistId: "PL-s1", title: "Season 1")], channelId: "UC-quiz", title: "Quizmaster"
        )

        try suggestions.apply([verdict("UC-quiz")])

        XCTAssertEqual(try pendingIds(), ["UC-quiz"])
    }

    // MARK: - The user's answers

    func testAcceptingAddsAUserShowThatKeepsItsReasons() throws {
        try suggestions.apply([verdict("UC-news", reasons: ["Episodes usually run 1 hr 5 min", "Numbered episodes"])])

        try suggestions.accept(["UC-news"])

        XCTAssertTrue(try pendingIds().isEmpty)
        let show = try XCTUnwrap(shows.shows().first)
        XCTAssertEqual(show.channelId, "UC-news")
        XCTAssertEqual(show.flagOrigin, .user)
        XCTAssertEqual(show.override, .forceShow)
        XCTAssertEqual(show.detectorReasons, ["Episodes usually run 1 hr 5 min", "Numbered episodes"])
    }

    func testSettingAsideLeavesATombstoneSoItIsNeverSuggestedAgain() throws {
        try suggestions.apply([verdict("UC-vlog")])

        try suggestions.setAside(["UC-vlog"])
        try suggestions.apply([verdict("UC-vlog")])

        XCTAssertTrue(try pendingIds().isEmpty)
        XCTAssertTrue(try shows.shows().isEmpty)
        XCTAssertEqual(try shows.record(forChannelId: "UC-vlog")?.override, .forceNotShow)
    }

    /// Set aside is permanent for the detector, not for the user: the
    /// Channels tab flag still works.
    func testASetAsideChannelCanStillBeFlaggedByHand() throws {
        try suggestions.apply([verdict("UC-vlog")])
        try suggestions.setAside(["UC-vlog"])

        try shows.markAsShow(channelId: "UC-vlog", channelTitle: "Berlin Vlogs")

        XCTAssertEqual(try shows.shows().map(\.channelId), ["UC-vlog"])
    }

    func testThePickAddsTheTickedAndSetsAsideTheRestInOneGo() throws {
        try suggestions.apply([verdict("UC-a"), verdict("UC-b"), verdict("UC-c")])

        try suggestions.resolve(accepting: ["UC-b"], settingAside: ["UC-a", "UC-c"])

        XCTAssertTrue(try pendingIds().isEmpty)
        XCTAssertEqual(try shows.shows().map(\.channelId), ["UC-b"])
        XCTAssertEqual(try shows.allRecords().filter { !$0.isActive }.map(\.channelId).sorted(), ["UC-a", "UC-c"])
        XCTAssertFalse(context.hasChanges, "saved")
    }

    /// A suggestion withdrawn while the sheet was open isn't decided by the
    /// button: nothing was promised about it.
    func testThePickSkipsAChannelNoLongerPending() throws {
        try suggestions.apply([verdict("UC-a"), verdict("UC-b")])
        try suggestions.apply([verdict("UC-b", isShow: false)])

        try suggestions.resolve(accepting: [], settingAside: ["UC-a", "UC-b"])

        XCTAssertNil(try shows.record(forChannelId: "UC-b"))
        XCTAssertEqual(try shows.record(forChannelId: "UC-a")?.override, .forceNotShow)
    }

    // MARK: - Decisions made elsewhere

    func testFlaggingAChannelByHandClearsItsSuggestionWithoutReasons() throws {
        try suggestions.apply([verdict("UC-news")])

        try shows.markAsShow(channelId: "UC-news", channelTitle: "Newsline")

        XCTAssertTrue(try pendingIds().isEmpty)
        XCTAssertEqual(try shows.record(forChannelId: "UC-news")?.detectorReasons, [])
    }

    func testMarkingNotAShowByHandClearsItsSuggestion() throws {
        try suggestions.apply([verdict("UC-vlog")])

        try shows.markAsNotAShow(channelId: "UC-vlog", channelTitle: "Berlin Vlogs")

        XCTAssertTrue(try pendingIds().isEmpty)
    }

    func testDismissingASuggestionLeavesTheCatalogueAlone() throws {
        try suggestions.apply([verdict("UC-news")])

        try suggestions.dismissSuggestion(forChannel: "UC-news")

        XCTAssertTrue(try pendingIds().isEmpty)
        XCTAssertNil(try shows.record(forChannelId: "UC-news"))
    }

    // MARK: - Reading

    /// What you already watch comes first, and the poster says so.
    func testPendingIsRankedByWhatYouWatchAndCarriesTheEngagement() throws {
        try suggestions.apply([
            verdict("UC-quiet", reasons: ["a", "b", "c"]),
            verdict("UC-watched", reasons: ["a"]),
        ])
        for index in 0..<4 {
            context.insert(Video(
                videoId: "w\(index)", channelId: "UC-watched", channelTitle: "Watched",
                title: "", videoDescription: "", publishedAt: .now, durationSeconds: 3_000,
                isWatched: index < 2
            ))
        }
        try context.save()

        let pending = try suggestions.pending()

        XCTAssertEqual(pending.map(\.channelId), ["UC-watched", "UC-quiet"])
        XCTAssertEqual(pending.first?.engagement, SuggestionEngagement(watched: 2, total: 4))
        XCTAssertEqual(pending.first?.engagement.line, "You've watched 2 of 4")
        XCTAssertNil(pending.last?.engagement.line, "nothing to say, so nothing said")
        XCTAssertEqual(try suggestions.pendingCount(), 2)
    }

    // MARK: - Upgrade

    private func insertShow(
        _ channelId: String,
        origin: ShowFlagOrigin,
        override: ShowOverride = .none,
        reasons: [String] = []
    ) {
        let show = Show(source: .channel(id: channelId), title: channelId, flagOrigin: origin, override: override)
        show.detectorReasons = reasons
        context.insert(show)
    }

    func testTheUpgradeHandsTheDetectorsShowsBackAsSuggestions() throws {
        insertShow("UC-guess", origin: .heuristic, reasons: ["Numbered episodes", "Over twenty minutes"])
        insertShow("UC-mine", origin: .user, override: .forceShow)
        insertShow("UC-no", origin: .user, override: .forceNotShow)
        insertShow("UC-overridden", origin: .heuristic, override: .forceShow)
        let playlist = try shows.addPlaylistShow(
            [PlaylistChoice(playlistId: "PL-s1", title: "Season 1")], channelId: "UC-quiz", title: "Quizmaster"
        )
        try context.save()

        let converted = try ShowSuggestions.convertHeuristicShows(in: context)

        XCTAssertEqual(converted, 1)
        XCTAssertEqual(try suggestions.pending().map(\.channelId), ["UC-guess"])
        XCTAssertEqual(try suggestions.pending().first?.reasons, ["Numbered episodes", "Over twenty minutes"])
        XCTAssertNil(try shows.record(forChannelId: "UC-guess"), "the guessed show is gone")
        XCTAssertEqual(
            try shows.shows().map(\.channelId).sorted(),
            ["UC-mine", "UC-overridden", "UC-quiz"],
            "hand-made shows, overrides and the playlist show are untouched"
        )
        XCTAssertNotNil(try shows.record(id: playlist.id))
        XCTAssertEqual(try shows.record(forChannelId: "UC-no")?.override, .forceNotShow)
    }

    func testRunningTheUpgradeTwiceDoesNothingTheSecondTime() throws {
        insertShow("UC-guess", origin: .heuristic, reasons: ["Numbered episodes"])
        try context.save()
        try ShowSuggestions.convertHeuristicShows(in: context)

        XCTAssertEqual(try ShowSuggestions.convertHeuristicShows(in: context), 0)
        XCTAssertEqual(try pendingIds(), ["UC-guess"])
    }
}

/// The Pick grid's order, as a pure function: engagement, then the
/// detector's confidence, then the name.
final class SuggestionRankingTests: XCTestCase {
    func testRankingOrder() {
        let cases: [(name: String, title: String, reasons: Int, engagement: SuggestionEngagement)] = [
            ("most watched", "Zed", 1, SuggestionEngagement(watched: 5, total: 10)),
            ("earmarked and started count too", "Yak", 1, SuggestionEngagement(started: 1, earmarked: 2, total: 10)),
            ("surest, unwatched", "Xylo", 4, SuggestionEngagement(total: 10)),
            ("tie on both, A first", "Alpha", 2, SuggestionEngagement(total: 10)),
            ("tie on both, B second", "Bravo", 2, SuggestionEngagement(total: 10)),
        ]
        let shuffled = [cases[3], cases[0], cases[4], cases[2], cases[1]]

        let ranked = shuffled.sorted {
            SuggestionRanking.key(title: $0.title, reasons: Array(repeating: "", count: $0.reasons), engagement: $0.engagement)
                < SuggestionRanking.key(title: $1.title, reasons: Array(repeating: "", count: $1.reasons), engagement: $1.engagement)
        }

        XCTAssertEqual(ranked.map(\.name), cases.map(\.name))
    }

    func testEngagementLine() {
        XCTAssertNil(SuggestionEngagement(total: 62).line)
        XCTAssertEqual(SuggestionEngagement(watched: 14, total: 62).line, "You've watched 14 of 62")
        XCTAssertEqual(SuggestionEngagement(earmarked: 2, total: 62).line, "2 in Up Next")
        XCTAssertEqual(
            SuggestionEngagement(watched: 3, started: 1, earmarked: 1, total: 20).line,
            "You've watched 3 of 20, 1 started, 1 in Up Next"
        )
    }
}
