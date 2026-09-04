import XCTest
import CoreGraphics
@testable import YourTube

/// Synthetic images that mimic the two shapes YouTube serves: a 16:9 frame
/// full of detail (regular video) versus detail only in the middle 9:16 slot
/// with smooth fill either side (a Short).
final class ThumbnailAnalyzerTests: XCTestCase {

    func testDetailAcrossFullWidthIsNotPillarboxed() {
        let image = Self.makeImage(width: 480, height: 360, detailedColumns: 0..<480)
        XCTAssertEqual(ThumbnailAnalyzer.looksPillarboxed(image), false)
    }

    func testDetailOnlyInCentreSlotIsPillarboxed() {
        // 9:16 content inside 480 wide ≈ the middle 270 px.
        let image = Self.makeImage(width: 480, height: 360, detailedColumns: 105..<375)
        XCTAssertEqual(ThumbnailAnalyzer.looksPillarboxed(image), true)
    }

    func testFlatImageIsNotPillarboxed() {
        let image = Self.makeImage(width: 480, height: 360, detailedColumns: 0..<0)
        XCTAssertEqual(ThumbnailAnalyzer.looksPillarboxed(image), false)
    }

    func testDetailOnOnlyOneSideIsNotPillarboxed() {
        // A talking head framed hard right with a plain wall on the left.
        let image = Self.makeImage(width: 480, height: 360, detailedColumns: 240..<480)
        XCTAssertEqual(ThumbnailAnalyzer.looksPillarboxed(image), false)
    }

    func testTinyImageIsInconclusive() {
        let image = Self.makeImage(width: 16, height: 9, detailedColumns: 0..<16)
        XCTAssertNil(ThumbnailAnalyzer.looksPillarboxed(image))
    }

    func testGarbageDataIsInconclusive() {
        XCTAssertNil(ThumbnailAnalyzer.looksPillarboxed(imageData: Data([0, 1, 2, 3])))
    }

    // MARK: - Fixtures

    /// Grey image with a deterministic high-contrast checker pattern in the
    /// given column range and a smooth horizontal gradient elsewhere (the
    /// gradient stands in for YouTube's blur: non-zero but low edge energy).
    /// Shared with `FeedRefresherTests`, which serves it as a stub thumbnail.
    static func makeImage(width: Int, height: Int, detailedColumns: Range<Int>) -> CGImage {
        var pixels = [UInt8](repeating: 0, count: width * height)
        var seed: UInt32 = 12345
        for y in 0..<height {
            for x in 0..<width {
                let value: Int
                if detailedColumns.contains(x) {
                    seed = seed &* 1_103_515_245 &+ 12345
                    value = Int((seed >> 16) & 0xFF)
                } else {
                    value = 60 + (x * 40) / max(1, width)
                }
                pixels[y * width + x] = UInt8(value)
            }
        }
        let context = pixels.withUnsafeMutableBytes { raw in
            CGContext(
                data: raw.baseAddress, width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: width,
                space: CGColorSpaceCreateDeviceGray(),
                bitmapInfo: CGImageAlphaInfo.none.rawValue
            )!
        }
        return context.makeImage()!
    }
}
