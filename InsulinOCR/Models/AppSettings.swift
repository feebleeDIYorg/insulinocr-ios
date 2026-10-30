import Foundation
import Observation

enum GlucoseDisplayUnit: String, CaseIterable, Identifiable, Codable, Sendable {
    case mmolL
    case mgdL

    var id: String { rawValue }

    var label: String {
        switch self {
        case .mmolL: "mmol/l"
        case .mgdL: "mg/dl"
        }
    }
}

enum StoredInsulinPreset: String, CaseIterable, Identifiable, Codable, Sendable {
    case novoRapid
    case fiasp
    case lyumjev

    var id: String { rawValue }

    var localizedName: String {
        switch self {
        case .novoRapid: "NovoRapid"
        case .fiasp: "Fiasp"
        case .lyumjev: "Lyumjev"
        }
    }

    var peakMinutes: Int {
        switch self {
        case .novoRapid: 75
        case .fiasp: 55
        case .lyumjev: 45
        }
    }
}

struct ComputationSettingsSnapshot: Codable, Equatable, Sendable {
    let diaMinutes: Int
    let insulinPreset: StoredInsulinPreset
    let insulinPeakMinutes: Int
    let carbAbsorptionMinutes: Int
    let carbDelayMinutes: Int
    let glucoseUnit: GlucoseDisplayUnit
    let createdAt: Date
}

@MainActor
@Observable
final class AppSettings {
    private enum Key {
        static let onboardingComplete = "settings.onboardingComplete"
        static let diaMinutes = "settings.diaMinutes"
        static let insulinPreset = "settings.insulinPreset"
        static let carbAbsorptionMinutes = "settings.carbAbsorptionMinutes"
        static let glucoseUnit = "settings.glucoseUnit"
        static let iCloudEnabled = "settings.iCloudEnabled"
    }

    private let defaults: UserDefaults

    var onboardingComplete: Bool {
        didSet { defaults.set(onboardingComplete, forKey: Key.onboardingComplete) }
    }

    var diaMinutes: Int {
        didSet { defaults.set(diaMinutes, forKey: Key.diaMinutes) }
    }

    var insulinPreset: StoredInsulinPreset {
        didSet { defaults.set(insulinPreset.rawValue, forKey: Key.insulinPreset) }
    }

    var carbAbsorptionMinutes: Int {
        didSet { defaults.set(carbAbsorptionMinutes, forKey: Key.carbAbsorptionMinutes) }
    }

    var glucoseUnit: GlucoseDisplayUnit {
        didSet { defaults.set(glucoseUnit.rawValue, forKey: Key.glucoseUnit) }
    }

    var iCloudEnabled: Bool {
        didSet { defaults.set(iCloudEnabled, forKey: Key.iCloudEnabled) }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.onboardingComplete = defaults.bool(forKey: Key.onboardingComplete)

        let storedDIA = defaults.integer(forKey: Key.diaMinutes)
        self.diaMinutes = storedDIA == 0 ? 360 : storedDIA

        self.insulinPreset = StoredInsulinPreset(
            rawValue: defaults.string(forKey: Key.insulinPreset) ?? ""
        ) ?? .fiasp

        let storedCarbDuration = defaults.integer(forKey: Key.carbAbsorptionMinutes)
        self.carbAbsorptionMinutes = storedCarbDuration == 0 ? 240 : storedCarbDuration

        self.glucoseUnit = GlucoseDisplayUnit(
            rawValue: defaults.string(forKey: Key.glucoseUnit) ?? ""
        ) ?? .mmolL
        self.iCloudEnabled = defaults.bool(forKey: Key.iCloudEnabled)
    }

    var snapshot: ComputationSettingsSnapshot {
        ComputationSettingsSnapshot(
            diaMinutes: diaMinutes,
            insulinPreset: insulinPreset,
            insulinPeakMinutes: insulinPreset.peakMinutes,
            carbAbsorptionMinutes: carbAbsorptionMinutes,
            carbDelayMinutes: 10,
            glucoseUnit: glucoseUnit,
            createdAt: .now
        )
    }

    func completeOnboarding(diaMinutes: Int, insulinPreset: StoredInsulinPreset) {
        self.diaMinutes = diaMinutes
        self.insulinPreset = insulinPreset
        onboardingComplete = true
    }
}
