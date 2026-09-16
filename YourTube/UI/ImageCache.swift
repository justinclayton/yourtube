import SwiftUI
import ImageIO
import UIKit

/// A small shared cache of decoded, downsampled images, so a thumbnail or
/// avatar already seen on screen never re-decodes and never flashes a
/// placeholder when it scrolls back into view.
///
/// Two tiers, both keyed by URL:
///
/// - `rawData` holds the compressed bytes a fetch returned. `analyzeThumbnails`
///   already downloads every new upload's `hqdefault` for the Shorts
///   heuristic, so it seeds this tier directly (`seed(data:for:)`) and the
///   feed row that shows the same video's thumbnail decodes it without a
///   second download.
/// - `decoded` holds the `UIImage` produced from those bytes at one exact
///   pixel size. The same URL drawn at two different slots (a 44pt avatar
///   and a 120pt one) gets two entries: decoding once at the larger size and
///   scaling down in the view would keep the bigger bitmap resident
///   everywhere, which is exactly the memory cost this cache exists to avoid.
///
/// `NSCache` is thread-safe on its own, so this type is safe to call from any
/// thread or task without extra locking.
final class ImageCache: @unchecked Sendable {
    static let shared = ImageCache()

    private let rawData = NSCache<NSString, NSData>()
    private let decoded = NSCache<NSString, UIImage>()
    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
        rawData.countLimit = 300
        decoded.countLimit = 300
    }

    /// Stores bytes for `url` without decoding them, so a later request for a
    /// downsampled image can skip the network. `FeedRefresher.analyzeThumbnails`
    /// calls this with the `hqdefault` bytes it already downloaded.
    func seed(data: Data, for url: URL) {
        rawData.setObject(data as NSData, forKey: url.absoluteString as NSString)
    }

    /// A synchronous, decoded-cache-only lookup: no raw-data decode, no
    /// network. Lets a view seed its own state at init time so an
    /// already-seen image paints on the very first frame rather than waiting
    /// a run loop turn for `.task` to come back with the same answer.
    func cachedImage(for url: URL, pixelSize: CGSize) -> UIImage? {
        decoded.object(forKey: cacheKey(url: url, pixelSize: pixelSize))
    }

    /// The decoded image for `url` at `pixelSize`, from the decoded cache,
    /// the raw-data cache, or the network, in that order. `pixelSize` must
    /// already be in pixels (point size × display scale) — this cache never
    /// guesses a scale, so a view drawing at 3x doesn't get a 1x decode.
    func image(for url: URL, pixelSize: CGSize) async -> UIImage? {
        if let cached = cachedImage(for: url, pixelSize: pixelSize) { return cached }

        let data: Data
        if let cachedData = rawData.object(forKey: url.absoluteString as NSString) {
            data = cachedData as Data
        } else {
            guard let (fetched, response) = try? await session.data(from: url),
                  (response as? HTTPURLResponse)?.statusCode == 200
            else { return nil }
            data = fetched
            seed(data: data, for: url)
        }

        guard let image = Self.downsample(data: data, toPixelSize: pixelSize) else { return nil }
        decoded.setObject(image, forKey: cacheKey(url: url, pixelSize: pixelSize))
        return image
    }

    private func cacheKey(url: URL, pixelSize: CGSize) -> NSString {
        "\(url.absoluteString)@\(Int(pixelSize.width.rounded()))x\(Int(pixelSize.height.rounded()))" as NSString
    }

    /// Decodes `data` straight to a bitmap no larger than `pixelSize`'s
    /// longest side, via `CGImageSourceCreateThumbnailAtIndex` — the
    /// documented way to avoid ever holding the source image's full
    /// resolution in memory. The 480×360 `hqdefault` YouTube serves would
    /// otherwise decode at 4× the pixels a 120×68 feed row draws.
    ///
    /// The cap applies to the longest side rather than both dimensions
    /// independently: a slot's aspect ratio rarely matches the source
    /// image's, and every call site here draws with `.fill`/`.scaledToFill`,
    /// which crops rather than distorts — capping only the long side is what
    /// keeps the short side at least as large as the slot needs after that
    /// crop, while still cutting memory far below the source resolution.
    static func downsample(data: Data, toPixelSize pixelSize: CGSize) -> UIImage? {
        let maxDimension = max(pixelSize.width, pixelSize.height)
        guard maxDimension > 0, let source = CGImageSourceCreateWithData(data as CFData, nil) else {
            return nil
        }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxDimension
        ]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            return nil
        }
        return UIImage(cgImage: cgImage)
    }

    /// Test-only: empties both tiers so one test's images can't leak into
    /// another's expectations.
    func removeAll() {
        rawData.removeAllObjects()
        decoded.removeAllObjects()
    }
}

/// Drop-in replacement for `AsyncImage`'s phase-based API, backed by
/// `ImageCache`. The same URL drawn at the same point size on a later
/// appearance — a feed row scrolled back into view — is served from the
/// cache instead of re-downloading and re-decoding, so the placeholder
/// this view shows while `.task` runs the first time never reappears after
/// that.
struct CachedAsyncImage<Content: View, Placeholder: View>: View {
    private let url: URL?
    /// The slot this image is drawn into, in points; converted to pixels
    /// with the environment's display scale before it reaches the cache.
    private let size: CGSize
    private let content: (Image) -> Content
    private let placeholder: () -> Placeholder

    @Environment(\.displayScale) private var displayScale
    @State private var uiImage: UIImage?

    init(
        url: URL?,
        size: CGSize,
        @ViewBuilder content: @escaping (Image) -> Content,
        @ViewBuilder placeholder: @escaping () -> Placeholder
    ) {
        self.url = url
        self.size = size
        self.content = content
        self.placeholder = placeholder
    }

    var body: some View {
        Group {
            if let uiImage {
                content(Image(uiImage: uiImage))
            } else {
                placeholder()
            }
        }
        .task(id: RequestKey(url: url, size: size, scale: displayScale)) {
            guard let url, size.width > 0.5, size.height > 0.5 else {
                uiImage = nil
                return
            }
            uiImage = await ImageCache.shared.image(for: url, pixelSize: pixelSize(scale: displayScale))
        }
    }

    private func pixelSize(scale: CGFloat) -> CGSize {
        CGSize(width: (size.width * scale).rounded(.up), height: (size.height * scale).rounded(.up))
    }

    private struct RequestKey: Equatable {
        let url: URL?
        let size: CGSize
        let scale: CGFloat
    }
}
