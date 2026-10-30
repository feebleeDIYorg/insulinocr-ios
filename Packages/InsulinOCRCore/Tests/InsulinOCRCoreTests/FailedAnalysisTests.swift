import Foundation
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
