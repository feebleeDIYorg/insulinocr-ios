import CryptoKit
import Foundation
import InsulinOCRCore
import UniformTypeIdentifiers
import ZIPFoundation

struct VersionedArchivePayload: Codable, Sendable {
    let id: UUID
    let createdAt: Date
    let sha256: String
    let data: Data
}

struct CaseArchiveSnapshot: Sendable {
    struct Metadata: Codable, Sendable {
        let id: UUID
        let title: String
        let captureTime: Date
        let captureTimeSource: String
        let captureTimeZoneIdentifier: String
        let status: String
        let reviewReason: String?
        let activeAnalysisRunID: UUID?
        let activeCorrectionRevisionID: UUID?
        let activeComputationRunID: UUID?
    }

    struct Screenshot: Codable, Sendable {
        let id: UUID
        let originalFilename: String
        let uniformTypeIdentifier: String
        let pixelWidth: Int
        let pixelHeight: Int
        let byteCount: Int
        let sha256: String
    }

    let metadata: Metadata
    let screenshot: Screenshot
    let originalData: Data
    let diagnosticData: Data?
    let analysisRuns: [VersionedArchivePayload]
    let correctionRevisions: [VersionedArchivePayload]
    let computationRuns: [VersionedArchivePayload]
    let simulations: [VersionedArchivePayload]
    let effectiveData: EffectiveTherapyData?
    let activeAnalysis: AnalysisRun?

    @MainActor
    static func make(
        caseID: UUID,
        library: CaseLibraryStore,
        fileStore: any CaseFileStore
    ) async throws -> CaseArchiveSnapshot {
        guard let record = library.caseRecord(id: caseID),
              let asset = try library.screenshotAsset(caseID: caseID) else {
            throw CocoaError(.fileNoSuchFile)
        }

        let original = try await fileStore.read(relativePath: asset.relativeOriginalPath)
        let diagnostic: Data?
        if let path = asset.relativeDiagnosticPath {
            diagnostic = try? await fileStore.read(relativePath: path)
        } else {
            diagnostic = nil
        }

        let analysisEntities = try library.analysisRuns(caseID: caseID)
        let computationEntities = try library.computationRuns(caseID: caseID)
        let correctionEntities = try library.correctionRevisions(caseID: caseID)
        let simulationEntities = try library.simulations(caseID: caseID)

        let activeAnalysis = record.activeAnalysisRunID.flatMap { activeID in
            analysisEntities.first(where: { $0.id == activeID }).flatMap {
                if let envelope = try? JSONDecoder.insulinOCR.decode(
                    StoredAnalysisEnvelope.self,
                    from: $0.encodedPayload
                ) {
                    return envelope.run
                }
                return try? JSONDecoder.insulinOCR.decode(AnalysisRun.self, from: $0.encodedPayload)
            }
        }
        let activeEnvelope = record.activeComputationRunID.flatMap { activeID in
            computationEntities.first(where: { $0.id == activeID }).flatMap {
                try? JSONDecoder.insulinOCR.decode(StoredComputationEnvelope.self, from: $0.encodedPayload)
            }
        }

        return CaseArchiveSnapshot(
            metadata: Metadata(
                id: record.id,
                title: record.title,
                captureTime: record.captureTime,
                captureTimeSource: record.captureTimeSourceRaw,
                captureTimeZoneIdentifier: record.captureTimeZoneIdentifier,
                status: record.statusRaw,
                reviewReason: record.reviewReason,
                activeAnalysisRunID: record.activeAnalysisRunID,
                activeCorrectionRevisionID: record.activeCorrectionRevisionID,
                activeComputationRunID: record.activeComputationRunID
            ),
            screenshot: Screenshot(
                id: asset.id,
                originalFilename: asset.originalFilename,
                uniformTypeIdentifier: asset.uniformTypeIdentifier,
                pixelWidth: asset.pixelWidth,
                pixelHeight: asset.pixelHeight,
                byteCount: asset.byteCount,
                sha256: asset.sha256
            ),
            originalData: original,
            diagnosticData: diagnostic,
            analysisRuns: analysisEntities.map {
                VersionedArchivePayload(id: $0.id, createdAt: $0.createdAt, sha256: $0.payloadSHA256, data: $0.encodedPayload)
            },
            correctionRevisions: correctionEntities.map {
                VersionedArchivePayload(id: $0.id, createdAt: $0.createdAt, sha256: $0.payloadSHA256, data: $0.encodedPayload)
            },
            computationRuns: computationEntities.map {
                VersionedArchivePayload(id: $0.id, createdAt: $0.createdAt, sha256: $0.payloadSHA256, data: $0.encodedPayload)
            },
            simulations: simulationEntities.map {
                VersionedArchivePayload(id: $0.id, createdAt: $0.createdAt, sha256: $0.payloadSHA256, data: $0.encodedPayload)
            },
            effectiveData: activeEnvelope?.effectiveData,
            activeAnalysis: activeAnalysis
        )
    }
}

protocol CaseExporter: Sendable {
    func export(_ snapshot: CaseArchiveSnapshot) async throws -> URL
}

actor CaseArchiveExporter: CaseExporter {
    static let schemaName = "CaseArchive"
    static let schemaVersion = 1

    private struct Manifest: Codable {
        struct App: Codable {
            let bundleIdentifier: String
            let version: String
            let build: String
            let gitRevision: String?
        }

        struct Versions: Codable {
            let analysisAlgorithm: String?
            let activityModel: String?
            let visionRevision: Int?
        }

        struct Units: Codable {
            let glucose: String
            let insulin: String
            let basalRate: String
            let carbohydrates: String
        }

        struct Active: Codable {
            let analysisRunID: UUID?
            let correctionRevisionID: UUID?
            let computationRunID: UUID?
        }

        struct FileEntry: Codable {
            let path: String
            let mediaType: String
            let byteCount: Int
            let sha256: String
        }

        let schemaName: String
        let schemaVersion: Int
        let createdAt: Date
        let app: App
        let `case`: CaseArchiveSnapshot.Metadata
        let versions: Versions
        let units: Units
        let active: Active
        let screenshot: CaseArchiveSnapshot.Screenshot
        let files: [FileEntry]
    }

    private struct AnalysisConfidenceExport: Codable {
        struct Observation: Codable {
            let id: UUID
            let overall: Double
            let geometry: Double
            let recognition: Double
            let calibration: Double
        }

        let quality: AnalysisQuality
        let observations: [Observation]
        let warnings: [OCRAnalysisWarning]
    }

    private let fileManager = FileManager.default

    func export(_ snapshot: CaseArchiveSnapshot) async throws -> URL {
        guard Self.sha256(snapshot.originalData) == snapshot.screenshot.sha256 else {
            throw ImportQueueError.checksumMismatch
        }
        let workRoot = fileManager.temporaryDirectory
            .appendingPathComponent("InsulinOCR-Export-\(UUID().uuidString)", isDirectory: true)
        let archiveRoot = workRoot.appendingPathComponent("CaseArchive-v1", isDirectory: true)
        try fileManager.createDirectory(at: archiveRoot, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: workRoot) }

        var entries: [Manifest.FileEntry] = []
        var checksumPayloads: [String: Data] = [:]
        func write(_ data: Data, path: String, mediaType: String? = nil) throws {
            guard Self.isSafeArchivePath(path), checksumPayloads[path] == nil else {
                throw CocoaError(.fileWriteInvalidFileName)
            }
            let url = archiveRoot.appendingPathComponent(path)
            try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url, options: [.atomic])
            try fileManager.setAttributes([.protectionKey: FileProtectionType.complete], ofItemAtPath: url.path)
            checksumPayloads[path] = data
            entries.append(
                .init(
                    path: path,
                    mediaType: mediaType ?? Self.mediaType(for: path),
                    byteCount: data.count,
                    sha256: Self.sha256(data)
                )
            )
        }

        let originalExtension = UTType(snapshot.screenshot.uniformTypeIdentifier)?.preferredFilenameExtension ?? "img"
        try write(
            snapshot.originalData,
            path: "assets/original.\(originalExtension)",
            mediaType: UTType(snapshot.screenshot.uniformTypeIdentifier)?.preferredMIMEType
                ?? "application/octet-stream"
        )
        if let diagnostic = snapshot.diagnosticData {
            try write(diagnostic, path: "assets/diagnostic-overlay.png", mediaType: "image/png")
        }

        let encoder = JSONEncoder.insulinOCR
        try write(try encoder.encode(snapshot.metadata), path: "case.json")
        try write(try encoder.encode(snapshot.screenshot), path: "screenshot.json")

        for run in snapshot.analysisRuns {
            try write(run.data, path: "analysis/runs/\(run.id.uuidString).json")
            if let envelope = try? JSONDecoder.insulinOCR.decode(
                StoredAnalysisFailureEnvelope.self, from: run.data
            ) {
                try write(run.data, path: "analysis/failures/\(run.id.uuidString).json")
                try write(try encoder.encode(envelope.failure.rawTextObservations),
                          path: "analysis/raw-ocr/\(run.id.uuidString).json")
                continue
            }
            let decoded: (run: AnalysisRun, warnings: [OCRAnalysisWarning])?
            if let envelope = try? JSONDecoder.insulinOCR.decode(
                StoredAnalysisEnvelope.self,
                from: run.data
            ) {
                decoded = (envelope.run, envelope.extractorResult.warnings)
            } else if let analysis = try? JSONDecoder.insulinOCR.decode(
                AnalysisRun.self,
                from: run.data
            ) {
                decoded = (analysis, [])
            } else {
                decoded = nil
            }
            if let decoded {
                try write(
                    try encoder.encode(decoded.run.rawOCR),
                    path: "analysis/raw-ocr/\(run.id.uuidString).json"
                )
                try write(
                    try encoder.encode(decoded.run.calibration),
                    path: "analysis/calibration/\(run.id.uuidString).json"
                )
                let confidence = AnalysisConfidenceExport(
                    quality: decoded.run.quality,
                    observations: decoded.run.observations.map {
                        .init(
                            id: $0.id,
                            overall: $0.confidence.overall,
                            geometry: $0.confidence.geometry,
                            recognition: $0.confidence.recognition,
                            calibration: $0.confidence.calibration
                        )
                    },
                    warnings: decoded.warnings
                )
                try write(
                    try encoder.encode(confidence),
                    path: "analysis/confidence/\(run.id.uuidString).json"
                )
            }
        }
        for revision in snapshot.correctionRevisions {
            try write(revision.data, path: "corrections/\(revision.id.uuidString).json")
        }
        for run in snapshot.computationRuns {
            try write(run.data, path: "computations/\(run.id.uuidString).json")
            if let envelope = try? JSONDecoder.insulinOCR.decode(
                StoredComputationEnvelope.self,
                from: run.data
            ) {
                try write(
                    try encoder.encode(envelope.effectiveData),
                    path: "effective/\(run.id.uuidString).json"
                )
            }
        }
        for scenario in snapshot.simulations {
            try write(scenario.data, path: "simulations/\(scenario.id.uuidString).json")
        }

        if let analysis = snapshot.activeAnalysis {
            try write(Self.rawBasalCSV(analysis).data(using: .utf8)!, path: "csv/raw-basal.csv")
            try write(Self.rawGlucoseCSV(analysis).data(using: .utf8)!, path: "csv/raw-glucose.csv")
            try write(Self.rawBolusCSV(analysis).data(using: .utf8)!, path: "csv/raw-bolus.csv")
            try write(Self.rawCarbohydrateCSV(analysis).data(using: .utf8)!, path: "csv/raw-carbohydrates.csv")
            try write(Self.ambiguousCSV(analysis).data(using: .utf8)!, path: "csv/raw-ambiguities.csv")
        } else {
            try write(Data(Self.rawBasalHeader.utf8), path: "csv/raw-basal.csv")
            try write(Data(Self.rawGlucoseHeader.utf8), path: "csv/raw-glucose.csv")
            try write(Data(Self.rawBolusHeader.utf8), path: "csv/raw-bolus.csv")
            try write(Data(Self.rawCarbohydrateHeader.utf8), path: "csv/raw-carbohydrates.csv")
            try write(Data(Self.rawAmbiguityHeader.utf8), path: "csv/raw-ambiguities.csv")
        }

        let effective = snapshot.effectiveData
        try write(
            Data((effective.map(Self.basalCSV) ?? Self.effectiveBasalHeader).utf8),
            path: "csv/effective-basal.csv"
        )
        try write(
            Data((effective.map(Self.glucoseCSV) ?? Self.effectiveGlucoseHeader).utf8),
            path: "csv/effective-glucose.csv"
        )
        try write(
            Data((effective.map(Self.bolusCSV) ?? Self.effectiveBolusHeader).utf8),
            path: "csv/effective-bolus.csv"
        )
        try write(
            Data((effective.map(Self.carbohydrateCSV) ?? Self.effectiveCarbohydrateHeader).utf8),
            path: "csv/effective-carbohydrates.csv"
        )
        try write(
            Data(Self.simulationCSV(snapshot.simulations).utf8),
            path: "csv/simulation-events.csv"
        )

        let manifest = Manifest(
            schemaName: Self.schemaName,
            schemaVersion: Self.schemaVersion,
            createdAt: .now,
            app: .init(
                bundleIdentifier: Bundle.main.bundleIdentifier ?? "org.example.insulinocr",
                version: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown",
                build: Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown",
                gitRevision: Bundle.main.object(forInfoDictionaryKey: "GitRevision") as? String
            ),
            case: snapshot.metadata,
            versions: .init(
                analysisAlgorithm: snapshot.activeAnalysis?.algorithmVersion,
                activityModel: snapshot.effectiveData == nil ? nil : DefaultActivityCalculator.modelVersion,
                visionRevision: snapshot.activeAnalysis?.visionRevision
            ),
            units: .init(
                glucose: "mmol/L",
                insulin: "U",
                basalRate: "U/h",
                carbohydrates: "g"
            ),
            active: .init(
                analysisRunID: snapshot.metadata.activeAnalysisRunID,
                correctionRevisionID: snapshot.metadata.activeCorrectionRevisionID,
                computationRunID: snapshot.metadata.activeComputationRunID
            ),
            screenshot: snapshot.screenshot,
            files: entries.sorted { $0.path < $1.path }
        )
        let manifestData = try encoder.encode(manifest)
        let manifestURL = archiveRoot.appendingPathComponent("manifest.json")
        try manifestData.write(to: manifestURL, options: [.atomic])
        try fileManager.setAttributes(
            [.protectionKey: FileProtectionType.complete],
            ofItemAtPath: manifestURL.path
        )
        checksumPayloads["manifest.json"] = manifestData

        let checksumText = checksumPayloads
            .map { (path: $0.key, sha256: Self.sha256($0.value)) }
            .sorted { $0.path < $1.path }
            .map { "\($0.sha256)  \($0.path)" }
            .joined(separator: "\n") + "\n"
        let checksumURL = archiveRoot.appendingPathComponent("checksums.sha256")
        try Data(checksumText.utf8).write(to: checksumURL, options: [.atomic])
        try fileManager.setAttributes(
            [.protectionKey: FileProtectionType.complete],
            ofItemAtPath: checksumURL.path
        )

        let exportsDirectory = try fileManager.url(
            for: .cachesDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        ).appendingPathComponent("InsulinOCRExports", isDirectory: true)
        try fileManager.createDirectory(at: exportsDirectory, withIntermediateDirectories: true)
        let destination = exportsDirectory.appendingPathComponent(
            "InsulinOCR-\(snapshot.metadata.id.uuidString)-\(UUID().uuidString.prefix(8)).zip"
        )
        try fileManager.zipItem(at: archiveRoot, to: destination, shouldKeepParent: true)
        try fileManager.setAttributes([.protectionKey: FileProtectionType.complete], ofItemAtPath: destination.path)
        return destination
    }

    private static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func decimal(_ value: Double, format: String = "%.12g") -> String {
        String(format: format, locale: Locale(identifier: "en_US_POSIX"), value)
    }

    private static func isSafeArchivePath(_ path: String) -> Bool {
        guard !path.isEmpty, !path.hasPrefix("/") else { return false }
        return path.split(separator: "/", omittingEmptySubsequences: false).allSatisfy {
            !$0.isEmpty && $0 != "." && $0 != ".."
        }
    }

    private static func mediaType(for path: String) -> String {
        switch URL(fileURLWithPath: path).pathExtension.lowercased() {
        case "json": "application/json"
        case "csv": "text/csv"
        case "png": "image/png"
        case "jpg", "jpeg": "image/jpeg"
        default: "application/octet-stream"
        }
    }

    private static let rawBasalHeader =
        "id,start_time,end_time,units_per_hour,amount_state,confidence,provenance,bounding_box,candidates\n"
    private static let rawGlucoseHeader =
        "id,time,value,unit,amount_state,confidence,provenance,bounding_box,candidates\n"
    private static let rawBolusHeader =
        "id,time,insulin_units,amount_state,confidence,provenance,bounding_box,candidates\n"
    private static let rawCarbohydrateHeader =
        "id,time,grams,amount_state,confidence,provenance,bounding_box,candidates\n"
    private static let rawAmbiguityHeader =
        "id,kind,time,amount_state,amount,unit,confidence,provenance,bounding_box,candidates\n"
    private static let effectiveBasalHeader =
        "id,start_time,end_time,units_per_hour,source_observation_id\n"
    private static let effectiveGlucoseHeader =
        "id,time,value,unit,source_observation_id\n"
    private static let effectiveBolusHeader =
        "id,time,insulin_units,source_observation_id\n"
    private static let effectiveCarbohydrateHeader =
        "id,time,grams,source_observation_id\n"
    private static let simulationHeader =
        "scenario_id,scenario_name,event_id,event_kind,time,amount,unit,baseline_basal_iob,baseline_bolus_iob,baseline_total_iob,baseline_cob,scenario_basal_iob,scenario_bolus_iob,scenario_total_iob,scenario_cob,delta_basal_iob,delta_bolus_iob,delta_total_iob,delta_cob\n"

    private static func rawBasalCSV(_ analysis: AnalysisRun) -> String {
        rawObservationCSV(
            analysis.observations.filter { $0.kind == .basalRate },
            header: rawBasalHeader,
            includeEndDate: true
        )
    }

    private static func rawGlucoseCSV(_ analysis: AnalysisRun) -> String {
        rawObservationCSV(
            analysis.observations.filter { $0.kind == .glucose },
            header: rawGlucoseHeader
        )
    }

    private static func rawBolusCSV(_ analysis: AnalysisRun) -> String {
        rawObservationCSV(
            analysis.observations.filter { $0.kind == .bolus },
            header: rawBolusHeader
        )
    }

    private static func rawCarbohydrateCSV(_ analysis: AnalysisRun) -> String {
        rawObservationCSV(
            analysis.observations.filter { $0.kind == .carbohydrate },
            header: rawCarbohydrateHeader
        )
    }

    private static func rawObservationCSV(
        _ observations: [RawObservation],
        header: String,
        includeEndDate: Bool = false
    ) -> String {
        let rows = observations.sorted {
            if $0.startDate == $1.startDate { return $0.id.uuidString < $1.id.uuidString }
            return $0.startDate < $1.startDate
        }.map { observation in
            var values = [
                observation.id.uuidString,
                PreciseISO8601DateCoding.string(from: observation.startDate) ?? "",
            ]
            if includeEndDate {
                values.append(observation.endDate.flatMap { PreciseISO8601DateCoding.string(from: $0) } ?? "")
            }
            values += [
                observation.amount.map { decimal($0) } ?? "",
            ]
            if observation.kind == .glucose {
                values.append(observation.unit.rawValue)
            }
            values += [
                observation.amountState.rawValue,
                decimal(observation.confidence.overall, format: "%.6f"),
                observation.provenance.rawValue,
                boundingBoxString(observation.boundingBox),
                candidateString(observation),
            ]
            return values.map(csv).joined(separator: ",")
        }
        return header + (rows.isEmpty ? "" : rows.joined(separator: "\n") + "\n")
    }

    private static func boundingBoxString(_ box: NormalizedBoundingBox) -> String {
        [box.x, box.y, box.width, box.height]
            .map { decimal($0, format: "%.8f") }
            .joined(separator: "|")
    }

    private static func candidateString(_ observation: RawObservation) -> String {
        observation.candidates.compactMap { candidate in
            candidate.text ?? candidate.numericValue.map { decimal($0) }
        }.joined(separator: "|")
    }

    private static func simulationCSV(_ payloads: [VersionedArchivePayload]) -> String {
        let rows = payloads.compactMap {
            try? JSONDecoder.insulinOCR.decode(SimulationScenario.self, from: $0.data)
        }.flatMap { scenario -> [String] in
            let delta = SimulationDelta(baseline: scenario.baseline, scenario: scenario.scenario)
            return scenario.events.map { event in
                let eventID: UUID
                let kind: String
                let date: Date
                let amount: Double
                let unit: String
                switch event {
                case .bolus(let insulin):
                    eventID = insulin.id
                    kind = "bolus"
                    date = insulin.date
                    amount = insulin.units
                    unit = "U"
                case .carbohydrate(let carbohydrate):
                    eventID = carbohydrate.id
                    kind = "carbohydrate"
                    date = carbohydrate.date
                    amount = carbohydrate.grams
                    unit = "g"
                }
                return [
                    scenario.id.uuidString,
                    scenario.name,
                    eventID.uuidString,
                    kind,
                    PreciseISO8601DateCoding.string(from: date) ?? "",
                    decimal(amount),
                    unit,
                    metricString(scenario.baseline.basalIOB),
                    metricString(scenario.baseline.bolusIOB),
                    metricString(scenario.baseline.totalIOB),
                    metricString(scenario.baseline.cob),
                    metricString(scenario.scenario.basalIOB),
                    metricString(scenario.scenario.bolusIOB),
                    metricString(scenario.scenario.totalIOB),
                    metricString(scenario.scenario.cob),
                    delta.basalIOB.map { decimal($0) } ?? "",
                    delta.bolusIOB.map { decimal($0) } ?? "",
                    delta.totalIOB.map { decimal($0) } ?? "",
                    delta.cob.map { decimal($0) } ?? "",
                ].map(csv).joined(separator: ",")
            }
        }
        return simulationHeader + (rows.isEmpty ? "" : rows.joined(separator: "\n") + "\n")
    }

    private static func metricString(_ result: MetricResult) -> String {
        result.value.map { decimal($0) } ?? ""
    }

    private static func basalCSV(_ data: EffectiveTherapyData) -> String {
        let rows = data.basalSegments.map {
            [
                $0.id.uuidString,
                PreciseISO8601DateCoding.string(from: $0.startDate) ?? "",
                PreciseISO8601DateCoding.string(from: $0.endDate) ?? "",
                decimal($0.unitsPerHour),
                $0.sourceObservationID?.uuidString ?? "",
            ].map(csv).joined(separator: ",")
        }
        return effectiveBasalHeader + (rows.isEmpty ? "" : rows.joined(separator: "\n") + "\n")
    }

    private static func glucoseCSV(_ data: EffectiveTherapyData) -> String {
        let rows = data.glucoseSamples.map {
            [
                $0.id.uuidString,
                PreciseISO8601DateCoding.string(from: $0.date) ?? "",
                decimal($0.value),
                $0.unit.rawValue,
                $0.sourceObservationID?.uuidString ?? "",
            ].map(csv).joined(separator: ",")
        }
        return effectiveGlucoseHeader + (rows.isEmpty ? "" : rows.joined(separator: "\n") + "\n")
    }

    private static func bolusCSV(_ data: EffectiveTherapyData) -> String {
        let rows = data.boluses.map {
            [
                $0.id.uuidString,
                PreciseISO8601DateCoding.string(from: $0.date) ?? "",
                decimal($0.units),
                $0.sourceObservationID?.uuidString ?? "",
            ].map(csv).joined(separator: ",")
        }
        return effectiveBolusHeader + (rows.isEmpty ? "" : rows.joined(separator: "\n") + "\n")
    }

    private static func carbohydrateCSV(_ data: EffectiveTherapyData) -> String {
        let rows = data.carbohydrates.map {
            [
                $0.id.uuidString,
                PreciseISO8601DateCoding.string(from: $0.date) ?? "",
                decimal($0.grams),
                $0.sourceObservationID?.uuidString ?? "",
            ].map(csv).joined(separator: ",")
        }
        return effectiveCarbohydrateHeader + (rows.isEmpty ? "" : rows.joined(separator: "\n") + "\n")
    }

    private static func ambiguousCSV(_ analysis: AnalysisRun) -> String {
        let ambiguous = analysis.observations.filter {
            $0.amountState == .amountUnknown || $0.kind == .eventStem || $0.confidence.overall < 0.8
        }
        let rows = ambiguous.map { observation in
            let candidates = observation.candidates.compactMap { candidate in
                candidate.text ?? candidate.numericValue.map { decimal($0) }
            }.joined(separator: "|")
            return [
                observation.id.uuidString,
                observation.kind.rawValue,
                PreciseISO8601DateCoding.string(from: observation.startDate) ?? "",
                observation.amountState.rawValue,
                observation.amount.map { decimal($0) } ?? "",
                observation.unit.rawValue,
                decimal(observation.confidence.overall, format: "%.6f"),
                observation.provenance.rawValue,
                boundingBoxString(observation.boundingBox),
                candidates,
            ].map(csv).joined(separator: ",")
        }
        return rawAmbiguityHeader + (rows.isEmpty ? "" : rows.joined(separator: "\n") + "\n")
    }

    private static func csv(_ value: String) -> String {
        guard value.contains(",") || value.contains("\"") || value.contains("\n") else { return value }
        return "\"\(value.replacingOccurrences(of: "\"", with: "\"\""))\""
    }
}
