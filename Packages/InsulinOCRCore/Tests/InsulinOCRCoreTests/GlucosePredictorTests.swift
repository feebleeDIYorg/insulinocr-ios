import XCTest
@testable import InsulinOCRCore

final class GlucosePredictorTests: XCTestCase {
    private let reference = Date(timeIntervalSince1970: 1_800_000_000)

    private func after(_ minutes: Double) -> Date { reference.addingTimeInterval(minutes * 60) }

    private func input(
        boluses: [InsulinEvent] = [],
        carbohydrates: [CarbohydrateEvent] = [],
        basal: [BasalSegment] = [],
        glucose: [(minutes: Double, mmol: Double)] = [(0, 6)],
        profileBasal: Double = 0,
        adjustments: [InsulinNeedAdjustment] = []
    ) throws -> GlucosePredictionInput {
        GlucosePredictionInput(
            data: EffectiveTherapyData(
                basalSegments: basal, boluses: boluses, carbohydrates: carbohydrates,
                glucoseSamples: glucose.map {
                    GlucoseSample(date: after($0.minutes), value: $0.mmol, unit: .millimolesPerLiter)
                }),
            therapy: try TherapySettings(diaMinutes: 360, insulinType: .fiasp, carbAbsorptionMinutes: 240),
            prediction: try GlucosePredictionSettings(
                sensitivity: try DailyProfile(constant: 2), carbRatio: try DailyProfile(constant: 10),
                profileBasalUnitsPerHour: profileBasal, timeZoneIdentifier: "UTC"),
            adjustments: adjustments,
            referenceDate: reference)
    }

    private func loop(_ input: GlucosePredictionInput) throws -> GlucosePrediction {
        try XCTUnwrap(GlucosePredictor.predict(input, model: .loop))
    }

    func testDailyProfileResolvesBlocksInTheCaseTimeZone() throws {
        let profile = try DailyProfile(blocks: [
            .init(startMinute: 0, value: 2), .init(startMinute: 360, value: 3), .init(startMinute: 1_320, value: 1.5),
        ])
        XCTAssertEqual(profile.value(atMinuteOfDay: 0), 2)
        XCTAssertEqual(profile.value(atMinuteOfDay: 359), 2)
        XCTAssertEqual(profile.value(atMinuteOfDay: 360), 3)
        XCTAssertEqual(profile.value(atMinuteOfDay: 1_439), 1.5)
        // 05:30 UTC is 06:30 in Zurich in winter and 05:30 in UTC.
        let date = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-01-02T05:30:00Z"))
        XCTAssertEqual(profile.value(at: date, timeZone: try XCTUnwrap(TimeZone(identifier: "Europe/Zurich"))), 3)
        XCTAssertEqual(profile.value(at: date, timeZone: try XCTUnwrap(TimeZone(identifier: "UTC"))), 2)
        XCTAssertEqual(try JSONDecoder().decode(DailyProfile.self, from: JSONEncoder().encode(profile)), profile)

        let invalid: [[DailyProfile.Block]] = [
            [], [.init(startMinute: 60, value: 2)],
            [.init(startMinute: 0, value: 2), .init(startMinute: 0, value: 3)],
            [.init(startMinute: 0, value: 0)], [.init(startMinute: 0, value: 2), .init(startMinute: 1_440, value: 3)],
        ]
        for blocks in invalid {
            XCTAssertThrowsError(try DailyProfile(blocks: blocks))
        }
        XCTAssertThrowsError(try JSONDecoder().decode(DailyProfile.self,
            from: Data(#"{"blocks":[{"startMinute":30,"value":2}]}"#.utf8)))
    }

    func testInsulinAndCarbohydratesMoveGlucoseBySensitivityAndRatio() throws {
        // 1 U at 2 mmol/L per unit lowers glucose by 2 once fully absorbed.
        let bolus = try loop(try input(boluses: [.init(date: reference, units: 1)]))
        XCTAssertEqual(bolus.points.first?.glucoseMmolPerLiter, 6)
        XCTAssertEqual(try XCTUnwrap(bolus.points.first).insulinOnBoard, 1, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(bolus.points.last).glucoseMmolPerLiter, 4, accuracy: 1e-6)
        XCTAssertEqual(try XCTUnwrap(bolus.points.last).insulinOnBoard, 0, accuracy: 1e-9)
        XCTAssertEqual(bolus.points.count, 73)
        XCTAssertEqual(bolus.points.last?.date, after(360))
        XCTAssertFalse(bolus.usedGlucoseTrend)
        for (earlier, later) in zip(bolus.points, bolus.points.dropFirst()) {
            XCTAssertLessThanOrEqual(later.glucoseMmolPerLiter, earlier.glucoseMmolPerLiter + 1e-12)
        }
        // 20 g at 10 g per unit count like 2 U upward: +4.
        let meal = try loop(try input(carbohydrates: [.init(date: reference, grams: 20)]))
        XCTAssertEqual(try XCTUnwrap(meal.points.first).carbohydratesOnBoard, 20, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(meal.points.last).glucoseMmolPerLiter, 10, accuracy: 1e-6)
        // Both together cancel in the end.
        let both = try loop(try input(boluses: [.init(date: reference, units: 2)],
                                      carbohydrates: [.init(date: reference, grams: 20)]))
        XCTAssertEqual(try XCTUnwrap(both.points.last).glucoseMmolPerLiter, 6, accuracy: 1e-6)
    }

    func testFutureEventsActFromTheirOwnTime() throws {
        let prediction = try loop(try input(boluses: [.init(date: after(30), units: 1)]))
        for point in prediction.points where point.date <= after(30) {
            XCTAssertEqual(point.glucoseMmolPerLiter, 6, accuracy: 1e-12)
            XCTAssertEqual(point.insulinOnBoard, point.date == after(30) ? 1 : 0, accuracy: 1e-9)
        }
        XCTAssertEqual(prediction.points.last?.date, after(390))
        XCTAssertEqual(try XCTUnwrap(prediction.points.last).glucoseMmolPerLiter, 4, accuracy: 1e-6)
    }

    func testBasalCountsRelativeToTheProfileRate() throws {
        let delivered = [BasalSegment(startDate: after(-360), endDate: reference, unitsPerHour: 1)]
        // Delivery equal to the profile is neutral.
        let neutral = try loop(try input(basal: delivered, profileBasal: 1))
        for point in neutral.points {
            XCTAssertEqual(point.glucoseMmolPerLiter, 6, accuracy: 1e-9)
        }
        // An empty basal field means profile 0: all delivered basal lowers
        // glucose by sensitivity times the basal insulin still on board.
        let basalOnBoard = DefaultActivityCalculator().basalIOB(
            segments: delivered, at: reference, durationMinutes: 360, peakMinutes: InsulinType.fiasp.peakMinutes)
        XCTAssertGreaterThan(basalOnBoard, 0.5)
        let zeroProfile = try loop(try input(basal: delivered, profileBasal: 0))
        XCTAssertEqual(try XCTUnwrap(zeroProfile.points.first).insulinOnBoard, basalOnBoard, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(zeroProfile.points.last).glucoseMmolPerLiter,
                       6 - 2 * basalOnBoard, accuracy: 1e-6)
        // Delivery below the profile raises glucose by the same amount.
        let below = try loop(try input(basal: delivered, profileBasal: 2))
        XCTAssertEqual(try XCTUnwrap(below.points.last).glucoseMmolPerLiter,
                       6 + 2 * basalOnBoard, accuracy: 1e-6)
    }

    func testInsulinNeedAdjustmentScalesInsulinEffectButNotCarbohydrates() throws {
        let half = try InsulinNeedAdjustment(startDate: after(-60), durationMinutes: 1_440, percent: 50)
        // Half the insulin need: every unit acts twice as strongly.
        let bolus = try loop(try input(boluses: [.init(date: reference, units: 1)], adjustments: [half]))
        XCTAssertEqual(try XCTUnwrap(bolus.points.last).glucoseMmolPerLiter, 2, accuracy: 1e-6)
        // Sensitivity and carb ratio scale together, so the meal effect stays.
        let meal = try loop(try input(carbohydrates: [.init(date: reference, grams: 20)], adjustments: [half]))
        XCTAssertEqual(try XCTUnwrap(meal.points.last).glucoseMmolPerLiter, 10, accuracy: 1e-6)
        // The basal reference scales too: 1 U/h delivered equals 200 % of a 0.5 U/h profile.
        let delivered = [BasalSegment(startDate: after(-360), endDate: reference, unitsPerHour: 1)]
        let double = try InsulinNeedAdjustment(startDate: after(-400), durationMinutes: 1_440, percent: 200)
        let neutral = try loop(try input(basal: delivered, profileBasal: 0.5, adjustments: [double]))
        XCTAssertEqual(try XCTUnwrap(neutral.points.last).glucoseMmolPerLiter, 6, accuracy: 1e-9)

        XCTAssertTrue(half.isActive(at: reference))
        XCTAssertFalse(half.isActive(at: after(1_380)))
        for (duration, percent) in [(0.0, 100.0), (60, 5), (60, 301), (3_000, 100), (Double.nan, 100)] {
            XCTAssertThrowsError(try InsulinNeedAdjustment(
                startDate: reference, durationMinutes: duration, percent: percent))
        }
    }

    func testLoopMomentumHandsOverToTheModelWithinTwentyMinutes() throws {
        // Rising 0.1 mmol/L per minute, nothing on board.
        let rising = try loop(try input(glucose: [(-10, 5), (-5, 5.5), (0, 6)]))
        XCTAssertTrue(rising.usedGlucoseTrend)
        // Weights 0.875, 0.625, 0.375, 0.125 on 0.5 per step: +1 in total.
        XCTAssertEqual(rising.points[1].glucoseMmolPerLiter, 6.4375, accuracy: 1e-9)
        XCTAssertEqual(rising.points[4].glucoseMmolPerLiter, 7, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(rising.points.last).glucoseMmolPerLiter, 7, accuracy: 1e-9)
        // Two samples are no trend.
        XCTAssertFalse(try loop(try input(glucose: [(-5, 5.5), (0, 6)])).usedGlucoseTrend)
    }

    func testOrefCurvesCarryTheDeviationForAnHour() throws {
        let rising = try input(glucose: [(-10, 5), (-5, 5.5), (0, 6)], profileBasal: 1)
        let prediction = try XCTUnwrap(GlucosePredictor.predict(rising, model: .oref))
        let curves = try XCTUnwrap(prediction.orefCurves)
        // Deviation 0.5 per step, fading linearly to zero at one hour: +2.75.
        XCTAssertEqual(curves.insulinOnly[12], 8.75, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(curves.insulinOnly.last), 8.75, accuracy: 1e-9)
        XCTAssertNil(curves.withCarbohydrates)
        XCTAssertEqual(prediction.points.map(\.glucoseMmolPerLiter), curves.insulinOnly)
        // Without basal from now on glucose rises steadily; the trend is not carried.
        XCTAssertEqual(curves.zeroTemp[0], 6)
        XCTAssertGreaterThan(curves.zeroTemp[12], 6)
        XCTAssertGreaterThan(try XCTUnwrap(curves.zeroTemp.last), curves.zeroTemp[12])
        XCTAssertEqual(curves.zeroTemp.count, prediction.points.count)

        // With a meal the carbohydrate curve leads and ignores a positive deviation.
        let meal = try input(carbohydrates: [.init(date: reference, grams: 20)],
                             glucose: [(-10, 5), (-5, 5.5), (0, 6)])
        let withMeal = try XCTUnwrap(GlucosePredictor.predict(meal, model: .oref))
        let mealCurves = try XCTUnwrap(withMeal.orefCurves)
        XCTAssertEqual(try XCTUnwrap(mealCurves.withCarbohydrates?.last), 10, accuracy: 1e-6)
        XCTAssertEqual(withMeal.points.map(\.glucoseMmolPerLiter), try XCTUnwrap(mealCurves.withCarbohydrates))
        // Profile basal 0: the zero-temp curve has nothing to withhold.
        XCTAssertEqual(try XCTUnwrap(mealCurves.zeroTemp.last), 6, accuracy: 1e-9)
    }

    func testNoRecentGlucoseMeansNoPrediction() throws {
        XCTAssertNil(GlucosePredictor.predict(try input(glucose: []), model: .loop))
        XCTAssertNil(GlucosePredictor.predict(try input(glucose: [(-30, 6)]), model: .oref))
        XCTAssertNotNil(GlucosePredictor.predict(try input(glucose: [(-12, 6)]), model: .loop))
        XCTAssertThrowsError(try GlucosePredictionSettings(
            sensitivity: try DailyProfile(constant: 2), carbRatio: try DailyProfile(constant: 10),
            profileBasalUnitsPerHour: -0.1, timeZoneIdentifier: "UTC"))
        XCTAssertThrowsError(try GlucosePredictionSettings(
            sensitivity: try DailyProfile(constant: 2), carbRatio: try DailyProfile(constant: 10),
            profileBasalUnitsPerHour: 1, timeZoneIdentifier: "Nowhere/None"))
    }
}
