import Foundation

/// A failed attempt has no fabricated calibration, dates or therapy values.
public struct OCRFailedAnalysis: Codable, Equatable, Sendable, Error, LocalizedError {
    public enum Code: String, Codable, Sendable {
        case invalidImage, unsupportedLayout, invalidTimeAxis, cancelled, processingFailed
    }

    public let schemaVersion: Int
    public let id: UUID
    public let requestID: UUID
    public let createdAt: Date
    public let algorithmVersion: String
    public let visionRevision: Int
    public let requestedCaptureTime: Date?
    public let importedAt: Date?
    public let timeZoneIdentifier: String?
    public let code: Code
    public let message: String
    public let rawTextObservations: [OCRRawTextObservation]

    public init(id: UUID = UUID(), requestID: UUID, createdAt: Date = Date(),
                algorithmVersion: String, visionRevision: Int, code: Code,
                message: String, rawTextObservations: [OCRRawTextObservation],
                requestedCaptureTime: Date? = nil, importedAt: Date? = nil,
                timeZoneIdentifier: String? = nil) {
        schemaVersion = 1
        self.id = id
        self.requestID = requestID
        self.createdAt = createdAt
        self.algorithmVersion = algorithmVersion
        self.visionRevision = visionRevision
        self.requestedCaptureTime = requestedCaptureTime
        self.importedAt = importedAt
        self.timeZoneIdentifier = timeZoneIdentifier
        self.code = code
        self.message = message
        self.rawTextObservations = rawTextObservations
    }

    public var errorDescription: String? { message }
}
