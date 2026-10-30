import Foundation
import XCTest
@testable import InsulinOCRCore

final class DomainReducerTests: XCTestCase {
    func testCorrectionOverlayResolvesUnknownAmountWithoutChangingRawRun() throws {
        let caseID = UUID()
        let observationID = UUID()
        let date = Date(timeIntervalSince1970: 1_800_000_000)
        let unknown = observation(
            id: observationID,
            kind: .bolus,
            date: date,
            amount: nil,
            unit: .insulinUnits,
            amountState: .amountUnknown
        )
        let carbohydrateID = UUID()
        let unknownCarbohydrate = observation(id: carbohydrateID, kind: .carbohydrate,
            date: date, amount: nil, unit: .grams, amountState: .amountUnknown)
        let analysis = analysisRun(caseID: caseID, observations: [unknown, unknownCarbohydrate],
            blockers: [.unknownInsulinAmount, .unknownCarbohydrateAmount])
        let corrected = observation(
            id: observationID,
            kind: .bolus,
            date: date,
            amount: 1.25,
            unit: .insulinUnits,
            amountState: .known,
            provenance: .userCorrection
        )
        let correctedCarbohydrate = observation(id: carbohydrateID, kind: .carbohydrate,
            date: date, amount: 18, unit: .grams, amountState: .known, provenance: .userCorrection)
        let partialRevision = CorrectionRevision(caseID: caseID, analysisRunID: analysis.id,
            operations: [.update(targetID: observationID, replacement: corrected)])
        let partial = try DefaultEffectiveDataReducer().reduce(analysisRun: analysis, revisions: [partialRevision])
        XCTAssertFalse(partial.unresolvedIssues.contains(.unknownBolusAmount))
        XCTAssertTrue(partial.unresolvedIssues.contains(.unknownCarbohydrateAmount))
        let revision = CorrectionRevision(
            caseID: caseID,
            analysisRunID: analysis.id,
            operations: [
                .update(targetID: observationID, replacement: corrected),
                .update(targetID: carbohydrateID, replacement: correctedCarbohydrate)
            ]
        )

        let effective = try DefaultEffectiveDataReducer().reduce(
            analysisRun: analysis,
            revisions: [revision]
        )
        XCTAssertNil(analysis.observations[0].amount)
        XCTAssertNil(analysis.observations[1].amount)
        XCTAssertEqual(analysis.quality.blockers, [.unknownInsulinAmount, .unknownCarbohydrateAmount])
        XCTAssertEqual(effective.boluses.map(\.units), [1.25])
        XCTAssertEqual(effective.carbohydrates.map(\.grams), [18])
        XCTAssertFalse(effective.unresolvedIssues.contains(.unknownBolusAmount))
        XCTAssertFalse(effective.unresolvedIssues.contains(.unknownCarbohydrateAmount))
        XCTAssertEqual(effective.sourceCorrectionRevisionID, revision.id)
    }

    func testUnknownBolusAndCarbohydrateBecomeExplicitIssues() throws {
        let caseID = UUID()
        let analysis = analysisRun(
            caseID: caseID,
            observations: [
                observation(
                    kind: .bolus,
                    date: Date(),
                    amount: nil,
                    unit: .insulinUnits,
                    amountState: .amountUnknown
                ),
                observation(
                    kind: .carbohydrate,
                    date: Date(),
                    amount: nil,
                    unit: .grams,
                    amountState: .amountUnknown
                ),
            ]
        )
        let effective = try DefaultEffectiveDataReducer().reduce(
            analysisRun: analysis,
            revisions: []
        )
        XCTAssertEqual(
            effective.unresolvedIssues,
            [.unknownBolusAmount, .unknownCarbohydrateAmount]
        )
    }

    func testDeletingUnclassifiedStemClearsItsIssue() throws {
        let caseID = UUID()
        let stem = observation(
            kind: .eventStem,
            date: Date(),
            amount: nil,
            unit: .none,
            amountState: .notApplicable
        )
        let analysis = analysisRun(caseID: caseID, observations: [stem], blockers: [.unclassifiedEvent])
        let revision = CorrectionRevision(
            caseID: caseID,
            analysisRunID: analysis.id,
            operations: [.delete(targetID: stem.id)]
        )
        let effective = try DefaultEffectiveDataReducer().reduce(
            analysisRun: analysis,
            revisions: [revision]
        )
        XCTAssertFalse(effective.unresolvedIssues.contains(.unclassifiedEvent))
    }

    func testLowBasalCoverageBlocksBasalNumericalOutput() throws {
        let caseID = UUID()
        let analysis = analysisRun(caseID: caseID, observations: [], basalCoverage: 0.98)
        let effective = try DefaultEffectiveDataReducer().reduce(
            analysisRun: analysis,
            revisions: []
        )
        XCTAssertTrue(effective.unresolvedIssues.contains(.incompleteBasalPath))

        let settings = try TherapySettings(
            diaMinutes: 300,
            insulinType: .fiasp,
            carbAbsorptionMinutes: 240
        )
        let snapshot = DefaultActivityCalculator().snapshot(
            data: effective,
            settings: settings,
            date: Date()
        )
        XCTAssertEqual(snapshot.basalIOB, .unavailable(.incompleteBasalPath))
        XCTAssertNil(snapshot.totalIOB.value)
    }

    func testUnlocalizedQualityIssuesRemainBlocking() throws {
        let run = analysisRun(caseID: UUID(), observations: [],
            blockers: [.unknownInsulinAmount, .unknownCarbohydrateAmount, .unclassifiedEvent])
        let effective = try DefaultEffectiveDataReducer().reduce(analysisRun: run, revisions: [])
        XCTAssertEqual(effective.unresolvedIssues,
            [.unknownBolusAmount, .unknownCarbohydrateAmount, .unclassifiedEvent])
    }

    func testVersionedEntitiesRoundTripThroughJSON() throws {
        let caseID = UUID()
        let analysis = analysisRun(caseID: caseID, observations: [])
        let encoded = try JSONEncoder().encode(analysis)
        let decoded = try JSONDecoder().decode(AnalysisRun.self, from: encoded)
        XCTAssertEqual(decoded, analysis)
    }

    private func analysisRun(
        caseID: UUID,
        observations: [RawObservation],
        basalCoverage: Double = 1,
        blockers: Set<AnalysisBlocker> = []
    ) -> AnalysisRun {
        let end = Date(timeIntervalSince1970: 1_800_000_000)
        return AnalysisRun(
            caseID: caseID,
            algorithmVersion: "test",
            visionRevision: 1,
            layoutProfile: "test-landscape",
            calibration: AxisCalibration(
                timeStart: end.addingTimeInterval(-36_000),
                timeEnd: end,
                plotBounds: NormalizedBoundingBox(x: 0.1, y: 0.1, width: 0.8, height: 0.8),
                timeResidualMinutes: 0
            ),
            rawOCR: [],
            observations: observations,
            quality: AnalysisQuality(
                layoutConfidence: 1,
                timeAxisConfidence: 1,
                basalCoverage: basalCoverage,
                glucoseConfidence: 1,
                eventConfidence: 1,
                blockers: blockers
            )
        )
    }

    private func observation(
        id: UUID = UUID(),
        kind: ObservationKind,
        date: Date,
        amount: Double?,
        unit: ObservationUnit,
        amountState: ObservationAmountState,
        provenance: ObservationProvenance = .eventGeometry
    ) -> RawObservation {
        RawObservation(
            id: id,
            kind: kind,
            startDate: date,
            amount: amount,
            unit: unit,
            amountState: amountState,
            boundingBox: NormalizedBoundingBox(x: 0.2, y: 0.2, width: 0.1, height: 0.2),
            confidence: ObservationConfidence(
                overall: 0.8,
                geometry: 0.9,
                recognition: 0.7,
                calibration: 1
            ),
            provenance: provenance
        )
    }
}
