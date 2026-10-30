import CoreGraphics
import Foundation
import XCTest
@testable import InsulinOCRCore

final class PillImagePreparationTests: XCTestCase {
    func testPreparationPreservesInkAndRemovesPaleBorderWithoutMutatingSource() throws {
        let bytes: [UInt8] = [20, 140, 255, 255, 210, 210, 210, 255, 0, 0, 0, 0,
            255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255]
        let provider = try XCTUnwrap(CGDataProvider(data: Data(bytes) as CFData))
        let image = try XCTUnwrap(CGImage(width: 3, height: 2, bitsPerComponent: 8, bitsPerPixel: 32,
            bytesPerRow: 12, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGBitmapInfo.byteOrder32Big.rawValue
                | CGImageAlphaInfo.premultipliedLast.rawValue), provider: provider,
            decode: nil, shouldInterpolate: false, intent: .defaultIntent))
        let before = try XCTUnwrap(NativeAnalysisEngine.makePixelImage(from: image))
        let prepared = try XCTUnwrap(NativeAnalysisEngine.highContrastPillImage(from: image))
        let pixels = try XCTUnwrap(NativeAnalysisEngine.makePixelImage(from: prepared))
        XCTAssertEqual(pixels.width, 9)
        XCTAssertEqual(pixels.height, 6)
        for row in 0..<6 {
            for column in 0..<9 {
                let expected: UInt8 = row < 3 && column < 3 ? 0 : 255
                let index = (row * 9 + column) * 4
                XCTAssertEqual(Array(pixels.rgba[index..<index + 3]), [expected, expected, expected])
                XCTAssertEqual(pixels.rgba[index + 3], 255)
            }
        }
        XCTAssertEqual(NativeAnalysisEngine.makePixelImage(from: image)?.rgba, before.rgba)
    }

    func testTextTouchingCropBoundaryCannotSupplyAnEnhancedAmount() {
        let crop = OCRNormalizedRect(x: 0.1, y: 0.1, width: 0.2, height: 0.2)
        XCTAssertTrue(NativeAnalysisEngine.isUnclippedPillText(
            OCRNormalizedRect(x: 0.12, y: 0.12, width: 0.16, height: 0.16),
            in: crop, imageWidth: 100, imageHeight: 100))
        for box in [OCRNormalizedRect(x: 0.1, y: 0.12, width: 0.18, height: 0.16),
                    OCRNormalizedRect(x: 0.12, y: 0.12, width: 0.18, height: 0.16),
                    OCRNormalizedRect(x: 0.12, y: 0.1, width: 0.16, height: 0.18)] {
            XCTAssertFalse(NativeAnalysisEngine.isUnclippedPillText(
                box, in: crop, imageWidth: 100, imageHeight: 100))
        }
    }

    func testLegacyRawObservationDecodesWithoutPreprocessingField() throws {
        let original = OCRRawTextObservation(region: .eventPill,
            boundingBox: OCRNormalizedRect(x: 0.1, y: 0.1, width: 0.1, height: 0.1),
            candidates: [OCRTextCandidate(text: "1 U", confidence: 0.8)])
        let data = try JSONEncoder().encode(original)
        XCTAssertEqual(try JSONDecoder().decode(OCRRawTextObservation.self, from: data), original)
        let enhanced = OCRRawTextObservation(region: original.region, boundingBox: original.boundingBox,
            candidates: original.candidates, preprocessing: "binary-luma-0.7-nearest-3x/v1")
        XCTAssertEqual(try JSONDecoder().decode(OCRRawTextObservation.self,
            from: JSONEncoder().encode(enhanced)), enhanced)
        let ambiguous = OCRTextParser.amount(from: [
            OCRTextCandidate(text: "1 U", confidence: 0.8),
            OCRTextCandidate(text: "2 U", confidence: 0.99)], expectedKind: .bolus)
        XCTAssertNil(ambiguous.0.value)
    }
}
