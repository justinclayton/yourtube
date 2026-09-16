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

/// Serves every stubbed response immediately except one whose URL contains
/// `gatedFragment`, which is left outstanding — not blocked, just never
/// answered — until the test calls `releaseGate()`. Lets a refresh be frozen
/// mid-fan-out — one channel's videos already hydrated and classified,
/// another channel's request still outstanding — so the store and
/// `FeedRefresher.status` can be inspected at that exact point.
///
/// Deliberately doesn't block a thread to hold the gate (an earlier version
/// used a `DispatchSemaphore.wait()` inside `startLoading()`): on a
/// constrained simulator, blocking whatever thread `startLoading()` happens
/// to land on can starve Swift concurrency's cooperative pool, which is
/// exactly the concurrent progress this protocol exists to observe. Holding
/// the `URLProtocol` instance instead and finishing it later ties up nothing.
final class SelectiveGateURLProtocol: URLProtocol {
    nonisolated(unsafe) static var stubs: [(match: String, json: String)] = []
    nonisolated(unsafe) static var gatedFragment = ""
    /// Fulfilled when the gated request arrives.
    nonisolated(unsafe) static var gatedRequested: XCTestExpectation?
    nonisolated(unsafe) private static var pendingGated: [SelectiveGateURLProtocol] = []
    private static let lock = NSLock()

    static func reset() {
        stubs = []
        gatedFragment = ""
        gatedRequested = nil
        lock.lock()
        pendingGated = []
        lock.unlock()
    }

    /// Answers every request that arrived while the gate was closed.
    static func releaseGate() {
        lock.lock()
        let held = pendingGated
        pendingGated = []
        lock.unlock()
        for protocolInstance in held { protocolInstance.respond() }
    }

    static func session() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [SelectiveGateURLProtocol.self]
        return URLSession(configuration: config)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let url = request.url?.absoluteString ?? ""
        if !Self.gatedFragment.isEmpty, url.contains(Self.gatedFragment) {
            Self.gatedRequested?.fulfill()
            Self.lock.lock()
            Self.pendingGated.append(self)
            Self.lock.unlock()
            return
        }
        respond()
    }

    private func respond() {
        let url = request.url?.absoluteString ?? ""
        guard let match = Self.stubs.first(where: { url.contains($0.match) }) else {
            client?.urlProtocol(
                self,
                didFailWithError: NSError(
                    domain: "SelectiveGateURLProtocol", code: 404,
                    userInfo: [NSLocalizedDescriptionKey: "No stub matching \(url)"]
                )
            )
            return
        }

        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(match.json.utf8))
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

    /// A video from a channel earlier in the fan-out must reach the store
    /// while a later channel's own fetch hasn't even returned. Regression
    /// test for #67: `upsert` used to hold every new video until every
    /// channel's thumbnail analysis was done, so a first fill showed nothing
    /// for minutes.
    ///
    /// Gating channel B's *playlist* fetch (rather than, say, its hydration)
    /// means B cannot possibly finish before the test opens the gate — so
    /// there's no dependence on which of two equally-fast channels the task
    /// group happens to schedule first. `waitUntilStored` then gives channel
    /// A's own chain (hydrate, classify, insert, cross-context merge) room
    /// to land without a fixed, and therefore flaky, sleep.
    func testNewVideoAppearsWhileALaterChannelIsStillBeingFetched() async throws {
        SelectiveGateURLProtocol.reset()
        SelectiveGateURLProtocol.stubs = [
            ("subscriptions", Self.twoChannelSubscriptionsJSON),
            ("playlistId=UUaaa", Self.playlistJSON(videoId: "videoA")),
            ("playlistId=UUbbb", Self.playlistJSON(videoId: "videoB")),
            ("id=videoA", Self.videoJSON(id: "videoA")),
            ("id=videoB", Self.videoJSON(id: "videoB")),
        ]
        let gated = expectation(description: "channel B's playlist fetch requested")
        SelectiveGateURLProtocol.gatedFragment = "playlistId=UUbbb"
        SelectiveGateURLProtocol.gatedRequested = gated

        let api = YouTubeAPI(session: SelectiveGateURLProtocol.session()) { "test-access-token" }
        let refresher = FeedRefresher(
            modelContext: context,
            api: api,
            // Both videos run 10 minutes, outside the Shorts duration gate,
            // so neither triggers a thumbnail download this session doesn't
            // stub.
            thumbnailSession: SelectiveGateURLProtocol.session()
        )

        let refresh = Task { await refresher.refresh() }
        await fulfillment(of: [gated], timeout: 5)

        // Channel B is parked at the gate before its playlist fetch even
        // returns, so it cannot have contributed anything yet. If channel
        // A's video shows up regardless, that's solely because it was
        // stored on its own rather than held for the whole refresh.
        try await waitUntilStored(videoIds: ["videoA"])

        SelectiveGateURLProtocol.releaseGate()
        await refresh.value

        XCTAssertEqual(refresher.status, .idle)
        let stored = try context.fetch(FetchDescriptor<Video>())
        XCTAssertEqual(Set(stored.map(\.videoId)), ["videoA", "videoB"])
    }

    /// The progress indicator must not sit at "checking channels" once the
    /// (one and only) channel has been checked: hydration, Shorts
    /// classification and the save still have to run, and each now gets its
    /// own phase. Regression test for #67: `Status` used to have nothing but
    /// the channel count, so the ring looked done while all of that ran.
    func testPhaseAdvancesPastCheckingChannelsDuringHydration() async throws {
        SelectiveGateURLProtocol.reset()
        SelectiveGateURLProtocol.stubs = [
            ("subscriptions", Self.oneChannelSubscriptionJSON),
            ("playlistItems", Self.playlistJSON(videoId: "video1")),
            ("id=video1", Self.videoJSON(id: "video1")),
        ]
        let gated = expectation(description: "hydration requested")
        SelectiveGateURLProtocol.gatedFragment = "id=video1"
        SelectiveGateURLProtocol.gatedRequested = gated

        let api = YouTubeAPI(session: SelectiveGateURLProtocol.session()) { "test-access-token" }
        let refresher = FeedRefresher(
            modelContext: context,
            api: api,
            thumbnailSession: SelectiveGateURLProtocol.session()
        )

        let refresh = Task { await refresher.refresh() }
        await fulfillment(of: [gated], timeout: 5)

        // The one channel there is has already been checked, but the ring
        // is on the next phase, not stuck reporting that fan-out as "done".
        XCTAssertEqual(refresher.status, .refreshing(.fetchingVideos(completed: 0, total: 1)))

        SelectiveGateURLProtocol.releaseGate()
        await refresh.value

        XCTAssertEqual(refresher.status, .idle)
        let stored = try context.fetch(FetchDescriptor<Video>())
        XCTAssertEqual(stored.map(\.videoId), ["video1"])
    }

    /// Documents the SwiftData behaviour `syncSubscriptions`'s guarded
    /// assignment (`if record.title != title { record.title = title }`)
    /// exists to avoid: plain assignment dirties the context even when the
    /// value is unchanged, which is what used to turn an unchanged
    /// subscription list into 629 dirtied rows, a 629-row save, and one
    /// change notification per live query. `syncSubscriptions` itself
    /// isn't reachable from a test without a live refresh's own save
    /// masking the effect (see docs/agents/issue-tracker.md and this
    /// issue's notes on verifying via the real store instead).
    func testPlainReassignmentOfAnEqualValueDirtiesTheContext() throws {
        let subscription = Subscription(channelId: "UCaaa", title: "Some Channel")
        context.insert(subscription)
        try context.save()
        XCTAssertFalse(context.hasChanges)

        subscription.title = "Some Channel"

        XCTAssertTrue(
            context.hasChanges,
            "If this ever starts failing, SwiftData no longer dirties on a same-value "
                + "assignment and the guard in syncSubscriptions can be dropped."
        )
    }

    // MARK: - Helpers

    /// Polls the store until it holds exactly `videoIds`, rather than
    /// sleeping a fixed amount and hoping the async chain (hydrate, classify,
    /// insert, cross-context merge) has landed by then.
    private func waitUntilStored(
        videoIds: Set<String>, timeout: TimeInterval = 3,
        file: StaticString = #filePath, line: UInt = #line
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let stored = Set(try context.fetch(FetchDescriptor<Video>()).map(\.videoId))
            if stored == videoIds { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        let stored = Set(try context.fetch(FetchDescriptor<Video>()).map(\.videoId))
        XCTFail("Expected \(videoIds) in the store within \(timeout)s, found \(stored)", file: file, line: line)
    }

    // MARK: - Fixtures

    /// One subscribed channel with one uploads-playlist item.
    private static let oneChannelSubscriptionJSON = """
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
    """

    /// Two subscribed channels, each with one uploads-playlist item.
    private static let twoChannelSubscriptionsJSON = """
    {
      "items": [
        {
          "snippet": {
            "title": "Channel A",
            "resourceId": { "kind": "youtube#channel", "channelId": "UCaaa" }
          }
        },
        {
          "snippet": {
            "title": "Channel B",
            "resourceId": { "kind": "youtube#channel", "channelId": "UCbbb" }
          }
        }
      ]
    }
    """

    private static func playlistJSON(videoId: String) -> String {
        "{ \"items\": [ { \"contentDetails\": { \"videoId\": \"\(videoId)\" } } ] }"
    }

    /// A 10-minute video: outside the Shorts duration gate, so classifying
    /// it never touches the thumbnail session.
    private static func videoJSON(id: String) -> String {
        """
        {
          "items": [
            {
              "id": "\(id)",
              "snippet": {
                "title": "Video \(id)",
                "description": "",
                "channelId": "UCaaa",
                "channelTitle": "Some Channel",
                "publishedAt": "2026-09-01T10:00:00Z"
              },
              "contentDetails": { "duration": "PT10M" }
            }
          ]
        }
        """
    }

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
