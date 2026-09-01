import XCTest
@testable import YourTube

/// The Shorts heuristic is the one piece of the app that guesses, so it gets
/// the real test coverage.
///
/// NOTE: the corpus below is hand-written to cover the decision boundary, not
/// captured from live API responses. Before trusting the precision/recall
/// numbers, replace it with real `videos.list` output — see
/// `testCorpusPrecisionAndRecall` for the harness.
final class ShortsHeuristicTests: XCTestCase {

    // MARK: - Duration gate

    func testLongVideoIsNeverShortEvenWhenTagged() {
        let signals = VideoSignals(
            durationSeconds: 600,
            title: "How I edit my #shorts",
            description: "#shorts #short"
        )
        XCTAssertFalse(ShortsHeuristic.isLikelyShort(signals))
    }

    /// YouTube's cap has been 3 minutes since late 2024.
    func testExactlyThreeMinutesIsWithinTheGate() {
        let signals = VideoSignals(durationSeconds: 180, title: "Quick tip #shorts")
        XCTAssertTrue(ShortsHeuristic.isLikelyShort(signals))
    }

    func testOneSecondOverThreeMinutesIsOutsideTheGate() {
        let signals = VideoSignals(durationSeconds: 181, title: "Quick tip #shorts")
        XCTAssertFalse(ShortsHeuristic.isLikelyShort(signals))
    }

    /// Live streams and premieres report no duration. Treating 0 as "very short"
    /// would filter them out of the feed entirely.
    func testZeroDurationIsNotTreatedAsShort() {
        let signals = VideoSignals(durationSeconds: 0, title: "Live now #shorts")
        XCTAssertFalse(ShortsHeuristic.isLikelyShort(signals))
    }

    // MARK: - Corroborating signal required

    /// This is the case that makes duration-alone unusable: plenty of ordinary
    /// short videos predate Shorts or are trailers and clips.
    func testShortDurationAloneIsNotEnough() {
        let signals = VideoSignals(
            durationSeconds: 45,
            title: "Official Trailer",
            description: "In theaters this fall.",
            thumbnailWidth: 1280,
            thumbnailHeight: 720
        )
        XCTAssertFalse(ShortsHeuristic.isLikelyShort(signals))
    }

    func testShortDurationPlusTagIsEnough() {
        let signals = VideoSignals(durationSeconds: 30, description: "watch more #Shorts")
        XCTAssertTrue(ShortsHeuristic.isLikelyShort(signals))
    }

    func testShortDurationPlusPortraitThumbnailIsEnough() {
        let signals = VideoSignals(
            durationSeconds: 30,
            title: "no tag here",
            thumbnailWidth: 720,
            thumbnailHeight: 1280
        )
        XCTAssertTrue(ShortsHeuristic.isLikelyShort(signals))
    }

    /// The signal that catches untagged Shorts served with 16:9 thumbnails.
    func testShortDurationPlusPillarboxedThumbnailIsEnough() {
        let signals = VideoSignals(
            durationSeconds: 84,
            title: "Patch with me!",
            thumbnailWidth: 1280,
            thumbnailHeight: 720,
            hasPillarboxedThumbnail: true
        )
        XCTAssertTrue(ShortsHeuristic.isLikelyShort(signals))
    }

    func testUnanalysedThumbnailIsNotEvidence() {
        let signals = VideoSignals(
            durationSeconds: 45,
            title: "Official Trailer",
            thumbnailWidth: 1280,
            thumbnailHeight: 720,
            hasPillarboxedThumbnail: nil
        )
        XCTAssertFalse(ShortsHeuristic.isLikelyShort(signals))
    }

    func testPillarboxingIsIgnoredOutsideTheDurationGate() {
        let signals = VideoSignals(durationSeconds: 600, hasPillarboxedThumbnail: true)
        XCTAssertFalse(ShortsHeuristic.isLikelyShort(signals))
    }

    func testTagMatchingIsCaseInsensitive() {
        XCTAssertTrue(ShortsHeuristic.hasShortsTag(
            VideoSignals(durationSeconds: 20, title: "Cooking #SHORTS")
        ))
        XCTAssertTrue(ShortsHeuristic.hasShortsTag(
            VideoSignals(durationSeconds: 20, description: "#YouTubeShorts")
        ))
    }

    func testLandscapeThumbnailIsNotPortrait() {
        XCTAssertFalse(ShortsHeuristic.hasPortraitThumbnail(
            VideoSignals(durationSeconds: 20, thumbnailWidth: 1920, thumbnailHeight: 1080)
        ))
    }

    func testMissingThumbnailDimensionsAreNotPortrait() {
        XCTAssertFalse(ShortsHeuristic.hasPortraitThumbnail(
            VideoSignals(durationSeconds: 20)
        ))
    }

    // MARK: - Corpus

    private struct Case {
        let signals: VideoSignals
        let isShort: Bool
    }

    /// Measures the heuristic against a labelled corpus.
    ///
    /// The thresholds are deliberately loose: this is a heuristic filter whose
    /// failure mode is a hidden video, recoverable with the Settings toggle.
    func testCorpusPrecisionAndRecall() {
        let corpus = Self.corpus

        var truePositives = 0, falsePositives = 0, falseNegatives = 0
        for c in corpus {
            let predicted = ShortsHeuristic.isLikelyShort(c.signals)
            switch (predicted, c.isShort) {
            case (true, true): truePositives += 1
            case (true, false): falsePositives += 1
            case (false, true): falseNegatives += 1
            case (false, false): break
            }
        }

        let precision = Double(truePositives) / Double(max(1, truePositives + falsePositives))
        let recall = Double(truePositives) / Double(max(1, truePositives + falseNegatives))

        // Precision matters more than recall here: wrongly hiding a real video
        // is the annoying failure, wrongly showing a Short is just noise.
        XCTAssertGreaterThanOrEqual(precision, 0.90, "precision \(precision)")
        XCTAssertGreaterThanOrEqual(recall, 0.75, "recall \(recall)")
    }

    private static var corpus: [Case] {
        var cases: [Case] = []

        // Tagged Shorts, portrait thumbnails — the easy majority.
        for i in 0..<20 {
            cases.append(Case(
                signals: VideoSignals(
                    durationSeconds: 15 + i,
                    title: "Clip \(i) #shorts",
                    thumbnailWidth: 720, thumbnailHeight: 1280
                ),
                isShort: true
            ))
        }

        // Untagged Shorts with portrait thumbnails.
        for i in 0..<10 {
            cases.append(Case(
                signals: VideoSignals(
                    durationSeconds: 20 + i,
                    title: "Moment \(i)",
                    thumbnailWidth: 1080, thumbnailHeight: 1920
                ),
                isShort: true
            ))
        }

        // Untagged Shorts served with pillarboxed 16:9 thumbnails — the common
        // case in practice. Caught only via thumbnail analysis.
        for i in 0..<10 {
            cases.append(Case(
                signals: VideoSignals(
                    durationSeconds: 30 + i * 12,
                    title: "Quick thought \(i)",
                    thumbnailWidth: 1280, thumbnailHeight: 720,
                    hasPillarboxedThumbnail: true
                ),
                isShort: true
            ))
        }

        // Untagged Shorts whose thumbnail couldn't be analysed (fetch failed).
        // These set the recall ceiling.
        for i in 0..<3 {
            cases.append(Case(
                signals: VideoSignals(
                    durationSeconds: 30 + i,
                    title: "Unfetched \(i)",
                    thumbnailWidth: 1280, thumbnailHeight: 720
                ),
                isShort: true
            ))
        }

        // Ordinary long videos.
        for i in 0..<25 {
            cases.append(Case(
                signals: VideoSignals(
                    durationSeconds: 300 + i * 60,
                    title: "Deep dive episode \(i)",
                    description: "A long form discussion.",
                    thumbnailWidth: 1280, thumbnailHeight: 720
                ),
                isShort: false
            ))
        }

        // Short-but-not-Shorts: trailers, clips, old uploads. The reason the
        // heuristic needs a second signal beyond duration.
        for i in 0..<15 {
            cases.append(Case(
                signals: VideoSignals(
                    durationSeconds: 25 + i,
                    title: "Official Teaser \(i)",
                    description: "Coming soon.",
                    thumbnailWidth: 1280, thumbnailHeight: 720,
                    hasPillarboxedThumbnail: false
                ),
                isShort: false
            ))
        }

        return cases
    }
}
