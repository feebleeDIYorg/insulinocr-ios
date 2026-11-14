import Foundation
import InsulinOCRCore
import XCTest
@testable import InsulinOCR

final class SimulationChartDataTests: XCTestCase {
    private let reference = Date(timeIntervalSince1970: 1_800_000_000)

    func testEventRowsBecomeEventsOnlyWhenComplete() throws {
        // A bolus in twenty minutes, typed with a decimal comma.
        let bolus = SimulationEventDraft(kind: .bolus, amountText: "1,5", offsetText: "20")
        guard case .bolus(let insulin) = try XCTUnwrap(bolus.event(reference: reference)) else {
            return XCTFail("Expected a bolus")
        }
        XCTAssertEqual(insulin.units, 1.5)
        XCTAssertEqual(insulin.date, reference.addingTimeInterval(1_200))
        XCTAssertEqual(insulin.id, bolus.id)

        // A new row starts at the capture time and is incomplete until an amount is typed.
        let empty = SimulationEventDraft(kind: .carbohydrate)
        XCTAssertEqual(empty.offsetText, "0")
        XCTAssertNil(empty.event(reference: reference))
        XCTAssertEqual(empty.date(reference: reference), reference)

        // A preset fills an activity row; percent and duration stay editable.
        var activity = SimulationEventDraft(
            preset: ActivityPreset(name: "Joggen", insulinNeedPercent: 70, durationMinutes: 240))
        activity.offsetText = "-15"
        guard case .insulinNeed(let adjustment) = try XCTUnwrap(activity.event(reference: reference)) else {
            return XCTFail("Expected an activity")
        }
        XCTAssertEqual(activity.title, "Joggen")
        XCTAssertEqual(adjustment.percent, 70)
        XCTAssertEqual(adjustment.durationMinutes, 240)
        XCTAssertEqual(adjustment.startDate, reference.addingTimeInterval(-900))

        for invalid in [
            SimulationEventDraft(kind: .bolus, amountText: "0"),
            SimulationEventDraft(kind: .bolus, amountText: "51"),
            SimulationEventDraft(kind: .carbohydrate, amountText: "301"),
            SimulationEventDraft(kind: .bolus, amountText: "1", offsetText: "721"),
            SimulationEventDraft(kind: .bolus, amountText: "1", offsetText: ""),
            SimulationEventDraft(kind: .insulinNeed, amountText: "70", durationText: ""),
            SimulationEventDraft(kind: .insulinNeed, amountText: "5", durationText: "2"),
        ] {
            XCTAssertNil(invalid.event(reference: reference))
        }
    }

    func testZoneRunsColourHypoAndHyperStretchesWithoutGaps() {
        let limits = GlucoseLimits(hypo: 3.9, targetLow: 4.5, targetHigh: 8, hyper: 10)
        let samples = [5.0, 3.5, 3.0, 6.0, 11.0].enumerated().map { index, value in
            SimulationChartData.Sample(date: reference.addingTimeInterval(Double(index) * 300), value: value)
        }
        let runs = SimulationChartData.zoneRuns(samples, limits: limits)
        XCTAssertEqual(runs.map(\.zone), [.inRange, .low, .inRange, .high])
        XCTAssertEqual(runs.map { $0.samples.map(\.value) }, [[5], [5, 3.5, 3], [3, 6], [6, 11]])
        XCTAssertEqual(runs.map(\.index), [0, 1, 2, 3])
        // Between target range and limits a value is neither hypo nor hyper.
        XCTAssertEqual(SimulationChartData.zoneRuns(Array(samples.prefix(1)), limits: limits).map(\.zone), [.inRange])
        XCTAssertTrue(SimulationChartData.zoneRuns([], limits: limits).isEmpty)
    }

    func testScaleMapsInsulinAndCarbohydratesOntoTheGlucoseAxis() {
        let scale = SimulationChartScale(maxGlucose: 9, maxIOB: 3.2, maxCOB: 55, displayScale: 1)
        XCTAssertEqual(scale.glucoseMax, 15)
        // 55 g count as 5.5 units, so the right axis ends at 6.
        XCTAssertEqual(scale.unitsMax, 6)
        XCTAssertEqual(scale.position(units: 3), 7.5, accuracy: 1e-9)
        XCTAssertEqual(scale.position(grams: 30), 7.5, accuracy: 1e-9)
        XCTAssertEqual(scale.rightTickPositions, [0, 3.75, 7.5, 11.25, 15])
        XCTAssertEqual(scale.units(atPosition: 15), 6, accuracy: 1e-9)

        // mg/dl uses steps of 30 and a floor of 270; nothing on board still gives one unit.
        let mgdl = SimulationChartScale(maxGlucose: 290, maxIOB: 0, maxCOB: 0, displayScale: 18)
        XCTAssertEqual(mgdl.glucoseMax, 330)
        XCTAssertEqual(mgdl.unitsMax, 1)
        XCTAssertEqual(SimulationChartScale(maxGlucose: .nan, maxIOB: .nan, maxCOB: .nan, displayScale: 18).glucoseMax, 270)
    }

    func testChartDataShowsActivityWithoutProfilesAndGlucoseWithThem() throws {
        let therapy = try TherapySettings(diaMinutes: 360, insulinType: .fiasp, carbAbsorptionMinutes: 240)
        let data = EffectiveTherapyData(
            basalSegments: [], boluses: [], carbohydrates: [],
            glucoseSamples: [-180.0, -60, -5, 0].map {
                GlucoseSample(date: reference.addingTimeInterval($0 * 60), value: 6, unit: .millimolesPerLiter)
            })
        let events: [SimulationEvent] = [
            .bolus(InsulinEvent(date: reference, units: 1)),
            .carbohydrate(CarbohydrateEvent(date: reference.addingTimeInterval(1_800), grams: 20)),
        ]
        func build(_ simulation: SimulationSettings, model: GlucosePredictionModel = .loop) -> SimulationChartData {
            SimulationChartBuilder.build(
                data: data, therapy: therapy, reference: reference, events: events, simulation: simulation,
                profileBasalUnitsPerHour: 0, model: model, timeZoneIdentifier: "Europe/Zurich")
        }

        // No sensitivity or carb ratio: insulin and carbohydrates on board only, with a reason.
        let bare = build(SimulationSettings())
        XCTAssertNotNil(bare.missingGlucoseReason)
        XCTAssertTrue(bare.scenario.allSatisfy { $0.glucose == nil })
        XCTAssertEqual(try XCTUnwrap(bare.scenario.first).iob, 1, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(bare.scenario.first).cob, 0, accuracy: 1e-9)
        XCTAssertEqual(bare.scenario.last?.date, reference.addingTimeInterval(390 * 60))
        XCTAssertEqual(try XCTUnwrap(bare.baseline.first).iob, 0, accuracy: 1e-9)
        // Only the last two hours of measured glucose are drawn.
        XCTAssertEqual(bare.measured.count, 3)
        XCTAssertTrue(bare.orefCurves.isEmpty)

        var configured = SimulationSettings()
        configured.sensitivity = try DailyProfile(constant: 2)
        configured.carbRatio = try DailyProfile(constant: 10)
        let loop = build(configured)
        XCTAssertNil(loop.missingGlucoseReason)
        XCTAssertEqual(loop.scenario.first?.glucose, 6)
        // 1 U lowers by 2, 20 g raise by 4.
        XCTAssertEqual(try XCTUnwrap(loop.scenario.last?.glucose), 8, accuracy: 1e-6)
        XCTAssertEqual(try XCTUnwrap(loop.baseline.last?.glucose), 6, accuracy: 1e-6)
        XCTAssertEqual(loop.events.count, 2)

        let oref = build(configured, model: .oref)
        XCTAssertEqual(oref.orefCurves.map(\.kind), [.insulinOnly, .withCarbohydrates, .zeroTemp])
        XCTAssertEqual(oref.orefCurves.first?.samples.count, oref.scenario.count)
    }
}
