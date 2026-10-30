import CoreGraphics
import XCTest
@testable import InsulinOCRCore

final class AnalysisPipelineTests: XCTestCase {
    func testBasalZeroAcceptsRoundingNoiseButRejectsNegativeCalibration() throws {
        let width = 200, height = 100
        var pixels = [UInt8](repeating: 255, count: width * height * 4)
        for x in 0..<width {
            for y in 80...88 {
                let index = (y * width + x) * 4
                pixels[index] = 10; pixels[index + 1] = 80; pixels[index + 2] = 220
            }
        }
        let time = OCRAxisCalibration(kind: .time, source: .multipleOCRAnchors,
            slope: 60, intercept: 0, maximumResidual: 0, anchors: [])
        for offset in [5e-15, 0.01] {
            let calibration = OCRAxisCalibration(kind: .basalRate, source: .numericAxisAnchors,
                slope: -10, intercept: 8.8 - offset, maximumResidual: 0, anchors: [])
            let result = OCRBasalPathExtractor.extract(
                image: .init(width: width, height: height, rgba: pixels),
                plotFrame: .init(x: 0, y: 0, width: 1, height: 1), excludedRects: [],
                timeline: .init(calibration: time, referenceX: 1,
                    referenceDate: Date(timeIntervalSince1970: 10_000)),
                rateCalibration: calibration)
            let step = try XCTUnwrap(result.steps.first)
            if offset < 1e-9 {
                XCTAssertEqual(step.rateUnitsPerHour, 0)
            } else {
                XCTAssertNil(step.rateUnitsPerHour)
            }
        }
    }

    func testThickBasalStepDoesNotCreateIntermediateDeliveryRate() {
        let width = 200, height = 100
        var pixels = [UInt8](repeating: 255, count: width * height * 4)
        func blue(_ x: Int, _ y: Int) {
            let index = (y * width + x) * 4
            pixels[index] = 10; pixels[index + 1] = 80; pixels[index + 2] = 220
        }
        // Nine-pixel CamAPS-style strokes end at the logical y=60 and y=20
        // ordinates. Reading their centres invents a +0.4 U/h offset here.
        for x in 0..<width {
            let ordinate = x < 100 ? 60 : 20
            for y in (ordinate - 8)...ordinate { blue(x, y) }
        }
        for x in 98...102 { for y in 12...60 { blue(x, y) } }
        let time = OCRAxisCalibration(kind: .time, source: .multipleOCRAnchors,
            slope: 60, intercept: 0, maximumResidual: 0, anchors: [])
        let rate = OCRAxisCalibration(kind: .basalRate, source: .numericAxisAnchors,
            slope: -10, intercept: 10, maximumResidual: 0, anchors: [])
        let result = OCRBasalPathExtractor.extract(
            image: .init(width: width, height: height, rgba: pixels),
            plotFrame: .init(x: 0, y: 0, width: 1, height: 1), excludedRects: [],
            timeline: .init(calibration: time, referenceX: 1, referenceDate: Date(timeIntervalSince1970: 10_000)),
            rateCalibration: rate)
        XCTAssertEqual(result.pathCoverage, 1, accuracy: 1e-9)
        XCTAssertEqual(result.steps.count, 2)
        XCTAssertEqual(result.steps.map(\.rateUnitsPerHour), [4, 8])
        XCTAssertEqual(result.steps[0].endDate, result.steps[1].startDate)
        var incomplete: [Double?] = [nil, 40, 40, 20]
        OCRBasalPathExtractor.resolveVerticalTransitions(in: &incomplete,
            verticalStroke: [false, true, true, false], maximumWidth: 10)
        XCTAssertEqual(incomplete, [nil, 40, 40, 20])
    }

    func testTouchingHollowMarkersRemainSeparateObservedSamples() {
        let width = 1_000, height = 1_000
        var pixels = [UInt8](repeating: 255, count: width * height * 4)
        for index in 0..<42 {
            let center = 12 + index * 24
            let hollow = index == 20 || index == 21
            let radius = hollow || (2...13).contains(index) ? 13 : 8
            for y in (500 - radius)...(500 + radius) {
                for x in max(0, center - radius)...min(width - 1, center + radius) {
                    let squared = (x - center) * (x - center) + (y - 500) * (y - 500)
                    if squared <= radius * radius && (!hollow || squared >= 121) {
                        for channel in 0..<3 { pixels[(y * width + x) * 4 + channel] = 0 }
                    }
                }
            }
        }
        let time = OCRAxisCalibration(kind: .time, source: .multipleOCRAnchors,
            slope: 1_000.0 / 24 * 5, intercept: 0, maximumResidual: 0, anchors: [])
        let glucose = OCRAxisCalibration(kind: .glucose, source: .numericAxisAnchors,
            slope: -20, intercept: 20, maximumResidual: 0, anchors: [])
        let result = OCRGlucoseExtractor.extract(
            image: .init(width: width, height: height, rgba: pixels),
            plotFrame: .init(x: 0, y: 0, width: 1, height: 1), excludedRects: [],
            timeline: .init(calibration: time, referenceX: 1, referenceDate: Date(timeIntervalSince1970: 10_000)),
            glucoseCalibration: glucose, visibleMinutes: 1_000.0 / 24 * 5)
        XCTAssertEqual(result.mode, "hybrid-local-centers")
        XCTAssertEqual(result.samples.count, 42)
        XCTAssertEqual(result.samples.filter { (0.48...0.53).contains($0.boundingBox.midX) }.count, 2)
        XCTAssertTrue(result.samples.allSatisfy { abs(($0.mmolPerLiter ?? 0) - 10) < 1e-9 })
    }

    func testHollowGlucoseMarkerUsesFullCircleCentre() {
        let width = 1_000, height = 1_000
        var pixels = [UInt8](repeating: 255, count: width * height * 4)
        for y in 487...513 {
            for x in 487...513 {
                let distance = (x - 500) * (x - 500) + (y - 500) * (y - 500)
                if (121...169).contains(distance) {
                    for channel in 0..<3 { pixels[(y * width + x) * 4 + channel] = 0 }
                }
            }
        }
        let time = OCRAxisCalibration(kind: .time, source: .multipleOCRAnchors,
            slope: 5, intercept: 0, maximumResidual: 0, anchors: [])
        let glucose = OCRAxisCalibration(kind: .glucose, source: .numericAxisAnchors,
            slope: -20, intercept: 20, maximumResidual: 0, anchors: [])
        let result = OCRGlucoseExtractor.extract(
            image: .init(width: width, height: height, rgba: pixels),
            plotFrame: .init(x: 0, y: 0, width: 1, height: 1), excludedRects: [],
            timeline: .init(calibration: time, referenceX: 1, referenceDate: Date(timeIntervalSince1970: 10_000)),
            glucoseCalibration: glucose, visibleMinutes: 5)
        XCTAssertEqual(result.mode, "local-centers")
        XCTAssertEqual(result.samples.count, 1)
        XCTAssertEqual(result.samples.first?.mmolPerLiter ?? 0, 10, accuracy: 1e-9)
        XCTAssertEqual(result.samples.first?.boundingBox.midX ?? 0, 0.5005, accuracy: 1e-9)
    }

    func testNumericAxisAnchorsUseTickGeometryAndPreserveUnmatchedLabels() {
        let width = 1_000, height = 500
        var pixels = [UInt8](repeating: 255, count: width * height * 4)
        for y in [100, 200] {
            for x in 190..<200 {
                for channel in 0..<3 { pixels[(y * width + x) * 4 + channel] = 180 }
            }
        }
        for x in 802..<810 {
            for channel in 0..<3 { pixels[(120 * width + x) * 4 + channel] = 180 }
        }
        let image = OCRPixelImage(width: width, height: height, rgba: pixels)
        let frame = OCRNormalizedRect(x: 0.2, y: 0.1, width: 0.6, height: 0.7)
        let anchors: [OCRNumericAnchor] = [
            .init(coordinate: 0.205, value: 4, observationID: UUID()),
            .init(coordinate: 0.404, value: 2, observationID: UUID()),
            .init(coordinate: 0.606, value: 1, observationID: UUID()),
        ]
        let aligned = OCRLayoutDetector.alignNumericAnchors(anchors, image: image, frame: frame, kind: .basalRate)
        XCTAssertEqual(aligned[0].coordinate, 0.2, accuracy: 1e-9)
        XCTAssertEqual(aligned[1].coordinate, 0.4, accuracy: 1e-9)
        XCTAssertEqual(aligned[2], anchors[2])
        XCTAssertEqual(aligned.map(\.value), anchors.map(\.value))
        XCTAssertEqual(aligned.map(\.observationID), anchors.map(\.observationID))
        let right = OCRLayoutDetector.alignNumericAnchors([
            .init(coordinate: 0.245, value: 10, observationID: nil),
        ], image: image, frame: frame, kind: .glucose)
        XCTAssertEqual(right[0].coordinate, 0.24, accuracy: 1e-9)
    }

    func testInterruptedUpperStemRequiresVisibleStubAndBluePillEvidence() {
        let width = 1_000, height = 500
        var bytes = [UInt8](repeating: 255, count: width * height * 4)
        for y in 62..<70 {
            for x in 400...402 {
                for channel in 0..<3 { bytes[(y * width + x) * 4 + channel] = 0 }
            }
        }
        let lower = OCRDetectedEventStem(kind: .unknown,
            stemRect: .init(x: 0.4, y: 0.18, width: 0.003, height: 0.06),
            pillRect: .init(x: 0.375, y: 0.135, width: 0.05, height: 0.045),
            isComplete: true, confidence: 0.9)
        let frame = OCRNormalizedRect(x: 0.1, y: 0.2, width: 0.8, height: 0.65)
        XCTAssertEqual(OCREventStemDetector.recoverStackedBolusStems([lower],
            image: .init(width: width, height: height, rgba: bytes), frame: frame).count, 1)
        for y in 48..<51 {
            for x in 390..<410 {
                let i = (y * width + x) * 4
                bytes[i] = 25; bytes[i + 1] = 143; bytes[i + 2] = 255
            }
        }
        let recovered = OCREventStemDetector.recoverStackedBolusStems([lower],
            image: .init(width: width, height: height, rgba: bytes), frame: frame)
        XCTAssertEqual(recovered.count, 2)
        XCTAssertEqual(recovered.filter { $0.kind == .bolus }.count, 1)
        XCTAssertEqual(OCREventStemDetector.recoverStackedBolusStems(recovered,
            image: .init(width: width, height: height, rgba: bytes), frame: frame).count, 2)
    }

    func testBasalBlueExcludesPurpleInterfaceHighlight() {
        XCTAssertTrue(OCRPixelColor(red: 25, green: 143, blue: 255, alpha: 255).isTherapyBlue)
        XCTAssertFalse(OCRPixelColor(red: 190, green: 185, blue: 255, alpha: 255).isTherapyBlue)
        XCTAssertFalse(OCRPixelColor(red: 216, green: 216, blue: 217, alpha: 255).isTherapyBlue)
    }

    func testChartAxisIgnoresProtrudingTicksAndFuturePanelExcludesProjection() throws {
        let width = 1_000, height = 500
        var bytes = [UInt8](repeating: 255, count: width * height * 4)
        func grey(_ x: Int, _ y: Int, _ value: UInt8) {
            for channel in 0..<3 { bytes[(y * width + x) * 4 + channel] = value }
        }
        for x in 100..<900 { grey(x, 240, 150) }
        for x in 110..<900 { grey(x, 420, 150) }
        for y in 100...420 { grey(110, y, 150) }
        for y in 100..<420 {
            for x in 800..<890 {
                grey(x, y, 211)
                bytes[(y * width + x) * 4 + 2] = 180
            }
            for x in 850...852 { grey(x, y, 150) }
        }
        let image = OCRPixelImage(width: width, height: height, rgba: bytes)
        let frame = try OCRLayoutDetector.detectPlotFrame(image: image)
        XCTAssertEqual(frame.minX, 0.11, accuracy: 1e-9)
        XCTAssertEqual(frame.minY, 0.2, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(OCRLayoutDetector.futurePanelBoundary(image: image, frame: frame)), 0.8, accuracy: 1e-9)
        for y in 100..<420 {
            for x in 800..<890 where bytes[(y * width + x) * 4] == 211 {
                bytes[(y * width + x) * 4 + 1] = 180
                bytes[(y * width + x) * 4 + 2] = 180
            }
        }
        let redPanel = OCRPixelImage(width: width, height: height, rgba: bytes)
        XCTAssertEqual(try XCTUnwrap(OCRLayoutDetector.futurePanelBoundary(image: redPanel, frame: frame)), 0.8, accuracy: 1e-9)
        for y in 100..<420 {
            for x in 800..<890 { grey(x, y, y < 250 ? 255 : 211) }
        }
        let noFuture = OCRPixelImage(width: width, height: height, rgba: bytes)
        XCTAssertNil(OCRLayoutDetector.futurePanelBoundary(image: noFuture, frame: frame))
    }

    func testContradictoryEventAmountsOrKindsRemainUnknown() {
        for texts in [["23 g", "235 g"], ["2 IE", "2 g"]] {
            let parsed = OCRTextParser.amount(
                from: texts.map { .init(text: $0, confidence: 0.9) }, expectedKind: .unknown)
            XCTAssertNil(parsed.0.value)
            XCTAssertEqual(parsed.1, .unknown)
        }
        let consistent = OCRTextParser.amount(from: [
            .init(text: "0.5 IE", confidence: 0.9),
            .init(text: "0,5 U", confidence: 0.8),
        ], expectedKind: .bolus)
        XCTAssertEqual(consistent.0.value, 0.5)
    }

    func testNeighbouringPillCropsDoNotSharePixelsOrClipDifferentRows() {
        func stem(_ x: Double, _ y: Double) -> OCRDetectedEventStem {
            .init(kind: .unknown, stemRect: .init(x: x, y: y, width: 0.002, height: 0.06),
                pillRect: .init(x: x - 0.025, y: y - 0.04, width: 0.05, height: 0.045),
                isComplete: true, confidence: 0.8)
        }
        let original = [stem(0.4, 0.18), stem(0.42, 0.18), stem(0.41, 0.12)]
        let isolated = OCREventStemDetector.isolatePillRegions(original)
        XCTAssertEqual(isolated[0].pillRect.maxX, isolated[1].pillRect.minX, accuracy: 1e-9)
        XCTAssertEqual(isolated[2].pillRect, original[2].pillRect)
        XCTAssertEqual(isolated.map(\.stemRect), original.map(\.stemRect))
    }

    func testEventStemDetectorRejectsStatusStripInsideChart() {
        let width = 1_000
        let height = 500
        var bytes = [UInt8](repeating: 255, count: width * height * 4)
        for y in 65..<130 {
            for x in 400...402 {
                for channel in 0..<3 { bytes[(y * width + x) * 4 + channel] = 0 }
            }
        }
        for y in 102..<140 {
            for x in 880...885 {
                let index = (y * width + x) * 4
                bytes[index] = 230; bytes[index + 1] = 100; bytes[index + 2] = 20
            }
        }
        let stems = OCREventStemDetector.detect(
            image: .init(width: width, height: height, rgba: bytes),
            plotFrame: .init(x: 0.1, y: 0.2, width: 0.8, height: 0.65)
        )
        XCTAssertEqual(stems.count, 1)
        XCTAssertEqual(stems.first?.stemRect.midX ?? 0, 0.4015, accuracy: 1e-9)
        XCTAssertTrue(stems.first?.isComplete == true)
    }

    func testBasalDataRangeExcludesStatusStripAndEndsAtCapture() {
        let width = 200
        let height = 100
        var bytes = [UInt8](repeating: 255, count: width * height * 4)
        for x in 0..<180 {
            let index = (60 * width + x) * 4
            bytes[index] = 10; bytes[index + 1] = 80; bytes[index + 2] = 220
        }
        let capture = Date(timeIntervalSince1970: 10_000)
        let time = OCRAxisCalibration(kind: .time, source: .multipleOCRAnchors,
            slope: 120, intercept: 0, maximumResidual: 0, anchors: [])
        let result = OCRBasalPathExtractor.extract(
            image: .init(width: width, height: height, rgba: bytes),
            plotFrame: .init(x: 0, y: 0, width: 0.9, height: 1), excludedRects: [],
            timeline: .init(calibration: time, referenceX: 0.9, referenceDate: capture),
            rateCalibration: nil
        )
        XCTAssertEqual(result.pathCoverage, 1, accuracy: 1e-9)
        XCTAssertEqual(result.steps.last?.endDate, capture)
        XCTAssertTrue(result.steps.allSatisfy { $0.endDate <= capture })
    }

    func testConnectedGlucoseMarkersUseLocalCentresWithoutFillingMissingWindows() {
        let width = 240
        let height = 400
        var bytes = [UInt8](repeating: 255, count: width * height * 4)
        for centerX in stride(from: 5, to: width, by: 10) where centerX < 85 || centerX > 155 {
            for y in 194...206 {
                for x in max(0, centerX - 6)...min(width - 1, centerX + 6)
                    where (x - centerX) * (x - centerX) + (y - 200) * (y - 200) <= 36 {
                    for channel in 0..<3 { bytes[(y * width + x) * 4 + channel] = 0 }
                }
            }
        }
        // A thin event-like stroke in the blank interval is not a marker.
        for y in 194...206 {
            for x in 120...121 {
                for channel in 0..<3 { bytes[(y * width + x) * 4 + channel] = 0 }
            }
        }
        let time = OCRAxisCalibration(kind: .time, source: .multipleOCRAnchors,
            slope: 120, intercept: 0, maximumResidual: 0, anchors: [])
        let glucose = OCRAxisCalibration(kind: .glucose, source: .numericAxisAnchors,
            slope: -20, intercept: 20, maximumResidual: 0, anchors: [])
        let result = OCRGlucoseExtractor.extract(
            image: OCRPixelImage(width: width, height: height, rgba: bytes),
            plotFrame: .init(x: 0, y: 0, width: 1, height: 1), excludedRects: [],
            timeline: .init(calibration: time, referenceX: 1, referenceDate: Date(timeIntervalSince1970: 10_000)),
            glucoseCalibration: glucose, visibleMinutes: 120
        )
        XCTAssertEqual(result.mode, "local-window-centers")
        XCTAssertEqual(result.samples.count, 16)
        XCTAssertTrue(result.samples.allSatisfy { abs(($0.mmolPerLiter ?? 0) - 10) < 0.05 })
        XCTAssertFalse(result.samples.contains { (0.4...0.6).contains($0.boundingBox.midX) })
    }

    func testPixelConversionPreservesTopAndBottomRows() throws {
        let bytes = Data([
            255, 0, 0, 255, 255, 0, 0, 255,
            0, 0, 255, 255, 0, 0, 255, 255,
        ])
        let provider = try XCTUnwrap(CGDataProvider(data: bytes as CFData))
        let image = try XCTUnwrap(CGImage(
            width: 2, height: 2, bitsPerComponent: 8, bitsPerPixel: 32,
            bytesPerRow: 8, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent
        ))
        let pixels = try XCTUnwrap(NativeAnalysisEngine.makePixelImage(from: image))
        XCTAssertEqual(pixels[0, 0].red, 255)
        XCTAssertEqual(pixels[0, 0].blue, 0)
        XCTAssertEqual(pixels[0, 1].red, 0)
        XCTAssertEqual(pixels[0, 1].blue, 255)
    }

    func testTimeLabelAlignmentRequiresLongNeutralGridline() {
        let width = 1_000
        let height = 400
        var pixels = [UInt8](repeating: 255, count: width * height * 4)
        for y in 50..<350 {
            for x in 302...305 {
                for channel in 0..<3 { pixels[(y * width + x) * 4 + channel] = 180 }
                // Yellow chart shading tints a neutral gridline.
                pixels[(y * width + x) * 4 + 2] = 140
            }
        }
        // A trace crossing one edge must not shift the raster centre.
        for y in 100..<120 {
            for channel in 0..<3 { pixels[(y * width + 302) * 4 + channel] = 0 }
        }
        let image = OCRPixelImage(width: width, height: height, rgba: pixels)
        let anchors: [OCRTimeAnchor] = [
            .init(x: 0.3, minuteOfDay: 120, observationID: nil),
            .init(x: 0.7, minuteOfDay: 240, observationID: nil),
        ]
        let aligned = OCRLayoutDetector.alignTimeAnchors(
            anchors, image: image,
            frame: .init(x: 0.1, y: 0.1, width: 0.8, height: 0.8)
        )
        XCTAssertEqual(aligned[0].x, 0.3035, accuracy: 1e-9)
        XCTAssertEqual(aligned[1].x, anchors[1].x)
        XCTAssertEqual(aligned.map(\.minuteOfDay), anchors.map(\.minuteOfDay))
    }

    func testTimeLabelAtFuturePanelUsesRasterInsteadOfBroadBackground() {
        let width = 1_000, height = 400
        var pixels = [UInt8](repeating: 255, count: width * height * 4)
        for y in 50..<350 {
            for x in 700..<900 {
                for channel in 0..<3 { pixels[(y * width + x) * 4 + channel] = 215 }
            }
            for x in 700...701 {
                for channel in 0..<3 { pixels[(y * width + x) * 4 + channel] = 150 }
            }
        }
        let anchors: [OCRTimeAnchor] = [
            .init(x: 0.699, minuteOfDay: 120, observationID: nil),
            .init(x: 0.895, minuteOfDay: 240, observationID: nil),
        ]
        let aligned = OCRLayoutDetector.alignTimeAnchors(anchors,
            image: .init(width: width, height: height, rgba: pixels),
            frame: .init(x: 0.1, y: 0.1, width: 0.8, height: 0.8))
        XCTAssertEqual(aligned[0].x, 0.7005, accuracy: 1e-9)
        XCTAssertEqual(aligned[1].x, anchors[1].x)
        XCTAssertEqual(aligned.map(\.minuteOfDay), anchors.map(\.minuteOfDay))
    }

    func testTargetedTimeAxisEvidenceTakesPriorityOverFullImageDuplicates() {
        let observations: [OCRRawTextObservation] = [
            .init(region: .fullImage, boundingBox: .init(x: 0.1, y: 0.8, width: 0.04, height: 0.02), candidates: [.init(text: "02:00", confidence: 0.9)]),
            .init(region: .timeAxis, boundingBox: .init(x: 0.2, y: 0.8, width: 0.04, height: 0.02), candidates: [.init(text: "02:00", confidence: 0.9)]),
            .init(region: .timeAxis, boundingBox: .init(x: 0.6, y: 0.8, width: 0.04, height: 0.02), candidates: [.init(text: "04:00", confidence: 0.9)]),
        ]
        let anchors = OCRObservationInterpreter.timeAnchors(from: observations, horizontalRange: 0...1)
        XCTAssertEqual(anchors.count, 2)
        XCTAssertEqual(anchors[0].x, 0.22, accuracy: 1e-9)
        XCTAssertEqual(anchors[1].x, 0.62, accuracy: 1e-9)
    }

    func testNearbyDuplicateClockLabelsDoNotCreateFalseDayRollover() throws {
        let calibration = try TimeAxisCalibrator.calibrate(
            anchors: [
                .init(x: 0.20, minuteOfDay: 120, observationID: nil),
                .init(x: 0.21, minuteOfDay: 120, observationID: nil),
                .init(x: 0.70, minuteOfDay: 240, observationID: nil),
                .init(x: 0.71, minuteOfDay: 240, observationID: nil),
            ],
            markerCentersX: [],
            plotRange: 0.1...0.9
        )
        XCTAssertEqual(calibration.anchors.count, 2)
        XCTAssertEqual(calibration.slope, 240, accuracy: 1e-9)
        XCTAssertLessThanOrEqual(calibration.maximumResidual, 1)
    }

    func testTimeParserAcceptsClockLabelsOnly() {
        XCTAssertEqual(OCRTextParser.minuteOfDay(from: "23:55"), 1_435)
        XCTAssertEqual(OCRTextParser.minuteOfDay(from: "0.05"), 5)
        XCTAssertNil(OCRTextParser.minuteOfDay(from: "24:00"))
        XCTAssertNil(OCRTextParser.minuteOfDay(from: "at 12:30 now"))
    }

    func testEventAmountParserDoesNotTruncateThreeDigitCarbs() {
        let parsed = OCRTextParser.amount(
            from: [OCRTextCandidate(text: "160 g", confidence: 0.98)],
            expectedKind: .carbohydrates
        )
        XCTAssertEqual(parsed.0, .known(160))
        XCTAssertEqual(parsed.1, .carbohydrates)

        let unsafe = OCRTextParser.amount(
            from: [OCRTextCandidate(text: "160", confidence: 0.99)],
            expectedKind: .carbohydrates
        )
        XCTAssertEqual(unsafe.0, .amountUnknown)
    }

    func testTimeCalibrationUnwrapsMidnight() throws {
        let calibration = try TimeAxisCalibrator.calibrate(
            anchors: [
                OCRTimeAnchor(x: 0.1, minuteOfDay: 23 * 60, observationID: nil),
                OCRTimeAnchor(x: 0.4, minuteOfDay: 0, observationID: nil),
                OCRTimeAnchor(x: 0.7, minuteOfDay: 60, observationID: nil),
            ],
            markerCentersX: [],
            plotRange: 0.1...0.7
        )
        XCTAssertEqual(calibration.source, .multipleOCRAnchors)
        XCTAssertEqual(calibration.slope, 200, accuracy: 1e-9)
        XCTAssertEqual(calibration.maximumResidual, 0, accuracy: 1e-9)
        XCTAssertEqual(calibration.value(at: 0.7) - calibration.value(at: 0.1), 120, accuracy: 1e-9)
    }

    func testSingleTimeAnchorUsesFiveMinuteMarkerSpacing() throws {
        let calibration = try TimeAxisCalibrator.calibrate(
            anchors: [OCRTimeAnchor(x: 0.4, minuteOfDay: 720, observationID: nil)],
            markerCentersX: [0.10, 0.11, 0.12, 0.13, 0.14, 0.16],
            plotRange: 0.1...0.7
        )
        XCTAssertEqual(calibration.source, .singleAnchorWithFiveMinuteSpacing)
        XCTAssertEqual(calibration.slope, 500, accuracy: 1e-9)
        XCTAssertEqual(calibration.value(at: 0.4), 720, accuracy: 1e-9)
    }

    func testSingleAnchorWithoutEnoughMarkersFailsClosed() {
        XCTAssertThrowsError(
            try TimeAxisCalibrator.calibrate(
                anchors: [OCRTimeAnchor(x: 0.4, minuteOfDay: 720, observationID: nil)],
                markerCentersX: [0.10, 0.11, 0.12],
                plotRange: 0.1...0.7
            )
        ) { error in
            guard case OCRAnalysisFailure.invalidTimeAxis = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
    }

    func testConnectedComponentsKeepSolidPathSeparateFromDashes() {
        var mask = OCRBinaryMask(width: 160, height: 30)
        for x in 5..<155 { mask[x, 20] = true }
        for x in stride(from: 10, to: 140, by: 15) {
            mask[x, 5] = true
            mask[x + 1, 5] = true
        }
        let components = OCRConnectedComponents.find(in: mask)
        let retained = components.filter {
            $0.pixelCount >= 100 || ($0.height >= 9 && $0.width >= 10)
        }
        XCTAssertEqual(retained.count, 1)
        XCTAssertEqual(retained[0].width, 150)
        XCTAssertEqual(components.count - retained.count, 9)
    }

    func testBasalGapReconstructionOnlyBridgesShortCompatibleGaps() {
        var path: [Double?] = [10, 10, nil, nil, 11, nil, nil, nil, 20]
        OCRBasalPathExtractor.reconstructShortGaps(in: &path, maximumGap: 2)
        XCTAssertNotNil(path[2])
        XCTAssertNotNil(path[3])
        XCTAssertNil(path[5])
        XCTAssertNil(path[6])
        XCTAssertNil(path[7])
    }

    func testBasalExtractorRemovesSmallBlueDashComponents() {
        let width = 200
        let height = 100
        var rgba = [UInt8](repeating: 255, count: width * height * 4)
        func setBlue(_ x: Int, _ y: Int) {
            let index = (y * width + x) * 4
            rgba[index] = 10
            rgba[index + 1] = 80
            rgba[index + 2] = 220
            rgba[index + 3] = 255
        }
        for x in 5..<195 { setBlue(x, 60) }
        for x in stride(from: 15, to: 180, by: 20) {
            setBlue(x, 20)
            setBlue(x + 1, 20)
        }
        let image = OCRPixelImage(width: width, height: height, rgba: rgba)
        let time = OCRAxisCalibration(
            kind: .time,
            source: .multipleOCRAnchors,
            slope: 120,
            intercept: 0,
            maximumResidual: 0,
            anchors: []
        )
        let timeline = OCRTimelineMapper(
            calibration: time,
            referenceX: 1,
            referenceDate: Date(timeIntervalSince1970: 10_000)
        )
        let rate = OCRAxisCalibration(
            kind: .basalRate,
            source: .numericAxisAnchors,
            slope: -10,
            intercept: 10,
            maximumResidual: 0,
            anchors: []
        )
        let result = OCRBasalPathExtractor.extract(
            image: image,
            plotFrame: OCRNormalizedRect(x: 0, y: 0, width: 1, height: 1),
            excludedRects: [],
            timeline: timeline,
            rateCalibration: rate
        )
        XCTAssertEqual(result.retainedComponentCount, 1)
        XCTAssertEqual(result.removedComponentCount, 9)
        XCTAssertEqual(result.pathCoverage, 0.95, accuracy: 1e-9)
        XCTAssertFalse(result.steps.isEmpty)
        XCTAssertTrue(result.steps.allSatisfy { $0.rateUnitsPerHour != nil })
    }

    func testDomainAdapterPreservesUnknownAmountsAndBlockers() throws {
        let capture = Date(timeIntervalSince1970: 50_000)
        let time = OCRAxisCalibration(
            kind: .time,
            source: .multipleOCRAnchors,
            slope: 600,
            intercept: 0,
            maximumResidual: 0,
            anchors: []
        )
        let event = OCRTherapyEvent(
            kind: .bolus,
            date: capture.addingTimeInterval(-600),
            amount: .amountUnknown,
            stemBoundingBox: OCRNormalizedRect(x: 0.8, y: 0.2, width: 0.002, height: 0.1),
            pillBoundingBox: OCRNormalizedRect(x: 0.77, y: 0.1, width: 0.06, height: 0.05),
            isCompleteStem: true,
            candidates: [OCRTextCandidate(text: "?", confidence: 0.5)],
            confidence: 0.6,
            provenance: OCRProvenance(kind: .pixelGeometry)
        )
        let result = OCRAnalysisResult(
            requestID: UUID(),
            algorithmVersion: "test",
            visionRevision: 3,
            capturedAt: capture,
            timeAxisReferenceDate: capture.addingTimeInterval(-75),
            status: .needsReview,
            layout: OCRDetectedLayout(
                profile: .camAPSFXLandscapeV1,
                plotFrame: OCRNormalizedRect(x: 0.05, y: 0.1, width: 0.9, height: 0.75),
                dataRightEdgeX: 0.95,
                estimatedVisibleHours: 9,
                confidence: 0.9
            ),
            timeCalibration: time,
            basalCalibration: nil,
            glucoseCalibration: nil,
            rawTextObservations: [],
            basalSteps: [],
            glucoseSamples: [],
            therapyEvents: [event],
            quality: OCRAnalysisQuality(
                layoutConfidence: 0.9,
                timeMaximumResidualMinutes: 0,
                basalPathCoverage: 0,
                glucoseSampleCount: 0,
                completeEventStemCount: 1,
                unknownEventAmountCount: 1,
                criticalDataComplete: false,
                timeAxisClockIsValid: false
            ),
            warnings: [],
            diagnostics: OCRDiagnosticMetadata(
                imageWidth: 1_000,
                imageHeight: 500,
                removedDashedBlueComponentCount: 0,
                retainedBasalComponentCount: 0,
                glucoseExtractionMode: "local-centers"
            )
        )
        let run = result.makeAnalysisRun(caseID: UUID())
        XCTAssertEqual(run.observations.count, 1)
        XCTAssertEqual(run.observations[0].amountState, .amountUnknown)
        XCTAssertNil(run.observations[0].amount)
        XCTAssertTrue(run.quality.blockers.contains(.unknownInsulinAmount))
        XCTAssertTrue(run.quality.blockers.contains(.invalidBasalAxis))
        XCTAssertTrue(run.quality.blockers.contains(.incompleteBasalPath))
        XCTAssertTrue(run.quality.blockers.contains(.invalidTimeAxis))
        let effective = try DefaultEffectiveDataReducer().reduce(analysisRun: run, revisions: [])
        let settings = try TherapySettings(diaMinutes: 360, insulinType: .fiasp, carbAbsorptionMinutes: 240)
        let current = DefaultActivityCalculator().snapshot(data: effective,
            settings: settings,
            date: capture)
        XCTAssertEqual(current.basalIOB, .unavailable(.invalidTimeAxis))
        XCTAssertEqual(current.bolusIOB, .unavailable(.invalidTimeAxis))
        XCTAssertEqual(current.totalIOB, .unavailable(.invalidTimeAxis))
        XCTAssertEqual(current.cob, .unavailable(.invalidTimeAxis))
        XCTAssertEqual(run.calibration.timeEnd, capture.addingTimeInterval(-75))
        let encoded = try JSONEncoder().encode(result)
        XCTAssertEqual(try JSONDecoder().decode(OCRAnalysisResult.self, from: encoded), result)
        var legacy = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        legacy.removeValue(forKey: "timeAxisReferenceDate")
        var legacyQuality = try XCTUnwrap(legacy["quality"] as? [String: Any])
        legacyQuality.removeValue(forKey: "timeAxisClockIsValid")
        legacy["quality"] = legacyQuality
        let decoded = try JSONDecoder().decode(OCRAnalysisResult.self,
            from: JSONSerialization.data(withJSONObject: legacy))
        XCTAssertNil(decoded.timeAxisReferenceDate)
        XCTAssertNil(decoded.quality.timeAxisClockIsValid)
        XCTAssertEqual(decoded.capturedAt, capture)
        XCTAssertEqual(decoded.makeAnalysisRun(caseID: UUID()).calibration.timeEnd, capture)
        XCTAssertFalse(decoded.makeAnalysisRun(caseID: UUID()).quality.blockers.contains(.invalidTimeAxis))
    }
}
