import Foundation

struct StoredCasePresentation: Codable, Equatable, Sendable {
    struct Metrics: Codable, Equatable, Sendable {
        let basalIOB: Double?
        let bolusIOB: Double?
        let totalIOB: Double?
        let activeCarbohydrates: Double?
    }

    struct GlucosePoint: Codable, Equatable, Identifiable, Sendable {
        let id: UUID
        let timestamp: Date
        let mmolL: Double
        let confidence: Double
    }

    struct BasalPoint: Codable, Equatable, Identifiable, Sendable {
        let id: UUID
        let timestamp: Date
        let unitsPerHour: Double
        let confidence: Double
    }

    struct EventPoint: Codable, Equatable, Identifiable, Sendable {
        enum Kind: String, Codable, Sendable {
            case bolus
            case carbohydrate
        }

        let id: UUID
        let timestamp: Date
        let kind: Kind
        let amount: Double?
        let confidence: Double
    }

    struct DecayPoint: Codable, Equatable, Identifiable, Sendable {
        let id: UUID
        let timestamp: Date
        let basalIOB: Double
        let bolusIOB: Double
        let totalIOB: Double
        let carbohydratesOnBoard: Double
    }

    let referenceTime: Date
    let isComplete: Bool
    let unavailableReasons: [String]
    let metrics: Metrics
    let glucose: [GlucosePoint]
    let basal: [BasalPoint]
    let events: [EventPoint]
    let decay: [DecayPoint]
}
