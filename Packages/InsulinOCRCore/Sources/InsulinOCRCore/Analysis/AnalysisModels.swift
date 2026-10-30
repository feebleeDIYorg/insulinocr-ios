import Foundation

/// Input for one immutable screenshot analysis. The original bytes are never rewritten.
public struct ScreenshotAnalysisRequest: Sendable, Equatable {
    public let id: UUID
    public let imageData: Data
    public let capturedAt: Date?
    public let importedAt: Date
    public let timeZoneIdentifier: String

    public init(
        id: UUID = UUID(),
        imageData: Data,
        capturedAt: Date? = nil,
        importedAt: Date = Date(),
        timeZoneIdentifier: String = TimeZone.current.identifier
    ) {
        self.id = id
        self.imageData = imageData
        self.capturedAt = capturedAt
        self.importedAt = importedAt
        self.timeZoneIdentifier = timeZoneIdentifier
    }
}

/// Normalized image coordinates with a top-left origin.
public struct OCRNormalizedRect: Codable, Sendable, Equatable, Hashable {
    public let x: Double
    public let y: Double
    public let width: Double
    public let height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    public var minX: Double { x }
    public var maxX: Double { x + width }
    public var minY: Double { y }
    public var maxY: Double { y + height }
    public var midX: Double { x + width / 2 }
    public var midY: Double { y + height / 2 }

    public func contains(x candidateX: Double, y candidateY: Double) -> Bool {
        candidateX >= minX && candidateX <= maxX && candidateY >= minY && candidateY <= maxY
    }

    public func clampedToUnitSquare() -> OCRNormalizedRect {
        let startX = min(1, max(0, minX))
        let startY = min(1, max(0, minY))
        let endX = min(1, max(startX, maxX))
        let endY = min(1, max(startY, maxY))
        return OCRNormalizedRect(x: startX, y: startY, width: endX - startX, height: endY - startY)
    }
}

public enum OCRRegionKind: String, Codable, Sendable, CaseIterable {
    case fullImage
    case timeAxis
    case basalAxis
    case glucoseAxis
    case eventPill
}

public struct OCRTextCandidate: Codable, Sendable, Equatable, Hashable {
    public let text: String
    public let confidence: Double

    public init(text: String, confidence: Double) {
        self.text = text
        self.confidence = confidence
    }
}

public struct OCRRawTextObservation: Codable, Sendable, Equatable, Identifiable {
    public let id: UUID
    public let region: OCRRegionKind
    public let boundingBox: OCRNormalizedRect
    public let candidates: [OCRTextCandidate]

    public init(
        id: UUID = UUID(),
        region: OCRRegionKind,
        boundingBox: OCRNormalizedRect,
        candidates: [OCRTextCandidate]
    ) {
        self.id = id
        self.region = region
        self.boundingBox = boundingBox
        self.candidates = candidates
    }

    public var bestCandidate: OCRTextCandidate? {
        candidates.max { $0.confidence < $1.confidence }
    }
}

public enum OCRLayoutProfile: String, Codable, Sendable {
    case camAPSFXLandscapeV1
}

public struct OCRDetectedLayout: Codable, Sendable, Equatable {
    public let profile: OCRLayoutProfile
    public let plotFrame: OCRNormalizedRect
    public let dataRightEdgeX: Double
    public let estimatedVisibleHours: Double
    public let confidence: Double

    public init(
        profile: OCRLayoutProfile,
        plotFrame: OCRNormalizedRect,
        dataRightEdgeX: Double,
        estimatedVisibleHours: Double,
        confidence: Double
    ) {
        self.profile = profile
        self.plotFrame = plotFrame
        self.dataRightEdgeX = dataRightEdgeX
        self.estimatedVisibleHours = estimatedVisibleHours
        self.confidence = confidence
    }
}

public enum OCRAxisKind: String, Codable, Sendable {
    case time
    case basalRate
    case glucose
}

public enum OCRCalibrationSource: String, Codable, Sendable {
    case multipleOCRAnchors
    case singleAnchorWithFiveMinuteSpacing
    case numericAxisAnchors
}

public struct OCRCalibrationAnchor: Codable, Sendable, Equatable, Identifiable {
    public let id: UUID
    public let coordinate: Double
    public let value: Double
    public let sourceObservationID: UUID?

    public init(
        id: UUID = UUID(),
        coordinate: Double,
        value: Double,
        sourceObservationID: UUID? = nil
    ) {
        self.id = id
        self.coordinate = coordinate
        self.value = value
        self.sourceObservationID = sourceObservationID
    }
}

/// Linear calibration. Time uses minutes as value and normalized X as coordinate;
/// numeric axes use their displayed unit and normalized top-origin Y.
public struct OCRAxisCalibration: Codable, Sendable, Equatable {
    public let kind: OCRAxisKind
    public let source: OCRCalibrationSource
    public let slope: Double
    public let intercept: Double
    public let maximumResidual: Double
    public let anchors: [OCRCalibrationAnchor]

    public init(
        kind: OCRAxisKind,
        source: OCRCalibrationSource,
        slope: Double,
        intercept: Double,
        maximumResidual: Double,
        anchors: [OCRCalibrationAnchor]
    ) {
        self.kind = kind
        self.source = source
        self.slope = slope
        self.intercept = intercept
        self.maximumResidual = maximumResidual
        self.anchors = anchors
    }

    public func value(at coordinate: Double) -> Double {
        slope * coordinate + intercept
    }
}

public enum OCRProvenanceKind: String, Codable, Sendable {
    case visionText
    case pixelGeometry
    case calibratedPixelGeometry
    case reconstructedShortOcclusion
}

public struct OCRProvenance: Codable, Sendable, Equatable {
    public let kind: OCRProvenanceKind
    public let sourceObservationIDs: [UUID]
    public let note: String?

    public init(
        kind: OCRProvenanceKind,
        sourceObservationIDs: [UUID] = [],
        note: String? = nil
    ) {
        self.kind = kind
        self.sourceObservationIDs = sourceObservationIDs
        self.note = note
    }
}

public struct OCRBasalStep: Codable, Sendable, Equatable, Identifiable {
    public let id: UUID
    public let startDate: Date
    public let endDate: Date
    public let rateUnitsPerHour: Double?
    public let pixelY: Double
    public let confidence: Double
    public let provenance: OCRProvenance

    public init(
        id: UUID = UUID(),
        startDate: Date,
        endDate: Date,
        rateUnitsPerHour: Double?,
        pixelY: Double,
        confidence: Double,
        provenance: OCRProvenance
    ) {
        self.id = id
        self.startDate = startDate
        self.endDate = endDate
        self.rateUnitsPerHour = rateUnitsPerHour
        self.pixelY = pixelY
        self.confidence = confidence
        self.provenance = provenance
    }
}

public struct OCRGlucoseSample: Codable, Sendable, Equatable, Identifiable {
    public let id: UUID
    public let date: Date
    public let mmolPerLiter: Double?
    public let boundingBox: OCRNormalizedRect
    public let confidence: Double
    public let provenance: OCRProvenance

    public init(
        id: UUID = UUID(),
        date: Date,
        mmolPerLiter: Double?,
        boundingBox: OCRNormalizedRect,
        confidence: Double,
        provenance: OCRProvenance
    ) {
        self.id = id
        self.date = date
        self.mmolPerLiter = mmolPerLiter
        self.boundingBox = boundingBox
        self.confidence = confidence
        self.provenance = provenance
    }
}

public enum OCRTherapyEventKind: String, Codable, Sendable {
    case bolus
    case carbohydrates
    case unknown
}

public enum OCRDetectedAmount: Codable, Sendable, Equatable {
    case known(Double)
    case amountUnknown

    public var value: Double? {
        guard case let .known(value) = self else { return nil }
        return value
    }
}

public struct OCRTherapyEvent: Codable, Sendable, Equatable, Identifiable {
    public let id: UUID
    public let kind: OCRTherapyEventKind
    public let date: Date
    public let amount: OCRDetectedAmount
    public let stemBoundingBox: OCRNormalizedRect
    public let pillBoundingBox: OCRNormalizedRect
    public let isCompleteStem: Bool
    public let candidates: [OCRTextCandidate]
    public let confidence: Double
    public let provenance: OCRProvenance

    public init(
        id: UUID = UUID(),
        kind: OCRTherapyEventKind,
        date: Date,
        amount: OCRDetectedAmount,
        stemBoundingBox: OCRNormalizedRect,
        pillBoundingBox: OCRNormalizedRect,
        isCompleteStem: Bool,
        candidates: [OCRTextCandidate],
        confidence: Double,
        provenance: OCRProvenance
    ) {
        self.id = id
        self.kind = kind
        self.date = date
        self.amount = amount
        self.stemBoundingBox = stemBoundingBox
        self.pillBoundingBox = pillBoundingBox
        self.isCompleteStem = isCompleteStem
        self.candidates = candidates
        self.confidence = confidence
        self.provenance = provenance
    }
}

public enum OCRAnalysisStatus: String, Codable, Sendable {
    case complete
    case needsReview
}

public enum OCRAnalysisWarningCode: String, Codable, Sendable {
    case captureTimeFromImportFallback
    case timeAxisSingleAnchorFallback
    case timeAxisCaptureInconsistent
    case basalAxisUncalibrated
    case glucoseAxisUncalibrated
    case basalCoverageInsufficient
    case basalCaptureIntervalMissing
    case eventAmountUnknown
    case eventKindUnknown
    case lowConfidence
}

public struct OCRAnalysisWarning: Codable, Sendable, Equatable, Identifiable {
    public let id: UUID
    public let code: OCRAnalysisWarningCode
    public let message: String
    public let relatedObservationIDs: [UUID]

    public init(
        id: UUID = UUID(),
        code: OCRAnalysisWarningCode,
        message: String,
        relatedObservationIDs: [UUID] = []
    ) {
        self.id = id
        self.code = code
        self.message = message
        self.relatedObservationIDs = relatedObservationIDs
    }
}

public struct OCRAnalysisQuality: Codable, Sendable, Equatable {
    public let layoutConfidence: Double
    public let timeMaximumResidualMinutes: Double
    public let basalPathCoverage: Double
    public let glucoseSampleCount: Int
    public let completeEventStemCount: Int
    public let unknownEventAmountCount: Int
    public let criticalDataComplete: Bool
    public let timeAxisClockIsValid: Bool?

    public init(
        layoutConfidence: Double,
        timeMaximumResidualMinutes: Double,
        basalPathCoverage: Double,
        glucoseSampleCount: Int,
        completeEventStemCount: Int,
        unknownEventAmountCount: Int,
        criticalDataComplete: Bool,
        timeAxisClockIsValid: Bool? = nil
    ) {
        self.layoutConfidence = layoutConfidence
        self.timeMaximumResidualMinutes = timeMaximumResidualMinutes
        self.basalPathCoverage = basalPathCoverage
        self.glucoseSampleCount = glucoseSampleCount
        self.completeEventStemCount = completeEventStemCount
        self.unknownEventAmountCount = unknownEventAmountCount
        self.criticalDataComplete = criticalDataComplete
        self.timeAxisClockIsValid = timeAxisClockIsValid
    }
}

public struct OCRDiagnosticMetadata: Codable, Sendable, Equatable {
    public let imageWidth: Int
    public let imageHeight: Int
    public let removedDashedBlueComponentCount: Int
    public let retainedBasalComponentCount: Int
    public let glucoseExtractionMode: String
    public let values: [String: Double]

    public init(
        imageWidth: Int,
        imageHeight: Int,
        removedDashedBlueComponentCount: Int,
        retainedBasalComponentCount: Int,
        glucoseExtractionMode: String,
        values: [String: Double] = [:]
    ) {
        self.imageWidth = imageWidth
        self.imageHeight = imageHeight
        self.removedDashedBlueComponentCount = removedDashedBlueComponentCount
        self.retainedBasalComponentCount = retainedBasalComponentCount
        self.glucoseExtractionMode = glucoseExtractionMode
        self.values = values
    }
}

public struct OCRAnalysisResult: Codable, Sendable, Equatable {
    public let id: UUID
    public let requestID: UUID
    public let algorithmVersion: String
    public let visionRevision: Int
    public let capturedAt: Date
    /// Absolute date of the calibrated data edge, independent of frozen capture.
    /// Nil preserves the capture-relative interpretation of older analysis runs.
    public let timeAxisReferenceDate: Date?
    public let status: OCRAnalysisStatus
    public let layout: OCRDetectedLayout
    public let timeCalibration: OCRAxisCalibration
    public let basalCalibration: OCRAxisCalibration?
    public let glucoseCalibration: OCRAxisCalibration?
    public let rawTextObservations: [OCRRawTextObservation]
    public let basalSteps: [OCRBasalStep]
    public let glucoseSamples: [OCRGlucoseSample]
    public let therapyEvents: [OCRTherapyEvent]
    public let quality: OCRAnalysisQuality
    public let warnings: [OCRAnalysisWarning]
    public let diagnostics: OCRDiagnosticMetadata

    public init(
        id: UUID = UUID(),
        requestID: UUID,
        algorithmVersion: String,
        visionRevision: Int,
        capturedAt: Date,
        timeAxisReferenceDate: Date? = nil,
        status: OCRAnalysisStatus,
        layout: OCRDetectedLayout,
        timeCalibration: OCRAxisCalibration,
        basalCalibration: OCRAxisCalibration?,
        glucoseCalibration: OCRAxisCalibration?,
        rawTextObservations: [OCRRawTextObservation],
        basalSteps: [OCRBasalStep],
        glucoseSamples: [OCRGlucoseSample],
        therapyEvents: [OCRTherapyEvent],
        quality: OCRAnalysisQuality,
        warnings: [OCRAnalysisWarning],
        diagnostics: OCRDiagnosticMetadata
    ) {
        self.id = id
        self.requestID = requestID
        self.algorithmVersion = algorithmVersion
        self.visionRevision = visionRevision
        self.capturedAt = capturedAt
        self.timeAxisReferenceDate = timeAxisReferenceDate
        self.status = status
        self.layout = layout
        self.timeCalibration = timeCalibration
        self.basalCalibration = basalCalibration
        self.glucoseCalibration = glucoseCalibration
        self.rawTextObservations = rawTextObservations
        self.basalSteps = basalSteps
        self.glucoseSamples = glucoseSamples
        self.therapyEvents = therapyEvents
        self.quality = quality
        self.warnings = warnings
        self.diagnostics = diagnostics
    }
}

public enum OCRAnalysisFailure: Error, LocalizedError, Sendable, Equatable {
    case invalidImage
    case unsupportedLayout(reason: String)
    case invalidTimeAxis(reason: String)
    case cancelled

    public var errorDescription: String? {
        switch self {
        case .invalidImage:
            "The supplied data is not a supported image."
        case let .unsupportedLayout(reason):
            "The screenshot layout is not supported: \(reason)"
        case let .invalidTimeAxis(reason):
            "The time axis could not be calibrated: \(reason)"
        case .cancelled:
            "The analysis was cancelled."
        }
    }
}
