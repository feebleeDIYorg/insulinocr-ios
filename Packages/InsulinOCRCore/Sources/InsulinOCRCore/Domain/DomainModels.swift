import Foundation

// MARK: - Shared value types

public struct NormalizedBoundingBox: Codable, Hashable, Sendable {
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

    public var isValid: Bool {
        [x, y, width, height].allSatisfy(\.isFinite)
            && x >= 0 && y >= 0
            && width >= 0 && height >= 0
            && x + width <= 1.000_001
            && y + height <= 1.000_001
    }
}

public enum GlucoseUnit: String, Codable, CaseIterable, Sendable {
    case millimolesPerLiter
    case milligramsPerDeciliter
}

public enum InsulinType: String, Codable, CaseIterable, Sendable {
    case novoRapid
    case fiasp
    case lyumjev

    public var peakMinutes: Double {
        switch self {
        case .novoRapid: 75
        case .fiasp: 55
        case .lyumjev: 45
        }
    }
}

public enum TherapySettingsError: Error, Equatable, Sendable {
    case invalidDIAMinutes
    case invalidCarbAbsorptionMinutes
}

public struct TherapySettings: Codable, Hashable, Sendable {
    public let diaMinutes: Int
    public let insulinType: InsulinType
    public let carbAbsorptionMinutes: Int
    public let glucoseUnit: GlucoseUnit

    public init(
        diaMinutes: Int,
        insulinType: InsulinType,
        carbAbsorptionMinutes: Int,
        glucoseUnit: GlucoseUnit = .millimolesPerLiter
    ) throws {
        guard (180 ... 600).contains(diaMinutes), diaMinutes.isMultiple(of: 30) else {
            throw TherapySettingsError.invalidDIAMinutes
        }
        guard (120 ... 480).contains(carbAbsorptionMinutes), carbAbsorptionMinutes.isMultiple(of: 30) else {
            throw TherapySettingsError.invalidCarbAbsorptionMinutes
        }
        self.diaMinutes = diaMinutes
        self.insulinType = insulinType
        self.carbAbsorptionMinutes = carbAbsorptionMinutes
        self.glucoseUnit = glucoseUnit
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let diaMinutes = try container.decode(Int.self, forKey: .diaMinutes)
        let insulinType = try container.decode(InsulinType.self, forKey: .insulinType)
        let carbAbsorptionMinutes = try container.decode(Int.self, forKey: .carbAbsorptionMinutes)
        let glucoseUnit = try container.decode(GlucoseUnit.self, forKey: .glucoseUnit)
        try self.init(
            diaMinutes: diaMinutes,
            insulinType: insulinType,
            carbAbsorptionMinutes: carbAbsorptionMinutes,
            glucoseUnit: glucoseUnit
        )
    }
}

// MARK: - Case and asset metadata

public enum CaseStatus: String, Codable, Sendable {
    case queued
    case analysing
    case complete
    case incomplete
    case needsReview
    case failed
    case unsupportedLayout
}

public enum CaptureDateSource: String, Codable, Sendable {
    case imageMetadata
    case fileMetadata
    case importDate
    case userCorrection
}

public enum SyncState: String, Codable, Sendable {
    case localOnly
    case pending
    case synced
    case conflict
    case failed
    case tombstone
}

public struct CaseRecord: Codable, Identifiable, Hashable, Sendable {
    public let id: UUID
    public var title: String
    public var captureDate: Date
    public var captureTimeZoneIdentifier: String
    public var captureDateSource: CaptureDateSource
    public var status: CaseStatus
    public let screenshotAssetID: UUID
    public var activeAnalysisRunID: UUID?
    public var activeCorrectionRevisionID: UUID?
    public var activeComputationRunID: UUID?
    public var syncState: SyncState
    public var createdAt: Date
    public var modifiedAt: Date
    public var deletedAt: Date?

    public init(
        id: UUID = UUID(),
        title: String,
        captureDate: Date,
        captureTimeZoneIdentifier: String,
        captureDateSource: CaptureDateSource,
        status: CaseStatus = .queued,
        screenshotAssetID: UUID,
        activeAnalysisRunID: UUID? = nil,
        activeCorrectionRevisionID: UUID? = nil,
        activeComputationRunID: UUID? = nil,
        syncState: SyncState = .localOnly,
        createdAt: Date = Date(),
        modifiedAt: Date = Date(),
        deletedAt: Date? = nil
    ) {
        self.id = id
        self.title = title
        self.captureDate = captureDate
        self.captureTimeZoneIdentifier = captureTimeZoneIdentifier
        self.captureDateSource = captureDateSource
        self.status = status
        self.screenshotAssetID = screenshotAssetID
        self.activeAnalysisRunID = activeAnalysisRunID
        self.activeCorrectionRevisionID = activeCorrectionRevisionID
        self.activeComputationRunID = activeComputationRunID
        self.syncState = syncState
        self.createdAt = createdAt
        self.modifiedAt = modifiedAt
        self.deletedAt = deletedAt
    }
}

public struct ScreenshotAsset: Codable, Identifiable, Hashable, Sendable {
    public let id: UUID
    public let relativePath: String
    public let diagnosticRelativePath: String?
    public let uniformTypeIdentifier: String
    public let pixelWidth: Int
    public let pixelHeight: Int
    public let byteCount: Int
    public let sha256: String
    public let captureDate: Date
    public let captureDateSource: CaptureDateSource
    public let layoutProfile: String?

    public init(
        id: UUID = UUID(),
        relativePath: String,
        diagnosticRelativePath: String? = nil,
        uniformTypeIdentifier: String,
        pixelWidth: Int,
        pixelHeight: Int,
        byteCount: Int,
        sha256: String,
        captureDate: Date,
        captureDateSource: CaptureDateSource,
        layoutProfile: String? = nil
    ) {
        self.id = id
        self.relativePath = relativePath
        self.diagnosticRelativePath = diagnosticRelativePath
        self.uniformTypeIdentifier = uniformTypeIdentifier
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.byteCount = byteCount
        self.sha256 = sha256
        self.captureDate = captureDate
        self.captureDateSource = captureDateSource
        self.layoutProfile = layoutProfile
    }
}

// MARK: - Analysis provenance

public enum ObservationKind: String, Codable, CaseIterable, Sendable {
    case basalRate
    case glucose
    case bolus
    case carbohydrate
    case eventStem
}

public enum ObservationUnit: String, Codable, Sendable {
    case unitsPerHour
    case insulinUnits
    case grams
    case millimolesPerLiter
    case milligramsPerDeciliter
    case none
}

public enum ObservationAmountState: String, Codable, Sendable {
    case known
    case amountUnknown
    case notApplicable
}

public struct ObservationCandidate: Codable, Identifiable, Hashable, Sendable {
    public let id: UUID
    public let text: String?
    public let numericValue: Double?
    public let confidence: Double
    public let rejectionReason: String?

    public init(
        id: UUID = UUID(),
        text: String? = nil,
        numericValue: Double? = nil,
        confidence: Double,
        rejectionReason: String? = nil
    ) {
        self.id = id
        self.text = text
        self.numericValue = numericValue
        self.confidence = confidence
        self.rejectionReason = rejectionReason
    }
}

public struct ObservationConfidence: Codable, Hashable, Sendable {
    public let overall: Double
    public let geometry: Double
    public let recognition: Double
    public let calibration: Double

    public init(overall: Double, geometry: Double, recognition: Double, calibration: Double) {
        self.overall = overall
        self.geometry = geometry
        self.recognition = recognition
        self.calibration = calibration
    }
}

public enum ObservationProvenance: String, Codable, Sendable {
    case visionOCR
    case pixelPath
    case eventGeometry
    case userCorrection
    case simulation
}

public struct RawObservation: Codable, Identifiable, Hashable, Sendable {
    public let id: UUID
    public let kind: ObservationKind
    public let startDate: Date
    public let endDate: Date?
    public let amount: Double?
    public let unit: ObservationUnit
    public let amountState: ObservationAmountState
    public let boundingBox: NormalizedBoundingBox
    public let candidates: [ObservationCandidate]
    public let confidence: ObservationConfidence
    public let provenance: ObservationProvenance
    public let sourceIdentifier: String?

    public init(
        id: UUID = UUID(),
        kind: ObservationKind,
        startDate: Date,
        endDate: Date? = nil,
        amount: Double?,
        unit: ObservationUnit,
        amountState: ObservationAmountState,
        boundingBox: NormalizedBoundingBox,
        candidates: [ObservationCandidate] = [],
        confidence: ObservationConfidence,
        provenance: ObservationProvenance,
        sourceIdentifier: String? = nil
    ) {
        self.id = id
        self.kind = kind
        self.startDate = startDate
        self.endDate = endDate
        self.amount = amount
        self.unit = unit
        self.amountState = amountState
        self.boundingBox = boundingBox
        self.candidates = candidates
        self.confidence = confidence
        self.provenance = provenance
        self.sourceIdentifier = sourceIdentifier
    }
}

public struct OCRToken: Codable, Identifiable, Hashable, Sendable {
    public let id: UUID
    public let text: String
    public let confidence: Double
    public let boundingBox: NormalizedBoundingBox
    public let alternatives: [String]

    public init(
        id: UUID = UUID(),
        text: String,
        confidence: Double,
        boundingBox: NormalizedBoundingBox,
        alternatives: [String] = []
    ) {
        self.id = id
        self.text = text
        self.confidence = confidence
        self.boundingBox = boundingBox
        self.alternatives = alternatives
    }
}

public struct AxisCalibration: Codable, Hashable, Sendable {
    public let timeStart: Date
    public let timeEnd: Date
    public let plotBounds: NormalizedBoundingBox
    public let timeResidualMinutes: Double
    public let basalUnitsPerNormalizedY: Double?
    public let glucoseUnitsPerNormalizedY: Double?

    public init(
        timeStart: Date,
        timeEnd: Date,
        plotBounds: NormalizedBoundingBox,
        timeResidualMinutes: Double,
        basalUnitsPerNormalizedY: Double? = nil,
        glucoseUnitsPerNormalizedY: Double? = nil
    ) {
        self.timeStart = timeStart
        self.timeEnd = timeEnd
        self.plotBounds = plotBounds
        self.timeResidualMinutes = timeResidualMinutes
        self.basalUnitsPerNormalizedY = basalUnitsPerNormalizedY
        self.glucoseUnitsPerNormalizedY = glucoseUnitsPerNormalizedY
    }
}

public enum AnalysisBlocker: String, Codable, Hashable, Sendable {
    case invalidTimeAxis
    case invalidBasalAxis
    case incompleteBasalPath
    case unknownInsulinAmount
    case unknownCarbohydrateAmount
    case unclassifiedEvent
    case corruptAsset
}

public struct AnalysisQuality: Codable, Hashable, Sendable {
    public let layoutConfidence: Double
    public let timeAxisConfidence: Double
    public let basalCoverage: Double
    public let glucoseConfidence: Double
    public let eventConfidence: Double
    public let blockers: Set<AnalysisBlocker>
    public let warnings: [String]

    public init(
        layoutConfidence: Double,
        timeAxisConfidence: Double,
        basalCoverage: Double,
        glucoseConfidence: Double,
        eventConfidence: Double,
        blockers: Set<AnalysisBlocker> = [],
        warnings: [String] = []
    ) {
        self.layoutConfidence = layoutConfidence
        self.timeAxisConfidence = timeAxisConfidence
        self.basalCoverage = basalCoverage
        self.glucoseConfidence = glucoseConfidence
        self.eventConfidence = eventConfidence
        self.blockers = blockers
        self.warnings = warnings
    }
}

public struct AnalysisRun: Codable, Identifiable, Hashable, Sendable {
    public let id: UUID
    public let caseID: UUID
    public let createdAt: Date
    public let algorithmVersion: String
    public let visionRevision: Int
    public let layoutProfile: String
    public let calibration: AxisCalibration
    public let rawOCR: [OCRToken]
    public let observations: [RawObservation]
    public let quality: AnalysisQuality
    public let diagnosticAssetSHA256: String?

    public init(
        id: UUID = UUID(),
        caseID: UUID,
        createdAt: Date = Date(),
        algorithmVersion: String,
        visionRevision: Int,
        layoutProfile: String,
        calibration: AxisCalibration,
        rawOCR: [OCRToken],
        observations: [RawObservation],
        quality: AnalysisQuality,
        diagnosticAssetSHA256: String? = nil
    ) {
        self.id = id
        self.caseID = caseID
        self.createdAt = createdAt
        self.algorithmVersion = algorithmVersion
        self.visionRevision = visionRevision
        self.layoutProfile = layoutProfile
        self.calibration = calibration
        self.rawOCR = rawOCR
        self.observations = observations
        self.quality = quality
        self.diagnosticAssetSHA256 = diagnosticAssetSHA256
    }
}

// MARK: - Corrections and effective data

public enum CorrectionOperation: Codable, Hashable, Sendable {
    case add(RawObservation)
    case update(targetID: UUID, replacement: RawObservation)
    case delete(targetID: UUID)
}

public struct CorrectionRevision: Codable, Identifiable, Hashable, Sendable {
    public let id: UUID
    public let caseID: UUID
    public let analysisRunID: UUID
    public let parentRevisionID: UUID?
    public let createdAt: Date
    public let operations: [CorrectionOperation]
    public let note: String?

    public init(
        id: UUID = UUID(),
        caseID: UUID,
        analysisRunID: UUID,
        parentRevisionID: UUID? = nil,
        createdAt: Date = Date(),
        operations: [CorrectionOperation],
        note: String? = nil
    ) {
        self.id = id
        self.caseID = caseID
        self.analysisRunID = analysisRunID
        self.parentRevisionID = parentRevisionID
        self.createdAt = createdAt
        self.operations = operations
        self.note = note
    }
}

public struct BasalSegment: Codable, Identifiable, Hashable, Sendable {
    public let id: UUID
    public let startDate: Date
    public let endDate: Date
    public let unitsPerHour: Double
    public let sourceObservationID: UUID?

    public init(
        id: UUID = UUID(),
        startDate: Date,
        endDate: Date,
        unitsPerHour: Double,
        sourceObservationID: UUID? = nil
    ) {
        self.id = id
        self.startDate = startDate
        self.endDate = endDate
        self.unitsPerHour = unitsPerHour
        self.sourceObservationID = sourceObservationID
    }
}

public struct InsulinEvent: Codable, Identifiable, Hashable, Sendable {
    public let id: UUID
    public let date: Date
    public let units: Double
    public let sourceObservationID: UUID?

    public init(id: UUID = UUID(), date: Date, units: Double, sourceObservationID: UUID? = nil) {
        self.id = id
        self.date = date
        self.units = units
        self.sourceObservationID = sourceObservationID
    }
}

public struct CarbohydrateEvent: Codable, Identifiable, Hashable, Sendable {
    public let id: UUID
    public let date: Date
    public let grams: Double
    public let sourceObservationID: UUID?

    public init(id: UUID = UUID(), date: Date, grams: Double, sourceObservationID: UUID? = nil) {
        self.id = id
        self.date = date
        self.grams = grams
        self.sourceObservationID = sourceObservationID
    }
}

public struct GlucoseSample: Codable, Identifiable, Hashable, Sendable {
    public let id: UUID
    public let date: Date
    public let value: Double
    public let unit: GlucoseUnit
    public let sourceObservationID: UUID?

    public init(
        id: UUID = UUID(),
        date: Date,
        value: Double,
        unit: GlucoseUnit,
        sourceObservationID: UUID? = nil
    ) {
        self.id = id
        self.date = date
        self.value = value
        self.unit = unit
        self.sourceObservationID = sourceObservationID
    }
}

public enum CriticalDataIssue: String, Codable, Hashable, Sendable {
    case invalidTimeAxis
    case invalidBasalAxis
    case incompleteBasalPath
    case unknownBolusAmount
    case unknownCarbohydrateAmount
    case unclassifiedEvent
}

public struct EffectiveTherapyData: Codable, Hashable, Sendable {
    public let basalSegments: [BasalSegment]
    public let boluses: [InsulinEvent]
    public let carbohydrates: [CarbohydrateEvent]
    public let glucoseSamples: [GlucoseSample]
    public let unresolvedIssues: Set<CriticalDataIssue>
    public let sourceAnalysisRunID: UUID?
    public let sourceCorrectionRevisionID: UUID?
    public let observedHistoryMinutes: Double?

    public init(
        basalSegments: [BasalSegment],
        boluses: [InsulinEvent],
        carbohydrates: [CarbohydrateEvent],
        glucoseSamples: [GlucoseSample],
        unresolvedIssues: Set<CriticalDataIssue> = [],
        sourceAnalysisRunID: UUID? = nil,
        sourceCorrectionRevisionID: UUID? = nil,
        observedHistoryMinutes: Double? = nil
    ) {
        self.basalSegments = basalSegments
        self.boluses = boluses
        self.carbohydrates = carbohydrates
        self.glucoseSamples = glucoseSamples
        self.unresolvedIssues = unresolvedIssues
        self.sourceAnalysisRunID = sourceAnalysisRunID
        self.sourceCorrectionRevisionID = sourceCorrectionRevisionID
        self.observedHistoryMinutes = observedHistoryMinutes
    }
}

public enum EffectiveDataError: Error, Equatable, Sendable {
    case revisionForDifferentAnalysisRun
    case invalidCorrectionTarget(UUID)
    case invalidObservation(UUID)
}

public protocol EffectiveDataReducer: Sendable {
    func reduce(analysisRun: AnalysisRun, revisions: [CorrectionRevision]) throws -> EffectiveTherapyData
    func reduce(analysisRun: AnalysisRun, revisions: [CorrectionRevision],
                basalCoverageWindow: DateInterval) throws -> EffectiveTherapyData
}

public extension EffectiveDataReducer {
    // Existing conformers remain conservative until they implement contextual review.
    func reduce(analysisRun: AnalysisRun, revisions: [CorrectionRevision],
                basalCoverageWindow: DateInterval) throws -> EffectiveTherapyData {
        try reduce(analysisRun: analysisRun, revisions: revisions)
    }
}

// MARK: - Computation and simulation

public enum MetricUnavailableReason: String, Codable, Hashable, Sendable {
    case insufficientHistory
    case invalidModelParameters
    case invalidTimeAxis
    case invalidBasalAxis
    case incompleteBasalPath
    case unknownBolusAmount
    case unknownCarbohydrateAmount
    case unclassifiedEvent
}

public enum MetricResult: Codable, Hashable, Sendable {
    case available(Double)
    case unavailable(MetricUnavailableReason)

    public var value: Double? {
        guard case .available(let value) = self else { return nil }
        return value
    }
}

public struct ActivitySnapshot: Codable, Hashable, Sendable {
    public let date: Date
    public let basalIOB: MetricResult
    public let bolusIOB: MetricResult
    public let totalIOB: MetricResult
    public let cob: MetricResult

    public init(
        date: Date,
        basalIOB: MetricResult,
        bolusIOB: MetricResult,
        totalIOB: MetricResult,
        cob: MetricResult
    ) {
        self.date = date
        self.basalIOB = basalIOB
        self.bolusIOB = bolusIOB
        self.totalIOB = totalIOB
        self.cob = cob
    }
}

public struct ActivityComputation: Codable, Hashable, Sendable {
    public let current: ActivitySnapshot
    public let forecast: [ActivitySnapshot]

    public init(current: ActivitySnapshot, forecast: [ActivitySnapshot]) {
        self.current = current
        self.forecast = forecast
    }
}

public protocol ActivityCalculator: Sendable {
    func calculate(
        data: EffectiveTherapyData,
        settings: TherapySettings,
        referenceDate: Date,
        forecastStepMinutes: Int
    ) -> ActivityComputation
}

public struct ComputationRun: Codable, Identifiable, Hashable, Sendable {
    public let id: UUID
    public let caseID: UUID
    public let analysisRunID: UUID
    public let correctionRevisionID: UUID?
    public let createdAt: Date
    public let referenceDate: Date
    public let modelVersion: String
    public let settings: TherapySettings
    public let result: ActivityComputation

    public init(
        id: UUID = UUID(),
        caseID: UUID,
        analysisRunID: UUID,
        correctionRevisionID: UUID? = nil,
        createdAt: Date = Date(),
        referenceDate: Date,
        modelVersion: String,
        settings: TherapySettings,
        result: ActivityComputation
    ) {
        self.id = id
        self.caseID = caseID
        self.analysisRunID = analysisRunID
        self.correctionRevisionID = correctionRevisionID
        self.createdAt = createdAt
        self.referenceDate = referenceDate
        self.modelVersion = modelVersion
        self.settings = settings
        self.result = result
    }
}

public enum SimulationEvent: Codable, Identifiable, Hashable, Sendable {
    case bolus(InsulinEvent)
    case carbohydrate(CarbohydrateEvent)

    public var id: UUID {
        switch self {
        case .bolus(let event): event.id
        case .carbohydrate(let event): event.id
        }
    }
}

public struct SimulationScenario: Codable, Identifiable, Hashable, Sendable {
    public let id: UUID
    public let caseID: UUID
    public let baseComputationRunID: UUID
    public let name: String
    public let createdAt: Date
    public let events: [SimulationEvent]
    public let baseline: ActivitySnapshot
    public let scenario: ActivitySnapshot

    public init(
        id: UUID = UUID(),
        caseID: UUID,
        baseComputationRunID: UUID,
        name: String,
        createdAt: Date = Date(),
        events: [SimulationEvent],
        baseline: ActivitySnapshot,
        scenario: ActivitySnapshot
    ) {
        self.id = id
        self.caseID = caseID
        self.baseComputationRunID = baseComputationRunID
        self.name = name
        self.createdAt = createdAt
        self.events = events
        self.baseline = baseline
        self.scenario = scenario
    }
}

public struct SimulationDelta: Codable, Hashable, Sendable {
    public let basalIOB: Double?
    public let bolusIOB: Double?
    public let totalIOB: Double?
    public let cob: Double?

    public init(baseline: ActivitySnapshot, scenario: ActivitySnapshot) {
        basalIOB = Self.delta(baseline.basalIOB, scenario.basalIOB)
        bolusIOB = Self.delta(baseline.bolusIOB, scenario.bolusIOB)
        totalIOB = Self.delta(baseline.totalIOB, scenario.totalIOB)
        cob = Self.delta(baseline.cob, scenario.cob)
    }

    private static func delta(_ baseline: MetricResult, _ scenario: MetricResult) -> Double? {
        guard let base = baseline.value, let simulated = scenario.value else { return nil }
        return simulated - base
    }
}
