import XCTest
@testable import YourTube

private struct Clip: Identifiable, Equatable {
    var id: String
    var channel: String
}

final class ChannelDailyCapTests: XCTestCase {
    private let day = Date(timeIntervalSinceReferenceDate: 86_400 * 100)

    private func rows(_ clips: [Clip], cap: Int, expanded: Set<String> = []) -> [FeedRow<Clip>] {
        ChannelDailyCap.apply(
            clips, cap: cap, day: day, expanded: expanded,
            channelId: \.channel, channelTitle: { "Channel \($0.channel)" }
        )
    }

    /// Compact readable form: video ids, or "+N" for a fold.
    private func describe(_ rows: [FeedRow<Clip>]) -> [String] {
        rows.map {
            switch $0 {
            case .video(let clip): return clip.id
            case .more(_, _, let hidden): return "+\(hidden.count)"
            }
        }
    }

    private let fiveFromA: [Clip] = (1...5).map { Clip(id: "a\($0)", channel: "A") }

    func testFiveVideosWithCapTwoShowsTwoPlusOneFold() {
        let result = rows(fiveFromA, cap: 2)
        XCTAssertEqual(describe(result), ["a1", "a2", "+3"])
        guard case .more(_, let title, let hidden) = result[2] else { return XCTFail() }
        XCTAssertEqual(title, "Channel A")
        XCTAssertEqual(hidden.map(\.id), ["a3", "a4", "a5"])
    }

    func testFoldSitsWhereTheFirstHiddenVideoWasAndOrderIsPreserved() {
        let clips = [
            Clip(id: "a1", channel: "A"), Clip(id: "b1", channel: "B"),
            Clip(id: "a2", channel: "A"), Clip(id: "a3", channel: "A"),
            Clip(id: "b2", channel: "B"), Clip(id: "a4", channel: "A"),
            Clip(id: "c1", channel: "C"),
        ]
        XCTAssertEqual(describe(rows(clips, cap: 2)), ["a1", "b1", "a2", "+2", "b2", "c1"])
    }

    func testChannelAtTheCapIsNotFolded() {
        let clips = Array(fiveFromA.prefix(2))
        XCTAssertEqual(describe(rows(clips, cap: 2)), ["a1", "a2"])
    }

    func testCapZeroDisablesCollapsing() {
        XCTAssertEqual(describe(rows(fiveFromA, cap: 0)), ["a1", "a2", "a3", "a4", "a5"])
    }

    func testExpandedFoldEmitsHiddenVideosInlineAfterTheRow() {
        let key = ChannelDailyCap.key(channelId: "A", day: day)
        let result = rows(fiveFromA, cap: 2, expanded: [key])
        XCTAssertEqual(describe(result), ["a1", "a2", "+3", "a3", "a4", "a5"])
    }

    func testExpansionKeyForAnotherDayDoesNotOpenThisFold() {
        let otherDay = ChannelDailyCap.key(channelId: "A", day: day.addingTimeInterval(86_400))
        XCTAssertEqual(describe(rows(fiveFromA, cap: 2, expanded: [otherDay])), ["a1", "a2", "+3"])
    }

    func testRowIdsAreUniqueAcrossVideosAndFolds() {
        let ids = rows(fiveFromA, cap: 1).map(\.id)
        XCTAssertEqual(Set(ids).count, ids.count)
    }
}
