import Foundation

public struct DefaultEffectiveDataReducer: EffectiveDataReducer {
    public init() {}

    public func reduce(
        analysisRun: AnalysisRun,
        revisions: [CorrectionRevision]
    ) throws -> EffectiveTherapyData {
        try reduceImpl(analysisRun: analysisRun, revisions: revisions, window: nil)
    }

    public func reduce(analysisRun: AnalysisRun, revisions: [CorrectionRevision],
                       basalCoverageWindow: DateInterval) throws -> EffectiveTherapyData {
        try reduceImpl(analysisRun: analysisRun, revisions: revisions, window: basalCoverageWindow)
    }

    public func reduce(analysisRun: AnalysisRun, revisions: [CorrectionRevision],
                       referenceDate: Date, settings: TherapySettings) throws -> EffectiveTherapyData {
        guard referenceDate.timeIntervalSinceReferenceDate.isFinite else { throw EffectiveDataError.invalidReferenceDate }
        return try reduceImpl(analysisRun: analysisRun, revisions: revisions,
            window: DateInterval(start: referenceDate.addingTimeInterval(-Double(settings.diaMinutes) * 60), end: referenceDate),
            activity: (referenceDate, settings))
    }

    private func reduceImpl(analysisRun: AnalysisRun, revisions: [CorrectionRevision],
                            window: DateInterval?, activity: (date: Date, settings: TherapySettings)? = nil) throws -> EffectiveTherapyData {
        var explicitlyReviewedBasal = false
        var observations = Dictionary(uniqueKeysWithValues: analysisRun.observations.map { ($0.id, $0) })
        let applicableRevisions = revisions.sorted {
            if $0.createdAt == $1.createdAt {
                return $0.id.uuidString < $1.id.uuidString
            }
            return $0.createdAt < $1.createdAt
        }

        for revision in applicableRevisions {
            guard revision.analysisRunID == analysisRun.id else {
                throw EffectiveDataError.revisionForDifferentAnalysisRun
            }
            for operation in revision.operations {
                switch operation {
                case .add(let observation):
                    explicitlyReviewedBasal = explicitlyReviewedBasal
                        || (observation.kind == .basalRate && observation.provenance == .userCorrection)
                    observations[observation.id] = observation
                case .update(let targetID, let replacement):
                    guard observations[targetID] != nil, replacement.id == targetID else {
                        throw EffectiveDataError.invalidCorrectionTarget(targetID)
                    }
                    explicitlyReviewedBasal = explicitlyReviewedBasal
                        || (replacement.provenance == .userCorrection
                            && (replacement.kind == .basalRate || observations[targetID]?.kind == .basalRate))
                    observations[targetID] = replacement
                case .delete(let targetID):
                    explicitlyReviewedBasal = explicitlyReviewedBasal || observations[targetID]?.kind == .basalRate
                    guard observations.removeValue(forKey: targetID) != nil else {
                        throw EffectiveDataError.invalidCorrectionTarget(targetID)
                    }
                }
            }
        }

        var invalidBasalObservation = false
        var basalSegments: [BasalSegment] = []
        var boluses: [InsulinEvent] = []
        var carbohydrates: [CarbohydrateEvent] = []
        var glucoseSamples: [GlucoseSample] = []
        var issues = issues(from: analysisRun)
        var inactiveIDs: [UUID] = []
        let calibration = analysisRun.calibration
        let trustworthyClock = analysisRun.quality.clockValidated == true && !issues.contains(.invalidTimeAxis)
            && analysisRun.quality.timeAxisConfidence.isFinite && (0...1).contains(analysisRun.quality.timeAxisConfidence)
            && analysisRun.quality.timeAxisConfidence > 0
            && calibration.timeResidualMinutes.isFinite && (0...1).contains(calibration.timeResidualMinutes)
            && calibration.timeStart.timeIntervalSinceReferenceDate.isFinite
            && calibration.timeEnd.timeIntervalSinceReferenceDate.isFinite
            && calibration.timeStart < calibration.timeEnd
        func isInactive(_ observation: RawObservation, horizonMinutes: Int, endDate: Date? = nil) -> Bool {
            guard let activity, trustworthyClock else { return false }
            guard observation.kind == .basalRate || analysisRun.quality.eventIssuesLocalized == true else { return false }
            let date = endDate ?? observation.startDate
            guard date.timeIntervalSinceReferenceDate.isFinite,
                  observation.confidence.geometry.isFinite, (0.99...1).contains(observation.confidence.geometry),
                  observation.startDate >= calibration.timeStart,
                  date <= calibration.timeEnd else { return false }
            // Retain both acceptance bounds: 2.5 minutes for event placement
            // and one minute for the calibrated clock.
            return date < activity.date.addingTimeInterval(-(Double(horizonMinutes) + 3.5) * 60)
        }

        for observation in observations.values {
            switch observation.kind {
            case .basalRate:
                guard observation.amountState == .known,
                      let rate = observation.amount,
                      rate.isFinite,
                      rate >= 0,
                      observation.unit == .unitsPerHour,
                      let endDate = observation.endDate,
                      endDate > observation.startDate else {
                    if let activity, let end = observation.endDate, end > observation.startDate,
                       isInactive(observation, horizonMinutes: activity.settings.diaMinutes, endDate: end) {
                        inactiveIDs.append(observation.id)
                        continue
                    }
                    invalidBasalObservation = true
                    issues.insert(.incompleteBasalPath)
                    continue
                }
                basalSegments.append(
                    BasalSegment(
                        id: observation.id,
                        startDate: observation.startDate,
                        endDate: endDate,
                        unitsPerHour: rate,
                        sourceObservationID: observation.id
                    )
                )

            case .bolus:
                guard observation.amountState == .known,
                      let units = observation.amount,
                      units.isFinite,
                      units >= 0,
                      observation.unit == .insulinUnits else {
                    if let activity, isInactive(observation, horizonMinutes: observation.unit == .insulinUnits
                        ? activity.settings.diaMinutes
                        : max(activity.settings.diaMinutes, activity.settings.carbAbsorptionMinutes + Int(CarbohydrateAbsorptionModel.delayMinutes))) {
                        inactiveIDs.append(observation.id)
                        continue
                    }
                    issues.insert(.unknownBolusAmount)
                    continue
                }
                boluses.append(
                    InsulinEvent(
                        id: observation.id,
                        date: observation.startDate,
                        units: units,
                        sourceObservationID: observation.id
                    )
                )

            case .carbohydrate:
                guard observation.amountState == .known,
                      let grams = observation.amount,
                      grams.isFinite,
                      grams >= 0,
                      observation.unit == .grams else {
                    if let activity, isInactive(observation, horizonMinutes: observation.unit == .grams
                        ? activity.settings.carbAbsorptionMinutes + Int(CarbohydrateAbsorptionModel.delayMinutes)
                        : max(activity.settings.diaMinutes, activity.settings.carbAbsorptionMinutes + Int(CarbohydrateAbsorptionModel.delayMinutes))) {
                        inactiveIDs.append(observation.id)
                        continue
                    }
                    issues.insert(.unknownCarbohydrateAmount)
                    continue
                }
                carbohydrates.append(
                    CarbohydrateEvent(
                        id: observation.id,
                        date: observation.startDate,
                        grams: grams,
                        sourceObservationID: observation.id
                    )
                )

            case .glucose:
                guard observation.amountState == .known,
                      let value = observation.amount,
                      value.isFinite,
                      value > 0 else {
                    continue
                }
                let unit: GlucoseUnit
                switch observation.unit {
                case .millimolesPerLiter: unit = .millimolesPerLiter
                case .milligramsPerDeciliter: unit = .milligramsPerDeciliter
                default: continue
                }
                glucoseSamples.append(
                    GlucoseSample(
                        id: observation.id,
                        date: observation.startDate,
                        value: value,
                        unit: unit,
                        sourceObservationID: observation.id
                    )
                )

            case .eventStem:
                if let activity, isInactive(observation,
                    horizonMinutes: max(activity.settings.diaMinutes, activity.settings.carbAbsorptionMinutes + Int(CarbohydrateAbsorptionModel.delayMinutes))) {
                    inactiveIDs.append(observation.id)
                    continue
                }
                issues.insert(.unclassifiedEvent)
            }
        }

        if let window, (explicitlyReviewedBasal || (activity != nil && trustworthyClock)), !invalidBasalObservation,
           !issues.contains(.invalidTimeAxis), !issues.contains(.invalidBasalAxis),
           BasalCoverageValidator.isComplete(basalSegments, in: window,
               observedStart: analysisRun.calibration.timeStart) {
            // Resolve only the effective coverage issue; immutable raw quality stays intact.
            issues.remove(.incompleteBasalPath)
        }

        return EffectiveTherapyData(
            basalSegments: basalSegments.sorted(by: Self.sortIntervals),
            boluses: boluses.sorted(by: Self.sortInsulinEvents),
            carbohydrates: carbohydrates.sorted(by: Self.sortCarbohydrateEvents),
            glucoseSamples: glucoseSamples.sorted(by: Self.sortGlucoseSamples),
            unresolvedIssues: issues,
            sourceAnalysisRunID: analysisRun.id,
            sourceCorrectionRevisionID: applicableRevisions.last?.id,
            observedHistoryMinutes: analysisRun.calibration.timeEnd.timeIntervalSince(analysisRun.calibration.timeStart) / 60,
            inactiveUncertainObservationIDs: activity == nil ? nil : inactiveIDs.sorted { $0.uuidString < $1.uuidString },
            activityAssessment: activity.map { ActivityAssessment(referenceDate: $0.date, settings: $0.settings) }
        )
    }

    private func issues(from analysisRun: AnalysisRun) -> Set<CriticalDataIssue> {
        let quality = analysisRun.quality
        func hasLocatedAmountIssue(kind: ObservationKind, unit: ObservationUnit) -> Bool {
            analysisRun.observations.contains { observation in
                observation.kind == kind && (
                    observation.amountState != .known
                    || observation.amount.map { $0.isFinite && $0 >= 0 } != true
                    || observation.unit != unit
                )
            }
        }
        var result = Set<CriticalDataIssue>()
        if quality.clockValidated == false { result.insert(.invalidTimeAxis) }
        if quality.basalCoverage < 0.99 {
            result.insert(.incompleteBasalPath)
        }
        for blocker in quality.blockers {
            switch blocker {
            case .invalidTimeAxis: result.insert(.invalidTimeAxis)
            case .invalidBasalAxis: result.insert(.invalidBasalAxis)
            case .incompleteBasalPath: result.insert(.incompleteBasalPath)
            // Located observation issues are recomputed after applying the
            // overlay. Immutable raw flags must not undo a confirmed correction.
            // An unlocalized quality warning still blocks: no data is invented.
            case .unknownInsulinAmount:
                if quality.eventIssuesLocalized == false || !hasLocatedAmountIssue(kind: .bolus, unit: .insulinUnits) {
                    result.insert(.unknownBolusAmount)
                }
            case .unknownCarbohydrateAmount:
                if quality.eventIssuesLocalized == false || !hasLocatedAmountIssue(kind: .carbohydrate, unit: .grams) {
                    result.insert(.unknownCarbohydrateAmount)
                }
            case .unclassifiedEvent:
                if quality.eventIssuesLocalized == false || !analysisRun.observations.contains(where: { $0.kind == .eventStem }) {
                    result.insert(.unclassifiedEvent)
                }
            case .corruptAsset:
                result.insert(.invalidTimeAxis)
                result.insert(.invalidBasalAxis)
            }
        }
        return result
    }

    private static func sortIntervals(_ lhs: BasalSegment, _ rhs: BasalSegment) -> Bool {
        if lhs.startDate == rhs.startDate { return lhs.id.uuidString < rhs.id.uuidString }
        return lhs.startDate < rhs.startDate
    }

    private static func sortInsulinEvents(_ lhs: InsulinEvent, _ rhs: InsulinEvent) -> Bool {
        if lhs.date == rhs.date { return lhs.id.uuidString < rhs.id.uuidString }
        return lhs.date < rhs.date
    }

    private static func sortCarbohydrateEvents(
        _ lhs: CarbohydrateEvent,
        _ rhs: CarbohydrateEvent
    ) -> Bool {
        if lhs.date == rhs.date { return lhs.id.uuidString < rhs.id.uuidString }
        return lhs.date < rhs.date
    }

    private static func sortGlucoseSamples(_ lhs: GlucoseSample, _ rhs: GlucoseSample) -> Bool {
        if lhs.date == rhs.date { return lhs.id.uuidString < rhs.id.uuidString }
        return lhs.date < rhs.date
    }
}
