import Foundation
import InsulinOCRCore
import Observation
import PhotosUI
import SwiftData
import UniformTypeIdentifiers

@MainActor
@Observable
final class AppModel {
    let settings: AppSettings
    let fileStore: ProtectedCaseFileStore
    let importQueue: AppGroupImportQueue
    let cloudSyncService: CloudSyncService
    private let analysisEngine = NativeAnalysisEngine()
    private let diagnosticRenderer = DiagnosticImageRenderer()
    private let reducer = DefaultEffectiveDataReducer()
    private let activityCalculator = DefaultActivityCalculator()

    private(set) var library: CaseLibraryStore?
    private(set) var bootstrapError: String?
    private(set) var isProcessingImports = false
    private(set) var importNotice: String?

    init(inMemory: Bool = false) {
        if ProcessInfo.processInfo.arguments.contains("-ui-testing-reset"),
           let identifier = Bundle.main.bundleIdentifier {
            UserDefaults.standard.removePersistentDomain(forName: identifier)
        }
        let settings = AppSettings()
        let fileStore = ProtectedCaseFileStore()
        let importQueue = AppGroupImportQueue()
        self.settings = settings
        self.fileStore = fileStore
        self.importQueue = importQueue
        self.cloudSyncService = CloudSyncService(containerIdentifier: BuildConfiguration.cloudKitContainerIdentifier)

        do {
            let container = try PersistenceFactory.makeContainer(inMemory: inMemory)
            let library = CaseLibraryStore(modelContainer: container, fileStore: fileStore)
            self.library = library
            // A newly created AppModel has no running analysis tasks. Persisted
            // analyzing states therefore belong to an interrupted process.
            for interrupted in library.cases.filter({ $0.status == .analyzing }) {
                try library.updateStatus(caseID: interrupted.id, status: .queued)
            }
            library.setChangeObserver { [weak self] caseID in
                Task { @MainActor [weak self] in
                    await self?.mirrorCaseIfEnabled(caseID: caseID)
                }
            }
        } catch {
            self.bootstrapError = error.localizedDescription
        }
    }

    func processPendingImports() async {
        guard let library, !isProcessingImports else { return }
        isProcessingImports = true
        defer { isProcessingImports = false }

        do {
            let pending = try await importQueue.pendingImports()
            var importedCount = 0
            var duplicateCount = 0
            for item in pending {
                let result = try await library.ingest(item)
                if result.wasDuplicate {
                    duplicateCount += 1
                } else {
                    importedCount += 1
                    try library.updateStatus(caseID: result.caseID, status: .queued)
                }
                try await importQueue.remove(item)
            }

            if importedCount > 0 || duplicateCount > 0 {
                var components: [String] = []
                if importedCount > 0 {
                    components.append("\(importedCount) Case importiert")
                }
                if duplicateCount > 0 {
                    components.append("\(duplicateCount) Duplikat übersprungen")
                }
                importNotice = components.joined(separator: ", ")
            }

            guard settings.onboardingComplete else { return }
            await analyzeQueuedCases()
        } catch {
            importNotice = error.localizedDescription
        }
    }

    func importImageData(
        _ data: Data,
        suggestedName: String,
        typeIdentifier: String,
        fileCaptureTime: Date? = nil
    ) async {
        let metadata = ImageMetadataReader.read(data: data, fallbackTypeIdentifier: typeIdentifier)
        do {
            _ = try await importQueue.enqueue(
                imageData: data,
                originalFilename: suggestedName,
                uniformTypeIdentifier: metadata?.uniformTypeIdentifier ?? typeIdentifier,
                captureTime: metadata?.captureTime ?? fileCaptureTime ?? .now,
                captureTimeSource: metadata?.captureTime != nil
                    ? .imageMetadata
                    : (fileCaptureTime != nil ? .fileMetadata : .importTime)
            )
            await processPendingImports()
        } catch {
            importNotice = error.localizedDescription
        }
    }

    func onboardingCompleted(diaMinutes: Int, insulinPreset: StoredInsulinPreset) {
        settings.completeOnboarding(diaMinutes: diaMinutes, insulinPreset: insulinPreset)
        Task { await processPendingImports() }
    }

    func applyCloudPreference() async {
        do {
            if settings.iCloudEnabled {
                await cloudSyncService.setRemoteChangeHandler { [weak self] change in
                    guard let self else { return }
                    try await self.applyRemoteCloudChange(change)
                }
                try await cloudSyncService.start()
                guard settings.iCloudEnabled else {
                    await cloudSyncService.stop()
                    await cloudSyncService.setRemoteChangeHandler(nil)
                    return
                }
                await mirrorAllCases()
            } else {
                await cloudSyncService.stop()
                await cloudSyncService.setRemoteChangeHandler(nil)
            }
        } catch {
            await cloudSyncService.stop()
            await cloudSyncService.setRemoteChangeHandler(nil)
            importNotice = error.localizedDescription
            settings.iCloudEnabled = false
        }
    }

    func dismissNotice() {
        importNotice = nil
    }

    private func mirrorAllCases() async {
        guard let library else { return }
        do {
            for caseID in try library.allCaseIDs() {
                let archive = try await library.cloudArchive(caseID: caseID)
                try await cloudSyncService.enqueue(archive)
            }
        } catch {
            importNotice = "iCloud-Synchronisierung: \(error.localizedDescription)"
        }
    }

    private func mirrorCaseIfEnabled(caseID: UUID) async {
        guard settings.iCloudEnabled,
              await cloudSyncService.state() == .syncing,
              let library else { return }
        do {
            let archive = try await library.cloudArchive(caseID: caseID)
            try await cloudSyncService.enqueue(archive)
        } catch {
            importNotice = "iCloud-Synchronisierung: \(error.localizedDescription)"
        }
    }

    private func applyRemoteCloudChange(_ change: CloudRemoteChange) async throws {
        guard settings.iCloudEnabled else {
            throw CloudSyncServiceError.disabled
        }
        guard let library else { return }
        switch change {
        case .merge(let archive):
            try await library.mergeCloudArchive(archive)
            let localArchive = try await library.cloudArchive(caseID: archive.manifest.caseID)
            if localArchive.manifest != archive.manifest
                || (archive.diagnosticImageData == nil && localArchive.diagnosticImageData != nil) {
                try await cloudSyncService.enqueue(localArchive)
            }
        case .tombstone(let caseID):
            try await library.applyRemoteTombstone(caseID: caseID)
            let tombstone = try await library.cloudArchive(caseID: caseID)
            try await cloudSyncService.enqueue(tombstone)
        }
    }

    private func analyzeQueuedCases() async {
        guard let library else { return }
        let queued = library.cases.filter { $0.status == .queued }
        for record in queued {
            await analyze(record: record)
        }
    }

    func reanalyzeCase(caseID: UUID) async {
        guard settings.onboardingComplete,
              let record = library?.caseRecord(id: caseID),
              record.status != .analyzing else { return }
        await analyze(record: record)
    }

    func recomputeCase(caseID: UUID) async {
        guard let library,
              let record = library.caseRecord(id: caseID),
              let analysisID = record.activeAnalysisRunID,
              let analysisEntity = try? library.analysisRuns(caseID: caseID).first(where: { $0.id == analysisID }),
              let analysisEnvelope = try? JSONDecoder.insulinOCR.decode(
                  StoredAnalysisEnvelope.self,
                  from: analysisEntity.encodedPayload
              ) else {
            return
        }
        do {
            guard try library.correctionRevisions(caseID: caseID).allSatisfy({ !$0.hasConflict }) else {
                try library.updateStatus(caseID: caseID, status: .needsReview, reason: "Konkurrierende Korrekturen müssen zuerst geprüft werden.")
                return
            }
            let revisions = try library.correctionRevisions(caseID: caseID)
                .compactMap { try? JSONDecoder.insulinOCR.decode(CorrectionRevision.self, from: $0.encodedPayload) }
                .filter { $0.analysisRunID == analysisEnvelope.run.id }
            try computeAndStore(
                record: record,
                analysisRun: analysisEnvelope.run,
                revisions: revisions
            )
        } catch {
            try? library.updateStatus(caseID: caseID, status: .failed, reason: error.localizedDescription)
        }
    }

    func applyCorrection(_ revision: CorrectionRevision) async throws {
        guard let library,
              let record = library.caseRecord(id: revision.caseID) else {
            throw CocoaError(.fileNoSuchFile)
        }
        try library.storeCorrectionRevision(
            caseID: revision.caseID,
            revisionID: revision.id,
            analysisRunID: revision.analysisRunID,
            parentRevisionID: revision.parentRevisionID,
            createdAt: revision.createdAt,
            payload: revision
        )
        await recomputeCase(caseID: record.id)
    }

    private func analyze(record: CaseEntity) async {
        guard let library else { return }
        do {
            try library.updateStatus(caseID: record.id, status: .analyzing)
            let data = try await library.screenshotData(caseID: record.id)
            let request = ScreenshotAnalysisRequest(
                imageData: data,
                capturedAt: record.captureTime,
                importedAt: record.createdAt,
                timeZoneIdentifier: record.captureTimeZoneIdentifier
            )
            let extractorResult = try await analysisEngine.analyze(request)
            let analysisRun = extractorResult.makeAnalysisRun(caseID: record.id)
            if let diagnostic = try? await diagnosticRenderer.render(originalData: data, result: extractorResult) {
                _ = try? await library.storeDiagnosticImage(caseID: record.id, data: diagnostic)
            }
            let analysisStatus: StoredCaseStatus = extractorResult.status == .complete
                ? .complete
                : .needsReview
            let envelope = StoredAnalysisEnvelope(run: analysisRun, extractorResult: extractorResult)
            try library.storeAnalysisRun(
                caseID: record.id,
                runID: analysisRun.id,
                createdAt: analysisRun.createdAt,
                algorithmVersion: analysisRun.algorithmVersion,
                visionRevision: analysisRun.visionRevision,
                status: analysisStatus,
                payload: envelope
            )
            try computeAndStore(record: record, analysisRun: analysisRun, revisions: [])
        } catch let failure as OCRAnalysisFailure {
            switch failure {
            case .unsupportedLayout:
                try? library.updateStatus(
                    caseID: record.id,
                    status: .unsupportedLayout,
                    reason: failure.localizedDescription
                )
            case .invalidTimeAxis:
                try? library.updateStatus(
                    caseID: record.id,
                    status: .incomplete,
                    reason: failure.localizedDescription
                )
            case .invalidImage, .cancelled:
                try? library.updateStatus(
                    caseID: record.id,
                    status: .failed,
                    reason: failure.localizedDescription
                )
            }
        } catch {
            try? library.updateStatus(caseID: record.id, status: .failed, reason: error.localizedDescription)
        }
    }

    private func computeAndStore(
        record: CaseEntity,
        analysisRun: AnalysisRun,
        revisions: [CorrectionRevision]
    ) throws {
        guard let library else { return }
        let effectiveData = try reducer.reduce(analysisRun: analysisRun, revisions: revisions)
        let therapySettings = try makeTherapySettings()
        let result = activityCalculator.calculate(
            data: effectiveData,
            settings: therapySettings,
            referenceDate: record.captureTime,
            forecastStepMinutes: 5
        )
        let run = ComputationRun(
            caseID: record.id,
            analysisRunID: analysisRun.id,
            correctionRevisionID: revisions.last?.id,
            referenceDate: record.captureTime,
            modelVersion: DefaultActivityCalculator.modelVersion,
            settings: therapySettings,
            result: result
        )
        let presentation = Self.makePresentation(
            run: run,
            effectiveData: effectiveData,
            analysisRun: analysisRun
        )
        let envelope = StoredComputationEnvelope(
            run: run,
            effectiveData: effectiveData,
            presentation: presentation
        )
        try library.storeComputationRun(
            caseID: record.id,
            runID: run.id,
            analysisRunID: analysisRun.id,
            correctionRevisionID: revisions.last?.id,
            createdAt: run.createdAt,
            referenceTime: record.captureTime,
            modelVersion: run.modelVersion,
            payload: envelope
        )
        let status: StoredCaseStatus = presentation.isComplete ? .complete : .needsReview
        let reason = presentation.unavailableReasons.first
        try library.updateStatus(caseID: record.id, status: status, reason: reason)
    }

    private func makeTherapySettings() throws -> TherapySettings {
        let insulinType: InsulinType = switch settings.insulinPreset {
        case .novoRapid: .novoRapid
        case .fiasp: .fiasp
        case .lyumjev: .lyumjev
        }
        let glucoseUnit: GlucoseUnit = settings.glucoseUnit == .mmolL
            ? .millimolesPerLiter
            : .milligramsPerDeciliter
        return try TherapySettings(
            diaMinutes: settings.diaMinutes,
            insulinType: insulinType,
            carbAbsorptionMinutes: settings.carbAbsorptionMinutes,
            glucoseUnit: glucoseUnit
        )
    }

    nonisolated private static func makePresentation(
        run: ComputationRun,
        effectiveData: EffectiveTherapyData,
        analysisRun: AnalysisRun
    ) -> StoredCasePresentation {
        let observationConfidence = Dictionary(
            uniqueKeysWithValues: analysisRun.observations.map { ($0.id, $0.confidence.overall) }
        )
        let reasons = [
            run.result.current.basalIOB,
            run.result.current.bolusIOB,
            run.result.current.totalIOB,
            run.result.current.cob,
        ].compactMap { result -> String? in
            guard case .unavailable(let reason) = result else { return nil }
            return Self.localizedUnavailableReason(reason)
        }
        let isComplete = reasons.isEmpty

        let glucose = effectiveData.glucoseSamples.map { sample in
            let mmol = sample.unit == .millimolesPerLiter ? sample.value : sample.value / 18.0
            return StoredCasePresentation.GlucosePoint(
                id: sample.id,
                timestamp: sample.date,
                mmolL: mmol,
                confidence: sample.sourceObservationID.flatMap { observationConfidence[$0] } ?? 1
            )
        }
        let insulinWindowStart = run.referenceDate.addingTimeInterval(-Double(run.settings.diaMinutes) * 60)
        let basal = effectiveData.basalSegments.filter {
            $0.endDate > insulinWindowStart && $0.startDate < run.referenceDate
        }.flatMap { segment in
            let confidence = segment.sourceObservationID.flatMap { observationConfidence[$0] } ?? 1
            return [
                StoredCasePresentation.BasalPoint(
                    id: UUID(),
                    timestamp: max(segment.startDate, insulinWindowStart),
                    unitsPerHour: segment.unitsPerHour,
                    confidence: confidence
                ),
                StoredCasePresentation.BasalPoint(
                    id: UUID(),
                    timestamp: min(segment.endDate, run.referenceDate),
                    unitsPerHour: segment.unitsPerHour,
                    confidence: confidence
                ),
            ]
        }
        let bolusEvents = effectiveData.boluses.filter { event in
            let age = run.referenceDate.timeIntervalSince(event.date) / 60
            return age >= 0 && InsulinActivityModel.remainingUnits(
                units: event.units,
                minutes: age,
                durationMinutes: Double(run.settings.diaMinutes),
                peakMinutes: run.settings.insulinType.peakMinutes
            ) > 0
        }.map { event in
            StoredCasePresentation.EventPoint(
                id: event.id,
                timestamp: event.date,
                kind: .bolus,
                amount: event.units,
                confidence: event.sourceObservationID.flatMap { observationConfidence[$0] } ?? 1
            )
        }
        let carbohydrateEvents = effectiveData.carbohydrates.filter { event in
            let age = run.referenceDate.timeIntervalSince(event.date) / 60
            return age >= 0 && CarbohydrateAbsorptionModel.remainingGrams(
                grams: event.grams,
                minutes: age,
                absorptionDurationMinutes: Double(run.settings.carbAbsorptionMinutes)
            ) > 0
        }.map { event in
            StoredCasePresentation.EventPoint(
                id: event.id,
                timestamp: event.date,
                kind: .carbohydrate,
                amount: event.grams,
                confidence: event.sourceObservationID.flatMap { observationConfidence[$0] } ?? 1
            )
        }
        let allSnapshots = [run.result.current] + run.result.forecast
        let decay: [StoredCasePresentation.DecayPoint] = isComplete
            ? allSnapshots.compactMap { snapshot in
                guard let basal = snapshot.basalIOB.value,
                      let bolus = snapshot.bolusIOB.value,
                      let total = snapshot.totalIOB.value,
                      let cob = snapshot.cob.value else { return nil }
                return .init(
                    id: UUID(),
                    timestamp: snapshot.date,
                    basalIOB: basal,
                    bolusIOB: bolus,
                    totalIOB: total,
                    carbohydratesOnBoard: cob
                )
            }
            : []

        return StoredCasePresentation(
            referenceTime: run.referenceDate,
            isComplete: isComplete,
            unavailableReasons: Array(Set(reasons)).sorted(),
            metrics: .init(
                basalIOB: isComplete ? run.result.current.basalIOB.value : nil,
                bolusIOB: isComplete ? run.result.current.bolusIOB.value : nil,
                totalIOB: isComplete ? run.result.current.totalIOB.value : nil,
                activeCarbohydrates: isComplete ? run.result.current.cob.value : nil
            ),
            glucose: glucose,
            basal: basal,
            events: (bolusEvents + carbohydrateEvents).sorted { $0.timestamp < $1.timestamp },
            decay: decay
        )
    }

    nonisolated private static func localizedUnavailableReason(
        _ reason: MetricUnavailableReason
    ) -> String {
        switch reason {
        case .invalidModelParameters: "Ungültige Modellparameter"
        case .invalidTimeAxis: "Zeitachse nicht sicher kalibriert"
        case .invalidBasalAxis: "Basalachse nicht sicher kalibriert"
        case .incompleteBasalPath: "Basalpfad unvollständig"
        case .unknownBolusAmount: "Bolusmenge unbekannt"
        case .unknownCarbohydrateAmount: "Kohlenhydratmenge unbekannt"
        case .unclassifiedEvent: "Ereignis nicht eindeutig klassifiziert"
        case .insufficientHistory: "Screenshot deckt das Wirkungsfenster nicht vollständig ab"
        }
    }
}
