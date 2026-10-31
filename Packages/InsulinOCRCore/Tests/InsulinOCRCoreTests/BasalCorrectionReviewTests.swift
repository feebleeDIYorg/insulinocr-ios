import Foundation
import XCTest
@testable import InsulinOCRCore

final class BasalCorrectionReviewTests: XCTestCase {
    private let reference = Date(timeIntervalSince1970: 1_800_000_000)
    private var window: DateInterval { DateInterval(start: reference.addingTimeInterval(-21600), end: reference) }
    private var base: RawObservation { basal(start: reference.addingTimeInterval(-28800), end: reference.addingTimeInterval(-30), rate: 0.8) }

    func testExplicitFullGapRepairMatchesIndependentCompleteHistoryAndPreservesRawRun() throws {
        let original = base
        let run = makeRun([original])
        let before = run
        let fill = basal(start: reference.addingTimeInterval(-30), end: reference, rate: 0, provenance: .userCorrection)
        let revision = CorrectionRevision(caseID: run.caseID, analysisRunID: run.id, operations: [.add(fill)])
        let reducer = DefaultEffectiveDataReducer()
        XCTAssertTrue(try reducer.reduce(analysisRun: run, revisions: [revision]).unresolvedIssues.contains(.incompleteBasalPath))
        let repaired = try reducer.reduce(analysisRun: run, revisions: [revision], basalCoverageWindow: window)
        XCTAssertFalse(repaired.unresolvedIssues.contains(.incompleteBasalPath))
        XCTAssertEqual(repaired.sourceCorrectionRevisionID, revision.id)
        XCTAssertEqual(run, before)
        let independent = EffectiveTherapyData(basalSegments: [
            .init(startDate: original.startDate, endDate: try XCTUnwrap(original.endDate), unitsPerHour: 0.8),
            .init(startDate: fill.startDate, endDate: reference, unitsPerHour: 0)
        ], boluses: [], carbohydrates: [], glucoseSamples: [], sourceAnalysisRunID: run.id, observedHistoryMinutes: 480)
        let settings = try TherapySettings(diaMinutes: 360, insulinType: .fiasp, carbAbsorptionMinutes: 240)
        let calculator = DefaultActivityCalculator()
        let actual = calculator.calculate(data: repaired, settings: settings, referenceDate: reference)
        XCTAssertNotNil(actual.current.totalIOB.value)
        XCTAssertEqual(actual, calculator.calculate(data: independent, settings: settings, referenceDate: reference))
    }

    func testPartialOverlappingAndNonUserBasalRepairsDoNotReleaseFlag() throws {
        let run = makeRun([base])
        for fill in [
            basal(start: reference.addingTimeInterval(-15), end: reference, rate: 1, provenance: .userCorrection),
            basal(start: reference.addingTimeInterval(-60), end: reference, rate: 1, provenance: .userCorrection),
            basal(start: reference.addingTimeInterval(-30), end: reference, rate: 1, provenance: .pixelPath)
        ] {
            let revision = CorrectionRevision(caseID: run.caseID, analysisRunID: run.id, operations: [.add(fill)])
            let result = try DefaultEffectiveDataReducer().reduce(analysisRun: run, revisions: [revision], basalCoverageWindow: window)
            XCTAssertTrue(result.unresolvedIssues.contains(.incompleteBasalPath))
        }
    }

    func testUnknownBasalObservationCannotHideBehindCompleteKnownCoverage() throws {
        let known = basal(start: window.start, end: reference, rate: 1)
        let unknown = basal(start: reference.addingTimeInterval(-600), end: reference.addingTimeInterval(-300), rate: nil)
        let run = makeRun([known, unknown])
        let replacement = basal(id: known.id, start: known.startDate, end: reference, rate: 0.9, provenance: .userCorrection)
        let revision = CorrectionRevision(caseID: run.caseID, analysisRunID: run.id, operations: [.update(targetID: known.id, replacement: replacement)])
        XCTAssertTrue(try DefaultEffectiveDataReducer().reduce(analysisRun: run, revisions: [revision], basalCoverageWindow: window)
            .unresolvedIssues.contains(.incompleteBasalPath))
    }

    func testInvalidAxesAndOtherCriticalEventsRemainUnresolved() throws {
        for blocker in [AnalysisBlocker.invalidTimeAxis, .invalidBasalAxis, .unknownInsulinAmount] {
            let run = makeRun([base], blockers: [.incompleteBasalPath, blocker])
            let fill = basal(start: reference.addingTimeInterval(-30), end: reference, rate: 1, provenance: .userCorrection)
            let revision = CorrectionRevision(caseID: run.caseID, analysisRunID: run.id, operations: [.add(fill)])
            let result = try DefaultEffectiveDataReducer().reduce(analysisRun: run, revisions: [revision], basalCoverageWindow: window)
            let expected: CriticalDataIssue = blocker == .invalidTimeAxis ? .invalidTimeAxis : (blocker == .invalidBasalAxis ? .invalidBasalAxis : .unknownBolusAmount)
            XCTAssertTrue(result.unresolvedIssues.contains(expected))
            if blocker != .unknownInsulinAmount { XCTAssertTrue(result.unresolvedIssues.contains(.incompleteBasalPath)) }
        }
    }

    func testNoRevisionOrUnrelatedRevisionCannotReleaseRawBasalQuality() throws {
        let run = makeRun([basal(start: window.start, end: reference, rate: 1)])
        let unrelated = CorrectionRevision(caseID: run.caseID, analysisRunID: run.id, operations: [])
        for revisions in [[], [unrelated]] {
            XCTAssertTrue(try DefaultEffectiveDataReducer().reduce(analysisRun: run, revisions: revisions, basalCoverageWindow: window)
                .unresolvedIssues.contains(.incompleteBasalPath))
        }
    }

    func testExplicitDeletionOfAnInvalidBasalObservationKeepsKnownCoverage() throws {
        let known = basal(start: window.start, end: reference, rate: 1)
        let unknown = basal(start: reference.addingTimeInterval(-600), end: reference, rate: nil)
        let run = makeRun([known, unknown])
        let revision = CorrectionRevision(caseID: run.caseID, analysisRunID: run.id,
            operations: [.delete(targetID: unknown.id)])
        let result = try DefaultEffectiveDataReducer().reduce(analysisRun: run, revisions: [revision],
                                                               basalCoverageWindow: window)
        XCTAssertFalse(result.unresolvedIssues.contains(.incompleteBasalPath))
        XCTAssertEqual(result.basalSegments.count, 1)
        XCTAssertEqual(run.observations.count, 2)
        XCTAssertNil(run.observations.last?.amount)
    }

    func testCorrectionCannotInventMissingScreenshotHistory() throws {
        let run = makeRun([base], historyMinutes: 30)
        let fill = basal(start: reference.addingTimeInterval(-30), end: reference, rate: 1, provenance: .userCorrection)
        let revision = CorrectionRevision(caseID: run.caseID, analysisRunID: run.id, operations: [.add(fill)])
        let result = try DefaultEffectiveDataReducer().reduce(analysisRun: run, revisions: [revision], basalCoverageWindow: window)
        let settings = try TherapySettings(diaMinutes: 360, insulinType: .fiasp, carbAbsorptionMinutes: 240)
        let snapshot = DefaultActivityCalculator().snapshot(data: result, settings: settings, date: reference)
        for metric in [snapshot.basalIOB, snapshot.bolusIOB, snapshot.totalIOB, snapshot.cob] {
            XCTAssertEqual(metric, .unavailable(.insufficientHistory))
        }
    }

    private func basal(id: UUID = UUID(), start: Date, end: Date, rate: Double?, provenance: ObservationProvenance = .pixelPath) -> RawObservation {
        RawObservation(id: id, kind: .basalRate, startDate: start, endDate: end, amount: rate, unit: .unitsPerHour,
            amountState: rate == nil ? .amountUnknown : .known,
            boundingBox: .init(x: 0.1, y: 0.5, width: 0.1, height: 0.1),
            confidence: .init(overall: 1, geometry: 1, recognition: 1, calibration: 1), provenance: provenance)
    }

    private func makeRun(_ observations: [RawObservation], blockers: Set<AnalysisBlocker> = [.incompleteBasalPath], historyMinutes: Double = 480) -> AnalysisRun {
        AnalysisRun(caseID: UUID(), algorithmVersion: "synthetic", visionRevision: 1, layoutProfile: "synthetic",
            calibration: .init(timeStart: reference.addingTimeInterval(-historyMinutes * 60), timeEnd: reference,
                plotBounds: .init(x: 0.1, y: 0.1, width: 0.8, height: 0.8), timeResidualMinutes: 0),
            rawOCR: [], observations: observations,
            quality: .init(layoutConfidence: 1, timeAxisConfidence: 1, basalCoverage: 0.98,
                           glucoseConfidence: 1, eventConfidence: 1, blockers: blockers))
    }
}
