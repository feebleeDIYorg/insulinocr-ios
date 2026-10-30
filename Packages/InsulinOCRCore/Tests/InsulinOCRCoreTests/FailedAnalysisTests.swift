import Foundation
import CoreGraphics
import CoreText
import ImageIO
import XCTest
@testable import InsulinOCRCore

@MainActor
final class FailedAnalysisTests: XCTestCase {
    func testFailedAttemptRoundTripRetainsRawCandidatesWithoutCalibration() throws {
        let raw = OCRRawTextObservation(region: .timeAxis,
            boundingBox: OCRNormalizedRect(x: 0.2, y: 0.8, width: 0.1, height: 0.05),
            candidates: [OCRTextCandidate(text: "02:00", confidence: 0.7),
                         OCRTextCandidate(text: "08:00", confidence: 0.3)])
        let failure = OCRFailedAnalysis(requestID: UUID(), algorithmVersion: "synthetic",
            visionRevision: 3, code: .invalidTimeAxis, message: "Synthetic inconsistent anchors",
            rawTextObservations: [raw])
        let bytes = try JSONEncoder().encode(failure)
        XCTAssertEqual(try JSONDecoder().decode(OCRFailedAnalysis.self, from: bytes), failure)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
        XCTAssertNil(object["calibration"])
        XCTAssertNil(object["observations"])
    }

    func testRejectedLayoutRetainsActualVisionObservations() async throws {
        let context = try XCTUnwrap(CGContext(data: nil, width: 800, height: 1200,
            bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 800, height: 1200))
        let font = CTFontCreateWithName("Helvetica" as CFString, 64, nil)
        let text = NSAttributedString(string: "02:00", attributes: [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 0, alpha: 1)])
        context.textPosition = CGPoint(x: 120, y: 600)
        CTLineDraw(CTLineCreateWithAttributedString(text), context)
        let image = try XCTUnwrap(context.makeImage())
        let bytes = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(bytes, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        let request = ScreenshotAnalysisRequest(imageData: bytes as Data)
        let result = await NativeAnalysisEngine().analyzeRetainingFailure(request)
        guard case .failure(let failure) = result else { return XCTFail("Portrait layout accepted") }
        XCTAssertEqual(failure.code, .unsupportedLayout, failure.message)
        XCTAssertEqual(failure.requestID, request.id)
        XCTAssertTrue(failure.rawTextObservations.contains {
            $0.region == .fullImage && $0.candidates.contains { $0.text == "02:00" }
        }, failure.message)
    }

    func testConcurrentInvalidRequestsKeepTheirOwnFailureIdentity() async throws {
        let engine = NativeAnalysisEngine()
        let first = ScreenshotAnalysisRequest(imageData: Data([0, 1]))
        let second = ScreenshotAnalysisRequest(imageData: Data([2, 3]))
        async let a = engine.analyzeRetainingFailure(first)
        async let b = engine.analyzeRetainingFailure(second)
        let results = await [a, b]
        var ids = Set<UUID>()
        for result in results {
            guard case .failure(let failure) = result else { return XCTFail("Invalid bytes accepted") }
            XCTAssertEqual(failure.code, .invalidImage)
            XCTAssertTrue(failure.rawTextObservations.isEmpty)
            ids.insert(failure.requestID)
        }
        XCTAssertEqual(ids, [first.id, second.id])
        do {
            _ = try await engine.analyze(first)
            XCTFail("Legacy throwing interface accepted invalid bytes")
        } catch {
            XCTAssertEqual(error as? OCRAnalysisFailure, .invalidImage)
        }
    }
}
