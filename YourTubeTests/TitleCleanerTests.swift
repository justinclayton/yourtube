import XCTest
import SwiftData
@testable import YourTube

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
            for: Video.self, Subscription.self, VideoCollection.self, ChannelRule.self,
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
}
