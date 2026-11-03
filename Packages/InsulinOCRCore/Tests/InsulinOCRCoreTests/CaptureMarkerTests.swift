import XCTest
@testable import InsulinOCRCore

final class CaptureMarkerTests: XCTestCase {
    private let frame = OCRNormalizedRect(x: 0.1, y: 0.1, width: 0.8, height: 0.8)

    private func image(marker: Int = 600, gap: Bool = false, futurePanel: Bool = true) -> OCRPixelImage {
        let width = 1000, height = 500
        var bytes = [UInt8](repeating: 255, count: width * height * 4)
        func paint(_ x: Int, _ y: Int, _ color: (UInt8, UInt8, UInt8)) {
            let i = (y * width + x) * 4
            bytes[i] = color.0; bytes[i+1] = color.1; bytes[i+2] = color.2
        }
        for y in 50..<450 {
            if futurePanel { for x in (marker+6)..<900 { paint(x,y,(216,216,217)) } }
            for x in marker..<(marker+6) { paint(x,y,(150,150,155)) }
        }
        for x in 100..<marker where !(gap && x >= marker-15) {
            for y in 390..<400 { paint(x,y,(10,80,220)) }
        }
        // Future delivery is deliberately a very different rate.
        for x in (marker+6)..<900 { for y in 300..<310 { paint(x,y,(10,80,220)) } }
        // A future event stem must not become a past unknown amount.
        for x in (marker+30)..<(marker+34) { for y in 25..<70 { paint(x,y,(0,0,0)) } }
        return .init(width: width, height: height, rgba: bytes)
    }

    func testMarkerCutsFutureBasalAndEventsAndAnchorsOnlyTouchingPath() throws {
        let pixels = image()
        let marker = try XCTUnwrap(OCRLayoutDetector.captureMarker(image: pixels, frame: frame))
        XCTAssertEqual(marker.minX, 0.6, accuracy: 1e-9)
        XCTAssertEqual(marker.maxX, 0.606, accuracy: 1e-9)
        let past = OCRNormalizedRect(x: frame.minX, y: frame.minY,
            width: marker.minX-frame.minX, height: frame.height)
        XCTAssertTrue(OCREventStemDetector.detect(image: pixels, plotFrame: past).isEmpty)
        let capture = Date(timeIntervalSince1970: 100_000)
        let time = OCRAxisCalibration(kind: .time, source: .multipleOCRAnchors,
            slope: 360, intercept: 0, maximumResidual: 0, anchors: [])
        let rate = OCRAxisCalibration(kind: .basalRate, source: .numericAxisAnchors,
            slope: -10, intercept: 10, maximumResidual: 0, anchors: [])
        let result = OCRBasalPathExtractor.extract(image: pixels, plotFrame: past,
            excludedRects: [], timeline: .init(calibration: time, referenceX: marker.maxX,
                referenceDate: capture.addingTimeInterval(-30)), rateCalibration: rate,
            captureMarkerEndDate: capture)
        XCTAssertEqual(result.pathCoverage, 1, accuracy: 1e-9)
        XCTAssertEqual(result.steps.count, 1)
        XCTAssertEqual(result.steps.first?.endDate, capture)
        XCTAssertEqual(try XCTUnwrap(result.steps.first?.rateUnitsPerHour), 2.02, accuracy: 1e-9)
        let missing = OCRBasalPathExtractor.extract(image: image(gap: true), plotFrame: past,
            excludedRects: [], timeline: .init(calibration: time, referenceX: marker.maxX,
                referenceDate: capture.addingTimeInterval(-30)), rateCalibration: rate,
            captureMarkerEndDate: capture)
        XCTAssertLessThan(try XCTUnwrap(missing.steps.last?.endDate), capture)
        XCTAssertLessThan(missing.pathCoverage, 0.99)
    }

    func testGridlineWithoutFutureShadeIsNotCaptureMarker() throws {
        XCTAssertNil(try OCRLayoutDetector.captureMarker(image: image(futurePanel: false), frame: frame))
    }

    func testMarkerBeforeChartMidpointStillCutsAllFutureValues() throws {
        XCTAssertEqual(try XCTUnwrap(OCRLayoutDetector.captureMarker(image: image(marker: 300), frame: frame)).minX,
            0.3, accuracy: 1e-9)
    }

    func testLegacyLayoutWithoutMarkerStillDecodes() throws {
        let old = OCRDetectedLayout(profile: .camAPSFXLandscapeV1, plotFrame: frame,
            dataRightEdgeX: 0.8, estimatedVisibleHours: 6, confidence: 1)
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(old)) as? [String: Any])
        json.removeValue(forKey: "captureMarkerBounds")
        XCTAssertNil(try JSONDecoder().decode(OCRDetectedLayout.self,
            from: JSONSerialization.data(withJSONObject: json)).captureMarkerBounds)
    }
}
