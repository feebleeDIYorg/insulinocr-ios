import Foundation
import XCTest
@testable import InsulinOCRCore

final class ClockAlignedTimelineTests: XCTestCase {
    func testClockLabelsAreNotShiftedToTheCaptureSecond() throws {
        let capture = try date("2026-01-02T12:01:15+01:00")
        let mapper = try makeMapper(slope: 720, intercept: 0, capture: capture)
        XCTAssertEqual(mapper.referenceDate, try date("2026-01-02T12:00:00+01:00"))
        XCTAssertEqual(mapper.date(atX: 0.5), try date("2026-01-02T06:00:00+01:00"))
        XCTAssertEqual(capture.timeIntervalSince(mapper.referenceDate), 75, accuracy: 1e-6)
    }

    func testMidnightUsesThePreviousCalendarDayOnTheLeft() throws {
        let mapper = try makeMapper(slope: 60, intercept: 1_380,
            capture: date("2026-01-02T00:00:30+01:00"))
        XCTAssertEqual(mapper.referenceDate, try date("2026-01-02T00:00:00+01:00"))
        XCTAssertEqual(mapper.date(atX: 0), try date("2026-01-01T23:00:00+01:00"))
    }

    func testFortyEightHourWindowPreservesBothCalendarDays() throws {
        let mapper = try makeMapper(slope: 2_880, intercept: 1_380,
            capture: date("2026-01-03T23:00:20+01:00"))
        XCTAssertEqual(mapper.referenceDate, try date("2026-01-03T23:00:00+01:00"))
        XCTAssertEqual(mapper.date(atX: 0), try date("2026-01-01T23:00:00+01:00"))
    }

    func testSmallFutureRoundingCanCrossTheYearBoundary() throws {
        let mapper = try makeMapper(slope: 60, intercept: -60,
            capture: date("2026-12-31T23:59:45+01:00"))
        XCTAssertEqual(mapper.referenceDate, try date("2027-01-01T00:00:00+01:00"))
        XCTAssertThrowsError(try makeMapper(slope: 60, intercept: -60,
            capture: date("2026-12-31T23:58:00+01:00")))
    }

    func testSpringAndAutumnOffsetTransitionsAreExplicitlyRejected() throws {
        for (capture, edge) in [("2026-03-29T03:30:00+02:00", 210.0),
                                ("2026-10-25T02:30:00+01:00", 150.0)] {
            XCTAssertThrowsError(try makeMapper(slope: 360, intercept: edge - 360,
                capture: date(capture)))
        }
    }

    func testInvalidCalibrationFailsClosed() throws {
        let capture = try date("2026-01-02T12:00:00+01:00")
        for slope in [Double.nan, .infinity, 0, -720] {
            XCTAssertThrowsError(try makeMapper(slope: slope, intercept: 0, capture: capture))
        }
    }

    private func makeMapper(slope: Double, intercept: Double, capture: Date) throws -> OCRTimelineMapper {
        try .clockAligned(calibration: .init(kind: .time, source: .multipleOCRAnchors,
            slope: slope, intercept: intercept, maximumResidual: 0, anchors: []),
            plotStartX: 0, referenceX: 1, capturedAt: capture,
            timeZone: XCTUnwrap(TimeZone(identifier: "Europe/Zurich")))
    }

    private func date(_ value: String) throws -> Date {
        try XCTUnwrap(ISO8601DateFormatter().date(from: value))
    }
}
