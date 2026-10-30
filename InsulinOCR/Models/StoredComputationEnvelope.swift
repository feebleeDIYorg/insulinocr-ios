import Foundation
import InsulinOCRCore

struct StoredComputationEnvelope: Codable, Equatable, Sendable {
    let run: ComputationRun
    let effectiveData: EffectiveTherapyData
    let presentation: StoredCasePresentation
}
