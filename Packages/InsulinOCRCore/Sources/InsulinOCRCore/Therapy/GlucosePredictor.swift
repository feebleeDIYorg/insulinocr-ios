import Foundation

/// Extrapolates glucose from insulin and carbohydrates with the methods of
/// the DIY closed-loop community. Clean-room arithmetic on the app's own
/// insulin and carbohydrate curves; experimental, not dosing advice.
///
/// Shared by both models:
/// - Insulin lowers glucose by sensitivity × insulin absorbed in a step.
///   Basal counts relative to the profile basal rate (delivered − profile).
///   After the reference date delivery is taken to equal the profile.
/// - Carbohydrates raise glucose by (sensitivity ÷ carb ratio) × grams absorbed.
/// - An insulin-need adjustment of p % scales the basal reference by p and
///   divides sensitivity and carb ratio by p, as Loop overrides and AndroidAPS
///   profile percentages do. The carbohydrate effect is therefore unchanged.
public enum GlucosePredictor {
    /// Recent samples used for the starting value and the glucose trend.
    static let trendWindowMinutes = 15.0
    static let loopMomentumMinutes = 20.0
    static let orefDeviationMinutes = 60.0
    static let maximumHorizonMinutes = 1_440.0

    /// Returns nil without a glucose sample in the last 15 minutes before the
    /// reference date: there is no value to start the extrapolation from.
    public static func predict(
        _ input: GlucosePredictionInput,
        model: GlucosePredictionModel,
        stepMinutes: Double = 5
    ) -> GlucosePrediction? {
        guard stepMinutes.isFinite, stepMinutes >= 1,
              input.referenceDate.timeIntervalSinceReferenceDate.isFinite,
              let timeZone = TimeZone(identifier: input.prediction.timeZoneIdentifier) else { return nil }
        let reference = input.referenceDate
        let recent = input.data.glucoseSamples.compactMap { sample -> (minutes: Double, mmol: Double)? in
            let minutes = sample.date.timeIntervalSince(reference) / 60
            guard sample.value.isFinite, sample.value > 0,
                  minutes >= -trendWindowMinutes - 1, minutes <= 1 else { return nil }
            let mmol = sample.unit == .millimolesPerLiter ? sample.value : sample.value / 18
            return (minutes, mmol)
        }.sorted { $0.minutes < $1.minutes }
        guard let start = recent.last?.mmol else { return nil }
        let slope = trendSlope(recent)

        let dia = Double(input.therapy.diaMinutes)
        let peak = input.therapy.insulinType.peakMinutes
        let carbDuration = Double(input.therapy.carbAbsorptionMinutes)
        func fractionRemaining(_ ageMinutes: Double) -> Double {
            ageMinutes <= 0 ? 1 : InsulinActivityModel.remainingUnits(
                units: 1, minutes: ageMinutes, durationMinutes: dia, peakMinutes: peak)
        }
        func needFactor(at date: Date) -> Double {
            // The adjustment that started last wins where several overlap.
            input.adjustments.filter { $0.isActive(at: date) }
                .max { $0.startDate < $1.startDate }.map { $0.percent / 100 } ?? 1
        }
        func sensitivity(at date: Date) -> Double {
            input.prediction.sensitivity.value(at: date, timeZone: timeZone)
        }

        let boluses = input.data.boluses.filter { $0.units.isFinite && $0.units > 0 }
        let carbohydrates = input.data.carbohydrates.filter { $0.grams.isFinite && $0.grams > 0 }
        let actionMinutes = max(dia, carbDuration + CarbohydrateAbsorptionModel.delayMinutes)
        let lastEvent = (boluses.map(\.date) + carbohydrates.map(\.date)).max() ?? reference
        let horizonMinutes = min(maximumHorizonMinutes,
            max(0, lastEvent.timeIntervalSince(reference) / 60) + actionMinutes)
        let stepCount = max(1, Int((horizonMinutes / stepMinutes).rounded(.up)))
        let horizonEnd = reference.addingTimeInterval(Double(stepCount) * stepMinutes * 60)

        // Every insulin delivery as a point dose: boluses, and basal relative
        // to the profile in one-minute slices, which may be negative.
        var doses = boluses.map { (date: $0.date, units: $0.units) }
        let profileBasal = input.prediction.profileBasalUnitsPerHour
        let actionStart = reference.addingTimeInterval(-dia * 60)
        let deliveredBasal = input.data.basalSegments.compactMap { segment -> BasalSegment? in
            guard segment.unitsPerHour.isFinite, segment.unitsPerHour >= 0,
                  segment.startDate < reference, segment.endDate > segment.startDate else { return nil }
            return BasalSegment(id: segment.id, startDate: segment.startDate,
                endDate: min(segment.endDate, reference), unitsPerHour: segment.unitsPerHour,
                sourceObservationID: segment.sourceObservationID)
        }
        for segment in deliveredBasal {
            var cursor = max(segment.startDate, actionStart)
            while cursor < segment.endDate {
                let end = min(cursor.addingTimeInterval(60), segment.endDate)
                let seconds = end.timeIntervalSince(cursor)
                let middle = cursor.addingTimeInterval(seconds / 2)
                let net = segment.unitsPerHour - profileBasal * needFactor(at: middle)
                doses.append((middle, net * seconds / 3_600))
                cursor = end
            }
        }
        // oref's zero-temp curve: no basal at all from the reference date on.
        var zeroTempDoses = doses
        if profileBasal > 0 {
            var cursor = reference
            while cursor < horizonEnd {
                let middle = cursor.addingTimeInterval(30)
                zeroTempDoses.append((middle, -profileBasal * needFactor(at: middle) / 60))
                cursor = cursor.addingTimeInterval(60)
            }
        }
        func absorbedInsulin(_ doses: [(date: Date, units: Double)], from: Date, to: Date) -> Double {
            doses.reduce(0) { sum, dose in
                guard dose.date < to else { return sum }
                return sum + dose.units * (
                    fractionRemaining(from.timeIntervalSince(dose.date) / 60)
                        - fractionRemaining(to.timeIntervalSince(dose.date) / 60))
            }
        }
        func absorbedCarbohydrates(from: Date, to: Date) -> Double {
            carbohydrates.reduce(0) { sum, event in
                sum + CarbohydrateAbsorptionModel.remainingGrams(grams: event.grams,
                        minutes: from.timeIntervalSince(event.date) / 60, absorptionDurationMinutes: carbDuration)
                    - CarbohydrateAbsorptionModel.remainingGrams(grams: event.grams,
                        minutes: to.timeIntervalSince(event.date) / 60, absorptionDurationMinutes: carbDuration)
            }
        }

        // Per step: glucose change from insulin (normal and zero-temp) and carbohydrates.
        var insulinEffect: [Double] = [], zeroTempEffect: [Double] = [], carbEffect: [Double] = []
        for index in 1...stepCount {
            let from = reference.addingTimeInterval(Double(index - 1) * stepMinutes * 60)
            let to = reference.addingTimeInterval(Double(index) * stepMinutes * 60)
            let middle = from.addingTimeInterval(stepMinutes * 30)
            let base = sensitivity(at: middle)
            let effective = base / needFactor(at: middle)
            insulinEffect.append(-effective * absorbedInsulin(doses, from: from, to: to))
            zeroTempEffect.append(-effective * absorbedInsulin(zeroTempDoses, from: from, to: to))
            carbEffect.append(base / input.prediction.carbRatio.value(at: middle, timeZone: timeZone)
                * absorbedCarbohydrates(from: from, to: to))
        }

        let calculator = DefaultActivityCalculator()
        func point(_ index: Int, _ glucose: Double) -> GlucosePrediction.Point {
            let date = reference.addingTimeInterval(Double(index) * stepMinutes * 60)
            return .init(date: date, glucoseMmolPerLiter: glucose,
                insulinOnBoard: calculator.bolusIOB(events: boluses, at: date,
                        durationMinutes: dia, peakMinutes: peak)
                    + calculator.basalIOB(segments: deliveredBasal, at: date,
                        durationMinutes: dia, peakMinutes: peak),
                carbohydratesOnBoard: calculator.cob(events: carbohydrates, at: date,
                    absorptionDurationMinutes: carbDuration))
        }

        switch model {
        case .loop:
            // The measured trend dominates at first and hands over to the
            // model linearly within twenty minutes.
            var glucose = start
            var points = [point(0, start)]
            for index in 1...stepCount {
                let modelled = insulinEffect[index - 1] + carbEffect[index - 1]
                let elapsed = (Double(index) - 0.5) * stepMinutes
                let weight = slope == nil ? 0 : max(0, 1 - elapsed / loopMomentumMinutes)
                glucose = max(0, glucose + weight * (slope ?? 0) * stepMinutes + (1 - weight) * modelled)
                points.append(point(index, glucose))
            }
            return GlucosePrediction(model: .loop, points: points, orefCurves: nil, usedGlucoseTrend: slope != nil)

        case .oref:
            // Deviation: what glucose did in the last step beyond what insulin
            // explains. It is carried forward and fades out within an hour.
            let lastStep = reference.addingTimeInterval(-stepMinutes * 60)
            let explained = -sensitivity(at: reference) / needFactor(at: reference)
                * absorbedInsulin(doses, from: lastStep, to: reference)
            let deviation = slope.map { $0 * stepMinutes - explained } ?? 0
            let hasCarbohydrates = carbEffect.contains { $0 > 1e-12 }
            var insulinOnly = [start], withCarbohydrates = [start], zeroTemp = [start]
            for index in 1...stepCount {
                let fading = deviation * (1 - min(1, Double(index) * stepMinutes / orefDeviationMinutes))
                insulinOnly.append(max(0, insulinOnly[index - 1] + insulinEffect[index - 1] + fading))
                withCarbohydrates.append(max(0, withCarbohydrates[index - 1] + insulinEffect[index - 1]
                    + min(0, fading) + carbEffect[index - 1]))
                zeroTemp.append(max(0, zeroTemp[index - 1] + zeroTempEffect[index - 1]))
            }
            let main = hasCarbohydrates ? withCarbohydrates : insulinOnly
            return GlucosePrediction(
                model: .oref,
                points: main.indices.map { point($0, main[$0]) },
                orefCurves: .init(insulinOnly: insulinOnly,
                    withCarbohydrates: hasCarbohydrates ? withCarbohydrates : nil, zeroTemp: zeroTemp),
                usedGlucoseTrend: slope != nil)
        }
    }

    /// Least-squares slope in mmol/L per minute; nil below three samples or
    /// without a spread in time.
    static func trendSlope(_ samples: [(minutes: Double, mmol: Double)]) -> Double? {
        guard samples.count >= 3 else { return nil }
        let count = Double(samples.count)
        let meanTime = samples.reduce(0) { $0 + $1.minutes } / count
        let meanValue = samples.reduce(0) { $0 + $1.mmol } / count
        let spread = samples.reduce(0) { $0 + ($1.minutes - meanTime) * ($1.minutes - meanTime) }
        guard spread > 1e-9 else { return nil }
        let slope = samples.reduce(0) { $0 + ($1.minutes - meanTime) * ($1.mmol - meanValue) } / spread
        return slope.isFinite ? slope : nil
    }
}
