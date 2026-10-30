import Foundation

public struct DefaultActivityCalculator: ActivityCalculator {
    public static let modelVersion = "openaps-exponential+loopkit-cob/1.2.0"

    public init() {}

    public func calculate(
        data: EffectiveTherapyData,
        settings: TherapySettings,
        referenceDate: Date,
        forecastStepMinutes: Int = 5
    ) -> ActivityComputation {
        let current = snapshot(data: data, settings: settings, date: referenceDate)
        let step = max(1, forecastStepMinutes)
        let horizonMinutes = max(
            settings.diaMinutes,
            settings.carbAbsorptionMinutes + Int(CarbohydrateAbsorptionModel.delayMinutes)
        )
        let forecast = stride(from: step, through: horizonMinutes, by: step).map { minute in
            snapshot(
                data: data,
                settings: settings,
                date: referenceDate.addingTimeInterval(Double(minute) * 60),
                coverageReferenceDate: referenceDate
            )
        }
        return ActivityComputation(current: current, forecast: forecast)
    }

    public func snapshot(
        data: EffectiveTherapyData,
        settings: TherapySettings,
        date: Date
    ) -> ActivitySnapshot {
        snapshot(data: data, settings: settings, date: date, coverageReferenceDate: date)
    }

    private func snapshot(
        data: EffectiveTherapyData,
        settings: TherapySettings,
        date: Date,
        coverageReferenceDate: Date
    ) -> ActivitySnapshot {
        let requiredHistory = Double(max(settings.diaMinutes,
            settings.carbAbsorptionMinutes + Int(CarbohydrateAbsorptionModel.delayMinutes)))
        if data.sourceAnalysisRunID != nil || data.observedHistoryMinutes != nil {
            guard let history = data.observedHistoryMinutes,
                  history.isFinite, history >= requiredHistory else {
                return ActivitySnapshot(date: date,
                    basalIOB: .unavailable(.insufficientHistory),
                    bolusIOB: .unavailable(.insufficientHistory),
                    totalIOB: .unavailable(.insufficientHistory),
                    cob: .unavailable(.insufficientHistory))
            }
        }
        let basalIOB: MetricResult
        if let reason = unavailableReason(for: .basal, issues: data.unresolvedIssues) {
            basalIOB = .unavailable(reason)
        } else if (data.sourceAnalysisRunID != nil || data.observedHistoryMinutes != nil)
            && !hasCompleteBasalCoverage(data.basalSegments, at: coverageReferenceDate,
                durationMinutes: settings.diaMinutes) {
            basalIOB = .unavailable(.incompleteBasalPath)
        } else {
            basalIOB = .available(
                self.basalIOB(
                    segments: data.basalSegments,
                    at: date,
                    durationMinutes: Double(settings.diaMinutes),
                    peakMinutes: settings.insulinType.peakMinutes,
                    integrationStepSeconds: 60
                )
            )
        }

        let bolusIOB: MetricResult
        if let reason = unavailableReason(for: .bolus, issues: data.unresolvedIssues) {
            bolusIOB = .unavailable(reason)
        } else {
            bolusIOB = .available(
                self.bolusIOB(
                    events: data.boluses,
                    at: date,
                    durationMinutes: Double(settings.diaMinutes),
                    peakMinutes: settings.insulinType.peakMinutes
                )
            )
        }

        let totalIOB: MetricResult
        switch (basalIOB, bolusIOB) {
        case (.available(let basal), .available(let bolus)):
            totalIOB = .available(basal + bolus)
        case (.unavailable(let reason), _), (_, .unavailable(let reason)):
            totalIOB = .unavailable(reason)
        }

        let cob: MetricResult
        if let reason = unavailableReason(for: .carbohydrate, issues: data.unresolvedIssues) {
            cob = .unavailable(reason)
        } else {
            cob = .available(
                self.cob(
                    events: data.carbohydrates,
                    at: date,
                    absorptionDurationMinutes: Double(settings.carbAbsorptionMinutes)
                )
            )
        }

        return ActivitySnapshot(
            date: date,
            basalIOB: basalIOB,
            bolusIOB: bolusIOB,
            totalIOB: totalIOB,
            cob: cob
        )
    }

    private func hasCompleteBasalCoverage(
        _ segments: [BasalSegment],
        at referenceDate: Date,
        durationMinutes: Int
    ) -> Bool {
        let start = referenceDate.addingTimeInterval(-Double(durationMinutes) * 60)
        guard referenceDate.timeIntervalSinceReferenceDate.isFinite else { return false }
        var intervals: [(start: Date, end: Date)] = []
        for segment in segments {
            guard segment.startDate.timeIntervalSinceReferenceDate.isFinite,
                  segment.endDate.timeIntervalSinceReferenceDate.isFinite,
                  segment.unitsPerHour.isFinite, segment.unitsPerHour >= 0,
                  segment.endDate > segment.startDate else { return false }
            let lower = max(start, segment.startDate)
            let upper = min(referenceDate, segment.endDate)
            if upper > lower { intervals.append((lower, upper)) }
        }
        intervals.sort { $0.start == $1.start ? $0.end < $1.end : $0.start < $1.start }
        var coveredUntil = start
        // Allow only floating-point date noise, never an inferred delivery interval.
        let epsilon: TimeInterval = 1e-6
        for interval in intervals {
            let boundary = interval.start.timeIntervalSince(coveredUntil)
            guard abs(boundary) <= epsilon else { return false }
            coveredUntil = interval.end
        }
        return referenceDate.timeIntervalSince(coveredUntil) <= epsilon
    }

    public func bolusIOB(
        events: [InsulinEvent],
        at date: Date,
        durationMinutes: Double,
        peakMinutes: Double
    ) -> Double {
        events.reduce(into: 0.0) { result, event in
            let ageMinutes = date.timeIntervalSince(event.date) / 60
            guard ageMinutes >= 0 else { return }
            result += InsulinActivityModel.remainingUnits(
                units: event.units,
                minutes: ageMinutes,
                durationMinutes: durationMinutes,
                peakMinutes: peakMinutes
            )
        }
    }

    public func basalIOB(
        segments: [BasalSegment],
        at date: Date,
        durationMinutes: Double,
        peakMinutes: Double,
        integrationStepSeconds: TimeInterval = 60
    ) -> Double {
        guard integrationStepSeconds.isFinite, integrationStepSeconds > 0 else { return 0 }
        let actionStart = date.addingTimeInterval(-durationMinutes * 60)
        var result = 0.0

        for segment in segments where segment.unitsPerHour > 0 && segment.unitsPerHour.isFinite {
            var cursor = max(segment.startDate, actionStart)
            let clippedEnd = min(segment.endDate, date)
            guard clippedEnd > cursor else { continue }

            while cursor < clippedEnd {
                let doseEnd = min(cursor.addingTimeInterval(integrationStepSeconds), clippedEnd)
                let overlapSeconds = doseEnd.timeIntervalSince(cursor)
                let midpoint = cursor.addingTimeInterval(overlapSeconds / 2)
                let ageMinutes = date.timeIntervalSince(midpoint) / 60
                let deliveredUnits = segment.unitsPerHour * overlapSeconds / 3_600
                result += InsulinActivityModel.remainingUnits(
                    units: deliveredUnits,
                    minutes: ageMinutes,
                    durationMinutes: durationMinutes,
                    peakMinutes: peakMinutes
                )
                cursor = doseEnd
            }
        }
        return result
    }

    public func cob(
        events: [CarbohydrateEvent],
        at date: Date,
        absorptionDurationMinutes: Double
    ) -> Double {
        events.reduce(into: 0.0) { result, event in
            let ageMinutes = date.timeIntervalSince(event.date) / 60
            guard ageMinutes >= 0 else { return }
            result += CarbohydrateAbsorptionModel.remainingGrams(
                grams: event.grams,
                minutes: ageMinutes,
                absorptionDurationMinutes: absorptionDurationMinutes
            )
        }
    }

    private enum Component {
        case basal
        case bolus
        case carbohydrate
    }

    private func unavailableReason(
        for component: Component,
        issues: Set<CriticalDataIssue>
    ) -> MetricUnavailableReason? {
        if issues.contains(.invalidTimeAxis) { return .invalidTimeAxis }

        switch component {
        case .basal:
            if issues.contains(.invalidBasalAxis) { return .invalidBasalAxis }
            if issues.contains(.incompleteBasalPath) { return .incompleteBasalPath }
        case .bolus:
            if issues.contains(.unclassifiedEvent) { return .unclassifiedEvent }
            if issues.contains(.unknownBolusAmount) { return .unknownBolusAmount }
        case .carbohydrate:
            if issues.contains(.unclassifiedEvent) { return .unclassifiedEvent }
            if issues.contains(.unknownCarbohydrateAmount) { return .unknownCarbohydrateAmount }
        }
        return nil
    }
}
