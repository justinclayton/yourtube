import XCTest
@testable import YourTube

final class LocalSearchTests: XCTestCase {
    private struct Clip: Equatable {
        var title: String
        var channel: String
    }

    private let clips = [
        Clip(title: "Conan Visits Cuba", channel: "Team Coco"),
        Clip(title: "Café Sessions #4", channel: "Beyoncé Fan Channel"),
        Clip(title: "Building a Synth", channel: "Look Mum No Computer"),
        Clip(title: "Straße walk", channel: "Berlin Vlogs"),
    ]

    private func search(_ query: String) -> [Clip] {
        LocalSearch.filter(clips, query: query) { [$0.title, $0.channel] }
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
        XCTAssertEqual(search("a"), clips.filter { ($0.title + $0.channel).lowercased().contains("a") })
    }

    func testNormalizeFoldsCaseAndDiacritics() {
        XCTAssertEqual(LocalSearch.normalize("Beyoncé"), "beyonce")
        XCTAssertEqual(LocalSearch.normalize("ÀÉÎÕÜ"), "aeiou")
    }
}
