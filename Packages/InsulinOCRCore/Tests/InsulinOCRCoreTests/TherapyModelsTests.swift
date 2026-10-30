import Foundation
import XCTest
@testable import InsulinOCRCore

final class TherapyModelsTests: XCTestCase {
    func testMissingObservedBasalIntervalsCannotBeAssumedZero() throws {
        let reference = Date(timeIntervalSince1970: 1_800_000_000)
        let start = reference.addingTimeInterval(-21_600)
        let middle = reference.addingTimeInterval(-10_800)
        let settings = try TherapySettings(diaMinutes: 360, insulinType: .fiasp,
            carbAbsorptionMinutes: 240)
        let cases: [[BasalSegment]] = [
            [],
            [.init(startDate: start, endDate: reference.addingTimeInterval(-1), unitsPerHour: 0.8)],
            [.init(startDate: start, endDate: middle.addingTimeInterval(-60), unitsPerHour: 0.8),
             .init(startDate: middle, endDate: reference, unitsPerHour: 0.8)],
        ]
        for segments in cases {
            let data = EffectiveTherapyData(basalSegments: segments, boluses: [],
                carbohydrates: [], glucoseSamples: [], sourceAnalysisRunID: UUID(),
                observedHistoryMinutes: 720)
            let result = DefaultActivityCalculator().calculate(data: data,
                settings: settings, referenceDate: reference)
            XCTAssertEqual(result.current.basalIOB, .unavailable(.incompleteBasalPath))
            XCTAssertEqual(result.current.totalIOB, .unavailable(.incompleteBasalPath))
            XCTAssertTrue(result.forecast.allSatisfy { $0.totalIOB.value == nil })
            XCTAssertEqual(result.current.bolusIOB, .available(0))
            XCTAssertEqual(result.current.cob, .available(0))
        }
    }

    func testOverlappingObservedBasalIntervalsAreNotCountedTwice() throws {
        let reference = Date(timeIntervalSince1970: 1_800_000_000)
        let middle = reference.addingTimeInterval(-10_800)
        let data = EffectiveTherapyData(basalSegments: [
            .init(startDate: middle, endDate: reference, unitsPerHour: 0.9),
            .init(startDate: reference.addingTimeInterval(-21_600),
                  endDate: middle.addingTimeInterval(30), unitsPerHour: 0.8),
        ], boluses: [], carbohydrates: [], glucoseSamples: [],
            sourceAnalysisRunID: UUID(), observedHistoryMinutes: 720)
        let settings = try TherapySettings(diaMinutes: 360, insulinType: .fiasp,
            carbAbsorptionMinutes: 240)
        XCTAssertEqual(DefaultActivityCalculator().snapshot(data: data,
            settings: settings, date: reference).totalIOB,
            .unavailable(.incompleteBasalPath))
    }

    func testForecastDecaysObservedBasalWithoutRequiringFutureDelivery() throws {
        let reference = Date(timeIntervalSince1970: 1_800_000_000)
        let middle = reference.addingTimeInterval(-10_800)
        let data = EffectiveTherapyData(basalSegments: [
            .init(startDate: reference.addingTimeInterval(-21_600),
                  endDate: middle, unitsPerHour: 0),
            .init(startDate: middle, endDate: reference, unitsPerHour: 0.8),
        ], boluses: [], carbohydrates: [], glucoseSamples: [],
            sourceAnalysisRunID: UUID(), observedHistoryMinutes: 720)
        let settings = try TherapySettings(diaMinutes: 360, insulinType: .fiasp,
            carbAbsorptionMinutes: 240)
        let result = DefaultActivityCalculator().calculate(data: data,
            settings: settings, referenceDate: reference)
        XCTAssertNotNil(result.current.totalIOB.value)
        XCTAssertTrue(result.forecast.allSatisfy { $0.totalIOB.value != nil })
        XCTAssertEqual(try XCTUnwrap(result.forecast.last?.totalIOB.value), 0, accuracy: 1e-9)
    }

    func testScreenshotHistoryMustCoverBothActionWindowsIncludingCarbDelay() throws {
        let settings = try TherapySettings(diaMinutes: 180, insulinType: .fiasp, carbAbsorptionMinutes: 240)
        let calculator = DefaultActivityCalculator()
        for minutes in [nil, 60.0, 249.999] as [Double?] {
            let data = EffectiveTherapyData(basalSegments: [], boluses: [], carbohydrates: [],
                glucoseSamples: [], sourceAnalysisRunID: UUID(), observedHistoryMinutes: minutes)
            let result = calculator.calculate(data: data, settings: settings, referenceDate: Date())
            XCTAssertEqual(result.current.totalIOB, .unavailable(.insufficientHistory))
            XCTAssertEqual(result.current.cob, .unavailable(.insufficientHistory))
            XCTAssertTrue(result.forecast.allSatisfy { $0.totalIOB.value == nil && $0.cob.value == nil })
            let simulated = SimulationCalculator.applying(events: [], to: data)
            XCTAssertEqual(simulated.observedHistoryMinutes, minutes)
        }
        let reference = Date(timeIntervalSince1970: 1_800_000_000)
        let enough = EffectiveTherapyData(basalSegments: [
            .init(startDate: reference.addingTimeInterval(-15_000),
                  endDate: reference, unitsPerHour: 0),
        ], boluses: [], carbohydrates: [],
            glucoseSamples: [], sourceAnalysisRunID: UUID(), observedHistoryMinutes: 250)
        XCTAssertEqual(calculator.snapshot(data: enough, settings: settings, date: reference).totalIOB, .available(0))
    }

    func testTherapySettingsEnforceSupportedSteps() throws {
        XCTAssertNoThrow(
            try TherapySettings(
                diaMinutes: 180,
                insulinType: .fiasp,
                carbAbsorptionMinutes: 240
            )
        )
        XCTAssertNoThrow(
            try TherapySettings(
                diaMinutes: 600,
                insulinType: .novoRapid,
                carbAbsorptionMinutes: 480
            )
        )
        XCTAssertThrowsError(
            try TherapySettings(
                diaMinutes: 200,
                insulinType: .fiasp,
                carbAbsorptionMinutes: 240
            )
        ) { error in
            XCTAssertEqual(error as? TherapySettingsError, .invalidDIAMinutes)
        }
        XCTAssertThrowsError(
            try TherapySettings(
                diaMinutes: 300,
                insulinType: .fiasp,
                carbAbsorptionMinutes: 245
            )
        ) { error in
            XCTAssertEqual(error as? TherapySettingsError, .invalidCarbAbsorptionMinutes)
        }
    }

    func testExponentialInsulinGoldenValuesAndBoundaries() {
        XCTAssertEqual(
            InsulinActivityModel.remainingUnits(
                units: 1,
                minutes: 0,
                durationMinutes: 300,
                peakMinutes: 75
            ),
            1,
            accuracy: 1e-12
        )
        XCTAssertEqual(
            InsulinActivityModel.remainingUnits(
                units: 1,
                minutes: 75,
                durationMinutes: 300,
                peakMinutes: 75
            ),
            0.672_639_890_458_107_3,
            accuracy: 1e-12
        )
        XCTAssertEqual(
            InsulinActivityModel.remainingUnits(
                units: 1,
                minutes: 150,
                durationMinutes: 300,
                peakMinutes: 75
            ),
            0.268_112_683_763_096_16,
            accuracy: 1e-12
        )
        XCTAssertEqual(
            InsulinActivityModel.remainingUnits(
                units: 1,
                minutes: 300,
                durationMinutes: 300,
                peakMinutes: 75
            ),
            0,
            accuracy: 1e-12
        )
        XCTAssertEqual(
            InsulinActivityModel.remainingUnits(
                units: 1,
                minutes: -1,
                durationMinutes: 300,
                peakMinutes: 75
            ),
            0,
            accuracy: 1e-12
        )
    }

    func testCarbohydrateGoldenValuesAtPiecewiseBoundaries() {
        XCTAssertEqual(remainingCarbs(at: 0), 60, accuracy: 1e-12)
        XCTAssertEqual(remainingCarbs(at: 10), 60, accuracy: 1e-12)
        XCTAssertEqual(remainingCarbs(at: 46), 53.333_333_333_333_33, accuracy: 1e-9)
        XCTAssertEqual(remainingCarbs(at: 130), 22.222_222_222_222_23, accuracy: 1e-9)
        XCTAssertEqual(remainingCarbs(at: 250), 0, accuracy: 1e-12)
    }

    func testBasalMinuteFoldingMatchesTenSecondReference() throws {
        let referenceDate = Date(timeIntervalSince1970: 1_800_000_000)
        let segments = [
            BasalSegment(
                startDate: referenceDate.addingTimeInterval(-4.5 * 3_600 + 17),
                endDate: referenceDate.addingTimeInterval(-2.1 * 3_600 + 37),
                unitsPerHour: 0.85
            ),
            BasalSegment(
                startDate: referenceDate.addingTimeInterval(-2.1 * 3_600 + 37),
                endDate: referenceDate.addingTimeInterval(-27),
                unitsPerHour: 1.45
            ),
        ]
        let calculator = DefaultActivityCalculator()
        let minuteFold = calculator.basalIOB(
            segments: segments,
            at: referenceDate,
            durationMinutes: 300,
            peakMinutes: 55,
            integrationStepSeconds: 60
        )
        let tenSecondReference = calculator.basalIOB(
            segments: segments,
            at: referenceDate,
            durationMinutes: 300,
            peakMinutes: 55,
            integrationStepSeconds: 10
        )
        XCTAssertLessThanOrEqual(abs(minuteFold - tenSecondReference), 0.005)
    }

    func testBolusBasalAndTotalRemainSeparate() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let data = EffectiveTherapyData(
            basalSegments: [
                BasalSegment(
                    startDate: now.addingTimeInterval(-3_600),
                    endDate: now,
                    unitsPerHour: 1
                ),
            ],
            boluses: [InsulinEvent(date: now.addingTimeInterval(-30 * 60), units: 2)],
            carbohydrates: [CarbohydrateEvent(date: now.addingTimeInterval(-30 * 60), grams: 40)],
            glucoseSamples: []
        )
        let settings = try TherapySettings(
            diaMinutes: 300,
            insulinType: .fiasp,
            carbAbsorptionMinutes: 240
        )
        let result = DefaultActivityCalculator().calculate(
            data: data,
            settings: settings,
            referenceDate: now,
            forecastStepMinutes: 5
        )
        let basal = try XCTUnwrap(result.current.basalIOB.value)
        let bolus = try XCTUnwrap(result.current.bolusIOB.value)
        let total = try XCTUnwrap(result.current.totalIOB.value)
        XCTAssertGreaterThan(basal, 0)
        XCTAssertGreaterThan(bolus, 0)
        XCTAssertEqual(total, basal + bolus, accuracy: 1e-12)
        XCTAssertEqual(result.forecast.last?.totalIOB.value ?? -1, 0, accuracy: 1e-9)
        XCTAssertEqual(result.forecast.last?.cob.value ?? -1, 0, accuracy: 1e-9)
    }

    func testCriticalUnknownValuesFailClosedWithoutSuppressingIndependentMetrics() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let data = EffectiveTherapyData(
            basalSegments: [
                BasalSegment(
                    startDate: now.addingTimeInterval(-3_600),
                    endDate: now,
                    unitsPerHour: 1
                ),
            ],
            boluses: [],
            carbohydrates: [],
            glucoseSamples: [],
            unresolvedIssues: [.unknownBolusAmount, .unknownCarbohydrateAmount]
        )
        let settings = try TherapySettings(
            diaMinutes: 300,
            insulinType: .fiasp,
            carbAbsorptionMinutes: 240
        )
        let snapshot = DefaultActivityCalculator().snapshot(
            data: data,
            settings: settings,
            date: now
        )
        XCTAssertNotNil(snapshot.basalIOB.value)
        XCTAssertNil(snapshot.bolusIOB.value)
        XCTAssertNil(snapshot.totalIOB.value)
        XCTAssertNil(snapshot.cob.value)
        XCTAssertEqual(snapshot.bolusIOB, .unavailable(.unknownBolusAmount))
        XCTAssertEqual(snapshot.cob, .unavailable(.unknownCarbohydrateAmount))
    }

    func testSimulationEventsAreAppliedWithoutMutatingBasis() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let basis = EffectiveTherapyData(
            basalSegments: [],
            boluses: [],
            carbohydrates: [],
            glucoseSamples: []
        )
        let events: [SimulationEvent] = [
            .bolus(InsulinEvent(date: now, units: 1.5)),
            .carbohydrate(CarbohydrateEvent(date: now, grams: 20)),
        ]
        let scenario = SimulationCalculator.applying(events: events, to: basis)
        XCTAssertTrue(basis.boluses.isEmpty)
        XCTAssertTrue(basis.carbohydrates.isEmpty)
        XCTAssertEqual(scenario.boluses.map(\.units), [1.5])
        XCTAssertEqual(scenario.carbohydrates.map(\.grams), [20])
    }

    private func remainingCarbs(at minutes: Double) -> Double {
        CarbohydrateAbsorptionModel.remainingGrams(
            grams: 60,
            minutes: minutes,
            absorptionDurationMinutes: 240
        )
    }
}
