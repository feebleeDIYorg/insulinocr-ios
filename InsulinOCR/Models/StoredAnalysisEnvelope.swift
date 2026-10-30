import Foundation
import InsulinOCRCore

struct StoredAnalysisEnvelope: Codable, Equatable, Sendable {
    let run: AnalysisRun
    let extractorResult: OCRAnalysisResult
}
