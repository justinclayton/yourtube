import XCTest
@testable import YourTube

final class YouTubeAPITests: XCTestCase {

    private func makeAPI() -> YouTubeAPI {
        YouTubeAPI(session: StubURLProtocol.session()) { "test-access-token" }
    }

    override func setUp() {
        super.setUp()
        StubURLProtocol.reset()
    }

    override func tearDown() {
        StubURLProtocol.reset()
        super.tearDown()
    }

    // MARK: - Subscriptions

    func testSubscriptionsDecodesItems() async throws {
        StubURLProtocol.stub(matching: "subscriptions", json: """
        {
          "items": [
            {
              "snippet": {
                "title": "Technology Connections",
                "resourceId": { "kind": "youtube#channel", "channelId": "UCy0tKL1T7wFoYcxCe0xjN6Q" },
                "thumbnails": { "default": { "url": "https://example.com/t.jpg", "width": 88, "height": 88 } }
              }
            }
          ]
        }
        """)

        let items = try await makeAPI().subscriptions()

        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items[0].snippet.title, "Technology Connections")
        XCTAssertEqual(items[0].snippet.resourceId.channelId, "UCy0tKL1T7wFoYcxCe0xjN6Q")
    }

    /// A pagination bug is the one realistic way this app burns its daily quota,
    /// so following nextPageToken is worth pinning down.
    func testSubscriptionsFollowsPagination() async throws {
        StubURLProtocol.stub(matching: "pageToken=PAGE2", json: """
        { "items": [ { "snippet": { "title": "B", "resourceId": { "channelId": "UCbbb" } } } ] }
        """)
        StubURLProtocol.stub(matching: "subscriptions", json: """
        {
          "nextPageToken": "PAGE2",
          "items": [ { "snippet": { "title": "A", "resourceId": { "channelId": "UCaaa" } } } ]
        }
        """)

        let items = try await makeAPI().subscriptions()

        XCTAssertEqual(items.count, 2)
        XCTAssertEqual(items.map(\.snippet.title), ["A", "B"])
        XCTAssertEqual(StubURLProtocol.recordedRequests.count, 2)
    }

    func testRequestCarriesBearerToken() async throws {
        StubURLProtocol.stub(matching: "subscriptions", json: #"{ "items": [] }"#)
        _ = try await makeAPI().subscriptions()

        let auth = StubURLProtocol.recordedRequests.first?
            .value(forHTTPHeaderField: "Authorization")
        XCTAssertEqual(auth, "Bearer test-access-token")
    }

    // MARK: - Videos

    func testVideosDecodesDurationAndSnippet() async throws {
        StubURLProtocol.stub(matching: "videos", json: """
        {
          "items": [
            {
              "id": "abc123",
              "snippet": {
                "title": "A video",
                "description": "Body text",
                "channelId": "UCaaa",
                "channelTitle": "Some Channel",
                "publishedAt": "2026-03-04T10:00:00Z",
                "thumbnails": { "high": { "url": "https://example.com/h.jpg", "width": 480, "height": 360 } }
              },
              "contentDetails": { "duration": "PT12M7S" }
            }
          ]
        }
        """)

        let videos = try await makeAPI().videos(ids: ["abc123"])

        XCTAssertEqual(videos.count, 1)
        XCTAssertEqual(videos[0].id, "abc123")
        XCTAssertEqual(videos[0].contentDetails?.duration, "PT12M7S")
        XCTAssertEqual(videos[0].snippet?.channelTitle, "Some Channel")
        XCTAssertNotNil(videos[0].snippet?.publishedAt)
    }

    /// videos.list caps at 50 IDs, so more than that has to be split.
    func testVideosBatchesRequestsInFifties() async throws {
        StubURLProtocol.stub(matching: "videos", json: #"{ "items": [] }"#)
        _ = try await makeAPI().videos(ids: (0..<120).map { "id\($0)" })
        XCTAssertEqual(StubURLProtocol.recordedRequests.count, 3)
    }

    func testVideosWithNoIdsMakesNoRequests() async throws {
        _ = try await makeAPI().videos(ids: [])
        XCTAssertTrue(StubURLProtocol.recordedRequests.isEmpty)
    }

    // MARK: - Dates

    /// YouTube sometimes includes fractional seconds and sometimes doesn't.
    func testDecodesTimestampsWithAndWithoutFractionalSeconds() async throws {
        StubURLProtocol.stub(matching: "videos", json: """
        {
          "items": [
            { "id": "a", "snippet": { "publishedAt": "2026-03-04T10:00:00Z" },
              "contentDetails": { "duration": "PT1M" } },
            { "id": "b", "snippet": { "publishedAt": "2026-03-04T10:00:00.123Z" },
              "contentDetails": { "duration": "PT1M" } }
          ]
        }
        """)

        let videos = try await makeAPI().videos(ids: ["a", "b"])
        XCTAssertNotNil(videos[0].snippet?.publishedAt)
        XCTAssertNotNil(videos[1].snippet?.publishedAt)
    }

    // MARK: - Errors

    func testQuotaExceededIsSurfacedDistinctly() async {
        StubURLProtocol.stub(matching: "subscriptions", json: """
        {
          "error": {
            "code": 403,
            "message": "The request cannot be completed because you have exceeded your quota.",
            "errors": [ { "reason": "quotaExceeded" } ]
          }
        }
        """, statusCode: 403)

        do {
            _ = try await makeAPI().subscriptions()
            XCTFail("Expected quotaExceeded")
        } catch YouTubeAPI.APIError.quotaExceeded {
            // Expected: the UI needs to tell these apart from generic failures.
        } catch {
            XCTFail("Expected quotaExceeded, got \(error)")
        }
    }

    func testUnauthorizedIsSurfacedDistinctly() async {
        StubURLProtocol.stub(
            matching: "subscriptions",
            json: #"{ "error": { "code": 401, "message": "Invalid Credentials" } }"#,
            statusCode: 401
        )

        do {
            _ = try await makeAPI().subscriptions()
            XCTFail("Expected unauthorized")
        } catch YouTubeAPI.APIError.unauthorized {
            // Expected: drives the re-auth banner.
        } catch {
            XCTFail("Expected unauthorized, got \(error)")
        }
    }

    // MARK: - Playlists

    func testPlaylistsDecodesTitlesAndItemCounts() async throws {
        StubURLProtocol.stub(matching: "playlists", json: """
        {
          "items": [
            {
              "id": "PLfriend",
              "snippet": { "title": "Conan O'Brien Needs a Friend", "channelId": "UCcoco" },
              "contentDetails": { "itemCount": 312 }
            },
            { "id": "PLclips", "snippet": { "title": "Clips" } }
          ]
        }
        """)

        let playlists = try await makeAPI().playlists(channelId: "UCcoco")

        XCTAssertEqual(playlists.count, 2)
        XCTAssertEqual(playlists[0].id, "PLfriend")
        XCTAssertEqual(playlists[0].title, "Conan O'Brien Needs a Friend")
        XCTAssertEqual(playlists[0].itemCount, 312)
        XCTAssertEqual(playlists[1].itemCount, 0, "a playlist with no contentDetails counts as empty")
    }

    /// One unit per call, and the call is only ever made on demand — so the
    /// request has to carry the channel it's asking about and nothing else.
    func testPlaylistsAsksForOneChannelInOnePageOfFifty() async throws {
        StubURLProtocol.stub(matching: "playlists", json: #"{ "items": [] }"#)
        _ = try await makeAPI().playlists(channelId: "UCcoco")

        let url = try XCTUnwrap(StubURLProtocol.recordedRequests.first?.url?.absoluteString)
        XCTAssertTrue(url.contains("channelId=UCcoco"), url)
        XCTAssertTrue(url.contains("maxResults=50"), url)
        XCTAssertEqual(StubURLProtocol.recordedRequests.count, 1)
    }

    // MARK: - Playlist items

    func testPlaylistItemsFollowsPaginationAndKeepsPlaylistOrder() async throws {
        StubURLProtocol.stub(matching: "pageToken=PAGE2", json: """
        { "items": [ { "contentDetails": { "videoId": "c" } } ] }
        """)
        StubURLProtocol.stub(matching: "playlistItems", json: """
        {
          "nextPageToken": "PAGE2",
          "items": [
            { "contentDetails": { "videoId": "a" } },
            { "snippet": { "resourceId": { "videoId": "b" } } }
          ]
        }
        """)

        let items = try await makeAPI().playlistItems(playlistId: "PLfriend")

        XCTAssertEqual(items.compactMap(\.videoId), ["a", "b", "c"])
        XCTAssertEqual(StubURLProtocol.recordedRequests.count, 2)
    }

    /// The same guard the uploads fetch has: a nextPageToken that never runs
    /// out stops at the page limit instead of spending the day's quota.
    func testPlaylistItemsStopsAtThePageLimit() async throws {
        StubURLProtocol.stub(matching: "playlistItems", json: """
        { "nextPageToken": "ALWAYS", "items": [ { "contentDetails": { "videoId": "a" } } ] }
        """)

        let items = try await makeAPI().playlistItems(playlistId: "PLloop", pageLimit: 3)

        XCTAssertEqual(items.count, 3)
        XCTAssertEqual(StubURLProtocol.recordedRequests.count, 3, "the guard holds")
    }

    func testPlaylistItemsAsksForOnePlaylist() async throws {
        StubURLProtocol.stub(matching: "playlistItems", json: #"{ "items": [] }"#)
        _ = try await makeAPI().playlistItems(playlistId: "PLfriend")

        let url = try XCTUnwrap(StubURLProtocol.recordedRequests.first?.url?.absoluteString)
        XCTAssertTrue(url.contains("playlistId=PLfriend"), url)
        XCTAssertEqual(StubURLProtocol.recordedRequests.count, 1)
    }
}
