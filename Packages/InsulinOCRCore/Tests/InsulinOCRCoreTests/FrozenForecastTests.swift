import Foundation
import XCTest
@testable import InsulinOCRCore

final class FrozenForecastTests: XCTestCase {
    private let reference = Date(timeIntervalSince1970: 1_730_000_000)

    func testFutureEventsDoNotBecomeAdditionalForecastTreatments() throws {
        let historical = data(end: reference)
        let withFuture = EffectiveTherapyData(
            basalSegments: historical.basalSegments + [BasalSegment(
                startDate: reference, endDate: reference.addingTimeInterval(3600), unitsPerHour: 7)],
            boluses: historical.boluses + [InsulinEvent(date: reference.addingTimeInterval(60), units: 5)],
            carbohydrates: historical.carbohydrates + [CarbohydrateEvent(date: reference.addingTimeInterval(60), grams: 20)],
            glucoseSamples: [], observedHistoryMinutes: 360)
        let calculator = DefaultActivityCalculator()
        let settings = try TherapySettings(diaMinutes: 360, insulinType: .fiasp, carbAbsorptionMinutes: 240)
        let baseline = calculator.calculate(data: historical, settings: settings, referenceDate: reference)
        let candidate = calculator.calculate(data: withFuture, settings: settings, referenceDate: reference)
        XCTAssertEqual(candidate.current, baseline.current)
        XCTAssertEqual(candidate.forecast, baseline.forecast)
        XCTAssertEqual(try XCTUnwrap(baseline.current.bolusIOB.value), 1, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(baseline.current.cob.value), 15, accuracy: 1e-9)
    }

    func testBasalSpanningCaptureStopsDeliveringAtFrozenReference() throws {
        let calculator = DefaultActivityCalculator()
        let settings = try TherapySettings(diaMinutes: 360, insulinType: .fiasp, carbAbsorptionMinutes: 240)
        let baseline = calculator.calculate(data: data(end: reference), settings: settings, referenceDate: reference)
        let candidate = calculator.calculate(data: data(end: reference.addingTimeInterval(3600)),
                                             settings: settings, referenceDate: reference)
        XCTAssertEqual(candidate.current, baseline.current)
        XCTAssertEqual(candidate.forecast, baseline.forecast)
        XCTAssertEqual(try XCTUnwrap(candidate.forecast.last?.totalIOB.value), 0, accuracy: 1e-9)
    }

    private func data(end: Date) -> EffectiveTherapyData {
        EffectiveTherapyData(basalSegments: [BasalSegment(
            startDate: reference.addingTimeInterval(-21600), endDate: end, unitsPerHour: 1)],
            boluses: [InsulinEvent(date: reference, units: 1)],
            carbohydrates: [CarbohydrateEvent(date: reference, grams: 15)],
            glucoseSamples: [], observedHistoryMinutes: 360)
    }
}
