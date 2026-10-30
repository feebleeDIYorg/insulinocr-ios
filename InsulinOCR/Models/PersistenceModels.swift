import Foundation
import SwiftData

enum StoredCaseStatus: String, Codable, CaseIterable, Sendable {
    case queued
    case analyzing
    case complete
    case incomplete
    case needsReview
    case unsupportedLayout
    case failed

    var isTerminal: Bool {
        switch self {
        case .complete, .incomplete, .needsReview, .unsupportedLayout, .failed:
            true
        case .queued, .analyzing:
            false
        }
    }
}

enum StoredCaptureTimeSource: String, Codable, Sendable {
    case imageMetadata
    case fileMetadata
    case importTime
    case userCorrection
}

@Model
final class CaseEntity {
    @Attribute(.unique) var id: UUID
    var title: String
    var createdAt: Date
    var updatedAt: Date
    var captureTime: Date
    var captureTimeSourceRaw: String
    var captureTimeZoneIdentifier: String
    var statusRaw: String
    var reviewReason: String?
    var screenshotAssetID: UUID?
    var activeAnalysisRunID: UUID?
    var activeCorrectionRevisionID: UUID?
    var activeComputationRunID: UUID?
    var isDeletedTombstone: Bool
    var cloudRecordName: String?

    init(
        id: UUID = UUID(),
        title: String,
        createdAt: Date = .now,
        captureTime: Date,
        captureTimeSource: StoredCaptureTimeSource,
        captureTimeZoneIdentifier: String = TimeZone.current.identifier,
        status: StoredCaseStatus = .queued,
        screenshotAssetID: UUID? = nil
    ) {
        self.id = id
        self.title = title
        self.createdAt = createdAt
        self.updatedAt = createdAt
        self.captureTime = captureTime
        self.captureTimeSourceRaw = captureTimeSource.rawValue
        self.captureTimeZoneIdentifier = captureTimeZoneIdentifier
        self.statusRaw = status.rawValue
        self.screenshotAssetID = screenshotAssetID
        self.isDeletedTombstone = false
    }

    var status: StoredCaseStatus {
        get { StoredCaseStatus(rawValue: statusRaw) ?? .failed }
        set {
            statusRaw = newValue.rawValue
            updatedAt = .now
        }
    }

    var captureTimeSource: StoredCaptureTimeSource {
        get { StoredCaptureTimeSource(rawValue: captureTimeSourceRaw) ?? .importTime }
        set {
            captureTimeSourceRaw = newValue.rawValue
            updatedAt = .now
        }
    }
}

@Model
final class ScreenshotAssetEntity {
    @Attribute(.unique) var id: UUID
    var caseID: UUID
    var relativeOriginalPath: String
    var relativeDiagnosticPath: String?
    var originalFilename: String
    var uniformTypeIdentifier: String
    var pixelWidth: Int
    var pixelHeight: Int
    var byteCount: Int
    var sha256: String
    var captureTime: Date
    var captureTimeSourceRaw: String
    var layoutProfile: String?
    var createdAt: Date

    init(
        id: UUID = UUID(),
        caseID: UUID,
        relativeOriginalPath: String,
        originalFilename: String,
        uniformTypeIdentifier: String,
        pixelWidth: Int,
        pixelHeight: Int,
        byteCount: Int,
        sha256: String,
        captureTime: Date,
        captureTimeSource: StoredCaptureTimeSource
    ) {
        self.id = id
        self.caseID = caseID
        self.relativeOriginalPath = relativeOriginalPath
        self.originalFilename = originalFilename
        self.uniformTypeIdentifier = uniformTypeIdentifier
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.byteCount = byteCount
        self.sha256 = sha256
        self.captureTime = captureTime
        self.captureTimeSourceRaw = captureTimeSource.rawValue
        self.createdAt = .now
    }
}

@Model
final class AnalysisRunEntity {
    @Attribute(.unique) var id: UUID
    var caseID: UUID
    var createdAt: Date
    var algorithmVersion: String
    var visionRevision: Int
    var statusRaw: String
    var encodedPayload: Data
    var payloadSHA256: String

    init(
        id: UUID,
        caseID: UUID,
        createdAt: Date,
        algorithmVersion: String,
        visionRevision: Int,
        statusRaw: String,
        encodedPayload: Data,
        payloadSHA256: String
    ) {
        self.id = id
        self.caseID = caseID
        self.createdAt = createdAt
        self.algorithmVersion = algorithmVersion
        self.visionRevision = visionRevision
        self.statusRaw = statusRaw
        self.encodedPayload = encodedPayload
        self.payloadSHA256 = payloadSHA256
    }
}

@Model
final class CorrectionRevisionEntity {
    @Attribute(.unique) var id: UUID
    var caseID: UUID
    var basedOnAnalysisRunID: UUID
    var parentRevisionID: UUID?
    var createdAt: Date
    var encodedPayload: Data
    var payloadSHA256: String
    var hasConflict: Bool

    init(
        id: UUID,
        caseID: UUID,
        basedOnAnalysisRunID: UUID,
        parentRevisionID: UUID?,
        createdAt: Date,
        encodedPayload: Data,
        payloadSHA256: String,
        hasConflict: Bool = false
    ) {
        self.id = id
        self.caseID = caseID
        self.basedOnAnalysisRunID = basedOnAnalysisRunID
        self.parentRevisionID = parentRevisionID
        self.createdAt = createdAt
        self.encodedPayload = encodedPayload
        self.payloadSHA256 = payloadSHA256
        self.hasConflict = hasConflict
    }
}

@Model
final class ComputationRunEntity {
    @Attribute(.unique) var id: UUID
    var caseID: UUID
    var analysisRunID: UUID
    var correctionRevisionID: UUID?
    var createdAt: Date
    var referenceTime: Date
    var modelVersion: String
    var encodedPayload: Data
    var payloadSHA256: String

    init(
        id: UUID,
        caseID: UUID,
        analysisRunID: UUID,
        correctionRevisionID: UUID?,
        createdAt: Date,
        referenceTime: Date,
        modelVersion: String,
        encodedPayload: Data,
        payloadSHA256: String
    ) {
        self.id = id
        self.caseID = caseID
        self.analysisRunID = analysisRunID
        self.correctionRevisionID = correctionRevisionID
        self.createdAt = createdAt
        self.referenceTime = referenceTime
        self.modelVersion = modelVersion
        self.encodedPayload = encodedPayload
        self.payloadSHA256 = payloadSHA256
    }
}

@Model
final class SimulationScenarioEntity {
    @Attribute(.unique) var id: UUID
    var caseID: UUID
    var basedOnComputationRunID: UUID
    var name: String
    var createdAt: Date
    var updatedAt: Date
    var encodedPayload: Data
    var payloadSHA256: String

    init(
        id: UUID,
        caseID: UUID,
        basedOnComputationRunID: UUID,
        name: String,
        createdAt: Date,
        encodedPayload: Data,
        payloadSHA256: String
    ) {
        self.id = id
        self.caseID = caseID
        self.basedOnComputationRunID = basedOnComputationRunID
        self.name = name
        self.createdAt = createdAt
        self.updatedAt = createdAt
        self.encodedPayload = encodedPayload
        self.payloadSHA256 = payloadSHA256
    }
}

enum PersistenceSchema {
    static let models: [any PersistentModel.Type] = [
        CaseEntity.self,
        ScreenshotAssetEntity.self,
        AnalysisRunEntity.self,
        CorrectionRevisionEntity.self,
        ComputationRunEntity.self,
        SimulationScenarioEntity.self,
    ]
}
