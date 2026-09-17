import XCTest
import SwiftData
@testable import YourTube

/// A thumbnail verdict the test decides when to answer, so intake can be
/// frozen with a video judged but not yet stored.
///
/// The point of the whole `ThumbnailVerdict` seam: what used to need a
/// semaphore-gated `URLProtocol`, an image encoder and a real `URLSession` is
/// now twelve lines and no network.
final class GatedThumbnailVerdict: ThumbnailVerdict, @unchecked Sendable {
    /// Fulfilled when intake asks for a verdict.
    let asked = XCTestExpectation(description: "thumbnail verdict asked for")
    /// IDs to answer "pillarboxed" for once the gate opens.
    let pillarboxedIds: Set<String>
    private let gate = DispatchSemaphore(value: 0)
    /// Every ID intake actually asked about, in the order the asks arrived.
    private(set) nonisolated(unsafe) var askedAbout: [[String]] = []

    init(pillarboxedIds: Set<String> = []) {
        self.pillarboxedIds = pillarboxedIds
    }

    func open() { gate.signal() }

    func pillarboxed(videoIds: [String]) async -> [String: Bool?] {
        askedAbout.append(videoIds)
        asked.fulfill()
        // Held on a thread of its own rather than by blocking here: blocking
        // inside an async function ties up a cooperative-pool thread, which
        // is the concurrency this test needs to stay free.
        let gate = gate
        await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                gate.wait()
                gate.signal()
                continuation.resume()
            }
        }
        return Dictionary(uniqueKeysWithValues: videoIds.map {
            ($0, pillarboxedIds.contains($0) ? true : Bool?.none)
        })
    }
}

@MainActor
final class VideoIntakeTests: XCTestCase {
    private var container: ModelContainer!
    private var context: ModelContext { container.mainContext }

    override func setUp() async throws {
        container = try ModelContainer(
            for: Video.self, Subscription.self, VideoCollection.self, ChannelRule.self, Show.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
    }

    private func makeIntake(_ thumbnails: ThumbnailVerdict) -> VideoIntake {
        VideoIntake(writer: StoreWriter(modelContainer: container), thumbnails: thumbnails)
    }

    /// The feed's `@Query` observes the store live, so a video inserted before
    /// its Shorts verdict is known would show in the feed and then disappear
    /// once the verdict landed. Freeze intake on the verdict and check that
    /// nothing has reached the store yet.
    func testVideoIsHeldUntilTheShortsVerdictIsKnown() async throws {
        let thumbnails = GatedThumbnailVerdict(pillarboxedIds: ["short1"])
        let intake = makeIntake(thumbnails)

        let admitting = Task { try await intake.admit([Self.item(id: "short1", seconds: 45)]) }
        await fulfillment(of: [thumbnails.asked], timeout: 5)

        let pending = try context.fetch(FetchDescriptor<Video>())
        XCTAssertTrue(
            pending.isEmpty,
            "Video reached the store before its verdict: \(pending.map(\.videoId))"
        )

        thumbnails.open()
        let stored = try await admitting.value

        XCTAssertEqual(stored, 1)
        let rows = try context.fetch(FetchDescriptor<Video>())
        XCTAssertEqual(rows.map(\.videoId), ["short1"])
        XCTAssertEqual(rows.first?.isLikelyShort, true)
        XCTAssertEqual(rows.first?.classifierVersion, ShortsHeuristic.version)
    }

    /// Holding the insert must not lose videos that turn out not to be Shorts.
    func testVideoWithNoPillarboxingIsStoredVisible() async throws {
        let intake = makeIntake(CannedThumbnailVerdict())

        let stored = try await intake.admit([Self.item(id: "clip1", seconds: 45)])

        XCTAssertEqual(stored, 1)
        let rows = try context.fetch(FetchDescriptor<Video>())
        XCTAssertEqual(rows.map(\.videoId), ["clip1"])
        XCTAssertEqual(rows.first?.isLikelyShort, false)
    }

    /// The thumbnail is the expensive signal, so it's only asked for where it
    /// could change the answer: inside the duration gate, and not already
    /// settled by a tag or a portrait thumbnail.
    func testOnlyUndecidedVideosCostAThumbnailVerdict() async throws {
        let thumbnails = GatedThumbnailVerdict()
        thumbnails.open()
        let intake = makeIntake(thumbnails)

        try await intake.admit([
            Self.item(id: "undecided", seconds: 45),
            Self.item(id: "tooLong", seconds: 900),
            Self.item(id: "tagged", seconds: 45, title: "A thing #shorts"),
        ])

        XCTAssertEqual(thumbnails.askedAbout, [["undecided"]])
        let byId = Dictionary(
            uniqueKeysWithValues: try context.fetch(FetchDescriptor<Video>())
                .map { ($0.videoId, $0.isLikelyShort) }
        )
        XCTAssertEqual(byId, ["undecided": false, "tooLong": false, "tagged": true])
    }

    /// A live stream or premiere has no duration, so there is nothing for the
    /// heuristic to judge. It isn't stored, and it isn't counted as stored.
    func testItemsWithNoDurationAreNotStored() async throws {
        let intake = makeIntake(CannedThumbnailVerdict())

        let stored = try await intake.admit([
            Self.item(id: "live", seconds: nil),
            Self.item(id: "real", seconds: 600),
        ])

        XCTAssertEqual(stored, 1)
        XCTAssertEqual(
            try context.fetch(FetchDescriptor<Video>()).map(\.videoId), ["real"]
        )
    }

    /// The DTO's fields have to survive the trip, since intake is now the only
    /// place they're read off the wire.
    func testAdmittedVideoCarriesWhatTheAPISaid() async throws {
        let intake = makeIntake(CannedThumbnailVerdict())
        let published = Date(timeIntervalSince1970: 1_780_000_000)

        try await intake.admit([Self.item(
            id: "v1", seconds: 630, title: "A Title", channelId: "UCaaa",
            channelTitle: "Some Channel", description: "Notes", publishedAt: published,
            categoryId: "25"
        )])

        let video = try XCTUnwrap(try context.fetch(FetchDescriptor<Video>()).first)
        XCTAssertEqual(video.videoId, "v1")
        XCTAssertEqual(video.title, "A Title")
        XCTAssertEqual(video.channelId, "UCaaa")
        XCTAssertEqual(video.channelTitle, "Some Channel")
        XCTAssertEqual(video.videoDescription, "Notes")
        XCTAssertEqual(video.publishedAt, published)
        XCTAssertEqual(video.durationSeconds, 630)
        XCTAssertEqual(video.youtubeCategoryId, "25")
    }

    /// An app update that changes the heuristic re-judges what's already
    /// stored, and the signals it judges come off the row — the same
    /// `VideoSignals` the DTO path builds, derived in the one place.
    func testReclassifyStaleRejudgesVideosFromAnOlderVersion() async throws {
        context.insert(Video(
            videoId: "old", channelId: "UCaaa", channelTitle: "Some Channel",
            title: "Quick tip", videoDescription: "", publishedAt: .now,
            durationSeconds: 45, classifierVersion: ShortsHeuristic.version - 1
        ))
        context.insert(Video(
            videoId: "current", channelId: "UCaaa", channelTitle: "Some Channel",
            title: "Also quick", videoDescription: "", publishedAt: .now,
            durationSeconds: 45, classifierVersion: ShortsHeuristic.version
        ))
        try context.save()

        let thumbnails = GatedThumbnailVerdict(pillarboxedIds: ["old", "current"])
        thumbnails.open()
        try await makeIntake(thumbnails).reclassifyStale()

        // Only the stale row was offered up, and only it was re-judged.
        XCTAssertEqual(thumbnails.askedAbout, [["old"]])
        let byId = Dictionary(
            uniqueKeysWithValues: try context.fetch(FetchDescriptor<Video>())
                .map { ($0.videoId, ($0.isLikelyShort, $0.classifierVersion)) }
        )
        XCTAssertEqual(byId["old"]?.0, true)
        XCTAssertEqual(byId["old"]?.1, ShortsHeuristic.version)
        XCTAssertEqual(byId["current"]?.0, false)
    }

    func testReclassifyStaleAsksNothingWhenEverythingIsCurrent() async throws {
        context.insert(Video(
            videoId: "current", channelId: "UCaaa", channelTitle: "Some Channel",
            title: "Quick tip", videoDescription: "", publishedAt: .now,
            durationSeconds: 45, classifierVersion: ShortsHeuristic.version
        ))
        try context.save()

        let thumbnails = GatedThumbnailVerdict()
        // Deliberately not opened: nothing may ask, so nothing can block.
        try await makeIntake(thumbnails).reclassifyStale()

        XCTAssertTrue(thumbnails.askedAbout.isEmpty)
    }

    func testKnownVideoIdsReportsWhatIsAlreadyThroughTheDoor() async throws {
        let intake = makeIntake(CannedThumbnailVerdict())
        try await intake.admit([Self.item(id: "a", seconds: 600), Self.item(id: "b", seconds: 600)])

        let known = try await intake.knownVideoIds()

        XCTAssertEqual(known, ["a", "b"])
    }

    // MARK: - Fixtures

    private static func item(
        id: String,
        seconds: Int?,
        title: String = "A video",
        channelId: String = "UCaaa",
        channelTitle: String = "Some Channel",
        description: String = "",
        publishedAt: Date = Date(timeIntervalSince1970: 1_780_000_000),
        categoryId: String? = nil
    ) -> YT.VideoItem {
        YT.VideoItem(
            id: id,
            snippet: YT.VideoItem.Snippet(
                title: title,
                description: description,
                channelId: channelId,
                channelTitle: channelTitle,
                publishedAt: publishedAt,
                thumbnails: nil,
                categoryId: categoryId
            ),
            contentDetails: YT.VideoItem.ContentDetails(
                duration: seconds.map { "PT\($0)S" }
            )
        )
    }
}
