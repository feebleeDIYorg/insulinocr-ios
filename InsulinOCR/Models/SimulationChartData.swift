import Foundation
import InsulinOCRCore

/// One editable row of the simulation's event list. The time is typed as
/// minutes relative to the capture time.
struct SimulationEventDraft: Identifiable, Equatable {
    enum Kind: Equatable {
        case bolus
        case carbohydrate
        case insulinNeed
    }

    /// Earliest and latest start, in minutes relative to the capture time.
    static let offsetRange = -720.0...720.0

    let id: UUID
    var kind: Kind
    /// Name of the preset an activity row came from; nil for a free one.
    var title: String?
    /// Units, grams or percent, depending on the kind.
    var amountText: String
    var offsetText: String
    /// Hours; activities only.
    var durationText: String

    init(id: UUID = UUID(), kind: Kind, title: String? = nil, amountText: String = "",
         offsetText: String = "0", durationText: String = "") {
        self.id = id
        self.kind = kind
        self.title = title
        self.amountText = amountText
        self.offsetText = offsetText
        self.durationText = durationText
    }

    init(preset: ActivityPreset) {
        self.init(kind: .insulinNeed, title: preset.name,
                  amountText: DailyProfileDraft.text(preset.insulinNeedPercent),
                  durationText: DailyProfileDraft.text(Double(preset.durationMinutes) / 60))
    }

    func date(reference: Date) -> Date? {
        guard let offset = DailyProfileDraft.number(offsetText), offset.isFinite,
              Self.offsetRange.contains(offset) else { return nil }
        return reference.addingTimeInterval(offset * 60)
    }

    /// Nil while the row is incomplete or out of range; such a row is not simulated.
    func event(reference: Date) -> SimulationEvent? {
        guard let amount = DailyProfileDraft.number(amountText), amount.isFinite,
              let date = date(reference: reference) else { return nil }
        switch kind {
        case .bolus:
            guard amount > 0, amount <= 50 else { return nil }
            return .bolus(InsulinEvent(id: id, date: date, units: amount))
        case .carbohydrate:
            guard amount > 0, amount <= 300 else { return nil }
            return .carbohydrate(CarbohydrateEvent(id: id, date: date, grams: amount))
        case .insulinNeed:
            guard let hours = DailyProfileDraft.number(durationText),
                  let adjustment = try? InsulinNeedAdjustment(
                      id: id, startDate: date, durationMinutes: hours * 60, percent: amount) else { return nil }
            return .insulinNeed(adjustment)
        }
    }
}

enum OrefCurveKind: String, CaseIterable, Identifiable {
    case insulinOnly
    case withCarbohydrates
    case zeroTemp

    var id: String { rawValue }

    var title: String {
        switch self {
        case .insulinOnly: "Nur Insulin"
        case .withCarbohydrates: "Mit KH"
        case .zeroTemp: "Ohne Basal"
        }
    }
}

enum GlucoseZone: Equatable {
    case low
    case inRange
    case high
}

/// Everything the simulation chart draws. Glucose is in mmol/L.
struct SimulationChartData {
    struct Point: Identifiable {
        let date: Date
        /// Nil when no glucose prediction is available.
        let glucose: Double?
        let iob: Double
        let cob: Double
        var id: Date { date }
    }

    struct Sample: Identifiable, Equatable {
        let date: Date
        let value: Double
        var id: Date { date }
    }

    struct OrefCurve: Identifiable {
        let kind: OrefCurveKind
        let samples: [Sample]
        var id: OrefCurveKind { kind }
    }

    struct ZoneRun: Identifiable {
        let index: Int
        let zone: GlucoseZone
        let samples: [Sample]
        var id: Int { index }
    }

    let reference: Date
    /// Measured glucose of the two hours before the reference date.
    let measured: [Sample]
    let scenario: [Point]
    /// The same extrapolation without the simulated events.
    let baseline: [Point]
    let orefCurves: [OrefCurve]
    let events: [SimulationEvent]
    /// Why there is no glucose curve; nil when there is one.
    let missingGlucoseReason: String?
    let usedGlucoseTrend: Bool

    /// Consecutive stretches of the predicted glucose in one zone. A stretch
    /// starts at the last point of the previous one, so the line has no gap;
    /// the connecting segment takes the colour of the zone it enters.
    static func zoneRuns(_ samples: [Sample], limits: GlucoseLimits) -> [ZoneRun] {
        func zone(_ value: Double) -> GlucoseZone {
            value < limits.hypo ? .low : (value > limits.hyper ? .high : .inRange)
        }
        var runs: [ZoneRun] = []
        var current: [Sample] = []
        var currentZone = GlucoseZone.inRange
        for sample in samples {
            let next = zone(sample.value)
            if current.isEmpty {
                currentZone = next
            } else if next != currentZone {
                runs.append(ZoneRun(index: runs.count, zone: currentZone, samples: current))
                current = [current[current.count - 1]]
                currentZone = next
            }
            current.append(sample)
        }
        if !current.isEmpty {
            runs.append(ZoneRun(index: runs.count, zone: currentZone, samples: current))
        }
        return runs
    }
}

/// Maps insulin and carbohydrates on board onto the glucose axis, so one
/// chart can carry all three. The right axis shows units; ten grams of
/// carbohydrate take the height of one unit.
struct SimulationChartScale: Equatable {
    static let gramsPerUnit = 10.0

    /// Top of the glucose axis in the display unit.
    let glucoseMax: Double
    /// Top of the right axis in units of insulin.
    let unitsMax: Double

    init(maxGlucose: Double, maxIOB: Double, maxCOB: Double, displayScale: Double) {
        let floor = 15 * displayScale
        let step = displayScale > 1 ? 30.0 : 1.0
        let needed = max(0, maxGlucose.isFinite ? maxGlucose : 0) * 1.08
        glucoseMax = max(floor, (needed / step).rounded(.up) * step)
        let units = max(1, maxIOB.isFinite ? maxIOB : 0, (maxCOB.isFinite ? maxCOB : 0) / Self.gramsPerUnit)
        unitsMax = [1, 2, 4, 6, 8, 10, 12, 16, 20, 30, 40, 60, 80, 100].first { $0 >= units } ?? units
    }

    func position(units: Double) -> Double { units / unitsMax * glucoseMax }

    func position(grams: Double) -> Double { position(units: grams / Self.gramsPerUnit) }

    /// Five ticks of the right axis as positions on the glucose axis.
    var rightTickPositions: [Double] { (0...4).map { Double($0) / 4 * glucoseMax } }

    func units(atPosition position: Double) -> Double { position / glucoseMax * unitsMax }
}

enum SimulationChartBuilder {
    static let historyMinutes = 120.0

    static func build(
        data: EffectiveTherapyData,
        therapy: TherapySettings,
        reference: Date,
        events: [SimulationEvent],
        simulation: SimulationSettings,
        profileBasalUnitsPerHour: Double,
        model: GlucosePredictionModel,
        timeZoneIdentifier: String
    ) -> SimulationChartData {
        let measured = data.glucoseSamples.compactMap { sample -> SimulationChartData.Sample? in
            let minutes = sample.date.timeIntervalSince(reference) / 60
            guard sample.value.isFinite, sample.value > 0, minutes >= -historyMinutes, minutes <= 1 else { return nil }
            return .init(date: sample.date,
                         value: sample.unit == .millimolesPerLiter ? sample.value : sample.value / 18)
        }.sorted { $0.date < $1.date }

        let simulated = SimulationCalculator.applying(events: events, to: data)
        let adjustments = SimulationCalculator.adjustments(in: events)
        let zone = TimeZone(identifier: timeZoneIdentifier) == nil ? TimeZone.current.identifier : timeZoneIdentifier
        let basal = profileBasalUnitsPerHour.isFinite ? min(20, max(0, profileBasalUnitsPerHour)) : 0
        var predictionSettings: GlucosePredictionSettings?
        if let sensitivity = simulation.sensitivity, let carbRatio = simulation.carbRatio {
            predictionSettings = try? GlucosePredictionSettings(
                sensitivity: sensitivity, carbRatio: carbRatio,
                profileBasalUnitsPerHour: basal, timeZoneIdentifier: zone)
        }
        func predict(_ data: EffectiveTherapyData, _ adjustments: [InsulinNeedAdjustment]) -> GlucosePrediction? {
            predictionSettings.flatMap {
                GlucosePredictor.predict(GlucosePredictionInput(
                    data: data, therapy: therapy, prediction: $0,
                    adjustments: adjustments, referenceDate: reference), model: model)
            }
        }
        func points(_ prediction: GlucosePrediction?, fallback: EffectiveTherapyData) -> [SimulationChartData.Point] {
            if let prediction {
                return prediction.points.map {
                    .init(date: $0.date, glucose: $0.glucoseMmolPerLiter,
                          iob: $0.insulinOnBoard, cob: $0.carbohydratesOnBoard)
                }
            }
            return activityPoints(data: fallback, therapy: therapy, reference: reference)
        }
        let scenarioPrediction = predict(simulated, adjustments)
        let baselinePrediction = predict(data, [])

        var curves: [SimulationChartData.OrefCurve] = []
        if let prediction = scenarioPrediction, let oref = prediction.orefCurves {
            func samples(_ values: [Double]) -> [SimulationChartData.Sample] {
                zip(prediction.points, values).map { .init(date: $0.date, value: $1) }
            }
            curves.append(.init(kind: .insulinOnly, samples: samples(oref.insulinOnly)))
            if let withCarbohydrates = oref.withCarbohydrates {
                curves.append(.init(kind: .withCarbohydrates, samples: samples(withCarbohydrates)))
            }
            curves.append(.init(kind: .zeroTemp, samples: samples(oref.zeroTemp)))
        }

        let reason: String?
        if predictionSettings == nil {
            reason = "Für den Glukoseverlauf fehlen Insulinsensitivität und KH-Faktor in den Simulations-Einstellungen."
        } else if scenarioPrediction == nil {
            reason = "Für den Glukoseverlauf fehlt ein Messwert in den 15 Minuten vor dem Aufnahmezeitpunkt."
        } else {
            reason = nil
        }
        return SimulationChartData(
            reference: reference,
            measured: measured,
            scenario: points(scenarioPrediction, fallback: simulated),
            baseline: points(baselinePrediction, fallback: data),
            orefCurves: curves,
            events: events,
            missingGlucoseReason: reason,
            usedGlucoseTrend: scenarioPrediction?.usedGlucoseTrend ?? false)
    }

    /// Insulin and carbohydrates on board without a glucose prediction.
    /// Basal counts up to the reference date; no future delivery is assumed.
    static func activityPoints(
        data: EffectiveTherapyData, therapy: TherapySettings, reference: Date, stepMinutes: Double = 5
    ) -> [SimulationChartData.Point] {
        let dia = Double(therapy.diaMinutes), peak = therapy.insulinType.peakMinutes
        let carbDuration = Double(therapy.carbAbsorptionMinutes)
        let delivered = data.basalSegments.compactMap { segment -> BasalSegment? in
            guard segment.startDate < reference, segment.endDate > segment.startDate else { return nil }
            return BasalSegment(id: segment.id, startDate: segment.startDate,
                endDate: min(segment.endDate, reference), unitsPerHour: segment.unitsPerHour,
                sourceObservationID: segment.sourceObservationID)
        }
        let lastEvent = (data.boluses.map(\.date) + data.carbohydrates.map(\.date)).max() ?? reference
        let horizon = min(1_440, max(0, lastEvent.timeIntervalSince(reference) / 60)
            + max(dia, carbDuration + CarbohydrateAbsorptionModel.delayMinutes))
        let calculator = DefaultActivityCalculator()
        return (0...max(1, Int((horizon / stepMinutes).rounded(.up)))).map { index in
            let date = reference.addingTimeInterval(Double(index) * stepMinutes * 60)
            return .init(
                date: date, glucose: nil,
                iob: calculator.bolusIOB(events: data.boluses, at: date, durationMinutes: dia, peakMinutes: peak)
                    + calculator.basalIOB(segments: delivered, at: date, durationMinutes: dia, peakMinutes: peak),
                cob: calculator.cob(events: data.carbohydrates, at: date, absorptionDurationMinutes: carbDuration))
        }
    }
}
