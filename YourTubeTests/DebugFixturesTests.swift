import XCTest
import SwiftData
@testable import YourTube

/// The fixture store is what a simulator run without a login sees, so it has
/// to open cleanly and contain the awkward cases search is meant to handle.
@MainActor
final class DebugFixturesTests: XCTestCase {
    func testFixturesSeedSubscriptionsRulesAndVideos() throws {
        let container = try DebugFixtures.makeContainer()
        let context = container.mainContext
        XCTAssertGreaterThan(try context.fetchCount(FetchDescriptor<Subscription>()), 0)
        XCTAssertGreaterThan(try context.fetchCount(FetchDescriptor<ChannelRule>()), 0)
        XCTAssertGreaterThan(try context.fetchCount(FetchDescriptor<Video>()), 0)
        XCTAssertEqual(
            try context.fetchCount(FetchDescriptor<VideoCollection>()),
            CategoryManager.defaultCategoryNames.count
        )
    }

    func testSearchOverFixturesFindsChannelAndVideosByDiacriticFreeQuery() throws {
        let container = try DebugFixtures.makeContainer()
        let context = container.mainContext
        let subscriptions = try context.fetch(FetchDescriptor<Subscription>())
        let videos = try context.fetch(FetchDescriptor<Video>(
            sortBy: [SortDescriptor(\.publishedAt, order: .reverse)]
        ))

        let channels = LocalSearch.filter(subscriptions, query: "beyonce") { [$0.title] }
        XCTAssertEqual(channels.map(\.title), ["Beyoncé"])

        let hits = LocalSearch.filter(videos, query: "conan") { [$0.title, $0.channelTitle] }
        XCTAssertFalse(hits.isEmpty)
        // Newest-first order survives filtering.
        XCTAssertEqual(hits.map(\.publishedAt), hits.map(\.publishedAt).sorted(by: >))
        // A channel-name match pulls in that channel's videos too.
        XCTAssertTrue(hits.contains { $0.channelTitle == "Conan Clips Archive" })
    }
}
