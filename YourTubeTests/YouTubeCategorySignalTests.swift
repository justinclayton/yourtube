import XCTest
@testable import YourTube

/// A hand-written corpus, not captured `videos.list` output — the same
/// caveat as `ShowDetectorTests`. Covers the shapes the acceptance criteria
/// name: a clear majority, no majority, an all-catch-all channel, videos with
/// no stored category, and a taxonomy where the target name has been renamed
/// away.
final class YouTubeCategorySignalTests: XCTestCase {
    private static let defaultTaxonomy = CategoryManager.defaultCategoryNames

    private static func video(_ categoryId: String?) -> EpisodeSignals {
        EpisodeSignals(durationSeconds: 600, publishedAt: .now, categoryId: categoryId)
    }

    private static func videos(_ categoryIds: [String?]) -> [EpisodeSignals] {
        categoryIds.map(video)
    }

    // MARK: - Clear majority

    func testClearMajorityMapsToTaxonomyName() {
        // 6 of 8 videos are Gaming (20) -> clear majority -> Games.
        let videos = Self.videos(Array(repeating: "20", count: 6) + ["10", "23"])
        let suggestion = YouTubeCategorySignal.suggestion(for: videos, taxonomy: Self.defaultTaxonomy)
        XCTAssertEqual(suggestion?.categoryName, "Games")
        XCTAssertEqual(suggestion?.reason, "YouTube files most of its videos under Gaming")
    }

    func testEachMappedCategoryResolvesToItsTaxonomyName() {
        let expected: [String: String] = [
            "1": "Film & TV",
            "2": "Cars",
            "10": "Music & Audio Gear",
            "20": "Games",
            "23": "Comedy",
            "25": "News & Politics",
            "26": "Makers & DIY",
            "28": "Tech & Engineering",
        ]
        for (youtubeId, taxonomyName) in expected {
            let videos = Self.videos(Array(repeating: youtubeId, count: 5))
            let suggestion = YouTubeCategorySignal.suggestion(for: videos, taxonomy: Self.defaultTaxonomy)
            XCTAssertEqual(suggestion?.categoryName, taxonomyName, "id \(youtubeId)")
        }
    }

    // MARK: - No majority

    func testNoMajorityYieldsNoSuggestion() {
        // A three-way split, nothing clears 50%.
        let videos = Self.videos(
            Array(repeating: "20", count: 3) + Array(repeating: "10", count: 3) + Array(repeating: "23", count: 2)
        )
        XCTAssertNil(YouTubeCategorySignal.suggestion(for: videos, taxonomy: Self.defaultTaxonomy))
    }

    func testExactlyHalfIsNotAClearMajority() {
        // 5 of 10 is exactly half, not a majority.
        let videos = Self.videos(Array(repeating: "20", count: 5) + Array(repeating: "10", count: 5))
        XCTAssertNil(YouTubeCategorySignal.suggestion(for: videos, taxonomy: Self.defaultTaxonomy))
    }

    // MARK: - Catch-all

    func testAllCatchAllCategoryYieldsNoSuggestion() {
        // People & Blogs (22) is a default, not a real signal.
        let videos = Self.videos(Array(repeating: "22", count: 8))
        XCTAssertNil(YouTubeCategorySignal.suggestion(for: videos, taxonomy: Self.defaultTaxonomy))
    }

    func testEntertainmentAndEducationAlsoYieldNoSuggestion() {
        for catchAll in ["24", "27"] {
            let videos = Self.videos(Array(repeating: catchAll, count: 8))
            XCTAssertNil(YouTubeCategorySignal.suggestion(for: videos, taxonomy: Self.defaultTaxonomy), "id \(catchAll)")
        }
    }

    // MARK: - No stored category

    func testVideosWithNoStoredCategoryDoNotVote() {
        // 5 nils plus 3 Gaming, 2 Music: if nils voted, Gaming would only be
        // 3/10 (no majority); excluded, it's 3/5, a clear majority.
        let videos = Self.videos(
            Array(repeating: nil, count: 5) + Array(repeating: "20", count: 3) + Array(repeating: "10", count: 2)
        )
        let suggestion = YouTubeCategorySignal.suggestion(for: videos, taxonomy: Self.defaultTaxonomy)
        XCTAssertEqual(suggestion?.categoryName, "Games")
    }

    func testAllVideosWithNoStoredCategoryYieldsNoSuggestion() {
        let videos = Self.videos(Array(repeating: nil, count: 8))
        XCTAssertNil(YouTubeCategorySignal.suggestion(for: videos, taxonomy: Self.defaultTaxonomy))
    }

    // MARK: - Renamed or deleted target category

    func testRenamedTargetCategoryYieldsNoSuggestion() {
        // Clear Gaming majority, but the taxonomy no longer has "Games".
        let renamedTaxonomy = Self.defaultTaxonomy.map { $0 == "Games" ? "Video Games" : $0 }
        let videos = Self.videos(Array(repeating: "20", count: 8))
        XCTAssertNil(YouTubeCategorySignal.suggestion(for: videos, taxonomy: renamedTaxonomy))
    }

    func testDeletedTargetCategoryYieldsNoSuggestion() {
        let taxonomyWithoutGames = Self.defaultTaxonomy.filter { $0 != "Games" }
        let videos = Self.videos(Array(repeating: "20", count: 8))
        XCTAssertNil(YouTubeCategorySignal.suggestion(for: videos, taxonomy: taxonomyWithoutGames))
    }

    // MARK: - Empty input

    func testNoVideosYieldsNoSuggestion() {
        XCTAssertNil(YouTubeCategorySignal.suggestion(for: [], taxonomy: Self.defaultTaxonomy))
    }
}
