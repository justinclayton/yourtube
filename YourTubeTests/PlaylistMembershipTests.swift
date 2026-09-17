import XCTest
import SwiftData
@testable import YourTube

/// Refreshing a playlist-backed show's membership: what it records, what it
/// counts as new, and what it costs.
///
/// The container holds `Show.self` — `FeedRefresherTests`' didn't, which is
/// why none of this could be tested there — and the thumbnail verdict is
/// canned, so the only stubbed traffic is the two API calls whose quota is
/// being counted.
@MainActor
final class PlaylistMembershipTests: XCTestCase {
    private var container: ModelContainer!
    private var context: ModelContext { container.mainContext }
    private var shows: ShowManager!

    override func setUp() async throws {
        container = try ModelContainer(
            for: Video.self, Subscription.self, VideoCollection.self, ChannelRule.self, Show.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        shows = ShowManager(
            modelContext: context, watchState: WatchState(modelContext: context)
        )
        StubURLProtocol.reset()
    }

    override func tearDown() {
        StubURLProtocol.reset()
        super.tearDown()
    }

    /// One playlist page and one hydration batch: two units, and every item
    /// is new.
    func testFirstRefreshRecordsMembershipAndCountsEveryVideoAsNew() async throws {
        StubURLProtocol.stub(matching: "playlistId=PL-a", json: Self.playlistJSON(["v1", "v2", "v3"]))
        StubURLProtocol.stub(matching: "videos", json: Self.videosJSON(["v1", "v2", "v3"]))
        let show = try makeShow(seasons: [("PL-a", "Series A")])

        let result = try await makeRefresher().refreshMembership(of: show, using: shows)

        XCTAssertEqual(result, .init(newVideos: 3, quotaUnits: 2))
        XCTAssertEqual(show.playlistItemIds["PL-a"], ["v1", "v2", "v3"])
        XCTAssertNotNil(show.membershipRefreshedAt)
        XCTAssertEqual(
            Set(try context.fetch(FetchDescriptor<Video>()).map(\.videoId)), ["v1", "v2", "v3"]
        )
    }

    /// A video the store already has costs nothing to see again: the playlist
    /// page is still a unit, the hydration batch isn't spent at all.
    func testKnownVideosAreNotHydratedAndAreNotNew() async throws {
        StubURLProtocol.stub(matching: "playlistId=PL-a", json: Self.playlistJSON(["v1", "v2"]))
        let intake = makeIntake()
        try await intake.admit([Self.item(id: "v1"), Self.item(id: "v2")])
        let show = try makeShow(seasons: [("PL-a", "Series A")])

        let result = try await makeRefresher(intake: intake)
            .refreshMembership(of: show, using: shows)

        XCTAssertEqual(result, .init(newVideos: 0, quotaUnits: 1))
        XCTAssertEqual(show.playlistItemIds["PL-a"], ["v1", "v2"])
    }

    /// Two seasons of one show can overlap, and a playlist can list the same
    /// video twice. Either would be a wasted hydration, so each ID is
    /// hydrated once — but every playlist page is still a unit.
    func testOverlappingSeasonsHydrateEachVideoOnce() async throws {
        StubURLProtocol.stub(matching: "playlistId=PL-a", json: Self.playlistJSON(["v1", "v2", "v2"]))
        StubURLProtocol.stub(matching: "playlistId=PL-b", json: Self.playlistJSON(["v2", "v3"]))
        StubURLProtocol.stub(matching: "videos", json: Self.videosJSON(["v1", "v2", "v3"]))
        let show = try makeShow(seasons: [("PL-a", "Series A"), ("PL-b", "Series B")])

        let result = try await makeRefresher().refreshMembership(of: show, using: shows)

        // Two playlist pages plus one hydration batch of three.
        XCTAssertEqual(result, .init(newVideos: 3, quotaUnits: 3))
        XCTAssertEqual(show.playlistItemIds["PL-a"], ["v1", "v2", "v2"])
        XCTAssertEqual(show.playlistItemIds["PL-b"], ["v2", "v3"])
    }

    /// A playlist page is 50 items, so a playlist of 60 costs two units to
    /// walk. The cost is counted from what came back rather than from how
    /// many calls `playlistItems` made for itself.
    func testQuotaCountsAPagePerFiftyPlaylistItems() async throws {
        let ids = (0..<60).map { "v\($0)" }
        StubURLProtocol.stub(matching: "playlistId=PL-a", json: Self.playlistJSON(ids))
        let intake = makeIntake()
        try await intake.admit(ids.map(Self.item(id:)))
        let show = try makeShow(seasons: [("PL-a", "Series A")])

        let result = try await makeRefresher(intake: intake)
            .refreshMembership(of: show, using: shows)

        XCTAssertEqual(result, .init(newVideos: 0, quotaUnits: 2))
    }

    /// An empty playlist still costs the page it was asked for.
    func testEmptyPlaylistStillCostsItsPage() async throws {
        StubURLProtocol.stub(matching: "playlistId=PL-a", json: Self.playlistJSON([]))
        let show = try makeShow(seasons: [("PL-a", "Series A")])

        let result = try await makeRefresher().refreshMembership(of: show, using: shows)

        XCTAssertEqual(result, .init(newVideos: 0, quotaUnits: 1))
    }

    /// A live stream in the playlist comes back from `videos.list` with no
    /// duration, so intake can't judge it and doesn't store it. It isn't new,
    /// because it isn't there.
    func testAVideoIntakeCannotStoreIsNotCountedAsNew() async throws {
        StubURLProtocol.stub(matching: "playlistId=PL-a", json: Self.playlistJSON(["v1", "live"]))
        StubURLProtocol.stub(matching: "videos", json: """
        { "items": [ \(Self.videoJSON(id: "v1")), \(Self.videoJSON(id: "live", duration: nil)) ] }
        """)
        let show = try makeShow(seasons: [("PL-a", "Series A")])

        let result = try await makeRefresher().refreshMembership(of: show, using: shows)

        XCTAssertEqual(result, .init(newVideos: 1, quotaUnits: 2))
        XCTAssertEqual(try context.fetch(FetchDescriptor<Video>()).map(\.videoId), ["v1"])
    }

    /// Making a playlist show and opening its page are two separate reasons
    /// to ask what's in the playlist, seconds apart — `PlaylistShowPicker
    /// .add()` and `ShowPageView.refreshMembershipIfNeeded()`. The second ask
    /// must cost nothing rather than walk the same playlists again.
    func testASecondRefreshStraightAfterTheFirstCostsNothing() async throws {
        StubURLProtocol.stub(matching: "playlistId=PL-a", json: Self.playlistJSON(["v1"]))
        StubURLProtocol.stub(matching: "videos", json: Self.videosJSON(["v1"]))
        let show = try makeShow(seasons: [("PL-a", "Series A")])
        let refresher = makeRefresher()

        _ = try await refresher.refreshMembership(of: show, using: shows)
        let requestsAfterFirst = StubURLProtocol.recordedRequests.count
        let second = try await refresher.refreshMembership(of: show, using: shows)

        XCTAssertEqual(second, .init(newVideos: 0, quotaUnits: 0))
        XCTAssertEqual(
            StubURLProtocol.recordedRequests.count, requestsAfterFirst,
            "the second refresh went to the network anyway"
        )
    }

    /// Once the window has passed, opening the page asks again — that's the
    /// point of asking when a page opens.
    func testARefreshAfterTheWindowAsksAgain() async throws {
        StubURLProtocol.stub(matching: "playlistId=PL-a", json: Self.playlistJSON(["v1"]))
        StubURLProtocol.stub(matching: "videos", json: Self.videosJSON(["v1"]))
        let show = try makeShow(seasons: [("PL-a", "Series A")])
        let refresher = makeRefresher()

        _ = try await refresher.refreshMembership(of: show, using: shows)
        show.membershipRefreshedAt = Date(
            timeIntervalSinceNow: -FeedRefresher.membershipFreshnessWindow - 1
        )
        let second = try await refresher.refreshMembership(of: show, using: shows)

        // The playlist is walked again; nothing in it is new any more.
        XCTAssertEqual(second, .init(newVideos: 0, quotaUnits: 1))
    }

    /// A channel-backed show has no playlist to walk. Its episodes arrive
    /// with the routine refresh.
    func testAChannelBackedShowCostsNothing() async throws {
        let show = try shows.markAsShow(channelId: "UCaaa", channelTitle: "Some Channel")

        let result = try await makeRefresher().refreshMembership(of: show, using: shows)

        XCTAssertEqual(result, .init(newVideos: 0, quotaUnits: 0))
        XCTAssertTrue(StubURLProtocol.recordedRequests.isEmpty)
    }

    // MARK: - Helpers

    private func makeShow(seasons: [(id: String, name: String)]) throws -> Show {
        try shows.addPlaylistShow(
            seasons.map { PlaylistChoice(playlistId: $0.id, title: $0.name) },
            channelId: "UCaaa",
            title: "A Show"
        )
    }

    private func makeIntake() -> VideoIntake {
        VideoIntake(
            writer: StoreWriter(modelContainer: container),
            thumbnails: CannedThumbnailVerdict()
        )
    }

    private func makeRefresher(intake: VideoIntake? = nil) -> FeedRefresher {
        FeedRefresher(
            modelContext: context,
            api: YouTubeAPI(session: StubURLProtocol.session()) { "test-access-token" },
            intake: intake ?? makeIntake()
        )
    }

    private static func playlistJSON(_ videoIds: [String]) -> String {
        let items = videoIds
            .map { "{ \"contentDetails\": { \"videoId\": \"\($0)\" } }" }
            .joined(separator: ",")
        return "{ \"items\": [\(items)] }"
    }

    private static func videosJSON(_ ids: [String]) -> String {
        "{ \"items\": [\(ids.map { videoJSON(id: $0) }.joined(separator: ","))] }"
    }

    /// Ten minutes: outside the Shorts duration gate, so no verdict is needed.
    private static func videoJSON(id: String, duration: String? = "PT10M") -> String {
        """
        {
          "id": "\(id)",
          "snippet": {
            "title": "Video \(id)",
            "description": "",
            "channelId": "UCaaa",
            "channelTitle": "Some Channel",
            "publishedAt": "2026-09-01T10:00:00Z"
          },
          "contentDetails": { \(duration.map { "\"duration\": \"\($0)\"" } ?? "") }
        }
        """
    }

    private static func item(id: String) -> YT.VideoItem {
        YT.VideoItem(
            id: id,
            snippet: YT.VideoItem.Snippet(
                title: "Video \(id)", description: "", channelId: "UCaaa",
                channelTitle: "Some Channel", publishedAt: .now,
                thumbnails: nil, categoryId: nil
            ),
            contentDetails: YT.VideoItem.ContentDetails(duration: "PT10M")
        )
    }
}
