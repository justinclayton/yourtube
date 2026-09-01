import Foundation
import CoreGraphics
import ImageIO

/// Detects vertical (9:16) video from its landscape thumbnail.
///
/// YouTube serves Shorts thumbnails as 16:9 images with the vertical frame in
/// the middle and a heavily blurred copy of it filling the sides. The blur
/// destroys fine detail, so the side strips have far less edge energy than the
/// centre. A normal 16:9 thumbnail has comparable detail across its width.
///
/// Measured on real thumbnails: Shorts score 0.1–0.35, regular videos 0.7+.
/// The threshold sits in the gap. This runs on-device against the `hqdefault`
/// image (480×360), costs no API quota, and takes about a millisecond.
enum ThumbnailAnalyzer {
    /// Max ratio of side-strip edge energy to centre edge energy for the image
    /// to count as pillarboxed. Both sides must be under it.
    static let sideToCenterEdgeRatio = 0.45

    /// Below this the centre is too flat to compare against — a solid-colour
    /// or mostly blank thumbnail must not be mistaken for pillarboxing.
    static let minimumCenterEdgeEnergy = 6.0

    /// Fraction of the width sampled at each side. Vertical content inside a
    /// 16:9 frame occupies the middle 9/16 ≈ 56%, leaving ~22% per side;
    /// sampling 1/6 stays safely inside the fill.
    private static let sideFraction = 1.0 / 6.0

    static func thumbnailURL(forVideoId id: String) -> URL {
        URL(string: "https://i.ytimg.com/vi/\(id)/hqdefault.jpg")!
    }

    static func looksPillarboxed(imageData: Data) -> Bool? {
        guard let source = CGImageSourceCreateWithData(imageData as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            return nil
        }
        return looksPillarboxed(image)
    }

    static func looksPillarboxed(_ image: CGImage) -> Bool? {
        guard let luma = Luma(image) else { return nil }
        let w = luma.width, h = luma.height
        guard w >= 48, h >= 27 else { return nil }

        // `hqdefault` is 4:3 with black bars top and bottom around a 16:9
        // frame. Sample only the middle band so the bars don't dilute the
        // side measurement. For images already close to 16:9 this is a no-op
        // safe margin.
        let bandInset = h / 8
        let rows = (bandInset + 1)..<(h - bandInset)

        let side = max(1, Int(Double(w) * sideFraction))
        let left = luma.meanEdgeEnergy(columns: 1..<side, rows: rows)
        let right = luma.meanEdgeEnergy(columns: (w - side)..<w, rows: rows)
        let center = luma.meanEdgeEnergy(columns: (w / 2 - side)..<(w / 2 + side), rows: rows)

        guard center >= minimumCenterEdgeEnergy else { return false }
        return left / center < sideToCenterEdgeRatio
            && right / center < sideToCenterEdgeRatio
    }

    /// Greyscale copy of an image with a cheap gradient-energy measure.
    private struct Luma {
        let width: Int
        let height: Int
        private let pixels: [UInt8]

        init?(_ image: CGImage) {
            let w = image.width, h = image.height
            var buffer = [UInt8](repeating: 0, count: w * h)
            let drawn = buffer.withUnsafeMutableBytes { raw -> Bool in
                guard let context = CGContext(
                    data: raw.baseAddress,
                    width: w, height: h,
                    bitsPerComponent: 8, bytesPerRow: w,
                    space: CGColorSpaceCreateDeviceGray(),
                    bitmapInfo: CGImageAlphaInfo.none.rawValue
                ) else { return false }
                context.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
                return true
            }
            guard drawn else { return nil }
            width = w
            height = h
            pixels = buffer
        }

        @inline(__always)
        private func at(_ x: Int, _ y: Int) -> Int { Int(pixels[y * width + x]) }

        /// Mean absolute horizontal + vertical gradient over a region. Columns
        /// and rows must start at ≥ 1 so the backward difference is in bounds.
        func meanEdgeEnergy(columns: Range<Int>, rows: Range<Int>) -> Double {
            var sum = 0, count = 0
            for y in rows {
                for x in columns {
                    sum += abs(at(x, y) - at(x - 1, y)) + abs(at(x, y) - at(x, y - 1))
                    count += 1
                }
            }
            return count == 0 ? 0 : Double(sum) / Double(count)
        }
    }
}
