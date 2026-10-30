import CoreGraphics
import Foundation

extension NativeAnalysisEngine {
    nonisolated static func isUnclippedPillText(
        _ box: OCRNormalizedRect, in region: OCRNormalizedRect,
        imageWidth: Int, imageHeight: Int
    ) -> Bool {
        guard imageWidth > 0, imageHeight > 0, box.width > 0, box.height > 0,
              [box.x, box.y, box.width, box.height].allSatisfy(\.isFinite) else { return false }
        let width = Double(imageWidth), height = Double(imageHeight)
        let crop = region.clampedToUnitSquare()
        return box.minX * width > floor(crop.minX * width) + 1
            && box.maxX * width < ceil(crop.maxX * width) - 1
            && box.minY * height > floor(crop.minY * height) + 1
            && box.maxY * height < ceil(crop.maxY * height) - 1
    }

    /// Fixed alternate observation: dark/blue ink, white background and removal
    /// of light pill borders. Never replaces the original image or candidates.
    nonisolated static func highContrastPillImage(from image: CGImage) -> CGImage? {
        guard image.width <= 1024, image.height <= 256,
              image.width * image.height <= 200_000,
              let pixels = makePixelImage(from: image) else { return nil }
        let scale = 3, width = pixels.width * scale, height = pixels.height * scale
        var output = [UInt8](repeating: 255, count: width * height * 4)
        for y in 0..<pixels.height {
            for x in 0..<pixels.width {
                let index = (y * pixels.width + x) * 4
                let alpha = Int(pixels.rgba[index + 3])
                // The source buffer is premultiplied: composite onto white.
                let r = Int(pixels.rgba[index]) + 255 - alpha
                let g = Int(pixels.rgba[index + 1]) + 255 - alpha
                let b = Int(pixels.rgba[index + 2]) + 255 - alpha
                let ink: UInt8 = (54 * r + 183 * g + 19 * b) / 256 < 179 ? 0 : 255
                for dy in 0..<scale {
                    for dx in 0..<scale {
                        let target = ((y * scale + dy) * width + x * scale + dx) * 4
                        output[target] = ink
                        output[target + 1] = ink
                        output[target + 2] = ink
                    }
                }
            }
        }
        guard let provider = CGDataProvider(data: Data(output) as CFData) else { return nil }
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
            bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGBitmapInfo.byteOrder32Big.rawValue
                | CGImageAlphaInfo.premultipliedLast.rawValue), provider: provider,
            decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }
}
