import Foundation

public struct DefaultEffectiveDataReducer: EffectiveDataReducer {
    public init() {}

    public func reduce(
        analysisRun: AnalysisRun,
        revisions: [CorrectionRevision]
    ) throws -> EffectiveTherapyData {
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
                    observations[observation.id] = observation
                case .update(let targetID, let replacement):
                    guard observations[targetID] != nil, replacement.id == targetID else {
                        throw EffectiveDataError.invalidCorrectionTarget(targetID)
                    }
                    observations[targetID] = replacement
                case .delete(let targetID):
                    guard observations.removeValue(forKey: targetID) != nil else {
                        throw EffectiveDataError.invalidCorrectionTarget(targetID)
                    }
                }
            }
        }

        var basalSegments: [BasalSegment] = []
        var boluses: [InsulinEvent] = []
        var carbohydrates: [CarbohydrateEvent] = []
        var glucoseSamples: [GlucoseSample] = []
        var issues = issues(from: analysisRun)

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
                issues.insert(.unclassifiedEvent)
            }
        }

        return EffectiveTherapyData(
            basalSegments: basalSegments.sorted(by: Self.sortIntervals),
            boluses: boluses.sorted(by: Self.sortInsulinEvents),
            carbohydrates: carbohydrates.sorted(by: Self.sortCarbohydrateEvents),
            glucoseSamples: glucoseSamples.sorted(by: Self.sortGlucoseSamples),
            unresolvedIssues: issues,
            sourceAnalysisRunID: analysisRun.id,
            sourceCorrectionRevisionID: applicableRevisions.last?.id,
            observedHistoryMinutes: analysisRun.calibration.timeEnd.timeIntervalSince(analysisRun.calibration.timeStart) / 60
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
                if !hasLocatedAmountIssue(kind: .bolus, unit: .insulinUnits) {
                    result.insert(.unknownBolusAmount)
                }
            case .unknownCarbohydrateAmount:
                if !hasLocatedAmountIssue(kind: .carbohydrate, unit: .grams) {
                    result.insert(.unknownCarbohydrateAmount)
                }
            case .unclassifiedEvent:
                if !analysisRun.observations.contains(where: { $0.kind == .eventStem }) {
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
