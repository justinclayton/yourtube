import XCTest
@testable import YourTube

final class LocalSearchTests: XCTestCase {
    private struct Clip: Equatable {
        var title: String
        /// Defaults to `title` when a clip's raw and cleaned titles don't
        /// differ, mirroring `Video.displayTitle`'s fallback.
        var displayTitle: String
        var channel: String

        init(title: String, displayTitle: String? = nil, channel: String) {
            self.title = title
            self.displayTitle = displayTitle ?? title
            self.channel = channel
        }
    }

    private let clips = [
        Clip(title: "Conan Visits Cuba", channel: "Team Coco"),
        Clip(title: "Café Sessions #4", channel: "Beyoncé Fan Channel"),
        Clip(title: "Building a Synth", channel: "Look Mum No Computer"),
        Clip(title: "Straße walk", channel: "Berlin Vlogs"),
        Clip(
            title: "SUBSCRIBE!! Epic Ski Fails 2024 | ExtremeSportsNet",
            displayTitle: "Spectacular Wipeouts on the Slopes",
            channel: "ExtremeSportsNet"
        ),
    ]

    private func search(_ query: String) -> [Clip] {
        LocalSearch.filter(clips, query: query) { [$0.title, $0.displayTitle, $0.channel] }
    }

    func testEmptyOrWhitespaceQueryMatchesEverything() {
        XCTAssertEqual(search(""), clips)
        XCTAssertEqual(search("   "), clips)
    }

    func testMatchIsCaseInsensitive() {
        XCTAssertEqual(search("CONAN"), [clips[0]])
        XCTAssertEqual(search("team coco"), [clips[0]])
    }

    func testMatchIgnoresDiacriticsInBothDirections() {
        XCTAssertEqual(search("cafe"), [clips[1]])
        XCTAssertEqual(search("beyonce"), [clips[1]])
        XCTAssertEqual(search("Café"), [clips[1]])
    }

    func testMatchesChannelNameAsWellAsTitle() {
        XCTAssertEqual(search("computer"), [clips[2]])
    }

    func testEveryWordMustMatchInAnyOrder() {
        XCTAssertEqual(search("cuba conan"), [clips[0]])
        XCTAssertEqual(search("conan synth"), [])
    }

    func testOrderIsPreserved() {
        XCTAssertEqual(
            search("a"),
            clips.filter { ($0.title + $0.displayTitle + $0.channel).lowercased().contains("a") }
        )
    }

    /// A word the user only sees in the cleaned title — the raw title never
    /// had it — still has to find its way to the user's search.
    func testMatchesCleanedTitleEvenWhenRawTitleDoesNot() {
        XCTAssertEqual(search("wipeouts"), [clips[4]])
        XCTAssertEqual(search("slopes"), [clips[4]])
    }

    /// Boilerplate that cleaning stripped out is still fair game: matching
    /// both the raw and cleaned title is fine, since the raw title is one
    /// tap away in the player.
    func testStillMatchesRawTitleBoilerplateStrippedFromCleanedTitle() {
        XCTAssertEqual(search("subscribe"), [clips[4]])
    }

    func testNormalizeFoldsCaseAndDiacritics() {
        XCTAssertEqual(LocalSearch.normalize("Beyoncé"), "beyonce")
        XCTAssertEqual(LocalSearch.normalize("ÀÉÎÕÜ"), "aeiou")
    }
}
