import Foundation
import InsulinOCRCore

struct StoredAnalysisEnvelope: Codable, Equatable, Sendable {
    let run: AnalysisRun
    let extractorResult: OCRAnalysisResult
}

/// Shares the immutable run store and cloud transport with successful attempts.
struct StoredAnalysisFailureEnvelope: Codable, Equatable, Sendable {
    let caseID: UUID
    let failure: OCRFailedAnalysis
}
