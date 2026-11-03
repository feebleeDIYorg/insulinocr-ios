import Foundation
import XCTest
@testable import InsulinOCRCore

final class ActiveWindowQualityTests: XCTestCase {
    private let reference = Date(timeIntervalSince1970: 1_800_000_000)
    private var settings: TherapySettings {
        get throws { try TherapySettings(diaMinutes: 240, insulinType: .fiasp, carbAbsorptionMinutes: 240) }
    }

    func testExpiredUncertaintyRemainsInRawRunAndIsAuditableWithoutBlockingCurrentActivity() throws {
        let observations = [ObservationKind.bolus, .carbohydrate, .eventStem].map { event($0, age: 360) }
        let run = analysis(observations)
        let effective = try reduce(run)
        XCTAssertTrue(effective.unresolvedIssues.isEmpty)
        XCTAssertEqual(Set(effective.inactiveUncertainObservationIDs ?? []), Set(observations.map(\.id)))
        XCTAssertEqual(run.observations.count, 4)
        XCTAssertTrue(observations.allSatisfy { $0.amount == nil })
        XCTAssertTrue(complete(try DefaultActivityCalculator().calculate(data: effective, settings: settings,
            referenceDate: reference).current))
        XCTAssertTrue(try DefaultEffectiveDataReducer().reduce(analysisRun: run, revisions: [])
            .unresolvedIssues.contains(.unclassifiedEvent))
    }

    func testDifferentActionWindowsKeepCarbohydrateAndUnclassifiedUncertaintyCritical() throws {
        let s = try TherapySettings(diaMinutes: 240, insulinType: .fiasp, carbAbsorptionMinutes: 360)
        let observations = [ObservationKind.bolus, .carbohydrate, .eventStem].map { event($0, age: 300) }
        let result = try reduce(analysis(observations), settings: s)
        XCTAssertFalse(result.unresolvedIssues.contains(.unknownBolusAmount))
        XCTAssertTrue(result.unresolvedIssues.contains(.unknownCarbohydrateAmount))
        XCTAssertTrue(result.unresolvedIssues.contains(.unclassifiedEvent))
        XCTAssertEqual(result.inactiveUncertainObservationIDs, [observations[0].id])
    }

    func testEventAssignmentMarginAndCarbohydrateDelayArePreservedAtBoundaries() throws {
        for (kind, horizon) in [(ObservationKind.bolus, 240.0), (.carbohydrate, 250.0), (.eventStem, 250.0)] {
            let boundary = event(kind, age: horizon + 3.5)
            let beyond = event(kind, age: horizon + 3.5 + 1.0 / 60)
            XCTAssertTrue(try reduce(analysis([boundary])).inactiveUncertainObservationIDs?.isEmpty == true)
            XCTAssertEqual(try reduce(analysis([beyond])).inactiveUncertainObservationIDs, [beyond.id])
        }
    }

    func testUnvalidatedLegacyOrInvalidClocksNeverExpireUncertainty() throws {
        for validated in [nil, false] as [Bool?] {
            let result = try reduce(analysis([event(.eventStem, age: 360)], clockValidated: validated))
            XCTAssertTrue(result.unresolvedIssues.contains(.unclassifiedEvent))
            XCTAssertTrue(result.inactiveUncertainObservationIDs?.isEmpty == true)
            if validated == false { XCTAssertTrue(result.unresolvedIssues.contains(.invalidTimeAxis)) }
        }
        let outside = try reduce(analysis([event(.eventStem, age: 600)]))
        XCTAssertTrue(outside.unresolvedIssues.contains(.unclassifiedEvent))
        let unlocalized = try reduce(analysis([event(.eventStem, age: 360)], issuesLocalized: false))
        XCTAssertTrue(unlocalized.unresolvedIssues.contains(.unclassifiedEvent))
    }

    func testHistoricalBasalGapDoesNotReplaceCompleteObservedDIAWithAnAssumption() throws {
        let run = analysis([], basalAge: 240, basalEndAge: 0, coverage: 0.5)
        let result = try reduce(run)
        XCTAssertFalse(result.unresolvedIssues.contains(.incompleteBasalPath))
        XCTAssertEqual(result.basalSegments.count, 1)
        XCTAssertEqual(result.basalSegments[0].startDate, reference.addingTimeInterval(-240 * 60))
        XCTAssertEqual(run.quality.basalCoverage, 0.5)
        let recentGap = try reduce(analysis([], basalAge: 240, basalEndAge: 1, coverage: 0.5))
        XCTAssertTrue(recentGap.unresolvedIssues.contains(.incompleteBasalPath))
    }

    func testChangedDurationOrReferenceRequiresFreshAssessment() throws {
        let run = analysis([event(.eventStem, age: 300)])
        let effective = try reduce(run)
        let longer = try TherapySettings(diaMinutes: 360, insulinType: .fiasp, carbAbsorptionMinutes: 240)
        for (s, date) in [(try settings, reference.addingTimeInterval(-3_600)), (longer, reference)] {
            let result = DefaultActivityCalculator().calculate(data: effective, settings: s, referenceDate: date)
            XCTAssertNil(result.current.basalIOB.value)
            XCTAssertNil(result.current.bolusIOB.value)
            XCTAssertNil(result.current.totalIOB.value)
            XCTAssertNil(result.current.cob.value)
        }
        XCTAssertTrue(try reduce(run, settings: longer).unresolvedIssues.contains(.unclassifiedEvent))
    }

    func testSimulationAndForecastRetainAssessmentAndRawProvenance() throws {
        let effective = try reduce(analysis([event(.eventStem, age: 360)]))
        let simulated = SimulationCalculator.applying(events: [.bolus(.init(date: reference, units: 1))], to: effective)
        XCTAssertEqual(simulated.activityAssessment, effective.activityAssessment)
        XCTAssertEqual(simulated.inactiveUncertainObservationIDs, effective.inactiveUncertainObservationIDs)
        let result = try DefaultActivityCalculator().calculate(data: simulated, settings: settings, referenceDate: reference)
        XCTAssertTrue(complete(result.current))
        XCTAssertTrue(result.forecast.allSatisfy(complete))
    }

    func testLegacyOptionalMetadataDecodesAndInvalidReferenceIsRejected() throws {
        let original = try reduce(analysis([event(.eventStem, age: 360)]))
        let encoder = JSONEncoder(), decoder = JSONDecoder()
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoder.encode(original)) as? [String: Any])
        object.removeValue(forKey: "activityAssessment")
        object.removeValue(forKey: "inactiveUncertainObservationIDs")
        let legacy = try decoder.decode(EffectiveTherapyData.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertNil(legacy.activityAssessment)
        XCTAssertNil(legacy.inactiveUncertainObservationIDs)
        let invalid = Date(timeIntervalSinceReferenceDate: .nan)
        XCTAssertThrowsError(try DefaultEffectiveDataReducer().reduce(analysisRun: analysis([]), revisions: [],
            referenceDate: invalid, settings: settings))
    }

    func testAmbiguousUnitsUseLongestWindowAndWeakLocalizationCannotExpire() throws {
        let s = try TherapySettings(diaMinutes: 240, insulinType: .fiasp, carbAbsorptionMinutes: 360)
        let ambiguous = event(.bolus, age: 300, unit: ObservationUnit.none)
        XCTAssertTrue(try reduce(analysis([ambiguous]), settings: s).unresolvedIssues.contains(.unknownBolusAmount))
        let weak = event(.eventStem, age: 420, geometry: 0.5)
        XCTAssertTrue(try reduce(analysis([weak]), settings: s).unresolvedIssues.contains(.unclassifiedEvent))
    }

    func testMissingAssessmentCannotReuseExpiredUncertainty() throws {
        let data = EffectiveTherapyData(basalSegments: [], boluses: [], carbohydrates: [], glucoseSamples: [],
            inactiveUncertainObservationIDs: [UUID()])
        let result = try DefaultActivityCalculator().calculate(data: data, settings: settings, referenceDate: reference)
        XCTAssertNil(result.current.basalIOB.value)
        XCTAssertNil(result.current.bolusIOB.value)
        XCTAssertNil(result.current.totalIOB.value)
        XCTAssertNil(result.current.cob.value)
    }

    func testDeletingLocatedObservationDoesNotResolveAnExplicitlyUnlocalizedWarning() throws {
        let event = event(.eventStem, age: 360)
        let run = analysis([event], issuesLocalized: false, extraBlockers: [.unclassifiedEvent])
        let revision = CorrectionRevision(caseID: run.caseID, analysisRunID: run.id, operations: [.delete(targetID: event.id)])
        let result = try DefaultEffectiveDataReducer().reduce(analysisRun: run, revisions: [revision],
            referenceDate: reference, settings: settings)
        XCTAssertTrue(result.unresolvedIssues.contains(.unclassifiedEvent))
    }

    private func reduce(_ run: AnalysisRun, settings: TherapySettings? = nil) throws -> EffectiveTherapyData {
        try DefaultEffectiveDataReducer().reduce(analysisRun: run, revisions: [], referenceDate: reference,
            settings: settings ?? self.settings)
    }

    private func complete(_ snapshot: ActivitySnapshot) -> Bool {
        [snapshot.basalIOB, snapshot.bolusIOB, snapshot.totalIOB, snapshot.cob].allSatisfy { $0.value != nil }
    }

    private func event(_ kind: ObservationKind, age: Double, unit: ObservationUnit? = nil, geometry: Double = 1) -> RawObservation {
        .init(kind: kind, startDate: reference.addingTimeInterval(-age * 60), amount: nil,
            unit: unit ?? (kind == .bolus ? .insulinUnits : kind == .carbohydrate ? .grams : .none),
            amountState: .amountUnknown, boundingBox: .init(x: 0.2, y: 0.1, width: 0.01, height: 0.1),
            confidence: .init(overall: 0.5, geometry: geometry, recognition: 0, calibration: 1), provenance: .visionOCR)
    }

    private func analysis(_ observations: [RawObservation], clockValidated: Bool? = true, issuesLocalized: Bool? = true,
                          basalAge: Double = 480, basalEndAge: Double = 0, coverage: Double = 1,
                          extraBlockers: Set<AnalysisBlocker> = []) -> AnalysisRun {
        let basal = RawObservation(kind: .basalRate, startDate: reference.addingTimeInterval(-basalAge * 60),
            endDate: reference.addingTimeInterval(-basalEndAge * 60), amount: 0, unit: .unitsPerHour,
            amountState: .known, boundingBox: .init(x: 0.1, y: 0.5, width: 0.8, height: 0.01),
            confidence: .init(overall: 1, geometry: 1, recognition: 1, calibration: 1), provenance: .pixelPath)
        return AnalysisRun(caseID: UUID(), algorithmVersion: "synthetic", visionRevision: 1, layoutProfile: "synthetic",
            calibration: .init(timeStart: reference.addingTimeInterval(-480 * 60), timeEnd: reference,
                plotBounds: .init(x: 0.1, y: 0.1, width: 0.8, height: 0.8), timeResidualMinutes: 0),
            rawOCR: [], observations: observations + [basal],
            quality: .init(layoutConfidence: 1, timeAxisConfidence: 1, basalCoverage: coverage,
                glucoseConfidence: 1, eventConfidence: 0.5,
                blockers: extraBlockers.union(coverage < 0.99 ? [.incompleteBasalPath] : []), clockValidated: clockValidated,
                eventIssuesLocalized: issuesLocalized))
    }
}
