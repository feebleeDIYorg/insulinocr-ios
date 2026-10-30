import Compression
import CryptoKit
import Foundation

struct CloudScreenshotManifest: Codable, Equatable, Sendable {
    let id: UUID
    let originalFilename: String
    let uniformTypeIdentifier: String
    let pixelWidth: Int
    let pixelHeight: Int
    let byteCount: Int
    let sha256: String
    let captureTime: Date
    let captureTimeSourceRaw: String
    let layoutProfile: String?
}

struct CloudAnalysisRun: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    let createdAt: Date
    let algorithmVersion: String
    let visionRevision: Int
    let statusRaw: String
    let encodedPayload: Data
    let payloadSHA256: String
}

struct CloudCorrectionRevision: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    let basedOnAnalysisRunID: UUID
    let parentRevisionID: UUID?
    let createdAt: Date
    let encodedPayload: Data
    let payloadSHA256: String
    let hasConflict: Bool
}

struct CloudComputationRun: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    let analysisRunID: UUID
    let correctionRevisionID: UUID?
    let createdAt: Date
    let referenceTime: Date
    let modelVersion: String
    let encodedPayload: Data
    let payloadSHA256: String
}

struct CloudSimulationScenario: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    let basedOnComputationRunID: UUID
    let name: String
    let createdAt: Date
    let updatedAt: Date
    let encodedPayload: Data
    let payloadSHA256: String
}

/// The versioned, portable representation stored as a compressed CloudKit asset.
/// Image bytes remain separate CKAssets to avoid base64 duplication in JSON.
struct CloudCaseManifest: Codable, Equatable, Sendable {
    static let currentSchemaVersion = 1

    let schemaVersion: Int
    let caseID: UUID
    var title: String
    let createdAt: Date
    var modifiedAt: Date
    var captureTime: Date
    var captureTimeSourceRaw: String
    var captureTimeZoneIdentifier: String
    var statusRaw: String
    var reviewReason: String?
    var screenshot: CloudScreenshotManifest?
    var activeAnalysisRunID: UUID?
    var activeCorrectionRevisionID: UUID?
    var activeComputationRunID: UUID?
    var isDeletedTombstone: Bool
    var analysisRuns: [CloudAnalysisRun]
    var correctionRevisions: [CloudCorrectionRevision]
    var computationRuns: [CloudComputationRun]
    var simulations: [CloudSimulationScenario]

    /// Merges two device snapshots without mutating immutable run history.
    /// Scalar case metadata follows the most recently modified snapshot. A
    /// tombstone always wins, preventing an offline device from resurrecting a
    /// deleted medical case. Divergent correction heads remain in history and
    /// explicitly require review.
    func merging(_ other: CloudCaseManifest) -> CloudCaseManifest {
        precondition(caseID == other.caseID)
        let preferred = Self.prefers(self, over: other) ? self : other
        let alternate = preferred == self ? other : self

        let analysis = Self.union(
            preferred.analysisRuns,
            alternate.analysisRuns,
            conflict: { $0.payloadSHA256 != $1.payloadSHA256 }
        )
        let corrections = Self.union(
            preferred.correctionRevisions,
            alternate.correctionRevisions,
            conflict: { $0.payloadSHA256 != $1.payloadSHA256 }
        )
        let computations = Self.union(
            preferred.computationRuns,
            alternate.computationRuns,
            conflict: { $0.payloadSHA256 != $1.payloadSHA256 }
        )
        let simulations = Self.union(
            preferred.simulations,
            alternate.simulations,
            conflict: { $0.payloadSHA256 != $1.payloadSHA256 }
        )

        let correctionConflict = Self.hasDivergentCorrectionHeads(corrections.values)
            || corrections.hadCollision
        let immutableCollision = analysis.hadCollision
            || computations.hadCollision
            || simulations.hadCollision
        let screenshotCollision = Self.screenshotsConflict(screenshot, other.screenshot)
        let needsReview = correctionConflict || immutableCollision || screenshotCollision

        var result = preferred
        result.modifiedAt = max(modifiedAt, other.modifiedAt)
        result.isDeletedTombstone = isDeletedTombstone || other.isDeletedTombstone
        result.screenshot = Self.mergedScreenshot(
            screenshot,
            other.screenshot,
            preferred: preferred.screenshot
        )
        result.analysisRuns = analysis.values.sorted {
            $0.createdAt == $1.createdAt
                ? $0.id.uuidString < $1.id.uuidString
                : $0.createdAt < $1.createdAt
        }
        result.correctionRevisions = corrections.values
            .map { revision in
                guard needsReview else { return revision }
                return CloudCorrectionRevision(
                    id: revision.id,
                    basedOnAnalysisRunID: revision.basedOnAnalysisRunID,
                    parentRevisionID: revision.parentRevisionID,
                    createdAt: revision.createdAt,
                    encodedPayload: revision.encodedPayload,
                    payloadSHA256: revision.payloadSHA256,
                    hasConflict: revision.hasConflict || correctionConflict
                )
            }
            .sorted {
                $0.createdAt == $1.createdAt
                    ? $0.id.uuidString < $1.id.uuidString
                    : $0.createdAt < $1.createdAt
            }
        result.computationRuns = computations.values.sorted {
            $0.createdAt == $1.createdAt
                ? $0.id.uuidString < $1.id.uuidString
                : $0.createdAt < $1.createdAt
        }
        result.simulations = simulations.values.sorted {
            $0.createdAt == $1.createdAt
                ? $0.id.uuidString < $1.id.uuidString
                : $0.createdAt < $1.createdAt
        }
        if result.isDeletedTombstone {
            result.analysisRuns = []
            result.correctionRevisions = []
            result.computationRuns = []
            result.simulations = []
            result.activeAnalysisRunID = nil
            result.activeCorrectionRevisionID = nil
            result.activeComputationRunID = nil
            result.title = "Gelöschter Case"
            result.reviewReason = nil
        }
        if needsReview, !result.isDeletedTombstone {
            result.activeComputationRunID = nil
            result.statusRaw = StoredCaseStatus.needsReview.rawValue
            result.reviewReason = "Synchronisierungskonflikt: konkurrierende Korrekturen oder unveränderliche Case-Daten stimmen nicht überein."
        }
        return result
    }

    func validate() throws {
        guard schemaVersion == Self.currentSchemaVersion else {
            throw CloudCaseValidationError.unsupportedSchema(schemaVersion)
        }
        try Self.validateUniqueIDs(analysisRuns, kind: "AnalysisRun")
        try Self.validateUniqueIDs(correctionRevisions, kind: "CorrectionRevision")
        try Self.validateUniqueIDs(computationRuns, kind: "ComputationRun")
        try Self.validateUniqueIDs(simulations, kind: "SimulationScenario")

        for run in analysisRuns where Self.sha256(run.encodedPayload) != run.payloadSHA256 {
            throw CloudCaseValidationError.payloadDigestMismatch("AnalysisRun", run.id)
        }
        for revision in correctionRevisions where Self.sha256(revision.encodedPayload) != revision.payloadSHA256 {
            throw CloudCaseValidationError.payloadDigestMismatch("CorrectionRevision", revision.id)
        }
        for run in computationRuns where Self.sha256(run.encodedPayload) != run.payloadSHA256 {
            throw CloudCaseValidationError.payloadDigestMismatch("ComputationRun", run.id)
        }
        for scenario in simulations where Self.sha256(scenario.encodedPayload) != scenario.payloadSHA256 {
            throw CloudCaseValidationError.payloadDigestMismatch("SimulationScenario", scenario.id)
        }

        let analysisIDs = Set(analysisRuns.map(\.id))
        let correctionIDs = Set(correctionRevisions.map(\.id))
        let computationIDs = Set(computationRuns.map(\.id))
        try Self.validateReference(activeAnalysisRunID, in: analysisIDs, kind: "activeAnalysisRunID")
        try Self.validateReference(
            activeCorrectionRevisionID,
            in: correctionIDs,
            kind: "activeCorrectionRevisionID"
        )
        try Self.validateReference(
            activeComputationRunID,
            in: computationIDs,
            kind: "activeComputationRunID"
        )
        for revision in correctionRevisions {
            try Self.validateReference(
                revision.basedOnAnalysisRunID,
                in: analysisIDs,
                kind: "CorrectionRevision.basedOnAnalysisRunID"
            )
            try Self.validateReference(
                revision.parentRevisionID,
                in: correctionIDs,
                kind: "CorrectionRevision.parentRevisionID"
            )
        }
        for run in computationRuns {
            try Self.validateReference(
                run.analysisRunID,
                in: analysisIDs,
                kind: "ComputationRun.analysisRunID"
            )
            try Self.validateReference(
                run.correctionRevisionID,
                in: correctionIDs,
                kind: "ComputationRun.correctionRevisionID"
            )
        }
        for scenario in simulations {
            try Self.validateReference(
                scenario.basedOnComputationRunID,
                in: computationIDs,
                kind: "SimulationScenario.basedOnComputationRunID"
            )
        }
    }

    private static func union<T: Identifiable>(
        _ preferred: [T],
        _ alternate: [T],
        conflict: (T, T) -> Bool
    ) -> (values: [T], hadCollision: Bool) where T.ID == UUID {
        var byID: [UUID: T] = [:]
        var hadCollision = false
        for value in preferred {
            if let existing = byID[value.id] {
                hadCollision = hadCollision || conflict(existing, value)
            } else {
                byID[value.id] = value
            }
        }
        for value in alternate {
            if let existing = byID[value.id] {
                hadCollision = hadCollision || conflict(existing, value)
            } else {
                byID[value.id] = value
            }
        }
        return (Array(byID.values), hadCollision)
    }

    private static func prefers(
        _ lhs: CloudCaseManifest,
        over rhs: CloudCaseManifest
    ) -> Bool {
        if lhs.modifiedAt != rhs.modifiedAt {
            return lhs.modifiedAt > rhs.modifiedAt
        }
        return lhs.tieBreaker >= rhs.tieBreaker
    }

    fileprivate static func prefersForArchive(
        _ lhs: CloudCaseManifest,
        over rhs: CloudCaseManifest
    ) -> Bool {
        prefers(lhs, over: rhs)
    }

    private var tieBreaker: String {
        [
            title,
            createdAt.timeIntervalSinceReferenceDate.description,
            captureTime.timeIntervalSinceReferenceDate.description,
            captureTimeSourceRaw,
            captureTimeZoneIdentifier,
            statusRaw,
            reviewReason ?? "",
            screenshot.map(Self.screenshotKey) ?? "",
            activeAnalysisRunID?.uuidString ?? "",
            activeCorrectionRevisionID?.uuidString ?? "",
            activeComputationRunID?.uuidString ?? "",
            isDeletedTombstone.description,
            analysisRuns.map { "\($0.id.uuidString):\($0.payloadSHA256)" }
                .sorted().joined(separator: ","),
            correctionRevisions.map {
                "\($0.id.uuidString):\($0.payloadSHA256):\($0.hasConflict)"
            }.sorted().joined(separator: ","),
            computationRuns.map { "\($0.id.uuidString):\($0.payloadSHA256)" }
                .sorted().joined(separator: ","),
            simulations.map { "\($0.id.uuidString):\($0.payloadSHA256)" }
                .sorted().joined(separator: ","),
        ].joined(separator: "\u{1f}")
    }

    private static func screenshotsConflict(
        _ lhs: CloudScreenshotManifest?,
        _ rhs: CloudScreenshotManifest?
    ) -> Bool {
        guard let lhs, let rhs else { return false }
        return lhs.id != rhs.id || lhs.sha256 != rhs.sha256
    }

    private static func mergedScreenshot(
        _ lhs: CloudScreenshotManifest?,
        _ rhs: CloudScreenshotManifest?,
        preferred: CloudScreenshotManifest?
    ) -> CloudScreenshotManifest? {
        guard let lhs else { return rhs }
        guard let rhs else { return lhs }
        guard lhs != rhs else { return lhs }
        if lhs.id == rhs.id, lhs.sha256 == rhs.sha256 {
            return preferred ?? lhs
        }
        let lhsKey = screenshotKey(lhs)
        let rhsKey = screenshotKey(rhs)
        return lhsKey <= rhsKey ? lhs : rhs
    }

    private static func screenshotKey(_ screenshot: CloudScreenshotManifest) -> String {
        [
            screenshot.sha256,
            screenshot.id.uuidString,
            screenshot.originalFilename,
            screenshot.uniformTypeIdentifier,
            screenshot.pixelWidth.description,
            screenshot.pixelHeight.description,
            screenshot.byteCount.description,
            screenshot.captureTime.timeIntervalSinceReferenceDate.description,
            screenshot.captureTimeSourceRaw,
            screenshot.layoutProfile ?? "",
        ].joined(separator: "\u{1e}")
    }

    private static func validateUniqueIDs<T: Identifiable>(
        _ values: [T],
        kind: String
    ) throws where T.ID == UUID {
        var ids = Set<UUID>()
        for value in values where !ids.insert(value.id).inserted {
            throw CloudCaseValidationError.duplicateIdentifier(kind, value.id)
        }
    }

    private static func validateReference(
        _ id: UUID?,
        in validIDs: Set<UUID>,
        kind: String
    ) throws {
        guard let id else { return }
        guard validIDs.contains(id) else {
            throw CloudCaseValidationError.danglingReference(kind, id)
        }
    }

    private static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func hasDivergentCorrectionHeads(
        _ revisions: [CloudCorrectionRevision]
    ) -> Bool {
        let childCounts = Dictionary(grouping: revisions) { revision in
            CorrectionBranch(
                analysisRunID: revision.basedOnAnalysisRunID,
                parentRevisionID: revision.parentRevisionID
            )
        }.mapValues(\.count)
        return childCounts.values.contains { $0 > 1 }
    }

    private struct CorrectionBranch: Hashable {
        let analysisRunID: UUID
        let parentRevisionID: UUID?
    }
}

struct CloudCaseArchive: Sendable {
    let manifest: CloudCaseManifest
    let originalImageData: Data?
    let diagnosticImageData: Data?

    func validate() throws {
        try manifest.validate()
        guard !manifest.isDeletedTombstone else { return }
        guard let screenshot = manifest.screenshot else {
            throw CloudCaseValidationError.missingScreenshotMetadata
        }
        guard let originalImageData else {
            throw CloudCaseValidationError.missingOriginalImage
        }
        guard originalImageData.count == screenshot.byteCount else {
            throw CloudCaseValidationError.originalImageSizeMismatch
        }
        guard Self.sha256(originalImageData) == screenshot.sha256 else {
            throw CloudCaseValidationError.originalImageDigestMismatch
        }
    }

    /// Merges complete snapshots while keeping the selected screenshot metadata
    /// and its CKAsset bytes paired. Tombstones intentionally discard assets.
    func merging(_ other: CloudCaseArchive) -> CloudCaseArchive {
        let mergedManifest = manifest.merging(other.manifest)
        guard !mergedManifest.isDeletedTombstone else {
            return CloudCaseArchive(
                manifest: mergedManifest,
                originalImageData: nil,
                diagnosticImageData: nil
            )
        }

        let selectedScreenshot = mergedManifest.screenshot
        let lhsMatches = manifest.screenshot == selectedScreenshot
        let rhsMatches = other.manifest.screenshot == selectedScreenshot
        let original: Data?
        let diagnostic: Data?
        if lhsMatches, !rhsMatches {
            original = originalImageData
            diagnostic = diagnosticImageData ?? other.diagnosticImageData
        } else if rhsMatches, !lhsMatches {
            original = other.originalImageData
            diagnostic = other.diagnosticImageData ?? diagnosticImageData
        } else if CloudCaseManifest.prefersForArchive(manifest, over: other.manifest) {
            original = originalImageData ?? other.originalImageData
            diagnostic = diagnosticImageData ?? other.diagnosticImageData
        } else {
            original = other.originalImageData ?? originalImageData
            diagnostic = other.diagnosticImageData ?? diagnosticImageData
        }
        return CloudCaseArchive(
            manifest: mergedManifest,
            originalImageData: original,
            diagnosticImageData: diagnostic
        )
    }

    private static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

enum CloudCaseValidationError: Error, LocalizedError, Equatable {
    case unsupportedSchema(Int)
    case duplicateIdentifier(String, UUID)
    case payloadDigestMismatch(String, UUID)
    case danglingReference(String, UUID)
    case missingScreenshotMetadata
    case missingOriginalImage
    case originalImageSizeMismatch
    case originalImageDigestMismatch

    var errorDescription: String? {
        switch self {
        case .unsupportedSchema(let version):
            "Nicht unterstütztes Cloud-Case-Schema: \(version)."
        case .duplicateIdentifier(let kind, let id):
            "\(kind) enthält die ID \(id.uuidString) mehrfach."
        case .payloadDigestMismatch(let kind, let id):
            "Die Prüfsumme von \(kind) \(id.uuidString) ist ungültig."
        case .danglingReference(let kind, let id):
            "\(kind) verweist auf die fehlende ID \(id.uuidString)."
        case .missingScreenshotMetadata:
            "Dem Cloud-Case fehlen Screenshot-Metadaten."
        case .missingOriginalImage:
            "Dem Cloud-Case fehlt der Original-Screenshot."
        case .originalImageSizeMismatch:
            "Die Größe des Original-Screenshots stimmt nicht mit dem Manifest überein."
        case .originalImageDigestMismatch:
            "Die Prüfsumme des Original-Screenshots ist ungültig."
        }
    }
}

enum CloudSyncCodecError: Error, Equatable {
    case invalidHeader
    case invalidPayloadLength
    case compressionFailed
    case decompressionFailed
}

enum CloudSyncCodec {
    private static let magic = Data("IOCRLZF1".utf8)

    static func encode(_ manifest: CloudCaseManifest) throws -> Data {
        let encoder = JSONEncoder.insulinOCR
        let json = try encoder.encode(manifest)
        let compressed = try lzfseCompress(json)
        var payload = magic
        var length = UInt64(json.count).bigEndian
        withUnsafeBytes(of: &length) { payload.append(contentsOf: $0) }
        payload.append(compressed)
        return payload
    }

    static func decode(_ data: Data) throws -> CloudCaseManifest {
        let headerCount = magic.count + MemoryLayout<UInt64>.size
        guard data.count >= headerCount, data.prefix(magic.count) == magic else {
            throw CloudSyncCodecError.invalidHeader
        }
        let lengthData = data.dropFirst(magic.count).prefix(MemoryLayout<UInt64>.size)
        let expectedLength = lengthData.reduce(UInt64.zero) { ($0 << 8) | UInt64($1) }
        guard expectedLength > 0, expectedLength <= 512 * 1_024 * 1_024 else {
            throw CloudSyncCodecError.invalidPayloadLength
        }
        let compressed = Data(data.dropFirst(headerCount))
        let json = try lzfseDecompress(compressed, outputCount: Int(expectedLength))
        return try JSONDecoder.insulinOCR.decode(CloudCaseManifest.self, from: json)
    }

    private static func lzfseCompress(_ data: Data) throws -> Data {
        let capacity = max(data.count + data.count / 8 + 256, 1_024)
        var destination = Data(count: capacity)
        let written = data.withUnsafeBytes { sourceBuffer in
            destination.withUnsafeMutableBytes { destinationBuffer in
                compression_encode_buffer(
                    destinationBuffer.bindMemory(to: UInt8.self).baseAddress!,
                    capacity,
                    sourceBuffer.bindMemory(to: UInt8.self).baseAddress!,
                    data.count,
                    nil,
                    COMPRESSION_LZFSE
                )
            }
        }
        guard written > 0 else { throw CloudSyncCodecError.compressionFailed }
        destination.count = written
        return destination
    }

    private static func lzfseDecompress(_ data: Data, outputCount: Int) throws -> Data {
        var destination = Data(count: outputCount)
        let written = data.withUnsafeBytes { sourceBuffer in
            destination.withUnsafeMutableBytes { destinationBuffer in
                compression_decode_buffer(
                    destinationBuffer.bindMemory(to: UInt8.self).baseAddress!,
                    outputCount,
                    sourceBuffer.bindMemory(to: UInt8.self).baseAddress!,
                    data.count,
                    nil,
                    COMPRESSION_LZFSE
                )
            }
        }
        guard written == outputCount else { throw CloudSyncCodecError.decompressionFailed }
        return destination
    }
}
