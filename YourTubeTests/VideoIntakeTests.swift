import XCTest
import SwiftData
@testable import YourTube

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

    private func makeIntake() -> VideoIntake {
        VideoIntake(writer: StoreWriter(modelContainer: container))
    }

    func testAdmitStoresEveryHydratedVideo() async throws {
        let stored = try await makeIntake().admit([
            Self.item(id: "a", seconds: 600),
            Self.item(id: "b", seconds: 45),
        ])

        XCTAssertEqual(stored, 2)
        XCTAssertEqual(
            Set(try context.fetch(FetchDescriptor<Video>()).map(\.videoId)), ["a", "b"]
        )
    }

    /// A live stream or premiere has no duration, so there is nothing to
    /// store it with. It isn't stored, and it isn't counted as stored.
    func testItemsWithNoDurationAreNotStored() async throws {
        let stored = try await makeIntake().admit([
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
        let published = Date(timeIntervalSince1970: 1_780_000_000)

        try await makeIntake().admit([Self.item(
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

    func testKnownVideoIdsReportsWhatIsAlreadyThroughTheDoor() async throws {
        let intake = makeIntake()
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
