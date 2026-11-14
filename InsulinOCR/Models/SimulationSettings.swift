import Foundation
import InsulinOCRCore

/// A named insulin-need adjustment to pick in the simulation.
struct ActivityPreset: Codable, Equatable, Identifiable, Sendable {
    static let percentRange = 10.0...300.0
    static let durationRange = 15...2_880

    var id: UUID = UUID()
    var name: String
    /// 100 is normal; below 100 means less insulin is needed.
    var insulinNeedPercent: Double
    var durationMinutes: Int

    var isValid: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && insulinNeedPercent.isFinite
            && Self.percentRange.contains(insulinNeedPercent)
            && Self.durationRange.contains(durationMinutes)
    }
}

/// Glucose limits for the simulation chart, in mmol/L.
struct GlucoseLimits: Codable, Equatable, Sendable {
    static let allowedRange = 2.0...30.0

    /// Predicted glucose below this is marked as hypoglycaemic.
    var hypo = 3.9
    var targetLow = 3.9
    var targetHigh = 10.0
    /// Predicted glucose above this is marked as hyperglycaemic.
    var hyper = 10.0

    var isValid: Bool {
        [hypo, targetLow, targetHigh, hyper].allSatisfy { $0.isFinite && Self.allowedRange.contains($0) }
            && hypo <= targetLow && targetLow < targetHigh && targetHigh <= hyper
    }
}

/// Everything the glucose prediction of the simulation is configured with.
/// Sensitivity and carbohydrate ratio have no default: without them there is
/// no glucose prediction.
struct SimulationSettings: Codable, Equatable, Sendable {
    /// Allowed insulin sensitivity in mmol/L per unit.
    static let sensitivityRange = 0.1...20.0
    /// Allowed carbohydrate ratio in grams per unit.
    static let carbRatioRange = 1.0...150.0

    var sensitivity: DailyProfile?
    var carbRatio: DailyProfile?
    var activityPresets: [ActivityPreset] = []
    var limits = GlucoseLimits()
    var model: GlucosePredictionModel = .loop

    init() {}

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        sensitivity = try container.decodeIfPresent(DailyProfile.self, forKey: .sensitivity)
        carbRatio = try container.decodeIfPresent(DailyProfile.self, forKey: .carbRatio)
        activityPresets = (try container.decodeIfPresent([ActivityPreset].self, forKey: .activityPresets) ?? [])
            .filter(\.isValid)
        let storedLimits = try container.decodeIfPresent(GlucoseLimits.self, forKey: .limits)
        limits = storedLimits.flatMap { $0.isValid ? $0 : nil } ?? GlucoseLimits()
        model = try container.decodeIfPresent(GlucosePredictionModel.self, forKey: .model) ?? .loop
    }
}

/// Editable form of a daily profile. Values are typed in the display unit;
/// `displayScale` converts a stored value into it (18 for mg/dl, else 1).
struct DailyProfileDraft: Equatable {
    struct Row: Equatable, Identifiable {
        let id: UUID
        var startMinute: Int
        var text: String

        init(id: UUID = UUID(), startMinute: Int, text: String) {
            self.id = id
            self.startMinute = startMinute
            self.text = text
        }
    }

    /// The first row always starts at midnight.
    var rows: [Row]

    init(rows: [Row]) {
        self.rows = rows
    }

    init(profile: DailyProfile?, displayScale: Double) {
        rows = profile?.blocks.map {
            Row(startMinute: $0.startMinute, text: Self.text($0.value * displayScale))
        } ?? [Row(startMinute: 0, text: "")]
    }

    static func text(_ value: Double) -> String {
        String(format: "%.4g", value)
    }

    static func number(_ text: String) -> Double? {
        Double(text.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: "."))
    }

    /// A new block starts one hour after the latest one, while the day has room.
    var canAddRow: Bool {
        (rows.map(\.startMinute).max() ?? 0) + 60 < 1_440
    }

    mutating func addRow() {
        guard canAddRow else { return }
        rows.append(Row(startMinute: (rows.map(\.startMinute).max() ?? 0) + 60, text: ""))
    }

    /// Nil while any value is missing or outside `allowed` (in stored units),
    /// or two blocks start at the same time.
    func profile(displayScale: Double, allowed: ClosedRange<Double>) -> DailyProfile? {
        guard displayScale > 0, rows.first?.startMinute == 0 else { return nil }
        var blocks: [DailyProfile.Block] = []
        for row in rows.sorted(by: { $0.startMinute < $1.startMinute }) {
            guard let typed = Self.number(row.text) else { return nil }
            let value = typed / displayScale
            guard value.isFinite, allowed.contains(value) else { return nil }
            blocks.append(.init(startMinute: row.startMinute, value: value))
        }
        return try? DailyProfile(blocks: blocks)
    }
}
