import CryptoKit
import Foundation
import InsulinOCRCore
import XCTest
import ZIPFoundation
@testable import InsulinOCR

@MainActor
final class CaseLifecycleIntegrationTests: XCTestCase {
    func testFailedCalibrationExportsPartialOCRWithoutNumericOrCalibrationData() async throws {
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let store = ProtectedCaseFileStore(rootOverride: temporary.appendingPathComponent("Cases"))
        let library = CaseLibraryStore(modelContainer: try PersistenceFactory.makeContainer(inMemory: true), fileStore: store)
        let queue = AppGroupImportQueue(queueRootOverride: temporary.appendingPathComponent("Queue"))
        let image = try XCTUnwrap(Data(base64Encoded: Self.onePixelPNG))
        _ = try await queue.enqueue(imageData: image, originalFilename: "synthetic.png",
                                    uniformTypeIdentifier: "public.png", captureTime: .now,
                                    captureTimeSource: .importTime)
        let pending = try await queue.pendingImports()
        let imported = try await library.ingest(try XCTUnwrap(pending.first))
        let raw = OCRRawTextObservation(region: .timeAxis,
            boundingBox: OCRNormalizedRect(x: 0.2, y: 0.8, width: 0.1, height: 0.05),
            candidates: [OCRTextCandidate(text: "02:00", confidence: 0.6)])
        let failure = OCRFailedAnalysis(requestID: UUID(), createdAt: Date(timeIntervalSince1970: 1_730_000_000), algorithmVersion: "synthetic",
            visionRevision: 3, code: .invalidTimeAxis, message: "Synthetic calibration failure",
            rawTextObservations: [raw])
        try library.storeAnalysisRun(caseID: imported.caseID, runID: failure.id,
            createdAt: failure.createdAt, algorithmVersion: failure.algorithmVersion,
            visionRevision: failure.visionRevision, status: .incomplete,
            payload: StoredAnalysisFailureEnvelope(caseID: imported.caseID, failure: failure))
        let diagnostic = try await DiagnosticImageRenderer().render(originalData: image, failure: failure)
        _ = try await library.storeDiagnosticImage(caseID: imported.caseID, data: diagnostic)
        let snapshot = try await CaseArchiveSnapshot.make(caseID: imported.caseID, library: library, fileStore: store)
        XCTAssertNil(snapshot.activeAnalysis)
        XCTAssertTrue(snapshot.computationRuns.isEmpty)
        XCTAssertEqual(snapshot.originalData, image)
        XCTAssertEqual(snapshot.diagnosticData, diagnostic)
        let zip = try await CaseArchiveExporter().export(snapshot)
        defer { try? FileManager.default.removeItem(at: zip) }
        let expanded = temporary.appendingPathComponent("Expanded")
        try FileManager.default.unzipItem(at: zip, to: expanded)
        let root = expanded.appendingPathComponent("CaseArchive-v1")
        let retained = try Data(contentsOf: root.appendingPathComponent("analysis/failures/\(failure.id).json"))
        XCTAssertEqual(try JSONDecoder.insulinOCR.decode(StoredAnalysisFailureEnvelope.self, from: retained).failure, failure)
        let rawData = try Data(contentsOf: root.appendingPathComponent("analysis/raw-ocr/\(failure.id).json"))
        XCTAssertEqual(try JSONDecoder.insulinOCR.decode([OCRRawTextObservation].self, from: rawData), [raw])
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("analysis/calibration/\(failure.id).json").path))
        let checksums = try String(contentsOf: root.appendingPathComponent("checksums.sha256"), encoding: .utf8)
        XCTAssertTrue(checksums.contains("analysis/failures/\(failure.id).json"))
    }

    func testImportCorrectionSimulationAndExportRoundTrip() async throws {
        let temporaryRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("CaseLifecycle-\(UUID().uuidString)", isDirectory: true)
        let queueRoot = temporaryRoot.appendingPathComponent("Queue", isDirectory: true)
        let caseRoot = temporaryRoot.appendingPathComponent("Cases", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: temporaryRoot) }

        let container = try PersistenceFactory.makeContainer(inMemory: true)
        let fileStore = ProtectedCaseFileStore(rootOverride: caseRoot)
        let queue = AppGroupImportQueue(queueRootOverride: queueRoot)
        let library = CaseLibraryStore(modelContainer: container, fileStore: fileStore)
        let captureTime = Date(timeIntervalSince1970: 1_730_000_000)
        let image = try XCTUnwrap(Data(base64Encoded: Self.onePixelPNG))

        _ = try await queue.enqueue(
            imageData: image,
            originalFilename: "synthetic.png",
            uniformTypeIdentifier: "public.png",
            captureTime: captureTime,
            captureTimeSource: .importTime
        )
        let queued = try await queue.pendingImports()
        let importResult = try await library.ingest(try XCTUnwrap(queued.first))
        try await queue.remove(try XCTUnwrap(queued.first))
        XCTAssertFalse(importResult.wasDuplicate)

        let caseID = importResult.caseID
        let analysis = makeAnalysisRun(caseID: caseID, reference: captureTime)
        try library.storeAnalysisRun(
            caseID: caseID,
            runID: analysis.id,
            createdAt: analysis.createdAt,
            algorithmVersion: analysis.algorithmVersion,
            visionRevision: analysis.visionRevision,
            status: .needsReview,
            payload: analysis
        )
        let uncorrected = try DefaultEffectiveDataReducer().reduce(analysisRun: analysis, revisions: [])
        XCTAssertTrue(uncorrected.unresolvedIssues.contains(.unknownBolusAmount))

        let revision = CorrectionRevision(
            caseID: caseID,
            analysisRunID: analysis.id,
            operations: [
                .update(
                    targetID: Self.bolusID,
                    replacement: Self.observation(
                        id: Self.bolusID,
                        kind: .bolus,
                        date: captureTime.addingTimeInterval(-1_800),
                        amount: 1.5,
                        unit: .insulinUnits,
                        provenance: .userCorrection
                    )
                ),
            ],
            note: "Synthetic integration correction"
        )
        try library.storeCorrectionRevision(
            caseID: caseID,
            revisionID: revision.id,
            analysisRunID: analysis.id,
            parentRevisionID: nil,
            createdAt: revision.createdAt,
            payload: revision
        )

        let effective = try DefaultEffectiveDataReducer().reduce(
            analysisRun: analysis,
            revisions: [revision]
        )
        let settings = try TherapySettings(
            diaMinutes: 360,
            insulinType: .fiasp,
            carbAbsorptionMinutes: 240
        )
        let computation = DefaultActivityCalculator().calculate(
            data: effective,
            settings: settings,
            referenceDate: captureTime,
            forecastStepMinutes: 5
        )
        XCTAssertTrue(effective.unresolvedIssues.isEmpty)
        _ = try XCTUnwrap(computation.current.bolusIOB.value)
        let isComplete = [computation.current.basalIOB, computation.current.bolusIOB,
            computation.current.totalIOB, computation.current.cob].allSatisfy { $0.value != nil }
        XCTAssertTrue(isComplete)
        let run = ComputationRun(
            caseID: caseID,
            analysisRunID: analysis.id,
            correctionRevisionID: revision.id,
            referenceDate: captureTime,
            modelVersion: DefaultActivityCalculator.modelVersion,
            settings: settings,
            result: computation
        )
        let presentation = StoredCasePresentation(
            referenceTime: captureTime,
            isComplete: isComplete,
            unavailableReasons: [],
            metrics: .init(
                basalIOB: computation.current.basalIOB.value,
                bolusIOB: computation.current.bolusIOB.value,
                totalIOB: computation.current.totalIOB.value,
                activeCarbohydrates: computation.current.cob.value
            ),
            glucose: [],
            basal: [],
            events: [],
            decay: []
        )
        let envelope = StoredComputationEnvelope(run: run, effectiveData: effective, presentation: presentation)
        try library.storeComputationRun(
            caseID: caseID,
            runID: run.id,
            analysisRunID: analysis.id,
            correctionRevisionID: revision.id,
            createdAt: run.createdAt,
            referenceTime: captureTime,
            modelVersion: run.modelVersion,
            payload: envelope
        )
        try library.updateStatus(caseID: caseID, status: .complete)

        let simulationEvents: [SimulationEvent] = [
            .carbohydrate(CarbohydrateEvent(date: captureTime, grams: 15)),
        ]
        let simulatedData = SimulationCalculator.applying(events: simulationEvents, to: effective)
        let simulatedSnapshot = DefaultActivityCalculator().snapshot(
            data: simulatedData,
            settings: settings,
            date: captureTime
        )
        let scenario = SimulationScenario(
            caseID: caseID,
            baseComputationRunID: run.id,
            name: "Synthetic scenario",
            events: simulationEvents,
            baseline: computation.current,
            scenario: simulatedSnapshot
        )
        try library.storeSimulation(
            caseID: caseID,
            scenarioID: scenario.id,
            basedOnComputationRunID: run.id,
            name: scenario.name,
            createdAt: scenario.createdAt,
            payload: scenario
        )

        let snapshot = try await CaseArchiveSnapshot.make(
            caseID: caseID,
            library: library,
            fileStore: fileStore
        )
        let archiveURL = try await CaseArchiveExporter().export(snapshot)
        defer { try? FileManager.default.removeItem(at: archiveURL) }
        XCTAssertTrue(FileManager.default.fileExists(atPath: archiveURL.path))
        XCTAssertGreaterThan((try Data(contentsOf: archiveURL)).count, 100)

        let expandedRoot = temporaryRoot.appendingPathComponent("Expanded", isDirectory: true)
        try FileManager.default.unzipItem(at: archiveURL, to: expandedRoot)
        let archiveRoot = expandedRoot.appendingPathComponent("CaseArchive-v1", isDirectory: true)
        let manifestURL = archiveRoot.appendingPathComponent("manifest.json")
        let manifestObject = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: Data(contentsOf: manifestURL)) as? [String: Any]
        )
        XCTAssertEqual(manifestObject["schemaVersion"] as? Int, CaseArchiveExporter.schemaVersion)

        let requiredPaths = [
            "case.json",
            "screenshot.json",
            "effective/\(run.id.uuidString).json",
            "csv/effective-basal.csv",
            "csv/effective-bolus.csv",
            "csv/effective-carbohydrates.csv",
            "csv/raw-basal.csv",
            "csv/simulation-events.csv",
            "checksums.sha256",
        ]
        for path in requiredPaths {
            XCTAssertTrue(
                FileManager.default.fileExists(atPath: archiveRoot.appendingPathComponent(path).path),
                "Missing QA archive payload: \(path)"
            )
        }
        let checksums = try String(
            contentsOf: archiveRoot.appendingPathComponent("checksums.sha256"),
            encoding: .utf8
        )
        XCTAssertTrue(checksums.contains("effective/\(run.id.uuidString).json"))
        XCTAssertTrue(checksums.contains("csv/effective-carbohydrates.csv"))
        XCTAssertTrue(checksums.contains("manifest.json"))
        var checkedPaths = Set<String>()
        for line in checksums.split(separator: "\n") {
            let parts = line.components(separatedBy: "  ")
            XCTAssertEqual(parts.count, 2)
            guard parts.count == 2 else { continue }
            let path = parts[1]
            XCTAssertTrue(checkedPaths.insert(path).inserted, "Duplicate checksum path")
            XCTAssertFalse(path.split(separator: "/").contains(".."))
            let payload = try Data(contentsOf: archiveRoot.appendingPathComponent(path))
            let digest = SHA256.hash(data: payload).map { String(format: "%02x", $0) }.joined()
            XCTAssertEqual(parts[0], digest, "Checksum mismatch for \(path)")
        }
        let files = try XCTUnwrap(manifestObject["files"] as? [[String: Any]])
        XCTAssertEqual(checkedPaths, Set(files.compactMap { $0["path"] as? String }).union(["manifest.json"]))
        let rawBolus = try String(contentsOf: archiveRoot.appendingPathComponent("csv/raw-bolus.csv"), encoding: .utf8)
        let effectiveBolus = try String(contentsOf: archiveRoot.appendingPathComponent("csv/effective-bolus.csv"), encoding: .utf8)
        XCTAssertTrue(rawBolus.contains(",,amountUnknown,"))
        XCTAssertTrue(effectiveBolus.contains(",1.5,"))
        let simulationCSV = try String(contentsOf: archiveRoot.appendingPathComponent("csv/simulation-events.csv"), encoding: .utf8)
        XCTAssertTrue(simulationCSV.contains("Synthetic scenario"))
        XCTAssertTrue(simulationCSV.contains(",15,g,"))

        let revisions = try library.correctionRevisions(caseID: caseID)
        let simulations = try library.simulations(caseID: caseID)
        XCTAssertEqual(revisions.count, 1)
        XCTAssertEqual(simulations.count, 1)
        XCTAssertGreaterThan(simulatedSnapshot.cob.value ?? 0, computation.current.cob.value ?? 0)

        let nextAnalysis = makeAnalysisRun(caseID: caseID, reference: captureTime)
        try library.storeAnalysisRun(caseID: caseID, runID: nextAnalysis.id,
            createdAt: nextAnalysis.createdAt, algorithmVersion: nextAnalysis.algorithmVersion,
            visionRevision: nextAnalysis.visionRevision, status: .needsReview, payload: nextAnalysis)
        let reanalyzedRecord = try XCTUnwrap(library.caseRecord(id: caseID))
        XCTAssertEqual(reanalyzedRecord.activeAnalysisRunID, nextAnalysis.id)
        XCTAssertNil(reanalyzedRecord.activeCorrectionRevisionID)
        XCTAssertNil(reanalyzedRecord.activeComputationRunID)
        XCTAssertEqual(try library.analysisRuns(caseID: caseID).count, 2)
        XCTAssertEqual(try library.computationRuns(caseID: caseID).count, 1)
        XCTAssertEqual(try library.correctionRevisions(caseID: caseID).count, 1)
        XCTAssertEqual(try library.simulations(caseID: caseID).count, 1)

        try await library.deleteCase(caseID: caseID)
        XCTAssertNil(library.caseRecord(id: caseID))
        XCTAssertTrue(try library.analysisRuns(caseID: caseID).isEmpty)
        XCTAssertTrue(try library.computationRuns(caseID: caseID).isEmpty)
        XCTAssertTrue(try library.correctionRevisions(caseID: caseID).isEmpty)
        XCTAssertTrue(try library.simulations(caseID: caseID).isEmpty)
        XCTAssertNil(try library.screenshotAsset(caseID: caseID))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: caseRoot.appendingPathComponent(caseID.uuidString).path
        ))
        let tombstone = try await library.cloudArchive(caseID: caseID)
        XCTAssertTrue(tombstone.manifest.isDeletedTombstone)
        XCTAssertNil(tombstone.originalImageData)
        XCTAssertNil(tombstone.diagnosticImageData)
        XCTAssertTrue(tombstone.manifest.analysisRuns.isEmpty)
        XCTAssertTrue(tombstone.manifest.computationRuns.isEmpty)
    }

    private func makeAnalysisRun(caseID: UUID, reference: Date) -> AnalysisRun {
        let start = reference.addingTimeInterval(-36_000)
        let observations = [
            RawObservation(
                id: UUID(),
                kind: .basalRate,
                startDate: start,
                endDate: reference,
                amount: 0.8,
                unit: .unitsPerHour,
                amountState: .known,
                boundingBox: .init(x: 0.1, y: 0.7, width: 0.8, height: 0.01),
                confidence: .init(overall: 1, geometry: 1, recognition: 1, calibration: 1),
                provenance: .pixelPath
            ),
            Self.observation(
                id: Self.bolusID,
                kind: .bolus,
                date: reference.addingTimeInterval(-1_800),
                amount: nil,
                unit: .insulinUnits
            ),
            Self.observation(
                id: UUID(),
                kind: .carbohydrate,
                date: reference.addingTimeInterval(-2_400),
                amount: 20,
                unit: .grams
            ),
        ]
        return AnalysisRun(
            caseID: caseID,
            algorithmVersion: "synthetic-integration/1",
            visionRevision: 3,
            layoutProfile: "synthetic",
            calibration: .init(
                timeStart: start,
                timeEnd: reference,
                plotBounds: .init(x: 0.1, y: 0.1, width: 0.8, height: 0.8),
                timeResidualMinutes: 0
            ),
            rawOCR: [],
            observations: observations,
            quality: .init(
                layoutConfidence: 1,
                timeAxisConfidence: 1,
                basalCoverage: 1,
                glucoseConfidence: 1,
                eventConfidence: 1,
                blockers: [.unknownInsulinAmount]
            )
        )
    }

    private static func observation(
        id: UUID,
        kind: ObservationKind,
        date: Date,
        amount: Double?,
        unit: ObservationUnit,
        provenance: ObservationProvenance = .eventGeometry
    ) -> RawObservation {
        RawObservation(
            id: id,
            kind: kind,
            startDate: date,
            amount: amount,
            unit: unit,
            amountState: amount == nil ? .amountUnknown : .known,
            boundingBox: .init(x: 0.5, y: 0.2, width: 0.01, height: 0.4),
            confidence: .init(overall: 1, geometry: 1, recognition: 1, calibration: 1),
            provenance: provenance
        )
    }

    private static let bolusID = UUID(uuidString: "10000000-0000-0000-0000-000000000001")!
    private static let onePixelPNG = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAAC0lEQVR4nGP4DwQACfsD/fteaysAAAAASUVORK5CYII="
}
