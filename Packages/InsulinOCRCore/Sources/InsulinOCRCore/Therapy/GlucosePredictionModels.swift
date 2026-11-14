import Foundation

public enum GlucosePredictionError: Error, Equatable, Sendable {
    case invalidProfile
    case invalidAdjustment
    case invalidSettings
}

/// A value that changes by time of day, as in Loop or AndroidAPS profiles.
/// The first block starts at midnight; each block holds until the next.
public struct DailyProfile: Codable, Hashable, Sendable {
    public struct Block: Codable, Hashable, Sendable {
        public let startMinute: Int
        public let value: Double

        public init(startMinute: Int, value: Double) {
            self.startMinute = startMinute
            self.value = value
        }
    }

    public let blocks: [Block]

    public init(blocks: [Block]) throws {
        guard let first = blocks.first, first.startMinute == 0,
              blocks.allSatisfy({ $0.value.isFinite && $0.value > 0 && (0..<1_440).contains($0.startMinute) }),
              zip(blocks, blocks.dropFirst()).allSatisfy({ $0.startMinute < $1.startMinute }) else {
            throw GlucosePredictionError.invalidProfile
        }
        self.blocks = blocks
    }

    public init(constant value: Double) throws {
        try self.init(blocks: [Block(startMinute: 0, value: value)])
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(blocks: try container.decode([Block].self, forKey: .blocks))
    }

    public func value(atMinuteOfDay minute: Int) -> Double {
        blocks.last(where: { $0.startMinute <= minute })?.value ?? blocks[0].value
    }

    public func value(at date: Date, timeZone: TimeZone) -> Double {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let parts = calendar.dateComponents([.hour, .minute], from: date)
        return value(atMinuteOfDay: (parts.hour ?? 0) * 60 + (parts.minute ?? 0))
    }
}

/// Temporary change of insulin need, as a Loop override ("overall insulin
/// needs") or an AndroidAPS profile percentage: 100 is normal, 70 means less
/// insulin is needed. It scales the basal reference by the factor and divides
/// insulin sensitivity and carbohydrate ratio by it.
public struct InsulinNeedAdjustment: Codable, Identifiable, Hashable, Sendable {
    public let id: UUID
    public let startDate: Date
    public let durationMinutes: Double
    public let percent: Double

    public init(id: UUID = UUID(), startDate: Date, durationMinutes: Double, percent: Double) throws {
        guard startDate.timeIntervalSinceReferenceDate.isFinite,
              durationMinutes.isFinite, durationMinutes > 0, durationMinutes <= 2_880,
              percent.isFinite, (10...300).contains(percent) else {
            throw GlucosePredictionError.invalidAdjustment
        }
        self.id = id
        self.startDate = startDate
        self.durationMinutes = durationMinutes
        self.percent = percent
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            id: try container.decode(UUID.self, forKey: .id),
            startDate: try container.decode(Date.self, forKey: .startDate),
            durationMinutes: try container.decode(Double.self, forKey: .durationMinutes),
            percent: try container.decode(Double.self, forKey: .percent)
        )
    }

    public var endDate: Date { startDate.addingTimeInterval(durationMinutes * 60) }

    public func isActive(at date: Date) -> Bool { date >= startDate && date < endDate }
}

/// Values a glucose prediction needs beyond the activity settings.
/// Glucose is in mmol/L throughout the model; the app converts for display.
public struct GlucosePredictionSettings: Codable, Hashable, Sendable {
    /// Insulin sensitivity in mmol/L per unit.
    public let sensitivity: DailyProfile
    /// Carbohydrate ratio in grams per unit.
    public let carbRatio: DailyProfile
    /// Profile basal rate that delivered basal is measured against. Zero
    /// counts all delivered basal as glucose-lowering.
    public let profileBasalUnitsPerHour: Double
    public let timeZoneIdentifier: String

    public init(
        sensitivity: DailyProfile,
        carbRatio: DailyProfile,
        profileBasalUnitsPerHour: Double,
        timeZoneIdentifier: String
    ) throws {
        guard profileBasalUnitsPerHour.isFinite, (0...20).contains(profileBasalUnitsPerHour),
              TimeZone(identifier: timeZoneIdentifier) != nil else {
            throw GlucosePredictionError.invalidSettings
        }
        self.sensitivity = sensitivity
        self.carbRatio = carbRatio
        self.profileBasalUnitsPerHour = profileBasalUnitsPerHour
        self.timeZoneIdentifier = timeZoneIdentifier
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            sensitivity: try container.decode(DailyProfile.self, forKey: .sensitivity),
            carbRatio: try container.decode(DailyProfile.self, forKey: .carbRatio),
            profileBasalUnitsPerHour: try container.decode(Double.self, forKey: .profileBasalUnitsPerHour),
            timeZoneIdentifier: try container.decode(String.self, forKey: .timeZoneIdentifier)
        )
    }
}

public enum GlucosePredictionModel: String, Codable, CaseIterable, Sendable {
    /// Loop: insulin and carbohydrate effects blended with glucose momentum.
    case loop
    /// oref-style curves (OpenAPS, AndroidAPS, Trio) with the app's own
    /// carbohydrate absorption curve. Not a bit-exact port of oref.
    case oref
}

public struct GlucosePredictionInput: Sendable {
    /// Therapy data with every simulated bolus and carbohydrate entry applied.
    public let data: EffectiveTherapyData
    public let therapy: TherapySettings
    public let prediction: GlucosePredictionSettings
    public let adjustments: [InsulinNeedAdjustment]
    public let referenceDate: Date

    public init(
        data: EffectiveTherapyData,
        therapy: TherapySettings,
        prediction: GlucosePredictionSettings,
        adjustments: [InsulinNeedAdjustment] = [],
        referenceDate: Date
    ) {
        self.data = data
        self.therapy = therapy
        self.prediction = prediction
        self.adjustments = adjustments
        self.referenceDate = referenceDate
    }
}

/// A model extrapolation, not a measurement and not dosing advice.
public struct GlucosePrediction: Codable, Hashable, Sendable {
    public struct Point: Codable, Hashable, Sendable {
        public let date: Date
        public let glucoseMmolPerLiter: Double
        /// Delivered insulin still active: boluses and basal up to the
        /// reference date. No future basal delivery is assumed.
        public let insulinOnBoard: Double
        public let carbohydratesOnBoard: Double
    }

    /// Individual oref-style curves, aligned with `points`.
    public struct OrefCurves: Codable, Hashable, Sendable {
        public let insulinOnly: [Double]
        /// Nil when no carbohydrates are absorbed in the prediction.
        public let withCarbohydrates: [Double]?
        public let zeroTemp: [Double]
    }

    public let model: GlucosePredictionModel
    /// The first point is the latest measured glucose at the reference date.
    public let points: [Point]
    public let orefCurves: OrefCurves?
    /// Whether a recent glucose trend was available and used.
    public let usedGlucoseTrend: Bool
}
