import CryptoKit
import Foundation
import Observation
import SwiftData
import UniformTypeIdentifiers

enum PersistenceFactory {
    static func makeContainer(inMemory: Bool = false) throws -> ModelContainer {
        let schema = Schema(PersistenceSchema.models)
        let configuration = ModelConfiguration(
            "InsulinOCRLocal",
            schema: schema,
            isStoredInMemoryOnly: inMemory,
            cloudKitDatabase: .none
        )
        return try ModelContainer(for: schema, configurations: [configuration])
    }
}

struct CaseImportResult: Sendable {
    let caseID: UUID
    let wasDuplicate: Bool
}

@MainActor
@Observable
final class CaseLibraryStore {
    private let modelContext: ModelContext
    private let fileStore: any CaseFileStore
    private var changeObserver: ((UUID) -> Void)?

    private(set) var cases: [CaseEntity] = []
    private(set) var isRefreshing = false
    private(set) var lastErrorMessage: String?
    var selectedCaseID: UUID?

    init(modelContainer: ModelContainer, fileStore: any CaseFileStore) {
        self.modelContext = ModelContext(modelContainer)
        self.modelContext.autosaveEnabled = false
        self.fileStore = fileStore
        refresh()
    }

    func setChangeObserver(_ observer: ((UUID) -> Void)?) {
        changeObserver = observer
    }

    func refresh() {
        isRefreshing = true
        defer { isRefreshing = false }
        do {
            let descriptor = FetchDescriptor<CaseEntity>(
                sortBy: [
                    SortDescriptor(\.captureTime, order: .reverse),
                    SortDescriptor(\.createdAt, order: .reverse)
                ]
            )
            cases = try modelContext.fetch(descriptor).filter { !$0.isDeletedTombstone }
            lastErrorMessage = nil
        } catch {
            lastErrorMessage = error.localizedDescription
        }
    }

    func caseRecord(id: UUID) -> CaseEntity? {
        cases.first { $0.id == id }
    }

    func ingest(_ queuedImport: QueuedImport) async throws -> CaseImportResult {
        if let duplicate = try screenshotAssets().first(where: { $0.sha256 == queuedImport.manifest.sha256 }),
           let existingCase = cases.first(where: { $0.id == duplicate.caseID }) {
            return CaseImportResult(caseID: existingCase.id, wasDuplicate: true)
        }

        let data = try Data(contentsOf: queuedImport.imageURL, options: [.mappedIfSafe])
        guard AppGroupImportQueue.sha256(data) == queuedImport.manifest.sha256 else {
            throw ImportQueueError.checksumMismatch
        }

        let imageMetadata = ImageMetadataReader.read(
            data: data,
            fallbackTypeIdentifier: queuedImport.manifest.uniformTypeIdentifier
        )
        let captureTime = imageMetadata?.captureTime ?? queuedImport.manifest.captureTime
        let captureSource: StoredCaptureTimeSource = imageMetadata?.captureTime == nil
            ? queuedImport.manifest.captureTimeSource
            : .imageMetadata

        let caseID = UUID()
        let assetID = UUID()
        let fileExtension = UTType(queuedImport.manifest.uniformTypeIdentifier)?.preferredFilenameExtension
            ?? queuedImport.imageURL.pathExtension
        let stored = try await fileStore.saveOriginal(
            data: data,
            caseID: caseID,
            filenameExtension: fileExtension
        )

        let title = Self.defaultTitle(captureTime: captureTime)
        let caseRecord = CaseEntity(
            id: caseID,
            title: title,
            captureTime: captureTime,
            captureTimeSource: captureSource,
            status: .queued,
            screenshotAssetID: assetID
        )
        let screenshot = ScreenshotAssetEntity(
            id: assetID,
            caseID: caseID,
            relativeOriginalPath: stored.relativePath,
            originalFilename: queuedImport.manifest.originalFilename,
            uniformTypeIdentifier: imageMetadata?.uniformTypeIdentifier
                ?? queuedImport.manifest.uniformTypeIdentifier,
            pixelWidth: imageMetadata?.pixelWidth ?? 0,
            pixelHeight: imageMetadata?.pixelHeight ?? 0,
            byteCount: stored.byteCount,
            sha256: stored.sha256,
            captureTime: captureTime,
            captureTimeSource: captureSource
        )

        modelContext.insert(caseRecord)
        modelContext.insert(screenshot)
        do {
            try modelContext.save()
            refresh()
            changeObserver?(caseID)
            return CaseImportResult(caseID: caseID, wasDuplicate: false)
        } catch {
            try? await fileStore.deleteCaseDirectory(caseID: caseID)
            throw error
        }
    }

    func screenshotAsset(caseID: UUID) throws -> ScreenshotAssetEntity? {
        try screenshotAssets().first { $0.caseID == caseID }
    }

    func screenshotData(caseID: UUID) async throws -> Data {
        guard let asset = try screenshotAsset(caseID: caseID) else {
            throw CocoaError(.fileNoSuchFile)
        }
        return try await fileStore.read(relativePath: asset.relativeOriginalPath)
    }

    func screenshotURL(caseID: UUID) async throws -> URL {
        guard let asset = try screenshotAsset(caseID: caseID) else {
            throw CocoaError(.fileNoSuchFile)
        }
        return try await fileStore.url(relativePath: asset.relativeOriginalPath)
    }

    /// Stores or replaces the derived QA overlay without modifying analysis,
    /// correction, computation, or simulation history.
    @discardableResult
    func storeDiagnosticImage(caseID: UUID, data: Data) async throws -> StoredAsset {
        guard let record = try persistentCaseRecord(id: caseID),
              !record.isDeletedTombstone,
              let asset = try screenshotAsset(caseID: caseID) else {
            throw CocoaError(.fileNoSuchFile)
        }
        let stored = try await fileStore.saveDiagnostic(
            data: data,
            caseID: caseID,
            filename: "diagnostic.png"
        )
        asset.relativeDiagnosticPath = stored.relativePath
        record.updatedAt = .now
        try modelContext.save()
        refresh()
        changeObserver?(caseID)
        return stored
    }

    func updateCaptureTime(caseID: UUID, captureTime: Date) throws {
        guard let record = caseRecord(id: caseID) else { return }
        record.captureTime = captureTime
        record.captureTimeSource = .userCorrection
        if let asset = try screenshotAsset(caseID: caseID) {
            asset.captureTime = captureTime
            asset.captureTimeSourceRaw = StoredCaptureTimeSource.userCorrection.rawValue
        }
        try modelContext.save()
        refresh()
        changeObserver?(caseID)
    }

    func updateStatus(caseID: UUID, status: StoredCaseStatus, reason: String? = nil) throws {
        guard let record = caseRecord(id: caseID) else { return }
        record.status = status
        record.reviewReason = reason
        try modelContext.save()
        refresh()
        changeObserver?(caseID)
    }

    func storeAnalysisRun<T: Encodable & Sendable>(
        caseID: UUID,
        runID: UUID,
        createdAt: Date,
        algorithmVersion: String,
        visionRevision: Int,
        status: StoredCaseStatus,
        payload: T
    ) throws {
        let encoded = try JSONEncoder.insulinOCR.encode(payload)
        let entity = AnalysisRunEntity(
            id: runID,
            caseID: caseID,
            createdAt: createdAt,
            algorithmVersion: algorithmVersion,
            visionRevision: visionRevision,
            statusRaw: status.rawValue,
            encodedPayload: encoded,
            payloadSHA256: Self.sha256(encoded)
        )
        modelContext.insert(entity)
        if let record = caseRecord(id: caseID) {
            record.activeAnalysisRunID = runID
            record.activeCorrectionRevisionID = nil
            record.activeComputationRunID = nil
            record.updatedAt = .now
            record.status = status
        }
        try modelContext.save()
        refresh()
        changeObserver?(caseID)
    }

    func storeComputationRun<T: Encodable & Sendable>(
        caseID: UUID,
        runID: UUID,
        analysisRunID: UUID,
        correctionRevisionID: UUID?,
        createdAt: Date,
        referenceTime: Date,
        modelVersion: String,
        payload: T
    ) throws {
        let encoded = try JSONEncoder.insulinOCR.encode(payload)
        let entity = ComputationRunEntity(
            id: runID,
            caseID: caseID,
            analysisRunID: analysisRunID,
            correctionRevisionID: correctionRevisionID,
            createdAt: createdAt,
            referenceTime: referenceTime,
            modelVersion: modelVersion,
            encodedPayload: encoded,
            payloadSHA256: Self.sha256(encoded)
        )
        modelContext.insert(entity)
        if let record = caseRecord(id: caseID) {
            record.activeComputationRunID = runID
            record.updatedAt = .now
        }
        try modelContext.save()
        refresh()
        changeObserver?(caseID)
    }

    func storeCorrectionRevision<T: Encodable & Sendable>(
        caseID: UUID,
        revisionID: UUID,
        analysisRunID: UUID,
        parentRevisionID: UUID?,
        createdAt: Date,
        payload: T,
        hasConflict: Bool = false
    ) throws {
        let encoded = try JSONEncoder.insulinOCR.encode(payload)
        let entity = CorrectionRevisionEntity(
            id: revisionID,
            caseID: caseID,
            basedOnAnalysisRunID: analysisRunID,
            parentRevisionID: parentRevisionID,
            createdAt: createdAt,
            encodedPayload: encoded,
            payloadSHA256: Self.sha256(encoded),
            hasConflict: hasConflict
        )
        modelContext.insert(entity)
        if let record = caseRecord(id: caseID) {
            record.activeCorrectionRevisionID = revisionID
            record.updatedAt = .now
            if hasConflict {
                record.status = .needsReview
            }
        }
        try modelContext.save()
        refresh()
        changeObserver?(caseID)
    }

    func storeSimulation<T: Encodable & Sendable>(
        caseID: UUID,
        scenarioID: UUID,
        basedOnComputationRunID: UUID,
        name: String,
        createdAt: Date,
        payload: T
    ) throws {
        let encoded = try JSONEncoder.insulinOCR.encode(payload)
        let entity = SimulationScenarioEntity(
            id: scenarioID,
            caseID: caseID,
            basedOnComputationRunID: basedOnComputationRunID,
            name: name,
            createdAt: createdAt,
            encodedPayload: encoded,
            payloadSHA256: Self.sha256(encoded)
        )
        modelContext.insert(entity)
        if let record = caseRecord(id: caseID) {
            record.updatedAt = .now
        }
        try modelContext.save()
        changeObserver?(caseID)
    }

    func analysisRuns(caseID: UUID) throws -> [AnalysisRunEntity] {
        try modelContext.fetch(
            FetchDescriptor<AnalysisRunEntity>(sortBy: [SortDescriptor(\.createdAt)])
        ).filter { $0.caseID == caseID }
    }

    func computationRuns(caseID: UUID) throws -> [ComputationRunEntity] {
        try modelContext.fetch(
            FetchDescriptor<ComputationRunEntity>(sortBy: [SortDescriptor(\.createdAt)])
        ).filter { $0.caseID == caseID }
    }

    func correctionRevisions(caseID: UUID) throws -> [CorrectionRevisionEntity] {
        try modelContext.fetch(
            FetchDescriptor<CorrectionRevisionEntity>(sortBy: [SortDescriptor(\.createdAt)])
        ).filter { $0.caseID == caseID }
    }

    func simulations(caseID: UUID) throws -> [SimulationScenarioEntity] {
        try modelContext.fetch(
            FetchDescriptor<SimulationScenarioEntity>(sortBy: [SortDescriptor(\.createdAt)])
        ).filter { $0.caseID == caseID }
    }

    func allCaseIDs() throws -> [UUID] {
        try modelContext.fetch(FetchDescriptor<CaseEntity>()).map(\.id)
    }

    func deleteCase(caseID: UUID) async throws {
        guard let record = try persistentCaseRecord(id: caseID) else { return }
        record.isDeletedTombstone = true
        record.updatedAt = .now
        try purgeCasePayloads(record)
        try modelContext.save()
        refresh()
        changeObserver?(caseID)
        try await fileStore.deleteCaseDirectory(caseID: caseID)
    }

    func applyRemoteTombstone(caseID: UUID) async throws {
        let record: CaseEntity
        if let existing = try persistentCaseRecord(id: caseID) {
            record = existing
        } else {
            record = CaseEntity(
                id: caseID,
                title: "Gelöschter Case",
                captureTime: .now,
                captureTimeSource: .importTime,
                status: .needsReview
            )
            modelContext.insert(record)
        }
        record.isDeletedTombstone = true
        record.updatedAt = .now
        try purgeCasePayloads(record)
        try modelContext.save()
        try? await fileStore.deleteCaseDirectory(caseID: caseID)
        refresh()
    }

    /// Produces a complete, immutable cloud snapshot without changing the
    /// SwiftData store. The local store remains authoritative if this fails.
    func cloudArchive(caseID: UUID) async throws -> CloudCaseArchive {
        guard let record = try persistentCaseRecord(id: caseID) else {
            throw CocoaError(.fileNoSuchFile)
        }
        let asset = try screenshotAsset(caseID: caseID)
        let screenshotManifest = asset.map {
            CloudScreenshotManifest(
                id: $0.id,
                originalFilename: $0.originalFilename,
                uniformTypeIdentifier: $0.uniformTypeIdentifier,
                pixelWidth: $0.pixelWidth,
                pixelHeight: $0.pixelHeight,
                byteCount: $0.byteCount,
                sha256: $0.sha256,
                captureTime: $0.captureTime,
                captureTimeSourceRaw: $0.captureTimeSourceRaw,
                layoutProfile: $0.layoutProfile
            )
        }
        let analysis = try analysisRuns(caseID: caseID).map {
            CloudAnalysisRun(
                id: $0.id,
                createdAt: $0.createdAt,
                algorithmVersion: $0.algorithmVersion,
                visionRevision: $0.visionRevision,
                statusRaw: $0.statusRaw,
                encodedPayload: $0.encodedPayload,
                payloadSHA256: $0.payloadSHA256
            )
        }
        let corrections = try correctionRevisions(caseID: caseID).map {
            CloudCorrectionRevision(
                id: $0.id,
                basedOnAnalysisRunID: $0.basedOnAnalysisRunID,
                parentRevisionID: $0.parentRevisionID,
                createdAt: $0.createdAt,
                encodedPayload: $0.encodedPayload,
                payloadSHA256: $0.payloadSHA256,
                hasConflict: $0.hasConflict
            )
        }
        let computations = try computationRuns(caseID: caseID).map {
            CloudComputationRun(
                id: $0.id,
                analysisRunID: $0.analysisRunID,
                correctionRevisionID: $0.correctionRevisionID,
                createdAt: $0.createdAt,
                referenceTime: $0.referenceTime,
                modelVersion: $0.modelVersion,
                encodedPayload: $0.encodedPayload,
                payloadSHA256: $0.payloadSHA256
            )
        }
        let scenarios = try simulations(caseID: caseID).map {
            CloudSimulationScenario(
                id: $0.id,
                basedOnComputationRunID: $0.basedOnComputationRunID,
                name: $0.name,
                createdAt: $0.createdAt,
                updatedAt: $0.updatedAt,
                encodedPayload: $0.encodedPayload,
                payloadSHA256: $0.payloadSHA256
            )
        }
        let manifest = CloudCaseManifest(
            schemaVersion: CloudCaseManifest.currentSchemaVersion,
            caseID: record.id,
            title: record.title,
            createdAt: record.createdAt,
            modifiedAt: record.updatedAt,
            captureTime: record.captureTime,
            captureTimeSourceRaw: record.captureTimeSourceRaw,
            captureTimeZoneIdentifier: record.captureTimeZoneIdentifier,
            statusRaw: record.statusRaw,
            reviewReason: record.reviewReason,
            screenshot: screenshotManifest,
            activeAnalysisRunID: record.activeAnalysisRunID,
            activeCorrectionRevisionID: record.activeCorrectionRevisionID,
            activeComputationRunID: record.activeComputationRunID,
            isDeletedTombstone: record.isDeletedTombstone,
            analysisRuns: analysis,
            correctionRevisions: corrections,
            computationRuns: computations,
            simulations: scenarios
        )
        let originalData: Data? = if record.isDeletedTombstone {
            nil
        } else if let asset {
            try await fileStore.read(relativePath: asset.relativeOriginalPath)
        } else {
            nil
        }
        let diagnosticData: Data? = if record.isDeletedTombstone {
            nil
        } else if let path = asset?.relativeDiagnosticPath {
            try await fileStore.read(relativePath: path)
        } else {
            nil
        }
        return CloudCaseArchive(
            manifest: manifest,
            originalImageData: originalData,
            diagnosticImageData: diagnosticData
        )
    }

    /// Merges an incoming device snapshot. Existing immutable payloads are
    /// never overwritten; conflicts remain in history and mark the case for
    /// review. The caller can safely retry this method after interruption.
    func mergeCloudArchive(_ archive: CloudCaseArchive) async throws {
        try archive.validate()
        let remote = archive.manifest
        guard remote.schemaVersion == CloudCaseManifest.currentSchemaVersion else {
            throw CocoaError(.fileReadUnsupportedScheme)
        }

        let localRecord = try persistentCaseRecord(id: remote.caseID)
        let localArchive: CloudCaseArchive?
        if localRecord != nil {
            localArchive = try await cloudArchive(caseID: remote.caseID)
        } else {
            localArchive = nil
        }
        let mergedArchive = localArchive?.merging(archive) ?? archive
        try mergedArchive.validate()
        let merged = mergedArchive.manifest

        let record: CaseEntity
        if let localRecord {
            record = localRecord
        } else {
            record = CaseEntity(
                id: merged.caseID,
                title: merged.title,
                createdAt: merged.createdAt,
                captureTime: merged.captureTime,
                captureTimeSource: StoredCaptureTimeSource(rawValue: merged.captureTimeSourceRaw) ?? .importTime,
                captureTimeZoneIdentifier: merged.captureTimeZoneIdentifier,
                status: StoredCaseStatus(rawValue: merged.statusRaw) ?? .needsReview,
                screenshotAssetID: merged.screenshot?.id
            )
            modelContext.insert(record)
        }

        record.title = merged.title
        record.updatedAt = merged.modifiedAt
        record.captureTime = merged.captureTime
        record.captureTimeSourceRaw = merged.captureTimeSourceRaw
        record.captureTimeZoneIdentifier = merged.captureTimeZoneIdentifier
        record.statusRaw = merged.statusRaw
        record.reviewReason = merged.reviewReason
        record.screenshotAssetID = merged.screenshot?.id
        record.activeAnalysisRunID = merged.activeAnalysisRunID
        record.activeCorrectionRevisionID = merged.activeCorrectionRevisionID
        record.activeComputationRunID = merged.activeComputationRunID
        record.isDeletedTombstone = merged.isDeletedTombstone

        if merged.isDeletedTombstone {
            try purgeCasePayloads(record)
            try modelContext.save()
            try? await fileStore.deleteCaseDirectory(caseID: merged.caseID)
            refresh()
            return
        }

        if let metadata = merged.screenshot {
            try await mergeScreenshot(
                metadata,
                caseID: merged.caseID,
                originalImageData: mergedArchive.originalImageData,
                diagnosticImageData: mergedArchive.diagnosticImageData
            )
        }
        try mergeAnalysisRuns(merged.analysisRuns, caseID: merged.caseID)
        try mergeCorrectionRevisions(merged.correctionRevisions, caseID: merged.caseID)
        try mergeComputationRuns(merged.computationRuns, caseID: merged.caseID)
        try mergeSimulations(merged.simulations, caseID: merged.caseID)
        try modelContext.save()
        refresh()
    }

    private func purgeCasePayloads(_ record: CaseEntity) throws {
        for run in try analysisRuns(caseID: record.id) { modelContext.delete(run) }
        for run in try computationRuns(caseID: record.id) { modelContext.delete(run) }
        for revision in try correctionRevisions(caseID: record.id) { modelContext.delete(revision) }
        for scenario in try simulations(caseID: record.id) { modelContext.delete(scenario) }
        if let asset = try screenshotAsset(caseID: record.id) { modelContext.delete(asset) }
        record.title = "Gelöschter Case"
        record.reviewReason = nil
        record.screenshotAssetID = nil
        record.activeAnalysisRunID = nil
        record.activeCorrectionRevisionID = nil
        record.activeComputationRunID = nil
    }

    private func screenshotAssets() throws -> [ScreenshotAssetEntity] {
        try modelContext.fetch(FetchDescriptor<ScreenshotAssetEntity>())
    }

    private func persistentCaseRecord(id: UUID) throws -> CaseEntity? {
        try modelContext.fetch(FetchDescriptor<CaseEntity>()).first { $0.id == id }
    }

    private func mergeScreenshot(
        _ metadata: CloudScreenshotManifest,
        caseID: UUID,
        originalImageData: Data?,
        diagnosticImageData: Data?
    ) async throws {
        let existing = try screenshotAsset(caseID: caseID)
        if let existing {
            if existing.sha256 != metadata.sha256 {
                guard let originalImageData else {
                    throw CocoaError(.fileReadNoSuchFile)
                }
                let baseExtension = UTType(metadata.uniformTypeIdentifier)?.preferredFilenameExtension ?? "img"
                let fileExtension = "\(metadata.sha256.prefix(12)).\(baseExtension)"
                let stored = try await fileStore.saveOriginal(
                    data: originalImageData,
                    caseID: caseID,
                    filenameExtension: fileExtension
                )
                guard stored.sha256 == metadata.sha256,
                      stored.byteCount == metadata.byteCount else {
                    throw ImportQueueError.checksumMismatch
                }
                existing.relativeOriginalPath = stored.relativePath
            }
            existing.id = metadata.id
            existing.originalFilename = metadata.originalFilename
            existing.uniformTypeIdentifier = metadata.uniformTypeIdentifier
            existing.pixelWidth = metadata.pixelWidth
            existing.pixelHeight = metadata.pixelHeight
            existing.byteCount = metadata.byteCount
            existing.sha256 = metadata.sha256
            existing.captureTime = metadata.captureTime
            existing.captureTimeSourceRaw = metadata.captureTimeSourceRaw
            existing.layoutProfile = metadata.layoutProfile
            if let diagnosticImageData {
                let stored = try await fileStore.saveDiagnostic(
                    data: diagnosticImageData,
                    caseID: caseID,
                    filename: "diagnostic.png"
                )
                existing.relativeDiagnosticPath = stored.relativePath
            }
            return
        }

        guard let originalImageData else {
            throw CocoaError(.fileReadNoSuchFile)
        }
        let fileExtension = UTType(metadata.uniformTypeIdentifier)?.preferredFilenameExtension ?? "img"
        let stored = try await fileStore.saveOriginal(
            data: originalImageData,
            caseID: caseID,
            filenameExtension: fileExtension
        )
        guard stored.sha256 == metadata.sha256 else {
            try? await fileStore.deleteCaseDirectory(caseID: caseID)
            throw ImportQueueError.checksumMismatch
        }
        let entity = ScreenshotAssetEntity(
            id: metadata.id,
            caseID: caseID,
            relativeOriginalPath: stored.relativePath,
            originalFilename: metadata.originalFilename,
            uniformTypeIdentifier: metadata.uniformTypeIdentifier,
            pixelWidth: metadata.pixelWidth,
            pixelHeight: metadata.pixelHeight,
            byteCount: stored.byteCount,
            sha256: stored.sha256,
            captureTime: metadata.captureTime,
            captureTimeSource: StoredCaptureTimeSource(rawValue: metadata.captureTimeSourceRaw) ?? .importTime
        )
        entity.layoutProfile = metadata.layoutProfile
        if let diagnosticImageData {
            let diagnostic = try await fileStore.saveDiagnostic(
                data: diagnosticImageData,
                caseID: caseID,
                filename: "diagnostic.png"
            )
            entity.relativeDiagnosticPath = diagnostic.relativePath
        }
        modelContext.insert(entity)
    }

    private func mergeAnalysisRuns(_ runs: [CloudAnalysisRun], caseID: UUID) throws {
        var existing = Set(try analysisRuns(caseID: caseID).map(\.id))
        for run in runs where existing.insert(run.id).inserted {
            modelContext.insert(
                AnalysisRunEntity(
                    id: run.id,
                    caseID: caseID,
                    createdAt: run.createdAt,
                    algorithmVersion: run.algorithmVersion,
                    visionRevision: run.visionRevision,
                    statusRaw: run.statusRaw,
                    encodedPayload: run.encodedPayload,
                    payloadSHA256: run.payloadSHA256
                )
            )
        }
    }

    private func mergeCorrectionRevisions(
        _ revisions: [CloudCorrectionRevision],
        caseID: UUID
    ) throws {
        let local = try correctionRevisions(caseID: caseID)
        var byID = Dictionary(uniqueKeysWithValues: local.map { ($0.id, $0) })
        for revision in revisions {
            if let existing = byID[revision.id] {
                existing.hasConflict = existing.hasConflict || revision.hasConflict
            } else {
                let entity = CorrectionRevisionEntity(
                    id: revision.id,
                    caseID: caseID,
                    basedOnAnalysisRunID: revision.basedOnAnalysisRunID,
                    parentRevisionID: revision.parentRevisionID,
                    createdAt: revision.createdAt,
                    encodedPayload: revision.encodedPayload,
                    payloadSHA256: revision.payloadSHA256,
                    hasConflict: revision.hasConflict
                )
                modelContext.insert(entity)
                byID[revision.id] = entity
            }
        }
    }

    private func mergeComputationRuns(_ runs: [CloudComputationRun], caseID: UUID) throws {
        var existing = Set(try computationRuns(caseID: caseID).map(\.id))
        for run in runs where existing.insert(run.id).inserted {
            modelContext.insert(
                ComputationRunEntity(
                    id: run.id,
                    caseID: caseID,
                    analysisRunID: run.analysisRunID,
                    correctionRevisionID: run.correctionRevisionID,
                    createdAt: run.createdAt,
                    referenceTime: run.referenceTime,
                    modelVersion: run.modelVersion,
                    encodedPayload: run.encodedPayload,
                    payloadSHA256: run.payloadSHA256
                )
            )
        }
    }

    private func mergeSimulations(_ scenarios: [CloudSimulationScenario], caseID: UUID) throws {
        var existing = Set(try simulations(caseID: caseID).map(\.id))
        for scenario in scenarios where existing.insert(scenario.id).inserted {
            let entity = SimulationScenarioEntity(
                id: scenario.id,
                caseID: caseID,
                basedOnComputationRunID: scenario.basedOnComputationRunID,
                name: scenario.name,
                createdAt: scenario.createdAt,
                encodedPayload: scenario.encodedPayload,
                payloadSHA256: scenario.payloadSHA256
            )
            entity.updatedAt = scenario.updatedAt
            modelContext.insert(entity)
        }
    }

    private static func defaultTitle(captureTime: Date) -> String {
        "Case \(captureTime.formatted(date: .numeric, time: .shortened))"
    }

    private static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
