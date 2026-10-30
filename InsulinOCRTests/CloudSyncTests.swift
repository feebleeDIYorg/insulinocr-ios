import CryptoKit
import Foundation
import XCTest
@testable import InsulinOCR

@MainActor
final class CloudSyncTests: XCTestCase {
    func testCodecRoundTripPreservesVersionedManifest() throws {
        let image = Data("screenshot".utf8)
        let manifest = makeManifest(image: image)

        let encoded = try CloudSyncCodec.encode(manifest)
        let decoded = try CloudSyncCodec.decode(encoded)

        XCTAssertEqual(decoded, manifest)
        XCTAssertNoThrow(try decoded.validate())
    }

    func testMergeUnionsImmutableRunsAndTombstoneAlwaysWins() {
        let caseID = UUID()
        let image = Data("screenshot".utf8)
        let firstRun = analysisRun(payload: Data("first".utf8))
        let secondRun = analysisRun(payload: Data("second".utf8))
        let screenshotID = UUID()
        let live = makeManifest(
            caseID: caseID,
            modifiedAt: Date(timeIntervalSince1970: 200),
            image: image,
            screenshotID: screenshotID,
            analysisRuns: [firstRun]
        )
        var deleted = makeManifest(
            caseID: caseID,
            modifiedAt: Date(timeIntervalSince1970: 100),
            image: image,
            screenshotID: screenshotID,
            analysisRuns: [secondRun]
        )
        deleted.isDeletedTombstone = true

        let merged = live.merging(deleted)

        XCTAssertTrue(merged.isDeletedTombstone)
        XCTAssertTrue(merged.analysisRuns.isEmpty)
        XCTAssertTrue(merged.computationRuns.isEmpty)
        XCTAssertNil(merged.activeAnalysisRunID)
    }

    func testDivergentCorrectionHeadsAreRetainedAndMarkedForReview() {
        let caseID = UUID()
        let analysis = analysisRun(payload: Data("analysis".utf8))
        let firstCorrection = correction(
            analysisRunID: analysis.id,
            payload: Data("left".utf8)
        )
        let secondCorrection = correction(
            analysisRunID: analysis.id,
            payload: Data("right".utf8)
        )
        let screenshotID = UUID()
        let left = makeManifest(
            caseID: caseID,
            image: Data("screenshot".utf8),
            screenshotID: screenshotID,
            analysisRuns: [analysis],
            corrections: [firstCorrection]
        )
        let right = makeManifest(
            caseID: caseID,
            modifiedAt: Date(timeIntervalSince1970: 101),
            image: Data("screenshot".utf8),
            screenshotID: screenshotID,
            analysisRuns: [analysis],
            corrections: [secondCorrection]
        )

        let merged = left.merging(right)

        XCTAssertEqual(merged.statusRaw, StoredCaseStatus.needsReview.rawValue)
        XCTAssertEqual(
            Set(merged.correctionRevisions.map(\.id)),
            Set([firstCorrection.id, secondCorrection.id])
        )
        XCTAssertTrue(merged.correctionRevisions.allSatisfy(\.hasConflict))
    }

    func testSameImmutableRunIDDifferentPayloadFailsClosedToReview() {
        let runID = UUID()
        let leftRun = analysisRun(id: runID, payload: Data("left".utf8))
        let rightRun = analysisRun(id: runID, payload: Data("right".utf8))
        let caseID = UUID()
        let image = Data("screenshot".utf8)
        let screenshotID = UUID()
        let left = makeManifest(
            caseID: caseID,
            image: image,
            screenshotID: screenshotID,
            analysisRuns: [leftRun]
        )
        let right = makeManifest(
            caseID: caseID,
            modifiedAt: Date(timeIntervalSince1970: 101),
            image: image,
            screenshotID: screenshotID,
            analysisRuns: [rightRun]
        )

        let merged = left.merging(right)

        XCTAssertEqual(merged.analysisRuns.count, 1)
        XCTAssertEqual(merged.statusRaw, StoredCaseStatus.needsReview.rawValue)
        XCTAssertNotNil(merged.reviewReason)
    }

    func testArchiveMergeKeepsSelectedScreenshotAndBytesPaired() throws {
        let caseID = UUID()
        let firstImage = Data("first-image".utf8)
        let secondImage = Data("second-image".utf8)
        let first = CloudCaseArchive(
            manifest: makeManifest(caseID: caseID, image: firstImage),
            originalImageData: firstImage,
            diagnosticImageData: Data("first-diagnostic".utf8)
        )
        let second = CloudCaseArchive(
            manifest: makeManifest(
                caseID: caseID,
                modifiedAt: Date(timeIntervalSince1970: 101),
                image: secondImage
            ),
            originalImageData: secondImage,
            diagnosticImageData: Data("second-diagnostic".utf8)
        )

        let merged = first.merging(second)

        XCTAssertNoThrow(try merged.validate())
        XCTAssertEqual(sha256(try XCTUnwrap(merged.originalImageData)), merged.manifest.screenshot?.sha256)
        XCTAssertEqual(merged.manifest.statusRaw, StoredCaseStatus.needsReview.rawValue)
    }

    func testValidationRejectsTamperedRunPayload() {
        let badRun = CloudAnalysisRun(
            id: UUID(),
            createdAt: Date(timeIntervalSince1970: 1),
            algorithmVersion: "test",
            visionRevision: 1,
            statusRaw: StoredCaseStatus.complete.rawValue,
            encodedPayload: Data("tampered".utf8),
            payloadSHA256: sha256(Data("original".utf8))
        )
        let manifest = makeManifest(
            image: Data("screenshot".utf8),
            analysisRuns: [badRun]
        )

        XCTAssertThrowsError(try manifest.validate()) { error in
            XCTAssertEqual(
                error as? CloudCaseValidationError,
                .payloadDigestMismatch("AnalysisRun", badRun.id)
            )
        }
    }

    func testDiagnosticImageUpdateDoesNotMutateImmutableRuns() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("CloudStoreTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let container = try PersistenceFactory.makeContainer(inMemory: true)
        let fileStore = ProtectedCaseFileStore(rootOverride: root)
        let library = CaseLibraryStore(modelContainer: container, fileStore: fileStore)
        let caseID = UUID()
        let image = Data("screenshot".utf8)
        let run = analysisRun(payload: Data("analysis".utf8))
        let archive = CloudCaseArchive(
            manifest: makeManifest(
                caseID: caseID,
                image: image,
                analysisRuns: [run]
            ),
            originalImageData: image,
            diagnosticImageData: nil
        )
        try await library.mergeCloudArchive(archive)
        let runHashesBefore = try library.analysisRuns(caseID: caseID).map(\.payloadSHA256)

        let diagnostic = Data("diagnostic".utf8)
        let stored = try await library.storeDiagnosticImage(caseID: caseID, data: diagnostic)
        let exported = try await library.cloudArchive(caseID: caseID)

        XCTAssertEqual(stored.sha256, sha256(diagnostic))
        XCTAssertEqual(exported.diagnosticImageData, diagnostic)
        XCTAssertEqual(try library.analysisRuns(caseID: caseID).map(\.payloadSHA256), runHashesBefore)
    }

    private func makeManifest(
        caseID: UUID = UUID(),
        modifiedAt: Date = Date(timeIntervalSince1970: 100),
        image: Data,
        screenshotID: UUID = UUID(),
        analysisRuns: [CloudAnalysisRun] = [],
        corrections: [CloudCorrectionRevision] = []
    ) -> CloudCaseManifest {
        let screenshot = CloudScreenshotManifest(
            id: screenshotID,
            originalFilename: "fixture.png",
            uniformTypeIdentifier: "public.png",
            pixelWidth: 2_622,
            pixelHeight: 1_206,
            byteCount: image.count,
            sha256: sha256(image),
            captureTime: Date(timeIntervalSince1970: 50),
            captureTimeSourceRaw: StoredCaptureTimeSource.imageMetadata.rawValue,
            layoutProfile: "test"
        )
        return CloudCaseManifest(
            schemaVersion: CloudCaseManifest.currentSchemaVersion,
            caseID: caseID,
            title: "Fixture",
            createdAt: Date(timeIntervalSince1970: 50),
            modifiedAt: modifiedAt,
            captureTime: Date(timeIntervalSince1970: 50),
            captureTimeSourceRaw: StoredCaptureTimeSource.imageMetadata.rawValue,
            captureTimeZoneIdentifier: "Europe/Zurich",
            statusRaw: StoredCaseStatus.complete.rawValue,
            reviewReason: nil,
            screenshot: screenshot,
            activeAnalysisRunID: analysisRuns.last?.id,
            activeCorrectionRevisionID: corrections.last?.id,
            activeComputationRunID: nil,
            isDeletedTombstone: false,
            analysisRuns: analysisRuns,
            correctionRevisions: corrections,
            computationRuns: [],
            simulations: []
        )
    }

    private func analysisRun(
        id: UUID = UUID(),
        payload: Data
    ) -> CloudAnalysisRun {
        CloudAnalysisRun(
            id: id,
            createdAt: Date(timeIntervalSince1970: 60),
            algorithmVersion: "test",
            visionRevision: 1,
            statusRaw: StoredCaseStatus.complete.rawValue,
            encodedPayload: payload,
            payloadSHA256: sha256(payload)
        )
    }

    private func correction(
        analysisRunID: UUID,
        payload: Data
    ) -> CloudCorrectionRevision {
        CloudCorrectionRevision(
            id: UUID(),
            basedOnAnalysisRunID: analysisRunID,
            parentRevisionID: nil,
            createdAt: Date(timeIntervalSince1970: 70),
            encodedPayload: payload,
            payloadSHA256: sha256(payload),
            hasConflict: false
        )
    }

    private func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
