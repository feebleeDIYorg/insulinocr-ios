import Foundation
import InsulinOCRCore
import XCTest
import ZIPFoundation
@testable import InsulinOCR

@MainActor final class ManualBasalCorrectionIntegrationTests: XCTestCase {
    func testPartialThenCompleteReviewPersistsWithoutRewritingRawHistory() async throws {
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let suite = "ManualBasalReview-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettings(defaults: defaults)
        settings.completeOnboarding(diaMinutes: 360, insulinPreset: .fiasp)
        let files = ProtectedCaseFileStore(rootOverride: temporary.appendingPathComponent("Cases"))
        let app = AppModel(inMemory: true, settingsOverride: settings, fileStoreOverride: files)
        let library = try XCTUnwrap(app.library)
        let queue = AppGroupImportQueue(queueRootOverride: temporary.appendingPathComponent("Queue"))
        let capture = Date(timeIntervalSinceReferenceDate: 800_000_000.1234567)
        let image = try XCTUnwrap(Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAAC0lEQVR4nGP4DwQACfsD/fteaysAAAAASUVORK5CYII="))
        _ = try await queue.enqueue(imageData: image, originalFilename: "synthetic-manual-gap.png",
            uniformTypeIdentifier: "public.png", captureTime: capture, captureTimeSource: .userCorrection)
        let pending = try await queue.pendingImports()
        let imported = try await library.ingest(try XCTUnwrap(pending.first))
        let record = try XCTUnwrap(library.caseRecord(id: imported.caseID))
        XCTAssertEqual(record.captureTime, capture)
        let native = result(reference: capture)
        let raw = native.makeAnalysisRun(caseID: record.id)
        try library.storeAnalysisRun(caseID: record.id, runID: raw.id, createdAt: raw.createdAt,
            algorithmVersion: raw.algorithmVersion, visionRevision: raw.visionRevision, status: .needsReview,
            payload: StoredAnalysisEnvelope(run: raw, extractorResult: native))
        let rawBytes = try XCTUnwrap(library.analysisRuns(caseID: record.id).first).encodedPayload
        await app.recomputeCase(caseID: record.id)
        XCTAssertFalse(try current(record: record, library: library).presentation.isComplete)

        let partial = entry(start: capture.addingTimeInterval(-240), end: capture)
        let revision = CorrectionRevision(caseID: record.id, analysisRunID: raw.id, operations: [.add(partial)])
        try await app.applyCorrection(revision)
        let stillIncomplete = try current(record: record, library: library)
        XCTAssertFalse(stillIncomplete.presentation.isComplete)
        let hidden = stillIncomplete.presentation.metrics
        XCTAssertTrue([hidden.basalIOB, hidden.bolusIOB, hidden.totalIOB, hidden.activeCarbohydrates].allSatisfy { $0 == nil })
        let full = entry(id: partial.id, start: capture.addingTimeInterval(-480), end: capture)
        let confirmed = CorrectionRevision(caseID: record.id, analysisRunID: raw.id, parentRevisionID: revision.id,
            operations: [.update(targetID: partial.id, replacement: full)])
        try await app.applyCorrection(confirmed)
        let completed = try current(record: record, library: library)
        XCTAssertTrue(completed.presentation.isComplete)
        XCTAssertEqual(record.status, .complete)
        XCTAssertNotNil(completed.presentation.metrics.totalIOB)
        XCTAssertEqual(completed.run.referenceDate, capture)
        XCTAssertFalse(completed.effectiveData.unresolvedIssues.contains(.incompleteBasalPath))
        XCTAssertEqual(try XCTUnwrap(library.analysisRuns(caseID: record.id).first).encodedPayload, rawBytes)
        XCTAssertEqual(try library.computationRuns(caseID: record.id).count, 3)
        let snapshot = try await CaseArchiveSnapshot.make(caseID: record.id, library: library, fileStore: files)
        XCTAssertEqual(snapshot.originalData, image)
        XCTAssertEqual(snapshot.correctionRevisions.count, 2)
        XCTAssertTrue(snapshot.activeAnalysis?.quality.blockers.contains(.incompleteBasalPath) == true)
        let url = try await CaseArchiveExporter().export(snapshot)
        defer { try? FileManager.default.removeItem(at: url) }
        let archive = try Archive(url: url, accessMode: .read)
        let exported = try XCTUnwrap(archive["CaseArchive-v1/effective/\(completed.run.id.uuidString).json"])
        var payload = Data()
        _ = try archive.extract(exported) { payload.append($0) }
        let effective = try JSONDecoder.insulinOCR.decode(EffectiveTherapyData.self, from: payload)
        XCTAssertEqual(effective, completed.effectiveData)
    }

    private func current(record: CaseEntity, library: CaseLibraryStore) throws -> StoredComputationEnvelope {
        let entity = try XCTUnwrap(library.computationRuns(caseID: record.id).first { $0.id == record.activeComputationRunID })
        return try JSONDecoder.insulinOCR.decode(StoredComputationEnvelope.self, from: entity.encodedPayload)
    }

    private func entry(id: UUID = UUID(), start: Date, end: Date) -> RawObservation {
        RawObservation(id: id, kind: .basalRate, startDate: start, endDate: end, amount: 0.8,
            unit: .unitsPerHour, amountState: .known, boundingBox: .init(x: 0, y: 0, width: 0, height: 0),
            confidence: .init(overall: 1, geometry: 0, recognition: 1, calibration: 1), provenance: .userCorrection)
    }

    private func result(reference: Date) -> OCRAnalysisResult {
        OCRAnalysisResult(requestID: UUID(), algorithmVersion: "synthetic-manual-review", visionRevision: 3,
            capturedAt: reference, timeAxisReferenceDate: reference, status: .needsReview,
            layout: .init(profile: .camAPSFXLandscapeV1, plotFrame: .init(x: 0.1, y: 0.1, width: 0.8, height: 0.8),
                          dataRightEdgeX: 0.9, estimatedVisibleHours: 8, confidence: 1),
            timeCalibration: .init(kind: .time, source: .multipleOCRAnchors, slope: 600, intercept: 0, maximumResidual: 0, anchors: []),
            basalCalibration: .init(kind: .basalRate, source: .numericAxisAnchors, slope: -5, intercept: 4.8, maximumResidual: 0, anchors: []),
            glucoseCalibration: nil, rawTextObservations: [],
            basalSteps: [.init(startDate: reference.addingTimeInterval(-28800), endDate: reference.addingTimeInterval(-480),
                rateUnitsPerHour: 0.8, pixelY: 0.8, confidence: 1, provenance: .init(kind: .calibratedPixelGeometry))],
            glucoseSamples: [], therapyEvents: [],
            quality: .init(layoutConfidence: 1, timeMaximumResidualMinutes: 0, basalPathCoverage: 472.0/480,
                glucoseSampleCount: 0, completeEventStemCount: 0, unknownEventAmountCount: 0,
                criticalDataComplete: false, timeAxisClockIsValid: true),
            warnings: [.init(code: .basalCaptureIntervalMissing, message: "Synthetic gap")],
            diagnostics: .init(imageWidth: 1, imageHeight: 1, removedDashedBlueComponentCount: 0,
                               retainedBasalComponentCount: 1, glucoseExtractionMode: "synthetic"))
    }
}
