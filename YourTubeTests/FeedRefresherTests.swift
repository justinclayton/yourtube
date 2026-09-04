import XCTest
import SwiftData
import ImageIO
import UniformTypeIdentifiers
@testable import YourTube

/// Serves a thumbnail only once the test opens the gate. Lets a refresh be
/// frozen in the middle of Shorts classification so the store can be
/// inspected while a verdict is still pending.
final class GatedThumbnailProtocol: URLProtocol {
    nonisolated(unsafe) static var body = Data()
    nonisolated(unsafe) static var gate = DispatchSemaphore(value: 0)
    /// Fulfilled when the first thumbnail request arrives.
    nonisolated(unsafe) static var requested: XCTestExpectation?

    static func reset(body: Data) {
        self.body = body
        gate = DispatchSemaphore(value: 0)
        requested = nil
    }

    static func session() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [GatedThumbnailProtocol.self]
        return URLSession(configuration: config)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.requested?.fulfill()
        // Runs on URLSession's own queue, so blocking here holds only the
        // download; the main actor stays free for the test to poke the store.
        Self.gate.wait()
        Self.gate.signal()

        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "image/png"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Self.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

@MainActor
final class FeedRefresherTests: XCTestCase {
    private var container: ModelContainer!
    private var context: ModelContext { container.mainContext }

    override func setUp() async throws {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        container = try ModelContainer(
            for: Video.self, Subscription.self, VideoCollection.self, ChannelRule.self,
            configurations: config
        )
        StubURLProtocol.reset()
        stubOneChannelWithOneShortUpload()
    }

    override func tearDown() {
        StubURLProtocol.reset()
        super.tearDown()
    }

    /// The feed's `@Query` observes the main context live, so a video that is
    /// inserted before its Shorts verdict is known briefly shows in the feed
    /// and then disappears once the thumbnail analysis flips `isLikelyShort`.
    /// Freeze the refresh on the thumbnail download and check that nothing has
    /// reached the store yet.
    func testNewVideoIsNotStoredUntilShortsVerdictIsKnown() async throws {
        GatedThumbnailProtocol.reset(body: Self.pillarboxedThumbnail)
        let requested = expectation(description: "thumbnail requested")
        GatedThumbnailProtocol.requested = requested
        let refresher = makeRefresher()

        let refresh = Task { await refresher.refresh() }
        await fulfillment(of: [requested], timeout: 5)

        let pending = try context.fetch(FetchDescriptor<Video>())
        XCTAssertTrue(
            pending.isEmpty,
            "Video reached the store before classification finished: \(pending.map(\.videoId))"
        )

        GatedThumbnailProtocol.gate.signal()
        await refresh.value

        XCTAssertEqual(refresher.status, .idle)
        let stored = try context.fetch(FetchDescriptor<Video>())
        XCTAssertEqual(stored.map(\.videoId), ["short1"])
        XCTAssertEqual(stored.first?.isLikelyShort, true)
        XCTAssertEqual(stored.first?.classifierVersion, ShortsHeuristic.version)
    }

    /// Deferring the insert must not lose videos that turn out not to be Shorts.
    func testRegularVideoIsStoredVisible() async throws {
        GatedThumbnailProtocol.reset(body: Self.regularThumbnail)
        GatedThumbnailProtocol.gate.signal()
        let refresher = makeRefresher()

        await refresher.refresh()

        XCTAssertEqual(refresher.status, .idle)
        let stored = try context.fetch(FetchDescriptor<Video>())
        XCTAssertEqual(stored.map(\.videoId), ["short1"])
        XCTAssertEqual(stored.first?.isLikelyShort, false)
    }

    // MARK: - Fixtures

    private func makeRefresher() -> FeedRefresher {
        let api = YouTubeAPI(session: StubURLProtocol.session()) { "test-access-token" }
        return FeedRefresher(
            modelContext: context,
            api: api,
            thumbnailSession: GatedThumbnailProtocol.session()
        )
    }

    /// One subscription whose uploads playlist holds one 45-second video with
    /// no `#shorts` tag, so only the thumbnail can decide whether it's a Short.
    private func stubOneChannelWithOneShortUpload() {
        StubURLProtocol.stub(matching: "subscriptions", json: """
        {
          "items": [
            {
              "snippet": {
                "title": "Some Channel",
                "resourceId": { "kind": "youtube#channel", "channelId": "UCaaa" }
              }
            }
          ]
        }
        """)
        StubURLProtocol.stub(matching: "playlistItems", json: """
        { "items": [ { "contentDetails": { "videoId": "short1" } } ] }
        """)
        StubURLProtocol.stub(matching: "videos", json: """
        {
          "items": [
            {
              "id": "short1",
              "snippet": {
                "title": "Quick tip",
                "description": "No tag here",
                "channelId": "UCaaa",
                "channelTitle": "Some Channel",
                "publishedAt": "2026-09-01T10:00:00Z",
                "thumbnails": { "high": { "url": "https://example.com/h.jpg", "width": 480, "height": 360 } }
              },
              "contentDetails": { "duration": "PT45S" }
            }
          ]
        }
        """)
    }

    /// Detail only in the middle 9:16 slot: what YouTube serves for a Short.
    private static let pillarboxedThumbnail = pngData(
        ThumbnailAnalyzerTests.makeImage(width: 480, height: 360, detailedColumns: 105..<375)
    )

    /// Detail across the full width: a regular 16:9 upload.
    private static let regularThumbnail = pngData(
        ThumbnailAnalyzerTests.makeImage(width: 480, height: 360, detailedColumns: 0..<480)
    )

    private static func pngData(_ image: CGImage) -> Data {
        let data = NSMutableData()
        let destination = CGImageDestinationCreateWithData(
            data, UTType.png.identifier as CFString, 1, nil
        )!
        CGImageDestinationAddImage(destination, image, nil)
        CGImageDestinationFinalize(destination)
        return data as Data
    }
}
