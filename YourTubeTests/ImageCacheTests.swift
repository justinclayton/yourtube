import XCTest
import UIKit
@testable import YourTube

final class ImageCacheTests: XCTestCase {
    override func setUp() {
        StubURLProtocol.reset()
    }

    override func tearDown() {
        StubURLProtocol.reset()
    }

    // MARK: - Downsampling

    /// The whole point of downsampling: a 480×360 `hqdefault` (YouTube's
    /// standard thumbnail) decoded for a 120×68 feed row must not come back
    /// anywhere near its source resolution.
    func testDownsampleNeverExceedsTheRequestedSlotsLongestSide() throws {
        let data = try Self.jpegData(width: 480, height: 360)
        let slot = CGSize(width: 120, height: 68)

        let image = try XCTUnwrap(ImageCache.downsample(data: data, toPixelSize: slot))
        let cgImage = try XCTUnwrap(image.cgImage)

        // CGImageSourceCreateThumbnailAtIndex bounds the longest side to the
        // slot's largest dimension; allow a pixel of rounding slack.
        XCTAssertLessThanOrEqual(max(cgImage.width, cgImage.height), Int(max(slot.width, slot.height)) + 1)
        // And it's a real reduction, not a no-op: the decode is a fraction of
        // the source's 480×360 = 172,800 pixels.
        XCTAssertLessThan(cgImage.width * cgImage.height, (480 * 360) / 4)
    }

    /// The cache takes pixel sizes, not point sizes, precisely so a 3x
    /// screen gets a decode sized for 3x rather than for 1x.
    func testDownsampleHonoursTheRequestedPixelSizeNotJustPoints() throws {
        let data = try Self.jpegData(width: 480, height: 360)
        let onePointX = CGSize(width: 120, height: 68)
        let threePointX = CGSize(width: 360, height: 204)

        let small = try XCTUnwrap(ImageCache.downsample(data: data, toPixelSize: onePointX))
        let large = try XCTUnwrap(ImageCache.downsample(data: data, toPixelSize: threePointX))
        let smallImage = try XCTUnwrap(small.cgImage)
        let largeImage = try XCTUnwrap(large.cgImage)

        XCTAssertLessThanOrEqual(max(smallImage.width, smallImage.height), 121)
        XCTAssertGreaterThan(max(largeImage.width, largeImage.height), 200)
        XCTAssertLessThanOrEqual(max(largeImage.width, largeImage.height), 361)
    }

    func testDownsampleReturnsNilForGarbageData() {
        XCTAssertNil(ImageCache.downsample(data: Data("not an image".utf8), toPixelSize: CGSize(width: 100, height: 100)))
    }

    // MARK: - Cache hits

    /// `FeedRefresher.analyzeThumbnails` seeds raw bytes for a URL it has
    /// already downloaded. A later request for that same URL must use them
    /// instead of hitting the network — proven here by leaving no stub
    /// registered at all: an actual fetch would fail and come back nil.
    func testSeededDataIsUsedWithoutTouchingTheNetwork() async throws {
        let url = URL(string: "https://i.ytimg.com/vi/abc123/hqdefault.jpg")!
        let data = try Self.jpegData(width: 480, height: 360)
        let cache = ImageCache(session: StubURLProtocol.session())
        cache.seed(data: data, for: url)

        let image = await cache.image(for: url, pixelSize: CGSize(width: 120, height: 68))

        XCTAssertNotNil(image)
        XCTAssertTrue(StubURLProtocol.recordedRequests.isEmpty)
    }

    /// A second request for the same URL at the same size is a decoded-cache
    /// hit: no second network fetch.
    func testSecondRequestAtTheSameSizeComesFromTheDecodedCache() async throws {
        let url = URL(string: "https://i.ytimg.com/vi/xyz789/hqdefault.jpg")!
        let data = try Self.jpegData(width: 480, height: 360)
        StubURLProtocol.stubs.append(("xyz789", StubURLProtocol.Stub(statusCode: 200, body: data)))
        let cache = ImageCache(session: StubURLProtocol.session())
        let size = CGSize(width: 120, height: 68)

        let first = await cache.image(for: url, pixelSize: size)
        XCTAssertNotNil(first)
        XCTAssertEqual(StubURLProtocol.recordedRequests.count, 1)

        let second = await cache.image(for: url, pixelSize: size)
        XCTAssertNotNil(second)
        XCTAssertEqual(StubURLProtocol.recordedRequests.count, 1, "same URL and size should be a decoded-cache hit")
    }

    /// The same URL drawn at a different slot (an avatar shown at 44pt in
    /// one place and 120pt in another) decodes fresh but never re-downloads:
    /// the bytes already live in the raw-data tier from the first fetch.
    func testDifferentSizeForSameURLReusesRawBytesInsteadOfRefetching() async throws {
        let url = URL(string: "https://i.ytimg.com/vi/qrs456/hqdefault.jpg")!
        let data = try Self.jpegData(width: 480, height: 360)
        StubURLProtocol.stubs.append(("qrs456", StubURLProtocol.Stub(statusCode: 200, body: data)))
        let cache = ImageCache(session: StubURLProtocol.session())

        _ = await cache.image(for: url, pixelSize: CGSize(width: 120, height: 68))
        XCTAssertEqual(StubURLProtocol.recordedRequests.count, 1)

        let second = await cache.image(for: url, pixelSize: CGSize(width: 44, height: 44))
        XCTAssertNotNil(second)
        XCTAssertEqual(StubURLProtocol.recordedRequests.count, 1, "different slot, same URL: reuse the bytes, don't refetch")
    }

    // MARK: - Helpers

    private static func jpegData(width: Int, height: Int) throws -> Data {
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: width, height: height))
        let image = renderer.image { _ in
            UIColor.systemBlue.setFill()
            UIRectFill(CGRect(x: 0, y: 0, width: width, height: height))
            UIColor.systemRed.setFill()
            UIRectFill(CGRect(x: width / 4, y: height / 4, width: width / 2, height: height / 2))
        }
        return try XCTUnwrap(image.jpegData(compressionQuality: 0.9))
    }
}
