import Foundation

public enum SimulationCalculator {
    /// Insulin-need adjustments among the events, for the glucose prediction.
    public static func adjustments(in events: [SimulationEvent]) -> [InsulinNeedAdjustment] {
        events.compactMap { event in
            if case .insulinNeed(let adjustment) = event { return adjustment }
            return nil
        }
    }


    public static func applying(
        events: [SimulationEvent],
        to data: EffectiveTherapyData
    ) -> EffectiveTherapyData {
        var boluses = data.boluses
        var carbohydrates = data.carbohydrates
        for event in events {
            switch event {
            case .bolus(let insulin): boluses.append(insulin)
            case .carbohydrate(let carbohydrate): carbohydrates.append(carbohydrate)
            // Changes sensitivity for the prediction only; no therapy data.
            case .insulinNeed: break
            }
        }
        return EffectiveTherapyData(
            basalSegments: data.basalSegments,
            boluses: boluses.sorted { $0.date < $1.date },
            carbohydrates: carbohydrates.sorted { $0.date < $1.date },
            glucoseSamples: data.glucoseSamples,
            unresolvedIssues: data.unresolvedIssues,
            sourceAnalysisRunID: data.sourceAnalysisRunID,
            sourceCorrectionRevisionID: data.sourceCorrectionRevisionID,
            observedHistoryMinutes: data.observedHistoryMinutes,
            inactiveUncertainObservationIDs: data.inactiveUncertainObservationIDs,
            activityAssessment: data.activityAssessment
        )
    }
}
